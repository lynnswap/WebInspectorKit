import WebInspectorKitCore
import ObservationsCompat

#if canImport(UIKit)
import UIKit
import SwiftUI

private protocol DiffableStableID: Hashable, Sendable {}
private protocol DiffableCellKind: Hashable, Sendable {}

private struct DiffableRenderState<ID: DiffableStableID, Payload> {
    let payloadByID: [ID: Payload]
    let revisionByID: [ID: Int]
}

private struct ElementAttributeEditingKey: Hashable {
    let nodeID: Int?
    let name: String
}

@MainActor
private protocol ElementAttributeEditorCellDelegate: AnyObject {
    func elementAttributeEditorCellDidBeginEditing(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    )
    func elementAttributeEditorCellDidChangeDraft(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    )
    func elementAttributeEditorCellDidCommitValue(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    )
    func elementAttributeEditorCellDidEndEditing(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    )
    func elementAttributeEditorCellNeedsRelayout(_ cell: ElementAttributeEditorCell)
}

@MainActor
final class ElementDetailsTabViewController: UICollectionViewController {
    private struct SectionIdentifier: Hashable, Sendable {
        let index: Int
        let title: String
    }

    private enum SectionKey: String, Hashable, Sendable {
        case element
        case selector
        case styles
        case attributes
    }

    private enum ItemCellKind: String, DiffableCellKind {
        case list
        case attributeEditor
    }

    private enum StyleMetaKind: String, Hashable, Sendable {
        case loading
        case empty
        case truncated
        case blockedStylesheets
    }

    private struct StyleRuleSignature: Hashable, Sendable {
        let selectorText: String
        let sourceLabel: String
    }

    private enum ItemStableKey: DiffableStableID {
        case element
        case selector
        case styleRule(signature: StyleRuleSignature, ordinal: Int)
        case styleMeta(kind: StyleMetaKind)
        case attribute(nodeID: Int?, name: String)
        case emptyAttribute
    }

    private struct ItemStableID: DiffableStableID {
        let key: ItemStableKey
        let cellKind: ItemCellKind
    }

    private struct ItemIdentifier: Hashable, Sendable {
        let stableID: ItemStableID
    }

    private struct DetailSection {
        let key: SectionKey
        let title: String
        let rows: [DetailRow]
    }

    private enum DetailRow {
        case element(preview: String)
        case selector(path: String)
        case styleRule(signature: StyleRuleSignature, selector: String, detail: String)
        case styleMeta(kind: StyleMetaKind, message: String)
        case attribute(nodeID: Int?, name: String, value: String)
        case emptyAttribute
    }

    private enum ItemPayload {
        case element(preview: String)
        case selector(path: String)
        case styleRule(selector: String, detail: String)
        case styleMeta(message: String)
        case attribute(nodeID: Int?, name: String, value: String)
        case emptyAttribute
    }

    private struct RenderSection {
        let sectionIdentifier: SectionIdentifier
        let stableIDs: [ItemStableID]
    }

    private let inspector: WIDOMTabViewModel
    private let showsNavigationControls: Bool
    private var hasStartedObservingState = false
    private let navigationUpdateCoalescer = UIUpdateCoalescer()
    private let contentUpdateCoalescer = UIUpdateCoalescer()
    private var sections: [DetailSection] = []
    private var editingAttributeKey: ElementAttributeEditingKey?
    private var editingDraftValue: String?
    private var isInlineEditingActive = false
    private var lastSelectionNodeID: Int?
    private var payloadByStableID: [ItemStableID: ItemPayload] = [:]
    private var revisionByStableID: [ItemStableID: Int] = [:]
    private var attributeRelayoutCoordinator = AttributeEditorRelayoutCoordinator()
    private var needsSnapshotReloadOnNextAppearance = false
    private var pendingReloadDataTask: Task<Void, Never>?

    private lazy var dataSource = makeDataSource()

