import WebInspectorKitCore

#if canImport(UIKit)
import UIKit

@MainActor
final class ElementDetailsTabViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case element
        case selector
        case styles
        case attributes
    }

    private let inspector: WebInspector.DOMInspector
    private let observationToken = WIObservationToken()
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

    init(inspector: WebInspector.DOMInspector) {
        self.inspector = inspector
        super.init(style: .insetGrouped)
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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        setupNavigationItems()

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

        let reloadAction = UIAction(
            title: wiLocalized("reload.target.inspector"),
            image: UIImage(systemName: "arrow.clockwise"),
            attributes: hasPageWebView ? [] : [.disabled]
        ) { [weak self] _ in
            self?.reloadInspector()
        }

        let deleteAction = UIAction(
            title: wiLocalized("inspector.delete_node"),
            image: UIImage(systemName: "trash"),
            attributes: hasSelection ? [.destructive] : [.destructive, .disabled]
        ) { [weak self] _ in
            self?.deleteNode()
        }

        return UIMenu(children: [reloadAction, deleteAction])
    }

    private func refreshUI() {
        let hasSelection = inspector.selection.nodeId != nil
        let hasPageWebView = inspector.hasPageWebView

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
        } else {
            contentUnavailableConfiguration = nil
        }

        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard inspector.selection.nodeId != nil else {
            return 0
        }

        guard let section = Section(rawValue: section) else {
            return 0
        }

        switch section {
        case .element:
            return 1
        case .selector:
            return 1
        case .styles:
            let styleRows = max(1, inspector.selection.matchedStyles.count)
            let truncatedRow = inspector.selection.matchedStylesTruncated ? 1 : 0
            let blockedRow = inspector.selection.blockedStylesheetCount > 0 ? 1 : 0
            return styleRows + truncatedRow + blockedRow
        case .attributes:
            return max(1, inspector.selection.attributes.count)
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section), inspector.selection.nodeId != nil else {
            return nil
        }

        switch section {
        case .element:
            return wiLocalized("dom.element.section.element")
        case .selector:
            return wiLocalized("dom.element.section.selector")
        case .styles:
            return wiLocalized("dom.element.section.styles")
        case .attributes:
            return wiLocalized("dom.element.section.attributes")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var configuration = cell.defaultContentConfiguration()
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryTextProperties.numberOfLines = 0
        cell.accessoryType = .none

        guard let section = Section(rawValue: indexPath.section) else {
            cell.contentConfiguration = configuration
            return cell
        }

        switch section {
        case .element:
            configuration.text = inspector.selection.preview
            configuration.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        case .selector:
            configuration.text = inspector.selection.selectorPath
            configuration.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        case .styles:
            configureStyleCell(configuration: &configuration, row: indexPath.row)
        case .attributes:
            configureAttributeCell(configuration: &configuration, row: indexPath.row)
        }

        cell.contentConfiguration = configuration
        return cell
    }

    private func configureStyleCell(configuration: inout UIListContentConfiguration, row: Int) {
        if inspector.selection.isLoadingMatchedStyles {
            configuration.text = wiLocalized("dom.element.styles.loading")
            configuration.textProperties.color = .secondaryLabel
            return
        }

        let rules = inspector.selection.matchedStyles
        var nextRow = 0

        if rules.isEmpty {
            if row == nextRow {
                configuration.text = wiLocalized("dom.element.styles.empty")
                configuration.textProperties.color = .secondaryLabel
                return
            }
            nextRow += 1
        } else if row < rules.count {
            let rule = rules[row]
            configuration.text = rule.selectorText
            let declarations = rule.declarations.map { declaration in
                let importantSuffix = declaration.important ? " !important" : ""
                return "\(declaration.name): \(declaration.value)\(importantSuffix);"
            }
            var details = declarations.joined(separator: "\n")
            if !rule.sourceLabel.isEmpty {
                details = "\(rule.sourceLabel)\n\(details)"
            }
            configuration.secondaryText = details
            configuration.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            return
        }
        nextRow += rules.count

        if inspector.selection.matchedStylesTruncated, row == nextRow {
            configuration.text = wiLocalized("dom.element.styles.truncated")
            configuration.textProperties.color = .secondaryLabel
            return
        }
        if inspector.selection.matchedStylesTruncated {
            nextRow += 1
        }

        if inspector.selection.blockedStylesheetCount > 0, row == nextRow {
            configuration.text = "\(inspector.selection.blockedStylesheetCount) \(wiLocalized("dom.element.styles.blocked_stylesheets"))"
            configuration.textProperties.color = .secondaryLabel
            return
        }

        configuration.text = nil
    }

    private func configureAttributeCell(configuration: inout UIListContentConfiguration, row: Int) {
        guard !inspector.selection.attributes.isEmpty else {
            configuration.text = wiLocalized("dom.element.attributes.empty")
            configuration.textProperties.color = .secondaryLabel
            return
        }

        let attribute = inspector.selection.attributes[row]
        configuration.text = attribute.name
        configuration.secondaryText = attribute.value
        configuration.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        configuration.textProperties.color = .secondaryLabel
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer {
            tableView.deselectRow(at: indexPath, animated: true)
        }

        guard
            let section = Section(rawValue: indexPath.section),
            section == .attributes,
            inspector.selection.attributes.indices.contains(indexPath.row)
        else {
            return
        }

        let attribute = inspector.selection.attributes[indexPath.row]
        let alert = UIAlertController(
            title: attribute.name,
            message: wiLocalized("dom.element.section.attributes"),
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = attribute.value
            textField.clearButtonMode = .whileEditing
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: wiLocalized("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: wiLocalized("common.save"), style: .default) { [weak self] _ in
            guard
                let self,
                let value = alert.textFields?.first?.text
            else {
                return
            }
            self.inspector.updateAttributeValue(name: attribute.name, value: value)
        })
        present(alert, animated: true)
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard
            let section = Section(rawValue: indexPath.section),
            section == .attributes,
            inspector.selection.attributes.indices.contains(indexPath.row)
        else {
            return nil
        }

        let attribute = inspector.selection.attributes[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: wiLocalized("delete")) { [weak self] _, _, completion in
            self?.inspector.removeAttribute(name: attribute.name)
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
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

    private let inspector: WebInspector.DOMInspector
    private let observationToken = WIObservationToken()

    private let tableView = NSTableView()
    private var rows: [Row] = []

    init(inspector: WebInspector.DOMInspector) {
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
