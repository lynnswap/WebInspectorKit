import WebInspectorKitCore

#if canImport(UIKit)
import UIKit

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
final class ElementDetailsTabViewController: UIViewController, UICollectionViewDelegate {
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

    private let inspector: WIDOMPaneViewModel
    private let observationToken = WIObservationToken()
    private var sections: [DetailSection] = []
    private var editingAttributeKey: ElementAttributeEditingKey?
    private var editingDraftValue: String?
    private var isInlineEditingActive = false
    private var lastSelectionNodeID: Int?
    private var payloadByStableID: [ItemStableID: ItemPayload] = [:]
    private var revisionByStableID: [ItemStableID: Int] = [:]

    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        return collectionView
    }()
    private lazy var dataSource = makeDataSource()

    private lazy var pickItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: "viewfinder.circle"),
            style: .plain,
            target: self,
            action: #selector(toggleSelectionMode)
        )
    }()
    private lazy var secondaryActionsItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: wiSecondaryActionSymbolName()),
            menu: makeSecondaryMenu()
        )
    }()

    init(inspector: WIDOMPaneViewModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationToken.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        navigationItem.title = ""
        setupNavigationItems()
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        observationToken.observe({ [weak self] in
            guard let self else { return }
            _ = self.inspector.selection.nodeId
            _ = self.inspector.selection.preview
            _ = self.inspector.selection.selectorPath
            _ = self.inspector.selection.matchedStyles
            _ = self.inspector.selection.attributes
            _ = self.inspector.selection.isLoadingMatchedStyles
            _ = self.inspector.selection.matchedStylesTruncated
            _ = self.inspector.selection.blockedStylesheetCount
            _ = self.inspector.hasPageWebView
            _ = self.inspector.isSelectingElement
        }, onChange: { [weak self] in
            self?.refreshUI()
        })

        refreshUI()
    }

    private func setupNavigationItems() {
        navigationItem.rightBarButtonItems = [secondaryActionsItem, pickItem]
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

    private func refreshUI() {
        let hasSelection = inspector.selection.nodeId != nil
        let hasPageWebView = inspector.hasPageWebView
        let currentSelectionNodeID = inspector.selection.nodeId
        if currentSelectionNodeID != lastSelectionNodeID {
            clearInlineEditingState()
            lastSelectionNodeID = currentSelectionNodeID
        }

        secondaryActionsItem.menu = makeSecondaryMenu()
        secondaryActionsItem.isEnabled = hasSelection || hasPageWebView
        pickItem.isEnabled = inspector.hasPageWebView
        pickItem.tintColor = inspector.isSelectingElement ? .systemBlue : .label

        if inspector.selection.nodeId == nil {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = wiLocalized("dom.element.select_prompt")
            configuration.secondaryText = wiLocalized("dom.element.hint")
            configuration.image = UIImage(systemName: "cursorarrow.rays")
            contentUnavailableConfiguration = configuration
            clearInlineEditingState()
            sections = []
        } else {
            contentUnavailableConfiguration = nil
            sections = makeSections()
        }

        guard !isInlineEditingActive else {
            return
        }
        applySnapshot(animatingDifferences: view.window != nil)
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
        dataSource.supplementaryViewProvider = { [weak self] collectionView, _, indexPath in
            guard let self else {
                return UICollectionReusableView()
            }
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
        return dataSource
    }

    private func applySnapshot(animatingDifferences: Bool) {
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

        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
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

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
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

    func collectionView(
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
        inspector.deleteSelectedNode()
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
        applySnapshot(animatingDifferences: true)
    }

    fileprivate func elementAttributeEditorCellNeedsRelayout(_ cell: ElementAttributeEditorCell) {
        collectionView.performBatchUpdates(nil)
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

    deinit {
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
        updateTextViewHeightIfNeeded()
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

    private func updateTextViewHeightIfNeeded() {
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
        delegate?.elementAttributeEditorCellNeedsRelayout(self)
    }
}

#elseif canImport(AppKit)
import AppKit

private protocol DiffableStableID: Hashable, Sendable {}
private protocol DiffableCellKind: Hashable, Sendable {}

private struct DiffableRenderState<ID: DiffableStableID, Payload> {
    let payloadByID: [ID: Payload]
    let revisionByID: [ID: Int]
}

@MainActor
final class ElementDetailsTabViewController: NSViewController, NSCollectionViewDelegate {
    private enum SectionIdentifier: Hashable, Sendable {
        case main
    }

    private enum SectionKind: String, Hashable, Sendable {
        case element
        case selector
        case styles
        case attributes
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

    private enum ItemCellKind: String, DiffableCellKind {
        case macDetailItem
    }

    private enum ItemStableKey: DiffableStableID {
        case placeholder
        case sectionHeader(SectionKind)
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

    fileprivate enum ItemKind: Hashable {
        case placeholder(title: String, detail: String)
        case header(title: String)
        case element(preview: String)
        case selector(path: String)
        case styleRule(selector: String, detail: String)
        case styleMeta(message: String)
        case attribute(nodeID: Int?, name: String, value: String)
        case emptyAttribute(message: String)
    }

    private let inspector: WIDOMPaneViewModel
    private let observationToken = WIObservationToken()
    private var payloadByStableID: [ItemStableID: ItemKind] = [:]
    private var revisionByStableID: [ItemStableID: Int] = [:]

    private lazy var collectionView: NSCollectionView = {
        let collectionView = NSCollectionView(frame: .zero)
        collectionView.collectionViewLayout = makeLayout()
        collectionView.delegate = self
        collectionView.register(
            ElementDetailsMacItem.self,
            forItemWithIdentifier: ElementDetailsMacItem.reuseIdentifier
        )
        return collectionView
    }()
    private lazy var dataSource = makeDataSource()
    private lazy var pickButton: NSButton = {
        let button = NSButton(
            title: wiLocalized("dom.controls.pick"),
            target: self,
            action: #selector(toggleSelectionMode)
        )
        button.bezelStyle = .rounded
        return button
    }()
    private lazy var reloadButton: NSButton = {
        let button = NSButton(
            title: wiLocalized("reload"),
            target: self,
            action: #selector(reloadInspector)
        )
        button.bezelStyle = .rounded
        return button
    }()
    private lazy var deleteButton: NSButton = {
        let button = NSButton(
            title: wiLocalized("inspector.delete_node"),
            target: self,
            action: #selector(deleteNode)
        )
        button.bezelStyle = .rounded
        return button
    }()

    init(inspector: WIDOMPaneViewModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationToken.invalidate()
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let buttonStack = NSStackView(views: [pickButton, reloadButton, deleteButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        view.addSubview(buttonStack)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            buttonStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        observationToken.observe({ [weak self] in
            guard let self else { return }
            _ = self.inspector.selection.nodeId
            _ = self.inspector.selection.preview
            _ = self.inspector.selection.selectorPath
            _ = self.inspector.selection.matchedStyles
            _ = self.inspector.selection.attributes
            _ = self.inspector.selection.isLoadingMatchedStyles
            _ = self.inspector.selection.matchedStylesTruncated
            _ = self.inspector.selection.blockedStylesheetCount
            _ = self.inspector.hasPageWebView
            _ = self.inspector.isSelectingElement
        }, onChange: { [weak self] in
            self?.refreshUI()
        })

        refreshUI()
    }

    private func makeLayout() -> NSCollectionViewLayout {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumLineSpacing = 6
        layout.minimumInteritemSpacing = 0
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        layout.estimatedItemSize = NSSize(width: 200, height: 52)
        return layout
    }

    private func makeDataSource() -> NSCollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier> {
        NSCollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            guard
                let self,
                let itemView = collectionView.makeItem(
                    withIdentifier: ElementDetailsMacItem.reuseIdentifier,
                    for: indexPath
                ) as? ElementDetailsMacItem
            else {
                return NSCollectionViewItem()
            }
            guard item.stableID.cellKind == .macDetailItem else {
                assertionFailure("Unexpected cell kind for ElementDetailsMacItem")
                return NSCollectionViewItem()
            }
            guard let payload = self.payloadByStableID[item.stableID] else {
                return NSCollectionViewItem()
            }
            itemView.configure(with: payload)
            return itemView
        }
    }

    private func refreshUI() {
        pickButton.state = inspector.isSelectingElement ? .on : .off
        pickButton.isEnabled = inspector.hasPageWebView
        reloadButton.isEnabled = inspector.hasPageWebView
        deleteButton.isEnabled = inspector.selection.nodeId != nil
        applySnapshot(animatingDifferences: view.window != nil)
    }

    private func applySnapshot(animatingDifferences: Bool) {
        let renderItems = makeRenderItems()
        precondition(
            renderItems.stableIDs.count == Set(renderItems.stableIDs).count,
            "Duplicate diffable IDs detected in macOS ElementDetailsTabViewController"
        )
        let previousRevisionByStableID = revisionByStableID
        payloadByStableID = renderItems.payloadByID
        revisionByStableID = renderItems.revisionByID

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        snapshot.appendSections([.main])
        let identifiers = renderItems.stableIDs.map { stableID in
            ItemIdentifier(stableID: stableID)
        }
        snapshot.appendItems(identifiers, toSection: .main)
        let reloaded = renderItems.stableIDs.compactMap { stableID -> ItemIdentifier? in
            guard
                let previousRevision = previousRevisionByStableID[stableID],
                let nextRevision = renderItems.revisionByID[stableID],
                previousRevision != nextRevision
            else {
                return nil
            }
            return ItemIdentifier(stableID: stableID)
        }
        if !reloaded.isEmpty {
            snapshot.reloadItems(reloaded)
        }
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func makeRenderItems() -> (stableIDs: [ItemStableID], payloadByID: [ItemStableID: ItemKind], revisionByID: [ItemStableID: Int]) {
        var stableIDs: [ItemStableID] = []
        var payloadByID: [ItemStableID: ItemKind] = [:]
        var revisionByID: [ItemStableID: Int] = [:]
        func append(_ stableID: ItemStableID, _ payload: ItemKind) {
            stableIDs.append(stableID)
            payloadByID[stableID] = payload
            revisionByID[stableID] = revision(for: payload)
        }

        guard inspector.selection.nodeId != nil else {
            append(
                ItemStableID(key: .placeholder, cellKind: .macDetailItem),
                .placeholder(
                    title: wiLocalized("dom.element.select_prompt"),
                    detail: wiLocalized("dom.element.hint")
                )
            )
            return (stableIDs: stableIDs, payloadByID: payloadByID, revisionByID: revisionByID)
        }

        append(
            ItemStableID(key: .sectionHeader(.element), cellKind: .macDetailItem),
            .header(title: wiLocalized("dom.element.section.element"))
        )
        append(
            ItemStableID(key: .element, cellKind: .macDetailItem),
            .element(preview: inspector.selection.preview)
        )
        append(
            ItemStableID(key: .sectionHeader(.selector), cellKind: .macDetailItem),
            .header(title: wiLocalized("dom.element.section.selector"))
        )
        append(
            ItemStableID(key: .selector, cellKind: .macDetailItem),
            .selector(path: inspector.selection.selectorPath)
        )
        append(
            ItemStableID(key: .sectionHeader(.styles), cellKind: .macDetailItem),
            .header(title: wiLocalized("dom.element.section.styles"))
        )

        if inspector.selection.isLoadingMatchedStyles {
            append(
                ItemStableID(key: .styleMeta(kind: .loading), cellKind: .macDetailItem),
                .styleMeta(message: wiLocalized("dom.element.styles.loading"))
            )
        } else if inspector.selection.matchedStyles.isEmpty {
            append(
                ItemStableID(key: .styleMeta(kind: .empty), cellKind: .macDetailItem),
                .styleMeta(message: wiLocalized("dom.element.styles.empty"))
            )
        } else {
            var styleRuleOccurrences: [StyleRuleSignature: Int] = [:]
            for rule in inspector.selection.matchedStyles {
                let declarations = rule.declarations.map { declaration in
                    let importantSuffix = declaration.important ? " !important" : ""
                    return "\(declaration.name): \(declaration.value)\(importantSuffix);"
                }.joined(separator: "\n")
                var detail = declarations
                if !rule.sourceLabel.isEmpty {
                    detail = "\(rule.sourceLabel)\n\(detail)"
                }
                let signature = StyleRuleSignature(
                    selectorText: rule.selectorText,
                    sourceLabel: rule.sourceLabel
                )
                let ordinal = styleRuleOccurrences[signature, default: 0]
                styleRuleOccurrences[signature] = ordinal + 1
                append(
                    ItemStableID(
                        key: .styleRule(signature: signature, ordinal: ordinal),
                        cellKind: .macDetailItem
                    ),
                    .styleRule(selector: rule.selectorText, detail: detail)
                )
            }
            if inspector.selection.matchedStylesTruncated {
                append(
                    ItemStableID(key: .styleMeta(kind: .truncated), cellKind: .macDetailItem),
                    .styleMeta(message: wiLocalized("dom.element.styles.truncated"))
                )
            }
            if inspector.selection.blockedStylesheetCount > 0 {
                append(
                    ItemStableID(key: .styleMeta(kind: .blockedStylesheets), cellKind: .macDetailItem),
                    .styleMeta(message: "\(inspector.selection.blockedStylesheetCount) \(wiLocalized("dom.element.styles.blocked_stylesheets"))")
                )
            }
        }

        append(
            ItemStableID(key: .sectionHeader(.attributes), cellKind: .macDetailItem),
            .header(title: wiLocalized("dom.element.section.attributes"))
        )
        if inspector.selection.attributes.isEmpty {
            append(
                ItemStableID(key: .emptyAttribute, cellKind: .macDetailItem),
                .emptyAttribute(message: wiLocalized("dom.element.attributes.empty"))
            )
        } else {
            for attribute in inspector.selection.attributes {
                append(
                    ItemStableID(
                        key: .attribute(nodeID: attribute.nodeId, name: attribute.name),
                        cellKind: .macDetailItem
                    ),
                    .attribute(nodeID: attribute.nodeId, name: attribute.name, value: attribute.value)
                )
            }
        }

        return (stableIDs: stableIDs, payloadByID: payloadByID, revisionByID: revisionByID)
    }

    private func revision(for payload: ItemKind) -> Int {
        var hasher = Hasher()
        hasher.combine(payload)
        return hasher.finalize()
    }

    @objc
    private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        guard
            let indexPath = collectionView.indexPathForItem(at: point),
            let item = dataSource.itemIdentifier(for: indexPath),
            let payload = payloadByStableID[item.stableID],
            case let .attribute(_, name, value) = payload
        else {
            return
        }

        Task { [weak self] in
            guard let self else { return }
            guard let nextValue = await self.presentAttributeEditor(name: name, currentValue: value) else {
                return
            }
            self.inspector.updateAttributeValue(name: name, value: nextValue)
        }
    }

    private func presentAttributeEditor(name: String, currentValue: String) async -> String? {
        guard let window = view.window else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = name
            alert.informativeText = wiLocalized("dom.element.section.attributes")
            alert.addButton(withTitle: wiLocalized("common.save"))
            alert.addButton(withTitle: wiLocalized("common.cancel"))
            let textField = NSTextField(string: currentValue)
            textField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = textField
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: textField.stringValue)
            }
        }
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
        inspector.deleteSelectedNode()
    }
}

private final class ElementDetailsMacItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ElementDetailsMacItem")

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let stackView = NSStackView()

    override func loadView() {
        view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor

        stackView.orientation = .vertical
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        detailLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0

        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(detailLabel)
        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }

    func configure(with kind: ElementDetailsTabViewController.ItemKind) {
        switch kind {
        case let .placeholder(title, detail):
            titleLabel.stringValue = title
            detailLabel.stringValue = detail
            titleLabel.textColor = .secondaryLabelColor
            detailLabel.textColor = .tertiaryLabelColor
        case let .header(title):
            titleLabel.stringValue = title
            detailLabel.stringValue = ""
            titleLabel.textColor = .labelColor
            detailLabel.textColor = .clear
        case let .element(preview):
            titleLabel.stringValue = wiLocalized("dom.element.section.element")
            detailLabel.stringValue = preview
            titleLabel.textColor = .secondaryLabelColor
            detailLabel.textColor = .labelColor
        case let .selector(path):
            titleLabel.stringValue = wiLocalized("dom.element.section.selector")
            detailLabel.stringValue = path
            titleLabel.textColor = .secondaryLabelColor
            detailLabel.textColor = .labelColor
        case let .styleRule(selector, detail):
            titleLabel.stringValue = selector
            detailLabel.stringValue = detail
            titleLabel.textColor = .secondaryLabelColor
            detailLabel.textColor = .labelColor
        case let .styleMeta(message):
            titleLabel.stringValue = message
            detailLabel.stringValue = ""
            titleLabel.textColor = .secondaryLabelColor
            detailLabel.textColor = .clear
        case let .attribute(_, name, value):
            titleLabel.stringValue = name
            detailLabel.stringValue = value
            titleLabel.textColor = .secondaryLabelColor
            detailLabel.textColor = .labelColor
        case let .emptyAttribute(message):
            titleLabel.stringValue = message
            detailLabel.stringValue = ""
            titleLabel.textColor = .secondaryLabelColor
            detailLabel.textColor = .clear
        }
    }
}

#endif