    private lazy var pickItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: pickSymbolName),
            style: .plain,
            target: self,
            action: #selector(toggleSelectionMode)
        )
    }()

    init(inspector: WIDOMTabViewModel, showsNavigationControls: Bool = true) {
        self.inspector = inspector
        self.showsNavigationControls = showsNavigationControls
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        pendingReloadDataTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        navigationItem.title = ""
        collectionView.collectionViewLayout = makeLayout()
        setupNavigationItems()

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.scheduleNavigationControlsUpdate()
            self.scheduleContentUpdate()
        }

        startObservingStateIfNeeded()

        updateNavigationControls()
        updateContent()
    }

    private var pickSymbolName: String {
        traitCollection.horizontalSizeClass == .compact ? "viewfinder.circle" : "scope"
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        flushPendingAttributeEditorRelayoutIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flushPendingSnapshotUpdateIfNeeded()
    }

    private func setupNavigationItems() {
        guard showsNavigationControls else {
            navigationItem.rightBarButtonItems = nil
            return
        }
        navigationItem.rightBarButtonItems = [pickItem]
    }

    private func startObservingStateIfNeeded() {
        guard hasStartedObservingState == false else {
            return
        }
        hasStartedObservingState = true

        inspector.observe(
            \.hasPageWebView,
            options: WIObservationOptions.dedupe
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        inspector.observe(
            \.isSelectingElement,
            options: WIObservationOptions.dedupe
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        inspector.selection.observe(
            \.nodeId,
            options: WIObservationOptions.dedupe
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
            self?.scheduleContentUpdate()
        }
        inspector.selection.observe(
            \.preview,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleContentUpdate()
        }
        inspector.selection.observe(
            \.selectorPath,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleContentUpdate()
        }
        inspector.selection.observe(
            \.attributes,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleContentUpdate()
        }
        inspector.selection.observe(
            \.matchedStyles,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleContentUpdate()
        }
        inspector.selection.observe(
            \.isLoadingMatchedStyles,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleContentUpdate()
        }
        inspector.selection.observe(
            \.matchedStylesTruncated,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleContentUpdate()
        }
        inspector.selection.observe(
            \.blockedStylesheetCount,
            options: WIObservationOptions.dedupeDebounced
        ) { [weak self] _ in
            self?.scheduleContentUpdate()
        }
    }

    private func makeSecondaryMenu() -> UIMenu {
        let hasSelection = inspector.selection.nodeId != nil
        let hasPageWebView = inspector.hasPageWebView

        return DOMSecondaryMenuBuilder.makeMenu(
            hasSelection: hasSelection,
            hasPageWebView: hasPageWebView,
            onCopyHTML: { [weak self] in
                self?.inspector.copySelection(.html)
            },
            onCopySelectorPath: { [weak self] in
                self?.inspector.copySelection(.selectorPath)
            },
            onCopyXPath: { [weak self] in
                self?.inspector.copySelection(.xpath)
            },
            onReloadInspector: { [weak self] in
                self?.reloadInspector()
            },
            onReloadPage: { [weak self] in
                self?.inspector.session.reloadPage()
            },
            onDeleteNode: { [weak self] in
                self?.deleteNode()
            }
        )
    }

    private func scheduleNavigationControlsUpdate() {
        navigationUpdateCoalescer.schedule { [weak self] in
            self?.updateNavigationControls()
        }
    }

    private func scheduleContentUpdate() {
        contentUpdateCoalescer.schedule { [weak self] in
            self?.updateContent()
        }
    }

    private func updateNavigationControls() {
        if showsNavigationControls {
            navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] completion in
                completion((self?.makeSecondaryMenu() ?? UIMenu()).children)
            }
            pickItem.isEnabled = inspector.hasPageWebView
            pickItem.image = UIImage(systemName: pickSymbolName)
            pickItem.tintColor = inspector.isSelectingElement ? .systemBlue : .label
        } else {
            navigationItem.additionalOverflowItems = nil
        }
    }

    private func updateContent() {
        let currentSelectionNodeID = inspector.selection.nodeId
        if currentSelectionNodeID != lastSelectionNodeID {
            clearInlineEditingState()
            lastSelectionNodeID = currentSelectionNodeID
        }

        if inspector.selection.nodeId == nil {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = wiLocalized("dom.element.select_prompt")
            configuration.secondaryText = wiLocalized("dom.element.hint")
            configuration.image = UIImage(systemName: "cursorarrow.rays")
            contentUnavailableConfiguration = configuration
            collectionView.isHidden = true
            clearInlineEditingState()
            sections = []
        } else {
            contentUnavailableConfiguration = nil
            collectionView.isHidden = false
            sections = makeSections()
        }

        guard !isInlineEditingActive else {
            return
        }
        requestSnapshotUpdate(animatingDifferences: true)
    }

    private func makeLayout() -> UICollectionViewLayout {
        var listConfiguration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        listConfiguration.showsSeparators = true
        listConfiguration.headerMode = .supplementary
        listConfiguration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.trailingSwipeActions(for: indexPath)
        }

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
        guard inspector.selection.nodeId != nil else {
            return []
        }

        let elementSection = DetailSection(
            key: .element,
            title: wiLocalized("dom.element.section.element"),
            rows: [.element(preview: inspector.selection.preview)]
        )

        let selectorSection = DetailSection(
            key: .selector,
            title: wiLocalized("dom.element.section.selector"),
            rows: [.selector(path: inspector.selection.selectorPath)]
        )

        var styleRows: [DetailRow] = []
        if inspector.selection.isLoadingMatchedStyles {
            styleRows.append(.styleMeta(kind: .loading, message: wiLocalized("dom.element.styles.loading")))
        } else if inspector.selection.matchedStyles.isEmpty {
            styleRows.append(.styleMeta(kind: .empty, message: wiLocalized("dom.element.styles.empty")))
        } else {
            for rule in inspector.selection.matchedStyles {
                let declarations = rule.declarations.map { declaration in
                    let importantSuffix = declaration.important ? " !important" : ""
                    return "\(declaration.name): \(declaration.value)\(importantSuffix);"
                }
                var details = declarations.joined(separator: "\n")
                if !rule.sourceLabel.isEmpty {
                    details = "\(rule.sourceLabel)\n\(details)"
                }
                let signature = StyleRuleSignature(
                    selectorText: rule.selectorText,
                    sourceLabel: rule.sourceLabel
                )
                styleRows.append(.styleRule(signature: signature, selector: rule.selectorText, detail: details))
            }
        }
        if inspector.selection.matchedStylesTruncated {
            styleRows.append(.styleMeta(kind: .truncated, message: wiLocalized("dom.element.styles.truncated")))
        }
        if inspector.selection.blockedStylesheetCount > 0 {
            let blocked = "\(inspector.selection.blockedStylesheetCount) \(wiLocalized("dom.element.styles.blocked_stylesheets"))"
            styleRows.append(.styleMeta(kind: .blockedStylesheets, message: blocked))
        }

        let styleSection = DetailSection(
            key: .styles,
            title: wiLocalized("dom.element.section.styles"),
            rows: styleRows
        )

        let attributeRows: [DetailRow]
        if inspector.selection.attributes.isEmpty {
            attributeRows = [.emptyAttribute]
        } else {
            attributeRows = inspector.selection.attributes.map { attribute in
                let key = ElementAttributeEditingKey(nodeID: attribute.nodeId, name: attribute.name)
                let value = editingAttributeKey == key ? (editingDraftValue ?? attribute.value) : attribute.value
                return .attribute(nodeID: attribute.nodeId, name: attribute.name, value: value)
            }
        }

        let attributeSection = DetailSection(
            key: .attributes,
            title: wiLocalized("dom.element.section.attributes"),
            rows: attributeRows
        )

        return [elementSection, selectorSection, styleSection, attributeSection]
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier> {
        let listCellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ItemIdentifier> { [weak self] cell, _, item in
            self?.configureListCell(cell, item: item)
        }
        let attributeCellRegistration = UICollectionView.CellRegistration<ElementAttributeEditorCell, ItemIdentifier> { [weak self] cell, _, item in
            self?.configureAttributeCell(cell, item: item)
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
        ) { [weak self] collectionView, indexPath, item in
            guard let self else {
                return UICollectionViewCell()
            }
            self.attributeRelayoutCoordinator.beginCellDequeue()
            defer {
                self.attributeRelayoutCoordinator.endCellDequeue()
            }
            switch item.stableID.cellKind {
            case .attributeEditor:
                return collectionView.dequeueConfiguredReusableCell(
                    using: attributeCellRegistration,
                    for: indexPath,
                    item: item
                )
            case .list:
                return collectionView.dequeueConfiguredReusableCell(
                    using: listCellRegistration,
                    for: indexPath,
                    item: item
                )
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
        return dataSource
    }

    private func requestAttributeEditorRelayout() {
        attributeRelayoutCoordinator.requestRelayout()
        flushPendingAttributeEditorRelayoutIfNeeded()
    }

    private func flushPendingAttributeEditorRelayoutIfNeeded() {
        guard attributeRelayoutCoordinator.beginRelayoutIfPossible(isViewVisible: collectionView.window != nil) else {
            return
        }

        collectionView.performBatchUpdates(nil) { [weak self] _ in
            guard let self else {
                return
            }
            self.attributeRelayoutCoordinator.finishRelayout()
            self.flushPendingAttributeEditorRelayoutIfNeeded()
        }
    }

    private func applySnapshot(animatingDifferences: Bool) {
        pendingReloadDataTask?.cancel()
        let snapshot = makeSnapshot()
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func applySnapshotUsingReloadData() {
        pendingReloadDataTask?.cancel()
        let snapshot = makeSnapshot()
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
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
            guard !Task.isCancelled else {
                return
            }
        }
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier> {
        let renderSections = makeRenderSections()
        let allStableIDs = renderSections.flatMap(\.stableIDs)
        precondition(
            allStableIDs.count == Set(allStableIDs).count,
            "Duplicate diffable IDs detected in ElementDetailsTabViewController"
        )
        let renderState = makeRenderState(for: renderSections)
        let previousRevisionByStableID = revisionByStableID
        payloadByStableID = renderState.payloadByID
        revisionByStableID = renderState.revisionByID

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        for renderSection in renderSections {
            snapshot.appendSections([renderSection.sectionIdentifier])
            let itemIdentifiers = renderSection.stableIDs.map { stableID in
                ItemIdentifier(stableID: stableID)
            }
            snapshot.appendItems(itemIdentifiers, toSection: renderSection.sectionIdentifier)
        }

        let reconfigured = allStableIDs.compactMap { stableID -> ItemIdentifier? in
            guard
                let previousRevision = previousRevisionByStableID[stableID],
                let nextRevision = renderState.revisionByID[stableID],
                previousRevision != nextRevision
            else {
                return nil
            }
            return ItemIdentifier(stableID: stableID)
        }
        if !reconfigured.isEmpty {
            snapshot.reconfigureItems(reconfigured)
        }
        return snapshot
    }

    private var isCollectionViewVisible: Bool {
        isViewLoaded && view.window != nil
    }

    private func requestSnapshotUpdate(animatingDifferences: Bool) {
        guard isCollectionViewVisible else {
            needsSnapshotReloadOnNextAppearance = true
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        applySnapshot(animatingDifferences: animatingDifferences)
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard !isInlineEditingActive else {
            return
        }
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        applySnapshotUsingReloadData()
    }

    private func makeRenderSections() -> [RenderSection] {
        var styleRuleOccurrences: [StyleRuleSignature: Int] = [:]
        return sections.enumerated().map { sectionIndex, section in
            let sectionIdentifier = SectionIdentifier(index: sectionIndex, title: section.title)
            let stableIDs = section.rows.map { row in
                itemStableID(
                    for: row,
                    styleRuleOccurrences: &styleRuleOccurrences
                )
            }
            return RenderSection(sectionIdentifier: sectionIdentifier, stableIDs: stableIDs)
        }
    }

    private func makeRenderState(for renderSections: [RenderSection]) -> DiffableRenderState<ItemStableID, ItemPayload> {
        var payloadByID: [ItemStableID: ItemPayload] = [:]
        var revisionByID: [ItemStableID: Int] = [:]

        for (sectionIndex, section) in sections.enumerated() {
            guard sectionIndex < renderSections.count else {
                continue
            }
            let stableIDs = renderSections[sectionIndex].stableIDs
            for (rowIndex, row) in section.rows.enumerated() {
                guard rowIndex < stableIDs.count else {
                    continue
                }
                let stableID = stableIDs[rowIndex]
                let payload = payload(for: row)
                payloadByID[stableID] = payload
                revisionByID[stableID] = revision(for: payload)
            }
        }

        return DiffableRenderState(payloadByID: payloadByID, revisionByID: revisionByID)
    }

    private func itemStableID(
        for row: DetailRow,
        styleRuleOccurrences: inout [StyleRuleSignature: Int]
    ) -> ItemStableID {
        switch row {
        case .element:
            return ItemStableID(key: .element, cellKind: .list)
        case .selector:
            return ItemStableID(key: .selector, cellKind: .list)
        case let .styleRule(signature, _, _):
            let ordinal = styleRuleOccurrences[signature, default: 0]
            styleRuleOccurrences[signature] = ordinal + 1
            return ItemStableID(
                key: .styleRule(signature: signature, ordinal: ordinal),
                cellKind: .list
            )
        case let .styleMeta(kind, _):
            return ItemStableID(key: .styleMeta(kind: kind), cellKind: .list)
        case let .attribute(nodeID, name, _):
            return ItemStableID(key: .attribute(nodeID: nodeID, name: name), cellKind: .attributeEditor)
        case .emptyAttribute:
            return ItemStableID(key: .emptyAttribute, cellKind: .list)
        }
    }

    private func payload(for row: DetailRow) -> ItemPayload {
        switch row {
        case let .element(preview):
            return .element(preview: preview)
        case let .selector(path):
            return .selector(path: path)
        case let .styleRule(_, selector, detail):
            return .styleRule(selector: selector, detail: detail)
        case let .styleMeta(_, message):
            return .styleMeta(message: message)
        case let .attribute(nodeID, name, value):
            return .attribute(nodeID: nodeID, name: name, value: value)
        case .emptyAttribute:
            return .emptyAttribute
        }
    }

    private func revision(for payload: ItemPayload) -> Int {
        var hasher = Hasher()
        switch payload {
        case let .element(preview):
            hasher.combine(0)
            hasher.combine(preview)
        case let .selector(path):
            hasher.combine(1)
            hasher.combine(path)
        case let .styleRule(selector, detail):
            hasher.combine(2)
            hasher.combine(selector)
            hasher.combine(detail)
        case let .styleMeta(message):
            hasher.combine(3)
            hasher.combine(message)
        case let .attribute(nodeID, name, value):
            hasher.combine(4)
            hasher.combine(nodeID)
            hasher.combine(name)
            hasher.combine(value)
        case .emptyAttribute:
            hasher.combine(5)
        }
        return hasher.finalize()
    }

    private func configureListCell(_ cell: UICollectionViewListCell, item: ItemIdentifier) {
        guard item.stableID.cellKind == .list else {
            assertionFailure("List cell registration received non-list item kind")
            cell.contentConfiguration = nil
            return
        }
        guard let payload = payloadByStableID[item.stableID] else {
            cell.contentConfiguration = nil
            return
        }
        var configuration = UIListContentConfiguration.cell()
        cell.accessories = []

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
        case let .styleRule(selector, detail):
            configuration = UIListContentConfiguration.subtitleCell()
            configuration.text = selector
            configuration.secondaryText = detail
            configuration.textProperties.numberOfLines = 1
            configuration.textToSecondaryTextVerticalPadding = 8
            configuration.secondaryTextProperties.numberOfLines = 0
            configuration.textProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                for: .systemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                    weight: .semibold
                )
            )
            configuration.textProperties.color = .secondaryLabel
            configuration.secondaryTextProperties.color = .label
            configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                    weight: .regular
                )
            )
        case let .styleMeta(message):
            configuration.text = message
            configuration.textProperties.color = .secondaryLabel
            configuration.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        case .emptyAttribute:
            configuration.text = wiLocalized("dom.element.attributes.empty")
            configuration.textProperties.color = .secondaryLabel
        case .attribute:
            return
        }
        cell.contentConfiguration = configuration
    }

    private func configureAttributeCell(_ cell: ElementAttributeEditorCell, item: ItemIdentifier) {
        guard item.stableID.cellKind == .attributeEditor else {
            assertionFailure("Attribute editor registration received list item kind")
            return
        }
        guard
            let payload = payloadByStableID[item.stableID],
            case let .attribute(nodeID, name, value) = payload
        else {
            return
        }
        let key = ElementAttributeEditingKey(nodeID: nodeID, name: name)
        cell.delegate = self
        cell.configure(
            key: key,
            name: name,
            value: value,
            activateEditor: isInlineEditingActive && editingAttributeKey == key
        )
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        flushPendingAttributeEditorRelayoutIfNeeded()
    }

    private func trailingSwipeActions(for indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let attributeRow = attributeRow(at: indexPath) else {
            return nil
        }

        let action = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completion in
            let key = ElementAttributeEditingKey(nodeID: attributeRow.nodeID, name: attributeRow.name)
            self?.deleteAttribute(for: key)
            completion(true)
        }
        action.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let attributeRow = attributeRow(at: indexPath) else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let deleteAction = UIAction(
                title: wiLocalized("delete"),
                image: UIImage(systemName: "trash"),
                attributes: [.destructive]
            ) { _ in
                let key = ElementAttributeEditingKey(nodeID: attributeRow.nodeID, name: attributeRow.name)
                self?.deleteAttribute(for: key)
            }
            return UIMenu(children: [deleteAction])
        }
    }

    private func attributeRow(at indexPath: IndexPath) -> (nodeID: Int?, name: String, value: String)? {
        guard
            let item = dataSource.itemIdentifier(for: indexPath),
            let payload = payloadByStableID[item.stableID],
            case let .attribute(nodeID, name, value) = payload
        else {
            return nil
        }
        return (nodeID: nodeID, name: name, value: value)
    }

    private func deleteAttribute(for key: ElementAttributeEditingKey) {
        if let editorCell = visibleAttributeEditorCell(for: key) {
            editorCell.suppressNextCommitAndEndEditing()
        } else {
            view.endEditing(true)
        }
        if editingAttributeKey == key {
            clearInlineEditingState()
        }
        inspector.removeAttribute(name: key.name)
    }

    private func visibleAttributeEditorCell(for key: ElementAttributeEditingKey) -> ElementAttributeEditorCell? {
        for visibleCell in collectionView.visibleCells {
            guard let editorCell = visibleCell as? ElementAttributeEditorCell else {
                continue
            }
            if editorCell.currentEditingKey == key {
                return editorCell
            }
        }
        return nil
    }

    private func clearInlineEditingState() {
        editingAttributeKey = nil
        editingDraftValue = nil
        isInlineEditingActive = false
    }

    @objc
    private func toggleSelectionMode() {
        inspector.toggleSelectionMode()
    }

    @objc
    private func reloadInspector() {
        Task {
            await inspector.reloadInspector()
        }
    }

    @objc
    private func deleteNode() {
        inspector.deleteSelectedNode(undoManager: undoManager)
    }
}

