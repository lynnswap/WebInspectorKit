import WebInspectorEngine
import WebInspectorRuntime
import ObservationBridge

#if canImport(UIKit)
import UIKit
import SwiftUI

private protocol DiffableStableID: Hashable, Sendable {}

private struct ElementAttributeEditingKey: Hashable {
    let nodeID: DOMEntryID?
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
public final class WIDOMDetailViewController: UICollectionViewController {
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

    fileprivate enum ItemCellKind: String, Hashable, Sendable {
        case list
        case attributeEditor
    }

    fileprivate enum StyleMetaKind: String, Hashable, Sendable {
        case loading
        case empty
        case truncated
        case blockedStylesheets
    }

    fileprivate struct StyleRuleSignature: Hashable, Sendable {
        let selectorText: String
        let sourceLabel: String
    }

    fileprivate enum ItemStableKey: DiffableStableID {
        case element
        case selector
        case styleRule(signature: StyleRuleSignature, ordinal: Int)
        case styleMeta(kind: StyleMetaKind)
        case attribute(nodeID: DOMEntryID?, name: String)
        case emptyAttribute
    }

    fileprivate struct ItemStableID: DiffableStableID {
        let key: ItemStableKey
        let cellKind: ItemCellKind
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
        case styleRule(signature: StyleRuleSignature)
        case styleMeta(kind: StyleMetaKind)
        case attribute(nodeID: DOMEntryID?, name: String)
        case emptyAttribute
    }

    fileprivate enum ItemPayload {
        case element(preview: String)
        case selector(path: String)
        case styleRule(selector: String, detail: String)
        case styleMeta(message: String)
        case attribute(nodeID: DOMEntryID?, name: String, value: String)
        case emptyAttribute
    }

    private struct RenderSection {
        let sectionIdentifier: SectionIdentifier
        let stableIDs: [ItemStableID]
    }

    private let inspector: WIDOMModel
    private let showsNavigationControls: Bool
    private var hasStartedObservingState = false
    private var stateObservationHandles: Set<ObservationHandle> = []
    private var selectedEntryObservationHandles: Set<ObservationHandle> = []
    // Keep coalescing because navigation controls react to several independent state updates.
    private let navigationUpdateCoalescer = UIUpdateCoalescer()
    // Keep coalescing because structure snapshots can burst under DOM updates.
    private let structureUpdateCoalescer = UIUpdateCoalescer()
    private var sections: [DetailSection] = []
    private weak var observedSelectedEntry: DOMEntry?
    private var editingAttributeKey: ElementAttributeEditingKey?
    private var editingDraftValue: String?
    private var isSelectionActionPending = false
    private var isInlineEditingActive = false
    private var attributeRelayoutCoordinator = AttributeEditorRelayoutCoordinator()
    private var needsSnapshotReloadOnNextAppearance = false
    private var pendingReloadDataTask: Task<Void, Never>?
    private var pendingForcedStructureRefresh = false
    private var selectedEntryRenderGeneration: UInt64 = 0

#if DEBUG
    private(set) var snapshotApplyCountForTesting = 0
#endif

    private lazy var dataSource = makeDataSource()

