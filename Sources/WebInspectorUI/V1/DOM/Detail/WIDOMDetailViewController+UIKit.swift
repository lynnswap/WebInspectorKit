import WebInspectorEngine
import WebInspectorRuntime
import ObservationBridge

#if canImport(UIKit)
import UIKit
import SwiftUI

private protocol DiffableStableID: Hashable, Sendable {}

@MainActor
public final class WIDOMDetailViewController: UICollectionViewController {
    private struct SectionIdentifier: Hashable, Sendable {
        let index: Int
        let title: String
    }

    private enum SectionKey: String, Hashable, Sendable {
        case element
        case selector
        case attributes
    }

    fileprivate enum ItemStableKey: DiffableStableID {
        case element
        case selector
        case attribute(nodeID: DOMNodeModel.ID, name: String)
        case emptyAttribute
    }

    fileprivate struct ItemStableID: DiffableStableID {
        let key: ItemStableKey
    }

    private struct ItemIdentifier: Hashable, Sendable {
        let stableID: ItemStableID
        let selectionGeneration: UInt64
    }

    private struct DetailSection {
        let key: SectionKey
        let title: String
        let rows: [DetailRow]
    }

    private enum DetailRow {
        case element
        case selector
        case attribute(nodeID: DOMNodeModel.ID, name: String)
        case emptyAttribute
    }

    fileprivate enum ItemPayload {
        case element(preview: String)
        case selector(path: String)
        case attribute(name: String, value: String)
        case emptyAttribute
    }

    private struct RenderSection {
        let sectionIdentifier: SectionIdentifier
        let stableIDs: [ItemStableID]
    }

    private let inspector: WIDOMInspector
    private let showsNavigationControls: Bool
    private var hasStartedObservingState = false
    private var stateObservationHandles: Set<ObservationHandle> = []
    private var documentStoreObservationHandles: Set<ObservationHandle> = []
    private var selectedEntryObservationHandles: Set<ObservationHandle> = []
    private var sections: [DetailSection] = []
    private var needsSnapshotReloadOnNextAppearance = false
    private var pendingReloadDataTask: Task<Void, Never>?
    private var selectedEntryRenderGeneration: UInt64 = 0

#if DEBUG
    private(set) var snapshotApplyCountForTesting = 0
#endif

    private lazy var dataSource = makeDataSource()