@MainActor
extension ElementDetailsTabViewController: ElementAttributeEditorCellDelegate {
    fileprivate func elementAttributeEditorCellDidBeginEditing(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    ) {
        editingAttributeKey = key
        editingDraftValue = value
        isInlineEditingActive = true
    }

    fileprivate func elementAttributeEditorCellDidChangeDraft(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    ) {
        editingAttributeKey = key
        editingDraftValue = value
    }

    fileprivate func elementAttributeEditorCellDidCommitValue(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    ) {
        editingAttributeKey = key
        editingDraftValue = value
        inspector.updateAttributeValue(name: key.name, value: value)
    }

    fileprivate func elementAttributeEditorCellDidEndEditing(
        _ cell: ElementAttributeEditorCell,
        key: ElementAttributeEditingKey,
        value: String
    ) {
        isInlineEditingActive = false
        if editingAttributeKey == key {
            editingAttributeKey = nil
            editingDraftValue = nil
        }
        sections = makeSections()
        requestSnapshotUpdate(animatingDifferences: true)
    }

    fileprivate func elementAttributeEditorCellNeedsRelayout(_ cell: ElementAttributeEditorCell) {
        requestAttributeEditorRelayout()
    }
}

private final class ElementAttributeEditorCell: UICollectionViewListCell, UITextViewDelegate {
    weak var delegate: ElementAttributeEditorCellDelegate?