    private lazy var pickItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: pickSymbolName),
            style: .plain,
            target: self,
            action: #selector(toggleSelectionMode)
        )
    }()

    public init(inspector: WIDOMModel, showsNavigationControls: Bool = true) {
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
        handleSelectedEntryChange()
    }

    private var pickSymbolName: String {
        traitCollection.horizontalSizeClass == .compact ? "viewfinder.circle" : "scope"
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        flushPendingAttributeEditorRelayoutIfNeeded()
    }

    public override func viewDidAppear(_ animated: Bool) {
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
        let graphStore = inspector.session.graphStore

        inspector.observe(
            \.hasPageWebView,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        .store(in: &stateObservationHandles)
        inspector.observe(
            \.isSelectingElement,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        .store(in: &stateObservationHandles)
        graphStore.observe(\.selectedEntry) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
            self?.handleSelectedEntryObservationEvent()
        }
        .store(in: &stateObservationHandles)
    }

    private func makeSecondaryMenu() -> UIMenu {
        let hasSelection = inspector.selectedEntry != nil
        let hasPageWebView = inspector.hasPageWebView

        return DOMSecondaryMenuBuilder.makeMenu(
            hasSelection: hasSelection,
            hasPageWebView: hasPageWebView,
            onCopyHTML: { [weak self] in
                self?.copySelection(.html)
            },
            onCopySelectorPath: { [weak self] in
                self?.copySelection(.selectorPath)
            },
            onCopyXPath: { [weak self] in
                self?.copySelection(.xpath)
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

    private func scheduleStructureUpdate(forceSnapshotUpdate: Bool = false) {
        pendingForcedStructureRefresh = pendingForcedStructureRefresh || forceSnapshotUpdate
        structureUpdateCoalescer.schedule { [weak self] in
            guard let self else {
                return
            }
            let shouldForceSnapshotUpdate = self.pendingForcedStructureRefresh
            self.pendingForcedStructureRefresh = false
            self.reconcileSectionStructure(forceSnapshotUpdate: shouldForceSnapshotUpdate)
        }
    }

    private func updateNavigationControls() {
        if showsNavigationControls {
            navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] completion in
                completion((self?.makeSecondaryMenu() ?? UIMenu()).children)
            }
            pickItem.isEnabled = inspector.hasPageWebView && !isSelectionActionPending
            pickItem.image = UIImage(systemName: pickSymbolName)
            pickItem.tintColor = (inspector.isSelectingElement || isSelectionActionPending) ? .systemBlue : .label
        } else {
            navigationItem.additionalOverflowItems = nil
        }
    }

    private func handleSelectedEntryChange() {
        selectedEntryObservationHandles.removeAll()
        observedSelectedEntry = inspector.selectedEntry
        selectedEntryRenderGeneration &+= 1
        let currentSelectionID = inspector.selectedEntry?.id
        if editingAttributeKey?.nodeID != currentSelectionID {
            clearInlineEditingState()
        }

        if currentSelectionID == nil {
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
            if let selectedEntry = inspector.selectedEntry {
                startObservingSelectedEntry(selectedEntry)
            }
        }

        guard !isInlineEditingActive else {
            return
        }
        requestSnapshotUpdate(animatingDifferences: true, force: true)
    }

    private func handleSelectedEntryObservationEvent() {
        let currentSelectedEntry = inspector.selectedEntry
        switch (observedSelectedEntry, currentSelectedEntry) {
        case (nil, nil):
            return
        case let (observedEntry?, currentEntry?) where observedEntry === currentEntry:
            return
        default:
            handleSelectedEntryChange()
        }
    }

    private func startObservingSelectedEntry(_ entry: DOMEntry) {
        entry.observe(
            [\.attributes, \.matchedStyles, \.isLoadingMatchedStyles, \.matchedStylesTruncated, \.blockedStylesheetCount],
            onChange: { [weak self, weak entry] in
                guard let self, let entry else {
                    return
                }
                guard self.inspector.selectedEntry?.id == entry.id else {
                    return
                }
                self.scheduleStructureUpdate()
            },
            isolation: MainActor.shared
        )
        .store(in: &selectedEntryObservationHandles)
    }

    private func reconcileSectionStructure(forceSnapshotUpdate: Bool = false) {
        guard inspector.selectedEntry != nil else {
            handleSelectedEntryChange()
            return
        }

        let updatedSections = makeSections()
        let structureChanged = forceSnapshotUpdate || hasSectionStructureChanged(from: sections, to: updatedSections)
        sections = updatedSections

        guard structureChanged, !isInlineEditingActive else {
            return
        }
        requestSnapshotUpdate(animatingDifferences: true, force: forceSnapshotUpdate)
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
        guard let selected = inspector.selectedEntry else {
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

        var styleRows: [DetailRow] = []
        if selected.isLoadingMatchedStyles {
            styleRows.append(.styleMeta(kind: .loading))
        } else if selected.matchedStyles.isEmpty {
            styleRows.append(.styleMeta(kind: .empty))
        } else {
            for rule in selected.matchedStyles {
                styleRows.append(
                    .styleRule(
                        signature: StyleRuleSignature(
                            selectorText: rule.selectorText,
                            sourceLabel: rule.sourceLabel
                        )
                    )
                )
            }
        }
        if selected.matchedStylesTruncated {
            styleRows.append(.styleMeta(kind: .truncated))
        }
        if selected.blockedStylesheetCount > 0 {
            styleRows.append(.styleMeta(kind: .blockedStylesheets))
        }

        let styleSection = DetailSection(
            key: .styles,
            title: wiLocalized("dom.element.section.styles"),
            rows: styleRows
        )

        let attributeRows: [DetailRow]
        if selected.attributes.isEmpty {
            attributeRows = [.emptyAttribute]
        } else {
            attributeRows = selected.attributes.map { attribute in
                .attribute(nodeID: selected.id, name: attribute.name)
            }
        }

        let attributeSection = DetailSection(
            key: .attributes,
            title: wiLocalized("dom.element.section.attributes"),
            rows: attributeRows
        )

        return [elementSection, selectorSection, styleSection, attributeSection]
    }

    private func defaultPreview(for entry: DOMEntry) -> String {
        switch entry.nodeType {
        case 3:
            return entry.nodeValue
        case 8:
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
            guard !Task.isCancelled else {
                return
            }
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
        guard isCollectionViewVisible else {
            needsSnapshotReloadOnNextAppearance = true
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        let snapshot = makeSnapshot()
        guard force || snapshotStructureDiffers(from: dataSource.snapshot(), to: snapshot) else {
            return
        }
        applySnapshot(snapshot, animatingDifferences: animatingDifferences)
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard !isInlineEditingActive else {
            return
        }
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        applySnapshotUsingReloadData(makeSnapshot())
    }

    private func makeRenderSections(for sections: [DetailSection]) -> [RenderSection] {
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

    private func itemStableID(
        for row: DetailRow,
        styleRuleOccurrences: inout [StyleRuleSignature: Int]
    ) -> ItemStableID {
        switch row {
        case .element:
            return ItemStableID(key: .element, cellKind: .list)
        case .selector:
            return ItemStableID(key: .selector, cellKind: .list)
        case let .styleRule(signature):
            let ordinal = styleRuleOccurrences[signature, default: 0]
            styleRuleOccurrences[signature] = ordinal + 1
            return ItemStableID(
                key: .styleRule(signature: signature, ordinal: ordinal),
                cellKind: .list
            )
        case let .styleMeta(kind):
            return ItemStableID(key: .styleMeta(kind: kind), cellKind: .list)
        case let .attribute(nodeID, name):
            return ItemStableID(key: .attribute(nodeID: nodeID, name: name), cellKind: .attributeEditor)
        case .emptyAttribute:
            return ItemStableID(key: .emptyAttribute, cellKind: .list)
        }
    }

    private func payload(for stableID: ItemStableID) -> ItemPayload? {
        guard let selectedEntry = inspector.selectedEntry else {
            return nil
        }

        switch stableID.key {
        case .element:
            let previewText = selectedEntry.preview.isEmpty ? defaultPreview(for: selectedEntry) : selectedEntry.preview
            return .element(preview: previewText)
        case .selector:
            return .selector(path: selectedEntry.selectorPath)
        case let .styleRule(signature, ordinal):
            guard let rule = matchedStyleRule(signature: signature, ordinal: ordinal, in: selectedEntry) else {
                return nil
            }
            return .styleRule(
                selector: rule.selectorText,
                detail: styleRuleDetail(for: rule)
            )
        case let .styleMeta(kind):
            return styleMetaPayload(for: kind, in: selectedEntry)
        case let .attribute(nodeID, name):
            let key = ElementAttributeEditingKey(nodeID: nodeID, name: name)
            guard let value = attributeValue(for: key, in: selectedEntry) else {
                return nil
            }
            return .attribute(nodeID: nodeID, name: name, value: value)
        case .emptyAttribute:
            return .emptyAttribute
        }
    }

    private func configureListCell(_ cell: DOMObservingListCell, item: ItemIdentifier) {
        guard item.stableID.cellKind == .list else {
            assertionFailure("List cell registration received non-list item kind")
            cell.contentConfiguration = nil
            return
        }
        cell.configure(
            stableID: item.stableID,
            entry: inspector.selectedEntry,
            payloadProvider: { [weak self] stableID in
                self?.payload(for: stableID)
            }
        )
    }

    private func configureAttributeCell(_ cell: ElementAttributeEditorCell, item: ItemIdentifier) {
        guard item.stableID.cellKind == .attributeEditor else {
            assertionFailure("Attribute editor registration received list item kind")
            return
        }
        guard
            case let .attribute(nodeID, name) = item.stableID.key
        else {
            return
        }
        let key = ElementAttributeEditingKey(nodeID: nodeID, name: name)
        cell.delegate = self
        cell.configure(
            key: key,
            name: name,
            value: attributeValue(for: key) ?? "",
            entry: inspector.selectedEntry,
            activateEditor: isInlineEditingActive && editingAttributeKey == key
        )
    }

    public override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    public override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
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

    public override func collectionView(
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

    private func attributeRow(at indexPath: IndexPath) -> (nodeID: DOMEntryID?, name: String, value: String)? {
        guard
            let item = dataSource.itemIdentifier(for: indexPath),
            case let .attribute(nodeID, name) = item.stableID.key
        else {
            return nil
        }

        let key = ElementAttributeEditingKey(nodeID: nodeID, name: name)
        guard let value = attributeValue(for: key) else {
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
        let inspector = inspector
        Task.immediateIfAvailable {
            await inspector.removeAttribute(name: key.name)
        }
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
        guard isSelectionActionPending == false else {
            return
        }

        isSelectionActionPending = true
        updateNavigationControls()

        let inspector = inspector
        Task.immediateIfAvailable { [weak self] in
            defer {
                if let self {
                    self.isSelectionActionPending = false
                    self.scheduleNavigationControlsUpdate()
                }
            }
            if inspector.isSelectingElement {
                await inspector.cancelSelectionMode()
            } else {
                _ = try? await inspector.beginSelectionMode()
            }
        }
    }

    @objc
    private func reloadInspector() {
        Task {
            await inspector.reloadInspector()
        }
    }

    @objc
    private func deleteNode() {
        let inspector = inspector
        let undoManager = undoManager
        Task.immediateIfAvailable {
            await inspector.deleteSelectedNode(undoManager: undoManager)
        }
    }

    private func copySelection(_ kind: DOMSelectionCopyKind) {
        let inspector = inspector
        Task.immediateIfAvailable {
            do {
                let text = try await inspector.copySelection(kind)
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

@MainActor
extension WIDOMDetailViewController: ElementAttributeEditorCellDelegate {
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
        let inspector = inspector
        Task.immediateIfAvailable {
            await inspector.updateAttributeValue(name: key.name, value: value)
        }
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

private extension WIDOMDetailViewController {
    func attributeValue(for key: ElementAttributeEditingKey, in entry: DOMEntry? = nil) -> String? {
        guard let entry = entry ?? inspector.selectedEntry else {
            return nil
        }
        guard let attribute = entry.attributes.first(where: { $0.name == key.name }) else {
            return nil
        }
        if editingAttributeKey == key {
            return editingDraftValue ?? attribute.value
        }
        return attribute.value
    }

    func matchedStyleRule(
        signature: StyleRuleSignature,
        ordinal: Int,
        in entry: DOMEntry
    ) -> DOMMatchedStyleRule? {
        var currentOrdinal = 0
        for rule in entry.matchedStyles {
            let currentSignature = StyleRuleSignature(
                selectorText: rule.selectorText,
                sourceLabel: rule.sourceLabel
            )
            guard currentSignature == signature else {
                continue
            }
            if currentOrdinal == ordinal {
                return rule
            }
            currentOrdinal += 1
        }
        return nil
    }

    func styleRuleDetail(for rule: DOMMatchedStyleRule) -> String {
        let declarations = rule.declarations.map { declaration in
            let importantSuffix = declaration.important ? " !important" : ""
            return "\(declaration.name): \(declaration.value)\(importantSuffix);"
        }
        var details = declarations.joined(separator: "\n")
        if !rule.sourceLabel.isEmpty {
            details = "\(rule.sourceLabel)\n\(details)"
        }
        return details
    }

    func styleMetaPayload(for kind: StyleMetaKind, in entry: DOMEntry) -> ItemPayload? {
        switch kind {
        case .loading:
            guard entry.isLoadingMatchedStyles else {
                return nil
            }
            return .styleMeta(message: wiLocalized("dom.element.styles.loading"))
        case .empty:
            guard !entry.isLoadingMatchedStyles, entry.matchedStyles.isEmpty else {
                return nil
            }
            return .styleMeta(message: wiLocalized("dom.element.styles.empty"))
        case .truncated:
            guard entry.matchedStylesTruncated else {
                return nil
            }
            return .styleMeta(message: wiLocalized("dom.element.styles.truncated"))
        case .blockedStylesheets:
            guard entry.blockedStylesheetCount > 0 else {
                return nil
            }
            return .styleMeta(
                message: "\(entry.blockedStylesheetCount) \(wiLocalized("dom.element.styles.blocked_stylesheets"))"
            )
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
        entry: DOMEntry?,
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

    private func startObserving(entry: DOMEntry, stableID: WIDOMDetailViewController.ItemStableID) {
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
        case .styleRule:
            entry.observe(
                \.matchedStyles,
                onChange: { [weak self] _ in
                    self?.applyCurrentPayload()
                },
                isolation: MainActor.shared
            )
            .store(in: &observationHandles)
        case .styleMeta(.loading), .styleMeta(.empty):
            entry.observe(
                [\.isLoadingMatchedStyles, \.matchedStyles],
                onChange: { [weak self] in
                    self?.applyCurrentPayload()
                },
                isolation: MainActor.shared
            )
            .store(in: &observationHandles)
        case .styleMeta(.truncated):
            entry.observe(
                \.matchedStylesTruncated,
                onChange: { [weak self] _ in
                    self?.applyCurrentPayload()
                },
                isolation: MainActor.shared
            )
            .store(in: &observationHandles)
        case .styleMeta(.blockedStylesheets):
            entry.observe(
                \.blockedStylesheetCount,
                onChange: { [weak self] _ in
                    self?.applyCurrentPayload()
                },
                isolation: MainActor.shared
            )
            .store(in: &observationHandles)
        case .emptyAttribute:
            entry.observe(
                \.attributes,
                onChange: { [weak self] _ in
                    self?.applyCurrentPayload()
                },
                isolation: MainActor.shared
            )
            .store(in: &observationHandles)
        case .attribute:
            break
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
        contentConfiguration = configuration
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
    private var observationHandles: Set<ObservationHandle> = []
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
        observationHandles.removeAll()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if valueTextView.isFirstResponder {
            valueTextView.resignFirstResponder()
        }
        suppressNextCommit = false
        debounceTask?.cancel()
        debounceTask = nil
        observationHandles.removeAll()
        editingKey = nil
    }

    func configure(
        key: ElementAttributeEditingKey,
        name: String,
        value: String,
        entry: DOMEntry?,
        activateEditor: Bool
    ) {
        observationHandles.removeAll()
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

        guard let entry else {
            return
        }
        entry.observe(
            \.attributes,
            onChange: { [weak self, weak entry] attributes in
                guard let self, let entry, self.editingKey?.nodeID == entry.id else {
                    return
                }
                self.syncValueFromAttributes(attributes)
            },
            isolation: MainActor.shared
        )
        .store(in: &observationHandles)
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

    private func syncValueFromAttributes(_ attributes: [DOMAttribute]) {
        guard
            !valueTextView.isFirstResponder,
            let editingKey,
            let attribute = attributes.first(where: { $0.name == editingKey.name })
        else {
            return
        }

        let value = attribute.value
        guard valueTextView.text != value else {
            return
        }
        isApplyingValue = true
        valueTextView.text = value
        isApplyingValue = false
        updateTextViewHeightIfNeeded(notifyDelegate: true)
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
        let customButton = UIBarButtonItem(customView: hostingVC.view)
        if #available(iOS 26.0, *) {
            customButton.hidesSharedBackground = false
            customButton.sharesBackground = true
        }
        setItems([customButton], animated: false)
        sizeToFit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct KeyboardToolbarView: View {
    let onClose: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "chevron.down")
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

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("DOM Detail Empty (UIKit)") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WIDOMDetailViewController(
                inspector: WIDOMPreviewFixtures.makeInspector(mode: .empty)
            )
        )
    }
}

#Preview("DOM Detail Selected (UIKit)") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WIDOMDetailViewController(
                inspector: WIDOMPreviewFixtures.makeInspector(mode: .selected)
            )
        )
    }
}

#Preview("DOM Detail Editable Attributes (UIKit)") {
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
