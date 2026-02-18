import WebInspectorKitCore

#if canImport(UIKit)
import UIKit

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
final class ElementDetailsTabViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    private struct DetailSection {
        let title: String
        let rows: [DetailRow]
    }

    private enum DetailRow {
        case element(preview: String)
        case selector(path: String)
        case styleRule(selector: String, detail: String)
        case styleMeta(String)
        case attribute(nodeID: Int?, name: String, value: String)
        case emptyAttribute
    }

    private let inspector: WIDOMPaneViewModel
    private let observationToken = WIObservationToken()
    private var sections: [DetailSection] = []
    private let listCellReuseIdentifier = "ElementDetailsListCell"
    private let attributeEditorCellReuseIdentifier = "ElementDetailsAttributeEditorCell"
    private let headerReuseIdentifier = "ElementDetailsHeaderView"
    private var editingAttributeKey: ElementAttributeEditingKey?
    private var editingDraftValue: String?
    private var isInlineEditingActive = false
    private var lastSelectionNodeID: Int?

    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: listCellReuseIdentifier)
        collectionView.register(ElementAttributeEditorCell.self, forCellWithReuseIdentifier: attributeEditorCellReuseIdentifier)
        collectionView.register(
            UICollectionViewListCell.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: headerReuseIdentifier
        )
        return collectionView
    }()

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
        collectionView.reloadData()
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
            title: wiLocalized("dom.element.section.element"),
            rows: [.element(preview: inspector.selection.preview)]
        )

        let selectorSection = DetailSection(
            title: wiLocalized("dom.element.section.selector"),
            rows: [.selector(path: inspector.selection.selectorPath)]
        )

        var styleRows: [DetailRow] = []
        if inspector.selection.isLoadingMatchedStyles {
            styleRows.append(.styleMeta(wiLocalized("dom.element.styles.loading")))
        } else if inspector.selection.matchedStyles.isEmpty {
            styleRows.append(.styleMeta(wiLocalized("dom.element.styles.empty")))
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
                styleRows.append(.styleRule(selector: rule.selectorText, detail: details))
            }
        }
        if inspector.selection.matchedStylesTruncated {
            styleRows.append(.styleMeta(wiLocalized("dom.element.styles.truncated")))
        }
        if inspector.selection.blockedStylesheetCount > 0 {
            let blocked = "\(inspector.selection.blockedStylesheetCount) \(wiLocalized("dom.element.styles.blocked_stylesheets"))"
            styleRows.append(.styleMeta(blocked))
        }

        let styleSection = DetailSection(
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
            title: wiLocalized("dom.element.section.attributes"),
            rows: attributeRows
        )

        return [elementSection, selectorSection, styleSection, attributeSection]
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard sections.indices.contains(section) else {
            return 0
        }
        return sections[section].rows.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard
            sections.indices.contains(indexPath.section),
            sections[indexPath.section].rows.indices.contains(indexPath.item)
        else {
            return UICollectionViewCell()
        }

        let row = sections[indexPath.section].rows[indexPath.item]
        if case let .attribute(nodeID, name, value) = row {
            guard
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: attributeEditorCellReuseIdentifier,
                    for: indexPath
                ) as? ElementAttributeEditorCell
            else {
                return UICollectionViewCell()
            }
            let key = ElementAttributeEditingKey(nodeID: nodeID, name: name)
            cell.delegate = self
            cell.configure(
                key: key,
                name: name,
                value: value,
                activateEditor: isInlineEditingActive && editingAttributeKey == key
            )
            return cell
        }

        guard
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: listCellReuseIdentifier,
                for: indexPath
            ) as? UICollectionViewListCell
        else {
            return UICollectionViewCell()
        }

        var configuration = UIListContentConfiguration.cell()
        cell.accessories = []

        switch row {
        case .element(let preview):
            configuration = UIListContentConfiguration.cell()
            configuration.text = preview
            configuration.textProperties.numberOfLines = 0
            configuration.textProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                    weight: .regular
                )
            )
            configuration.textProperties.color = .label
        case .selector(let path):
            configuration = UIListContentConfiguration.cell()
            configuration.text = path
            configuration.textProperties.numberOfLines = 0
            configuration.textProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
                for: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                    weight: .regular
                )
            )
            configuration.textProperties.color = .label
        case .styleRule(let selector, let details):
            configuration = UIListContentConfiguration.subtitleCell()
            configuration.text = selector
            configuration.secondaryText = details
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
        case .styleMeta(let message):
            configuration = UIListContentConfiguration.cell()
            configuration.text = message
            configuration.textProperties.color = .secondaryLabel
            configuration.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        case .attribute:
            configuration = UIListContentConfiguration.cell()
        case .emptyAttribute:
            configuration = UIListContentConfiguration.cell()
            configuration.text = wiLocalized("dom.element.attributes.empty")
            configuration.textProperties.color = .secondaryLabel
        }

        cell.contentConfiguration = configuration
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        guard
            kind == UICollectionView.elementKindSectionHeader,
            sections.indices.contains(indexPath.section),
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: headerReuseIdentifier,
                for: indexPath
            ) as? UICollectionViewListCell
        else {
            return UICollectionReusableView()
        }
        var configuration = UIListContentConfiguration.header()
        configuration.text = sections[indexPath.section].title
        header.contentConfiguration = configuration
        return header
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
            sections.indices.contains(indexPath.section),
            sections[indexPath.section].rows.indices.contains(indexPath.item)
        else {
            return nil
        }
        guard case let .attribute(nodeID, name, value) = sections[indexPath.section].rows[indexPath.item] else {
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
        collectionView.reloadData()
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

@MainActor
final class ElementDetailsTabViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private struct Row {
        enum Kind {
            case element
            case selector
            case style
            case styleMeta
            case attribute
            case placeholder
        }

        let kind: Kind
        let title: String
        let detail: String
    }

    private let inspector: WIDOMPaneViewModel
    private let observationToken = WIObservationToken()

    private let tableView = NSTableView()
    private var rows: [Row] = []

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

        let reloadButton = NSButton(title: wiLocalized("reload"), target: self, action: #selector(reloadInspector))
        reloadButton.bezelStyle = .rounded
        let pickButton = NSButton(title: wiLocalized("dom.controls.pick"), target: self, action: #selector(toggleSelectionMode))
        pickButton.bezelStyle = .rounded
        let deleteButton = NSButton(title: wiLocalized("inspector.delete_node"), target: self, action: #selector(deleteNode))
        deleteButton.bezelStyle = .rounded
        deleteButton.identifier = NSUserInterfaceItemIdentifier("deleteNode")

        let buttonStack = NSStackView(views: [pickButton, reloadButton, deleteButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Title")))
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Detail")))
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(handleRowDoubleClick)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

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
        }, onChange: { [weak self] in
            self?.reloadRows()
        })

        reloadRows()
    }

    private func reloadRows() {
        rows.removeAll(keepingCapacity: true)

        guard inspector.selection.nodeId != nil else {
            rows.append(Row(kind: .placeholder, title: wiLocalized("dom.element.select_prompt"), detail: wiLocalized("dom.element.hint")))
            tableView.reloadData()
            return
        }

        rows.append(Row(kind: .element, title: wiLocalized("dom.element.section.element"), detail: inspector.selection.preview))
        rows.append(Row(kind: .selector, title: wiLocalized("dom.element.section.selector"), detail: inspector.selection.selectorPath))

        if inspector.selection.isLoadingMatchedStyles {
            rows.append(Row(kind: .styleMeta, title: wiLocalized("dom.element.styles.loading"), detail: ""))
        } else if inspector.selection.matchedStyles.isEmpty {
            rows.append(Row(kind: .styleMeta, title: wiLocalized("dom.element.styles.empty"), detail: ""))
        } else {
            for rule in inspector.selection.matchedStyles {
                let declarations = rule.declarations.map { declaration in
                    let importantSuffix = declaration.important ? " !important" : ""
                    return "\(declaration.name): \(declaration.value)\(importantSuffix);"
                }.joined(separator: "\n")
                rows.append(Row(kind: .style, title: rule.selectorText, detail: declarations))
            }
            if inspector.selection.matchedStylesTruncated {
                rows.append(Row(kind: .styleMeta, title: wiLocalized("dom.element.styles.truncated"), detail: ""))
            }
            if inspector.selection.blockedStylesheetCount > 0 {
                rows.append(Row(kind: .styleMeta, title: "\(inspector.selection.blockedStylesheetCount) \(wiLocalized("dom.element.styles.blocked_stylesheets"))", detail: ""))
            }
        }

        if inspector.selection.attributes.isEmpty {
            rows.append(Row(kind: .attribute, title: wiLocalized("dom.element.attributes.empty"), detail: ""))
        } else {
            for attribute in inspector.selection.attributes {
                rows.append(Row(kind: .attribute, title: attribute.name, detail: attribute.value))
            }
        }

        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else {
            return nil
        }

        let rowData = rows[row]
        let identifier = NSUserInterfaceItemIdentifier("Cell-\(tableColumn?.identifier.rawValue ?? "")")
        let textField: NSTextField

        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            textField = existing
        } else {
            textField = NSTextField(labelWithString: "")
            textField.identifier = identifier
            textField.lineBreakMode = .byTruncatingTail
            textField.maximumNumberOfLines = 3
        }

        if tableColumn?.identifier.rawValue == "Title" {
            textField.stringValue = rowData.title
            textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        } else {
            textField.stringValue = rowData.detail
            textField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textField.textColor = .secondaryLabelColor
        }
        return textField
    }

    @objc
    private func handleRowDoubleClick() {
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else {
            return
        }

        let rowData = rows[row]
        guard rowData.kind == .attribute,
              inspector.selection.attributes.isEmpty == false,
              let attribute = inspector.selection.attributes.first(where: { $0.name == rowData.title })
        else {
            return
        }

        let alert = NSAlert()
        alert.messageText = attribute.name
        alert.informativeText = wiLocalized("dom.element.section.attributes")
        alert.addButton(withTitle: wiLocalized("common.save"))
        alert.addButton(withTitle: wiLocalized("common.cancel"))

        let textField = NSTextField(string: attribute.value)
        textField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            inspector.updateAttributeValue(name: attribute.name, value: textField.stringValue)
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

#endif