    private let nameLabel = UILabel()
    private let valueTextView = UITextView()
    private let stackView = UIStackView()

    private var valueHeightConstraint: NSLayoutConstraint?
    private var editingKey: ElementAttributeEditingKey?
    private var debounceTask: Task<Void, Never>?
    private var isApplyingValue = false
    private var suppressNextCommit = false
    private lazy var keyboardAccessoryToolbar = ElementKeyboardAccessoryToolbar(onClose: { [weak self] in
        guard let self else {
            return
        }
        self.valueTextView.resignFirstResponder()
    })

    var currentEditingKey: ElementAttributeEditingKey? {
        editingKey
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        debounceTask?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if valueTextView.isFirstResponder {
            valueTextView.resignFirstResponder()
        }
        suppressNextCommit = false
        debounceTask?.cancel()
        debounceTask = nil
        editingKey = nil
    }

    func configure(
        key: ElementAttributeEditingKey,
        name: String,
        value: String,
        activateEditor: Bool
    ) {
        editingKey = key
        nameLabel.text = name

        if valueTextView.text != value {
            isApplyingValue = true
            valueTextView.text = value
            isApplyingValue = false
        }

        updateTextViewHeightIfNeeded()

        if activateEditor, !valueTextView.isFirstResponder {
            valueTextView.becomeFirstResponder()
        }
    }