    private lazy var pickItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: pickSymbolName),
            style: .plain,
            target: self,
            action: #selector(toggleSelectionMode)
        )
        item.accessibilityIdentifier = "WI.DOM.PickButton"
        return item
    }()

    private lazy var errorItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "exclamationmark.circle"),
            style: .plain,
            target: self,
            action: #selector(presentCurrentErrorMessage)
        )
        item.accessibilityIdentifier = "WI.DOM.ErrorButton"
        return item
    }()

    public init(inspector: WIDOMInspector, showsNavigationControls: Bool = true) {
        self.inspector = inspector
        self.showsNavigationControls = showsNavigationControls
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        pendingReloadDataTask?.cancel()
        stateObservationHandles.removeAll()
        documentStoreObservationHandles.removeAll()
        selectedEntryObservationHandles.removeAll()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        collectionView.collectionViewLayout = makeLayout()
        setupNavigationItems()

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.scheduleNavigationControlsUpdate()
            self.scheduleStructureUpdate(forceSnapshotUpdate: true)
        }

        startObservingStateIfNeeded()
        updateNavigationControls()
        handleSelectedNodeChange()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flushPendingSnapshotUpdateIfNeeded()
    }

    public override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    private var pickSymbolName: String {
        traitCollection.horizontalSizeClass == .compact ? "viewfinder.circle" : "scope"
    }

    private func setupNavigationItems() {
        guard showsNavigationControls else {
            navigationItem.rightBarButtonItems = nil
            return
        }
        navigationItem.rightBarButtonItems = currentRightBarButtonItems()
    }

    private func startObservingStateIfNeeded() {
        guard hasStartedObservingState == false else {
            return
        }
        hasStartedObservingState = true

        inspector.observe(\.hasPageWebView) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        .store(in: &stateObservationHandles)

        inspector.observe(\.isPageReadyForSelection) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        .store(in: &stateObservationHandles)

        inspector.observe(\.isSelectingElement) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        .store(in: &stateObservationHandles)

        inspector.observe(\.document) { [weak self] document in
            guard let self else {
                return
            }
            self.documentStoreObservationHandles.removeAll()
            document.observe(\.selectedNode) { [weak self] _ in
                self?.scheduleNavigationControlsUpdate()
                self?.handleSelectedNodeChange()
            }
            .store(in: &self.documentStoreObservationHandles)
            document.observe(\.errorMessage) { [weak self] _ in
                self?.scheduleNavigationControlsUpdate()
            }
            .store(in: &self.documentStoreObservationHandles)
            self.scheduleNavigationControlsUpdate()
            self.handleSelectedNodeChange()
        }
        .store(in: &stateObservationHandles)
    }

    private func makeSecondaryMenu() -> UIMenu {
        let hasSelection = inspector.document.selectedNode != nil
        let hasPageWebView = inspector.hasPageWebView

        return DOMSecondaryMenuBuilder.makeMenu(
            hasSelection: hasSelection,
            hasPageWebView: hasPageWebView,
            canReloadInspector: inspector.isPageReadyForSelection,
            onCopyHTML: { [weak self] in
                self?.copySelectedHTML()
            },
            onCopySelectorPath: { [weak self] in
                self?.copySelectedSelectorPath()
            },
            onCopyXPath: { [weak self] in
                self?.copySelectedXPath()
            },
            onReloadInspector: { [weak self] in
                self?.reloadDocument()
            },
            onReloadPage: { [weak self] in
                guard let self else { return }
                Task {
                    try? await self.inspector.reloadPage()
                }
            },
            onDeleteNode: { [weak self] in
                self?.deleteNode()
            }
        )
    }

    private func scheduleNavigationControlsUpdate() {
        updateNavigationControls()
    }

    private func scheduleStructureUpdate(forceSnapshotUpdate: Bool = false) {
        reconcileSectionStructure(forceSnapshotUpdate: forceSnapshotUpdate)
    }

    private func updateNavigationControls() {
        if showsNavigationControls {
            navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] completion in
                completion((self?.makeSecondaryMenu() ?? UIMenu()).children)
            }
            navigationItem.rightBarButtonItems = currentRightBarButtonItems()
            pickItem.isEnabled = inspector.isPageReadyForSelection
            pickItem.image = UIImage(systemName: pickSymbolName)
            pickItem.tintColor = inspector.isSelectingElement ? .systemBlue : .label
            errorItem.tintColor = .systemOrange
        } else {
            navigationItem.additionalOverflowItems = nil
        }
    }

    private func currentRightBarButtonItems() -> [UIBarButtonItem] {
        var items = [pickItem]
        if let errorMessage = inspector.document.errorMessage,
           !errorMessage.isEmpty {
            items.append(errorItem)
        }
        return items
    }

    private func handleSelectedNodeChange() {
        selectedEntryObservationHandles.removeAll()
        selectedEntryRenderGeneration &+= 1

        guard let selectedEntry = inspector.document.selectedNode else {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = wiLocalized("dom.element.select_prompt")
            configuration.secondaryText = wiLocalized("dom.element.hint")
            configuration.image = UIImage(systemName: "cursorarrow.rays")
            contentUnavailableConfiguration = configuration
            collectionView.isHidden = true
            sections = []
            requestSnapshotUpdate(animatingDifferences: true, force: true)
            return
        }

        contentUnavailableConfiguration = nil
        collectionView.isHidden = false
        sections = makeSections()
        startObservingSelectedEntry(selectedEntry)
        requestSnapshotUpdate(animatingDifferences: true, force: true)
    }

    private func handleSelectedNodeProjectionEvent() {
        handleSelectedNodeChange()
    }

    private func startObservingSelectedEntry(_ entry: DOMNodeModel) {
        entry.observe(
            [\.attributes],
            onChange: { [weak self, weak entry] in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.document.selectedNode === entry else {
                    return
                }
                self.scheduleStructureUpdate()
            },
            isolation: MainActor.shared
        )
        .store(in: &selectedEntryObservationHandles)
    }

    private func reconcileSectionStructure(forceSnapshotUpdate: Bool = false) {
        guard inspector.document.selectedNode != nil else {
            handleSelectedNodeChange()
            return
        }

        let updatedSections = makeSections()
        let structureChanged = forceSnapshotUpdate || hasSectionStructureChanged(from: sections, to: updatedSections)
        sections = updatedSections

        guard structureChanged else {
            return
        }
        requestSnapshotUpdate(animatingDifferences: true, force: forceSnapshotUpdate)
    }

    private func makeLayout() -> UICollectionViewLayout {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfiguration.showsSeparators = true
        listConfiguration.headerMode = .supplementary

        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: listConfiguration, layoutEnvironment: environment)
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(44)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            header.pinToVisibleBounds = true
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    private func makeSections() -> [DetailSection] {
        guard let selected = inspector.document.selectedNode else {
            return []
        }

        let elementSection = DetailSection(
            key: .element,
            title: wiLocalized("dom.element.section.element"),
            rows: [.element]
        )
        let selectorSection = DetailSection(
            key: .selector,
            title: wiLocalized("dom.element.section.selector"),
            rows: [.selector]
        )
        let attributeRows: [DetailRow] = selected.attributes.isEmpty
            ? [.emptyAttribute]
            : selected.attributes.map { .attribute(nodeID: selected.id, name: $0.name) }
        let attributeSection = DetailSection(
            key: .attributes,
            title: wiLocalized("dom.element.section.attributes"),
            rows: attributeRows
        )

        return [elementSection, selectorSection, attributeSection]
    }

    private func defaultPreview(for entry: DOMNodeModel) -> String {
        switch entry.nodeType {
        case .text:
            return entry.nodeValue
        case .comment:
            return "<!-- \(entry.nodeValue) -->"
        default:
            let name = entry.localName.isEmpty ? entry.nodeName : entry.localName
            let attributes = entry.attributes.map { attribute in
                "\(attribute.name)=\"\(attribute.value)\""
            }.joined(separator: " ")
            let suffix = attributes.isEmpty ? "" : " \(attributes)"
            return "<\(name)\(suffix)>"
        }
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier> {
        let listCellRegistration = UICollectionView.CellRegistration<DOMObservingListCell, ItemIdentifier> { [weak self] cell, _, item in
            self?.configureListCell(cell, item: item)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard
                let self,
                let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            else {
                return
            }
            var configuration = UIListContentConfiguration.header()
            configuration.text = section.title
            header.contentConfiguration = configuration
        }

        let dataSource = UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: listCellRegistration,
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

    private func applySnapshot(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>,
        animatingDifferences: Bool
    ) {
        pendingReloadDataTask?.cancel()
#if DEBUG
        snapshotApplyCountForTesting += 1
#endif
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func applySnapshotUsingReloadData(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>
    ) {
        pendingReloadDataTask?.cancel()
        pendingReloadDataTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.pendingReloadDataTask = nil
            }
            guard !Task.isCancelled else {
                return
            }
#if DEBUG
            self.snapshotApplyCountForTesting += 1
#endif
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
        }
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier> {
        let renderSections = makeRenderSections(for: sections)
        let allStableIDs = renderSections.flatMap(\.stableIDs)
        precondition(
            allStableIDs.count == Set(allStableIDs).count,
            "Duplicate diffable IDs detected in WIDOMDetailViewController"
        )

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        for renderSection in renderSections {
            snapshot.appendSections([renderSection.sectionIdentifier])
            snapshot.appendItems(
                renderSection.stableIDs.map { stableID in
                    makeItemIdentifier(
                        stableID: stableID,
                        selectionGeneration: selectedEntryRenderGeneration
                    )
                },
                toSection: renderSection.sectionIdentifier
            )
        }
        return snapshot
    }

    private var isCollectionViewVisible: Bool {
        isViewLoaded && view.window != nil
    }

    private func requestSnapshotUpdate(animatingDifferences: Bool, force: Bool = false) {
        guard isViewLoaded else {
            needsSnapshotReloadOnNextAppearance = true
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        let snapshot = makeSnapshot()
        if !isCollectionViewVisible {
            applySnapshotUsingReloadData(snapshot)
            return
        }
        guard force || snapshotStructureDiffers(from: dataSource.snapshot(), to: snapshot) else {
            return
        }
        if force {
            applySnapshotUsingReloadData(snapshot)
            return
        }
        applySnapshot(snapshot, animatingDifferences: animatingDifferences)
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        applySnapshotUsingReloadData(makeSnapshot())
    }

    private func makeRenderSections(for sections: [DetailSection]) -> [RenderSection] {
        sections.enumerated().map { sectionIndex, section in
            let sectionIdentifier = SectionIdentifier(index: sectionIndex, title: section.title)
            let stableIDs = section.rows.map { row in itemStableID(for: row) }
            return RenderSection(sectionIdentifier: sectionIdentifier, stableIDs: stableIDs)
        }
    }

    private func hasSectionStructureChanged(from oldSections: [DetailSection], to newSections: [DetailSection]) -> Bool {
        let oldRenderSections = makeRenderSections(for: oldSections)
        let newRenderSections = makeRenderSections(for: newSections)
        guard oldRenderSections.count == newRenderSections.count else {
            return true
        }

        return zip(oldRenderSections, newRenderSections).contains { oldSection, newSection in
            oldSection.sectionIdentifier != newSection.sectionIdentifier || oldSection.stableIDs != newSection.stableIDs
        }
    }

    private func snapshotStructureDiffers(
        from current: NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>,
        to proposed: NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>
    ) -> Bool {
        current.sectionIdentifiers != proposed.sectionIdentifiers || current.itemIdentifiers != proposed.itemIdentifiers
    }

    private func makeItemIdentifier(
        stableID: ItemStableID,
        selectionGeneration: UInt64
    ) -> ItemIdentifier {
        ItemIdentifier(stableID: stableID, selectionGeneration: selectionGeneration)
    }

    private func itemStableID(for row: DetailRow) -> ItemStableID {
        switch row {
        case .element:
            return ItemStableID(key: .element)
        case .selector:
            return ItemStableID(key: .selector)
        case let .attribute(nodeID, name):
            return ItemStableID(key: .attribute(nodeID: nodeID, name: name))
        case .emptyAttribute:
            return ItemStableID(key: .emptyAttribute)
        }
    }

    private func payload(for stableID: ItemStableID) -> ItemPayload? {
        guard let selectedEntry = inspector.document.selectedNode else {
            return nil
        }

        switch stableID.key {
        case .element:
            let previewText = selectedEntry.preview.isEmpty ? defaultPreview(for: selectedEntry) : selectedEntry.preview
            return .element(preview: previewText)
        case .selector:
            return .selector(path: selectedEntry.selectorPath)
        case let .attribute(nodeID, name):
            guard selectedEntry.id == nodeID,
                  let value = selectedEntry.attributes.first(where: { $0.name == name })?.value else {
                return nil
            }
            return .attribute(name: name, value: value)
        case .emptyAttribute:
            return .emptyAttribute
        }
    }

    private func configureListCell(_ cell: DOMObservingListCell, item: ItemIdentifier) {
        cell.configure(
            stableID: item.stableID,
            entry: inspector.document.selectedNode,
            payloadProvider: { [weak self] stableID in
                self?.payload(for: stableID)
            }
        )
    }

    @objc
    private func toggleSelectionMode() {
        inspector.requestSelectionModeToggle()
        updateNavigationControls()
    }

    @objc
    private func presentCurrentErrorMessage() {
        guard let errorMessage = inspector.document.errorMessage,
              !errorMessage.isEmpty else {
            return
        }
        WIDOMRuntimeErrorPresenter.present(
            message: errorMessage,
            from: errorItem,
            in: self
        )
    }

    @objc
    private func reloadDocument() {
        let inspector = inspector
        Task {
            try? await inspector.reloadDocument()
        }
    }

    @objc
    private func deleteNode() {
        let inspector = inspector
        let undoManager = undoManager
        Task {
            try? await inspector.deleteSelection(undoManager: undoManager)
        }
    }

    private func copySelectedHTML() {
        let inspector = inspector
        Task.immediateIfAvailable {
            do {
                let text = try await inspector.copySelectedHTML()
                guard !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            } catch {
                return
            }
        }
    }

    private func copySelectedSelectorPath() {
        let inspector = inspector
        Task.immediateIfAvailable {
            do {
                let text = try await inspector.copySelectedSelectorPath()
                guard !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            } catch {
                return
            }
        }
    }

    private func copySelectedXPath() {
        let inspector = inspector
        Task.immediateIfAvailable {
            do {
                let text = try await inspector.copySelectedXPath()
                guard !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            } catch {
                return
            }
        }
    }
}

private final class DOMObservingListCell: UICollectionViewListCell {
    private var observationHandles: Set<ObservationHandle> = []
    private var stableID: WIDOMDetailViewController.ItemStableID?
    private var payloadProvider: (@MainActor (WIDOMDetailViewController.ItemStableID) -> WIDOMDetailViewController.ItemPayload?)?

    override func prepareForReuse() {
        super.prepareForReuse()
        observationHandles.removeAll()
        stableID = nil
        payloadProvider = nil
    }

    func configure(
        stableID: WIDOMDetailViewController.ItemStableID,
        entry: DOMNodeModel?,
        payloadProvider: @escaping @MainActor (WIDOMDetailViewController.ItemStableID) -> WIDOMDetailViewController.ItemPayload?
    ) {
        observationHandles.removeAll()
        self.stableID = stableID
        self.payloadProvider = payloadProvider
        applyCurrentPayload()

        guard let entry else {
            return
        }
        startObserving(entry: entry, stableID: stableID)
    }

    private func startObserving(entry: DOMNodeModel, stableID: WIDOMDetailViewController.ItemStableID) {
        switch stableID.key {
        case .element:
            entry.observe(
                [\.preview, \.nodeType, \.nodeName, \.localName, \.nodeValue, \.attributes],
                onChange: { [weak self] in
                    self?.applyCurrentPayload()
                },
                isolation: MainActor.shared
            )
            .store(in: &observationHandles)
        case .selector:
            entry.observe(
                \.selectorPath,
                onChange: { [weak self] _ in
                    self?.applyCurrentPayload()
                },
                isolation: MainActor.shared
            )
            .store(in: &observationHandles)
        case .attribute, .emptyAttribute:
            entry.observe(
                \.attributes,
                onChange: { [weak self] _ in
                    self?.applyCurrentPayload()
                },
                isolation: MainActor.shared
            )
            .store(in: &observationHandles)
        }
    }

    private func applyCurrentPayload() {
        guard
            let stableID,
            let payload = payloadProvider?(stableID)
        else {
            contentConfiguration = nil
            accessories = []
            return
        }

        var configuration = UIListContentConfiguration.cell()
        accessories = []

        switch payload {
        case let .element(preview):
            configuration.text = preview
            configuration.textProperties.numberOfLines = 0
            configuration.textProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                    weight: .regular
                )
            )
            configuration.textProperties.color = .label
        case let .selector(path):
            configuration.text = path
            configuration.textProperties.numberOfLines = 0
            configuration.textProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                    weight: .regular
                )
            )
            configuration.textProperties.color = .label
        case let .attribute(name, value):
            configuration.text = name
            configuration.secondaryText = value
            configuration.textProperties.color = .secondaryLabel
            configuration.secondaryTextProperties.numberOfLines = 0
            configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                    weight: .regular
                )
            )
            configuration.secondaryTextProperties.color = .label
        case .emptyAttribute:
            configuration.text = wiLocalized("dom.element.attributes.empty")
            configuration.textProperties.color = .secondaryLabel
        }
        contentConfiguration = configuration
    }
}

