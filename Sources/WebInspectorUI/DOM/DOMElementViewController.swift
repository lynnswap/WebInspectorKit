#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorCore
import WebInspectorRuntime

@MainActor
package final class DOMElementViewController: UIViewController, UICollectionViewDelegate {
    package typealias StyleRefreshAction = @MainActor () async -> Void
    package typealias StyleToggleAction = @MainActor (CSSPropertyIdentifier, Bool) async throws -> Void
    package typealias StyleRefreshAvailability = @MainActor () -> Bool

    private struct ItemIdentifier: Hashable {
        var sectionID: CSSStyleSectionIdentifier
        var propertyIndex: Int
    }

    private struct RefreshRequest: Equatable {
        var identity: CSSNodeStyleIdentity
        var cssRevision: UInt64
        var nodeStylesRevision: UInt64
    }

    private let dom: DOMSession
    private let css: CSSSession?
    private let canRefreshStyles: StyleRefreshAvailability
    private let refreshStylesAction: StyleRefreshAction?
    private let setCSSPropertyAction: StyleToggleAction?
    private let observationScope = ObservationScope()
    private let selectedStylesObservationScope = ObservationScope()
    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeListLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "WebInspector.DOM.Element.Styles"
        collectionView.delegate = self
        collectionView.isHidden = true
        return collectionView
    }()
    private lazy var dataSource = makeDataSource()
    private var activeRefreshRequest: RefreshRequest?
    private var refreshTask: Task<Void, Never>?
    private var pendingTogglePropertyIDs: Set<CSSPropertyIdentifier> = []
    private var toggleTasks: [CSSPropertyIdentifier: Task<Void, Never>] = [:]

    package convenience init(session: InspectorSession) {
        self.init(
            dom: session.dom,
            css: session.css,
            canRefreshStyles: { session.isAttached },
            refreshStylesAction: {
                await session.refreshStylesForSelectedNode()
            },
            setCSSPropertyAction: { propertyID, enabled in
                try await session.setCSSProperty(propertyID, enabled: enabled)
            }
        )
    }

    package convenience init(dom: DOMSession) {
        self.init(
            dom: dom,
            css: nil,
            canRefreshStyles: { false },
            refreshStylesAction: nil,
            setCSSPropertyAction: nil
        )
    }

    package init(
        dom: DOMSession,
        css: CSSSession?,
        canRefreshStyles: @escaping StyleRefreshAvailability,
        refreshStylesAction: StyleRefreshAction?,
        setCSSPropertyAction: StyleToggleAction?
    ) {
        self.dom = dom
        self.css = css
        self.canRefreshStyles = canRefreshStyles
        self.refreshStylesAction = refreshStylesAction
        self.setCSSPropertyAction = setCSSPropertyAction
        super.init(nibName: nil, bundle: nil)
        startObservingDOM()
        startObservingCSS()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
        selectedStylesObservationScope.cancelAll()
        refreshTask?.cancel()
        for task in toggleTasks.values {
            task.cancel()
        }
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        installCollectionView()
        render()
    }

    override package func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        render()
    }

    package func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    private func installCollectionView() {
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func startObservingDOM() {
        dom.observe([\.treeRevision, \.selectionRevision]) { [weak self] in
            self?.render()
        }
        .store(in: observationScope)
    }

    private func startObservingCSS() {
        guard let css else {
            return
        }
        css.observe([\.revision, \.selectedState]) { [weak self] in
            self?.observeSelectedNodeStyles()
            self?.render()
        }
        .store(in: observationScope)
        observeSelectedNodeStyles()
    }

    private func observeSelectedNodeStyles() {
        selectedStylesObservationScope.update {
            guard let selectedNodeStyles = css?.selectedNodeStyles else {
                return
            }
            selectedNodeStyles.observe([\.state, \.revision, \.sections]) { [weak self] in
                self?.render()
            }
            .store(in: selectedStylesObservationScope)
        }
    }

    private static func makeListLayout() -> UICollectionViewLayout {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfiguration.showsSeparators = true
        listConfiguration.headerMode = .supplementary
        return UICollectionViewCompositionalLayout.list(using: listConfiguration)
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<CSSStyleSectionIdentifier, ItemIdentifier> {
        let propertyRegistration = UICollectionView.CellRegistration<DOMElementStylePropertyCell, ItemIdentifier> {
            [weak self] cell, _, item in
            self?.configure(cell, item: item)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            self?.configure(header, sectionIndex: indexPath.section)
        }

        let dataSource = UICollectionViewDiffableDataSource<CSSStyleSectionIdentifier, ItemIdentifier>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: propertyRegistration,
                for: indexPath,
                item: item
            )
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
        return dataSource
    }

    private func render() {
        guard isViewLoaded else {
            return
        }

        guard dom.currentPageRootNode != nil else {
            showUnavailable(
                text: webInspectorLocalized("dom.element.loading", default: "Loading DOM..."),
                secondaryText: nil,
                image: UIImage(systemName: "arrow.clockwise")
            )
            return
        }

        guard let selectedNode = dom.selectedNode else {
            showUnavailable(
                text: webInspectorLocalized("dom.element.select_prompt", default: "Select an element"),
                secondaryText: webInspectorLocalized(
                    "dom.element.hint",
                    default: "Choose a node in the DOM tree to inspect it."
                ),
                image: UIImage(systemName: "cursorarrow.rays")
            )
            return
        }

        guard let css else {
            showUnavailable(
                text: webInspectorLocalized("dom.element.placeholder.title", default: "Element details"),
                secondaryText: displayName(for: selectedNode),
                image: UIImage(systemName: "info.circle")
            )
            return
        }

        switch dom.selectedCSSNodeStyleIdentity() {
        case let .failure(reason):
            let unavailable = unavailableConfiguration(for: reason)
            showUnavailable(text: unavailable.text, secondaryText: unavailable.secondaryText, image: unavailable.image)
        case let .success(identity):
            renderStyles(identity: identity, css: css)
        }
    }

    private func renderStyles(identity: CSSNodeStyleIdentity, css: CSSSession) {
        guard let nodeStyles = css.selectedNodeStyles,
              nodeStyles.identity == identity else {
            requestStyleRefreshIfNeeded(identity: identity, cssRevision: css.revision, nodeStylesRevision: 0)
            showUnavailable(
                text: webInspectorLocalized("dom.element.styles.loading", default: "Loading styles..."),
                secondaryText: nil,
                image: UIImage(systemName: "arrow.clockwise")
            )
            return
        }

        switch nodeStyles.state {
        case .loading:
            showUnavailable(
                text: webInspectorLocalized("dom.element.styles.loading", default: "Loading styles..."),
                secondaryText: nil,
                image: UIImage(systemName: "arrow.clockwise")
            )
        case .loaded:
            showLoadedStyles(nodeStyles)
        case .needsRefresh:
            requestStyleRefreshIfNeeded(
                identity: identity,
                cssRevision: css.revision,
                nodeStylesRevision: nodeStyles.revision
            )
            if hasDisplayableProperties(nodeStyles) {
                showLoadedStyles(nodeStyles)
            } else {
                showUnavailable(
                    text: webInspectorLocalized("dom.element.styles.loading", default: "Loading styles..."),
                    secondaryText: nil,
                    image: UIImage(systemName: "arrow.clockwise")
                )
            }
        case let .unavailable(reason):
            let unavailable = unavailableConfiguration(for: reason)
            showUnavailable(text: unavailable.text, secondaryText: unavailable.secondaryText, image: unavailable.image)
        case let .failed(message):
            showUnavailable(
                text: webInspectorLocalized("dom.element.styles.failed", default: "Couldn’t load styles"),
                secondaryText: message,
                image: UIImage(systemName: "exclamationmark.triangle")
            )
        }
    }

    private func showLoadedStyles(_ nodeStyles: CSSNodeStyles) {
        guard hasDisplayableProperties(nodeStyles) else {
            showUnavailable(
                text: webInspectorLocalized("dom.element.styles.empty", default: "No styles"),
                secondaryText: webInspectorLocalized(
                    "dom.element.styles.empty.description",
                    default: "The selected element has no matched CSS declarations."
                ),
                image: UIImage(systemName: "curlybraces")
            )
            return
        }

        contentUnavailableConfiguration = nil
        collectionView.isHidden = false
        applySnapshot()
    }

    private func showUnavailable(text: String, secondaryText: String?, image: UIImage?) {
        collectionView.isHidden = true
        applyEmptySnapshot()
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = text
        configuration.secondaryText = secondaryText
        configuration.image = image
        contentUnavailableConfiguration = configuration
    }

    private func requestStyleRefreshIfNeeded(
        identity: CSSNodeStyleIdentity,
        cssRevision: UInt64,
        nodeStylesRevision: UInt64
    ) {
        guard canRefreshStyles(),
              let refreshStylesAction else {
            return
        }

        let request = RefreshRequest(
            identity: identity,
            cssRevision: cssRevision,
            nodeStylesRevision: nodeStylesRevision
        )
        guard activeRefreshRequest != request else {
            return
        }

        refreshTask?.cancel()
        activeRefreshRequest = request
        refreshTask = Task { @MainActor [weak self] in
            await refreshStylesAction()
            guard let self else {
                return
            }
            let shouldRender = self.didPublishStyleUpdate(after: request)
            if self.activeRefreshRequest == request {
                self.activeRefreshRequest = nil
            }
            self.refreshTask = nil
            if shouldRender {
                self.render()
            }
        }
    }

    private func didPublishStyleUpdate(after request: RefreshRequest) -> Bool {
        guard let css else {
            return false
        }
        if css.revision != request.cssRevision {
            return true
        }
        guard let nodeStyles = css.selectedNodeStyles,
              nodeStyles.identity == request.identity else {
            return false
        }
        return nodeStyles.revision != request.nodeStylesRevision
            || nodeStyles.state != .needsRefresh
    }

    private func hasDisplayableProperties(_ nodeStyles: CSSNodeStyles) -> Bool {
        nodeStyles.sections.contains { $0.style.cssProperties.isEmpty == false }
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<CSSStyleSectionIdentifier, ItemIdentifier> {
        guard let nodeStyles = css?.selectedNodeStyles else {
            return NSDiffableDataSourceSnapshot<CSSStyleSectionIdentifier, ItemIdentifier>()
        }

        var snapshot = NSDiffableDataSourceSnapshot<CSSStyleSectionIdentifier, ItemIdentifier>()
        for section in nodeStyles.sections where section.style.cssProperties.isEmpty == false {
            snapshot.appendSections([section.id])
            snapshot.appendItems(
                section.style.cssProperties.indices.map { ItemIdentifier(sectionID: section.id, propertyIndex: $0) },
                toSection: section.id
            )
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        return snapshot
    }

    private func applySnapshot() {
        guard isViewLoaded else {
            return
        }
        Task { @MainActor in
            let snapshot = self.makeSnapshot()
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
        }
    }

    private func applyEmptySnapshot() {
        guard isViewLoaded else {
            return
        }
        Task { @MainActor in
            await self.dataSource.apply(
                NSDiffableDataSourceSnapshot<CSSStyleSectionIdentifier, ItemIdentifier>(),
                animatingDifferences: false
            )
        }
    }

    private func configure(_ cell: DOMElementStylePropertyCell, item: ItemIdentifier) {
        guard let section = section(for: item.sectionID),
              let property = property(for: item, in: section) else {
            cell.clear()
            return
        }
        cell.bind(
            property: property,
            section: section,
            isPending: property.id.map { pendingTogglePropertyIDs.contains($0) } ?? false,
            canToggle: setCSSPropertyAction != nil,
            toggleAction: { [weak self] propertyID, enabled in
                self?.toggleProperty(propertyID, enabled: enabled)
            }
        )
    }

    private func configure(_ header: UICollectionViewListCell, sectionIndex: Int) {
        guard let sectionID = dataSource.sectionIdentifier(for: sectionIndex),
              let section = section(for: sectionID) else {
            header.contentConfiguration = nil
            header.accessibilityLabel = nil
            return
        }

        var configuration = UIListContentConfiguration.header()
        configuration.text = section.title
        configuration.secondaryText = sourceDescription(for: section)
        configuration.textProperties.numberOfLines = 2
        configuration.secondaryTextProperties.numberOfLines = 1
        configuration.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        header.contentConfiguration = configuration
        header.accessibilityIdentifier = "WebInspector.DOM.Element.StyleSection"
        header.accessibilityLabel = section.title
        header.accessibilityValue = configuration.secondaryText
    }

    private func toggleProperty(_ propertyID: CSSPropertyIdentifier, enabled: Bool) {
        guard pendingTogglePropertyIDs.contains(propertyID) == false,
              let setCSSPropertyAction else {
            return
        }

        pendingTogglePropertyIDs.insert(propertyID)
        applySnapshot()
        let task = Task { @MainActor [weak self] in
            defer {
                self?.pendingTogglePropertyIDs.remove(propertyID)
                self?.toggleTasks[propertyID] = nil
                self?.render()
            }
            do {
                try await setCSSPropertyAction(propertyID, enabled)
            } catch {
                self?.presentToggleFailure(error)
            }
        }
        toggleTasks[propertyID] = task
    }

    private func presentToggleFailure(_ error: any Error) {
        guard presentedViewController == nil else {
            return
        }
        let alert = UIAlertController(
            title: webInspectorLocalized("dom.element.styles.toggle_failed", default: "Couldn’t update property"),
            message: String(describing: error),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: webInspectorLocalized("ok", default: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func section(for id: CSSStyleSectionIdentifier) -> CSSStyleSection? {
        css?.selectedNodeStyles?.sections.first { $0.id == id }
    }

    private func property(for item: ItemIdentifier, in section: CSSStyleSection) -> CSSProperty? {
        guard section.style.cssProperties.indices.contains(item.propertyIndex) else {
            return nil
        }
        return section.style.cssProperties[item.propertyIndex]
    }

    private func sourceDescription(for section: CSSStyleSection) -> String? {
        guard let sourceURL = section.subtitle,
              sourceURL.isEmpty == false else {
            return nil
        }
        guard let sourceLine = section.rule?.sourceLine,
              sourceLine > 0 else {
            return sourceURL
        }
        return "\(sourceURL):\(sourceLine)"
    }

    private func unavailableConfiguration(
        for reason: CSSNodeStylesUnavailableReason
    ) -> (text: String, secondaryText: String?, image: UIImage?) {
        switch reason {
        case .noSelection:
            return (
                webInspectorLocalized("dom.element.select_prompt", default: "Select an element"),
                webInspectorLocalized(
                    "dom.element.hint",
                    default: "Choose a node in the DOM tree to inspect it."
                ),
                UIImage(systemName: "cursorarrow.rays")
            )
        case .nonElementNode:
            return (
                webInspectorLocalized("dom.element.styles.unavailable", default: "Styles unavailable"),
                webInspectorLocalized(
                    "dom.element.styles.non_element",
                    default: "Select an element node to inspect CSS styles."
                ),
                UIImage(systemName: "curlybraces")
            )
        case .staleNode:
            return (
                webInspectorLocalized("dom.element.styles.unavailable", default: "Styles unavailable"),
                webInspectorLocalized(
                    "dom.element.styles.stale_node",
                    default: "The selected node is no longer available."
                ),
                UIImage(systemName: "exclamationmark.triangle")
            )
        case .cssUnavailableForTarget:
            return (
                webInspectorLocalized("dom.element.styles.unavailable", default: "Styles unavailable"),
                webInspectorLocalized(
                    "dom.element.styles.css_unavailable",
                    default: "This target does not expose CSS styles."
                ),
                UIImage(systemName: "curlybraces")
            )
        }
    }

    private func displayName(for node: DOMNode) -> String {
        switch node.nodeType {
        case .element:
            let name = node.localName.isEmpty ? node.nodeName.lowercased() : node.localName
            return "<\(name)>"
        case .text:
            return "#text"
        case .comment:
            return "<!-- \(node.nodeValue) -->"
        case .documentType:
            return "<!DOCTYPE \(node.nodeName)>"
        case .document:
            return "#document"
        case .documentFragment:
            return "#document-fragment"
        default:
            return node.nodeName
        }
    }
}

#if DEBUG
extension DOMElementViewController {
    package var collectionViewForTesting: UICollectionView {
        collectionView
    }
}
#endif

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("DOM Element") {
    let dom = DOMPreviewFixtures.makeDOMSession()
    if let root = dom.currentPageRootNode,
       let body = dom.visibleDOMTreeChildren(of: root).last,
       let selectedNode = dom.visibleDOMTreeChildren(of: body).first {
        dom.selectNode(selectedNode.id)
    }
    return UINavigationController(rootViewController: DOMElementViewController(dom: dom))
}
#endif
#endif