    func suppressNextCommitAndEndEditing() {
        suppressNextCommit = true
        debounceTask?.cancel()
        debounceTask = nil
        if valueTextView.isFirstResponder {
            valueTextView.resignFirstResponder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTextViewHeightIfNeeded()
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        setNeedsLayout()
        layoutIfNeeded()
        let targetSize = CGSize(width: attributes.size.width, height: UIView.layoutFittingCompressedSize.height)
        let fittedSize = contentView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        attributes.size.height = ceil(fittedSize.height)
        return attributes
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        guard let editingKey else {
            return
        }
        delegate?.elementAttributeEditorCellDidBeginEditing(self, key: editingKey, value: textView.text ?? "")
    }

    func textViewDidChange(_ textView: UITextView) {
        guard
            !isApplyingValue,
            let editingKey
        else {
            return
        }

        let value = textView.text ?? ""
        updateTextViewHeightIfNeeded(notifyDelegate: true)
        delegate?.elementAttributeEditorCellDidChangeDraft(self, key: editingKey, value: value)

        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard
                let self,
                !Task.isCancelled,
                let currentKey = self.editingKey,
                currentKey == editingKey
            else {
                return
            }
            self.delegate?.elementAttributeEditorCellDidCommitValue(self, key: currentKey, value: self.valueTextView.text ?? "")
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        debounceTask?.cancel()
        guard let editingKey else {
            return
        }
        let value = textView.text ?? ""
        if suppressNextCommit {
            suppressNextCommit = false
            delegate?.elementAttributeEditorCellDidEndEditing(self, key: editingKey, value: value)
            return
        }
        delegate?.elementAttributeEditorCellDidCommitValue(self, key: editingKey, value: value)
        delegate?.elementAttributeEditorCellDidEndEditing(self, key: editingKey, value: value)
    }

    private func setupViews() {
        preservesSuperviewLayoutMargins = true
        contentView.preservesSuperviewLayoutMargins = true

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.numberOfLines = 1
        nameLabel.textColor = .secondaryLabel
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        nameLabel.setContentHuggingPriority(.required, for: .vertical)
        nameLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )

        valueTextView.translatesAutoresizingMaskIntoConstraints = false
        valueTextView.delegate = self
        valueTextView.isEditable = true
        valueTextView.isSelectable = true
        valueTextView.isScrollEnabled = false
        valueTextView.backgroundColor = .clear
        valueTextView.textContainerInset = .zero
        valueTextView.textContainer.lineFragmentPadding = 0
        valueTextView.adjustsFontForContentSizeCategory = true
        valueTextView.textColor = .label
        valueTextView.autocapitalizationType = .none
        valueTextView.autocorrectionType = .no
        valueTextView.smartDashesType = .no
        valueTextView.smartQuotesType = .no
        valueTextView.spellCheckingType = .no
        valueTextView.inputAccessoryView = keyboardAccessoryToolbar
        valueTextView.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
        )
        valueTextView.setContentCompressionResistancePriority(.required, for: .vertical)
        valueTextView.setContentHuggingPriority(.required, for: .vertical)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 6
        stackView.addArrangedSubview(nameLabel)
        stackView.addArrangedSubview(valueTextView)
        contentView.addSubview(stackView)