#if DEBUG
extension WIDOMDetailViewController {
    var isShowingEmptyStateForTesting: Bool {
        contentUnavailableConfiguration != nil && collectionView.isHidden
    }

    func renderedPreviewTextForTesting() -> String? {
        guard
            let item = dataSource.snapshot().itemIdentifiers.first(where: {
                if case .element = $0.stableID.key {
                    return true
                }
                return false
            }),
            case let .element(preview)? = payload(for: item.stableID)
        else {
            return nil
        }
        return preview
    }

    func renderedSelectorTextForTesting() -> String? {
        guard
            let item = dataSource.snapshot().itemIdentifiers.first(where: {
                if case .selector = $0.stableID.key {
                    return true
                }
                return false
            }),
            case let .selector(path)? = payload(for: item.stableID)
        else {
            return nil
        }
        return path
    }

    func renderedAttributeNamesForTesting() -> [String] {
        dataSource.snapshot().itemIdentifiers.compactMap { item in
            guard case let .attribute(_, name) = item.stableID.key else {
                return nil
            }
            return name
        }
    }

    func renderedAttributeValueForTesting(
        nodeID: DOMNodeModel.ID,
        name: String
    ) -> String? {
        guard
            let item = dataSource.snapshot().itemIdentifiers.first(where: {
                guard case let .attribute(itemNodeID, itemName) = $0.stableID.key else {
                    return false
                }
                return itemNodeID == nodeID && itemName == name
            }),
            case let .attribute(_, value)? = payload(for: item.stableID)
        else {
            return nil
        }
        return value
    }
}
#endif

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("DOM Detail Empty") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WIDOMDetailViewController(
                inspector: WIDOMPreviewFixtures.makeInspector(mode: .empty)
            )
        )
    }
}

#Preview("DOM Detail Selected") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WIDOMDetailViewController(
                inspector: WIDOMPreviewFixtures.makeInspector(mode: .selected)
            )
        )
    }
}

#Preview("DOM Detail Attributes") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WIDOMDetailViewController(
                inspector: WIDOMPreviewFixtures.makeInspector(mode: .selectedEditableAttributes)
            )
        )
    }
}
#endif

#endif