        let valueHeightConstraint = valueTextView.heightAnchor.constraint(equalToConstant: ceil(UIFont.preferredFont(forTextStyle: .footnote).lineHeight))
        valueHeightConstraint.priority = .required
        self.valueHeightConstraint = valueHeightConstraint

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            valueHeightConstraint
        ])
    }

    private func updateTextViewHeightIfNeeded(notifyDelegate: Bool = false) {
        guard let valueHeightConstraint else {
            return
        }
        let width = valueTextView.bounds.width
        guard width > 0 else {
            return
        }
        let fittingSize = valueTextView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let minLineHeight = valueTextView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .footnote).lineHeight
        let targetHeight = max(ceil(minLineHeight), ceil(fittingSize.height))
        if abs(valueHeightConstraint.constant - targetHeight) < 0.5 {
            return
        }
        valueHeightConstraint.constant = targetHeight
        guard notifyDelegate else {
            return
        }
        delegate?.elementAttributeEditorCellNeedsRelayout(self)
    }
}


final class ElementKeyboardAccessoryToolbar: UIToolbar {

    private let onClose: () -> Void
    private var hostingVC: UIViewController?
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)

        isTranslucent = true

        let swiftUIView = KeyboardToolbarView(onClose: { [weak self] in
            self?.onClose()
        })
        let hostingVC = UIHostingController(rootView: swiftUIView)
        hostingVC.view.backgroundColor = .clear
        
        self.hostingVC = hostingVC
        let customButton = UIBarButtonItem(customView:hostingVC.view )
        if #available(iOS 26.0, *) {
            customButton.hidesSharedBackground = false
            customButton.sharesBackground = true
        }
        setItems([customButton], animated: false)
        sizeToFit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct KeyboardToolbarView: View {
    let onClose: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button{
                onClose()
            }label:{
                Image(systemName:"chevron.down")
                    .frame(maxHeight: .infinity)
            }
            .foregroundStyle(.secondary)
            .containerShape(.capsule)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .background(.clear)
            .tint(.clear)
            .clipShape(.capsule)
        }
    }
}

#elseif canImport(AppKit)
import AppKit
import SwiftUI

@MainActor
final class ElementDetailsTabViewController: NSViewController {
    private let inspector: WIDOMTabViewModel
    private var hostingController: NSHostingController<ElementDetailsMacRootView>?

    init(inspector: WIDOMTabViewModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let hostingController = NSHostingController(rootView: ElementDetailsMacRootView(inspector: inspector))
        self.hostingController = hostingController
        addChild(hostingController)

        let hostedView = hostingController.view
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostedView)

        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: view.topAnchor),
            hostedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostedView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

@MainActor
private struct ElementDetailsMacRootView: View {
    private struct AttributeEditorState: Identifiable {
        let nodeID: Int?
        let name: String
        let initialValue: String

        var id: String {
            "\(nodeID ?? -1):\(name)"
        }
    }

    @Bindable var inspector: WIDOMTabViewModel
    @State private var attributeEditorState: AttributeEditorState?
    @State private var attributeEditorDraft = ""

    private var hasSelection: Bool {
        inspector.selection.nodeId != nil
    }

    var body: some View {
        if hasSelection {
            List {
                if let errorMessage = inspector.errorMessage, !errorMessage.isEmpty {
                    Section {
                        infoRow(message: errorMessage, color: .orange)
                    }
                }

                Section(LocalizedStringResource("dom.element.section.element", bundle: .module)) {
                    previewRow
                }

                Section(LocalizedStringResource("dom.element.section.selector", bundle: .module)) {
                    selectorRow
                }

                Section(LocalizedStringResource("dom.element.section.styles", bundle: .module)) {
                    stylesSection
                }

                Section(LocalizedStringResource("dom.element.section.attributes", bundle: .module)) {
                    attributesSection
                }
            }
            .listStyle(.inset)
            .sheet(item: $attributeEditorState) { state in
                VStack(alignment: .leading, spacing: 12) {
                    Text(wiLocalized("dom.element.attributes.edit", default: "Edit Attribute"))
                        .font(.headline)
                    Text(state.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    TextField(
                        wiLocalized("dom.element.attributes.value", default: "Value"),
                        text: $attributeEditorDraft
                    )
                    HStack {
                        Spacer()
                        Button(wiLocalized("cancel", default: "Cancel")) {
                            attributeEditorState = nil
                        }
                        Button(wiLocalized("save", default: "Save")) {
                            inspector.updateAttributeValue(name: state.name, value: attributeEditorDraft)
                            attributeEditorState = nil
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .frame(minWidth: 320)
                .onAppear {
                    attributeEditorDraft = state.initialValue
                }
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Image(systemName: "cursorarrow.rays")
                .foregroundStyle(.secondary)
        } description: {
            VStack(spacing: 4) {
                Text(wiLocalized("dom.element.select_prompt"))
                Text(wiLocalized("dom.element.hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewRow: some View {
        Text(inspector.selection.preview)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(4)
    }

    private var selectorRow: some View {
        Text(inspector.selection.selectorPath)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(4)
    }

    @ViewBuilder
    private var stylesSection: some View {
        if inspector.selection.isLoadingMatchedStyles {
            infoRow(message: wiLocalized("dom.element.styles.loading"), color: .secondary)
        } else if inspector.selection.matchedStyles.isEmpty {
            infoRow(message: wiLocalized("dom.element.styles.empty"), color: .secondary)
        } else {
            ForEach(Array(inspector.selection.matchedStyles.enumerated()), id: \.offset) { _, rule in
                VStack(alignment: .leading, spacing: 8) {
                    Text(rule.selectorText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(styleRuleDetail(rule))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(12)
                }
            }

            if inspector.selection.matchedStylesTruncated {
                infoRow(message: wiLocalized("dom.element.styles.truncated"), color: .secondary)
            }
            if inspector.selection.blockedStylesheetCount > 0 {
                infoRow(
                    message: "\(inspector.selection.blockedStylesheetCount) \(wiLocalized("dom.element.styles.blocked_stylesheets"))",
                    color: .secondary
                )
            }
        }
    }

    @ViewBuilder
    private var attributesSection: some View {
        if inspector.selection.attributes.isEmpty {
            infoRow(message: wiLocalized("dom.element.attributes.empty"), color: .secondary)
        } else {
            ForEach(Array(inspector.selection.attributes.enumerated()), id: \.offset) { _, attribute in
                VStack(alignment: .leading, spacing: 6) {
                    Text(attribute.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(attribute.value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(6)
                }
                .contextMenu {
                    Button(wiLocalized("dom.element.attributes.edit", default: "Edit Attribute")) {
                        attributeEditorState = AttributeEditorState(
                            nodeID: attribute.nodeId,
                            name: attribute.name,
                            initialValue: attribute.value
                        )
                        attributeEditorDraft = attribute.value
                    }
                    Button(wiLocalized("dom.element.attributes.delete", default: "Delete Attribute"), role: .destructive) {
                        inspector.removeAttribute(name: attribute.name)
                    }
                }
            }
        }
    }

    private func styleRuleDetail(_ rule: DOMMatchedStyleRule) -> String {
        var parts: [String] = []
        if !rule.sourceLabel.isEmpty {
            parts.append(rule.sourceLabel)
        }
        if !rule.atRuleContext.isEmpty {
            parts.append(contentsOf: rule.atRuleContext)
        }
        let declarations = rule.declarations.map { declaration in
            let importantSuffix = declaration.important ? " !important" : ""
            return "\(declaration.name): \(declaration.value)\(importantSuffix);"
        }.joined(separator: "\n")
        if !declarations.isEmpty {
            parts.append(declarations)
        }
        return parts.joined(separator: "\n")
    }

    private func infoRow(message: String, color: Color) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(color)
            .textSelection(.enabled)
    }
}

#endif
