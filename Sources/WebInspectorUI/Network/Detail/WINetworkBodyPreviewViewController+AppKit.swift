import Foundation
import ObservationBridge
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit

@MainActor
final class WINetworkBodyPreviewViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private struct ObservedFormEntryState: Equatable {
        let name: String
        let value: String
        let isFile: Bool
        let fileName: String?
    }

    private struct ObservedBodyState: Equatable {
        let role: NetworkBody.Role
        let kind: NetworkBody.Kind
        let preview: String?
        let full: String?
        let size: Int?
        let isBase64Encoded: Bool
        let isTruncated: Bool
        let summary: String?
        let reference: String?
        let formEntries: [ObservedFormEntryState]
        let fetchState: NetworkBody.FetchState
    }

    private final class TreeItem: NSObject {
        let node: NetworkJSONNode
        let path: String
        let pathComponents: [NetworkBodyPreviewTreeMenuSupport.PathComponent]
        let children: [TreeItem]

        init(
            node: NetworkJSONNode,
            path: String,
            pathComponents: [NetworkBodyPreviewTreeMenuSupport.PathComponent],
            children: [TreeItem]
        ) {
            self.node = node
            self.path = path
            self.pathComponents = pathComponents
            self.children = children
        }
    }

    private enum CellIdentifiers {
        static let tree = NSUserInterfaceItemIdentifier("WINetworkBodyPreview.TreeCell")
        static let key = NSUserInterfaceItemIdentifier("WINetworkBodyPreview.TreeKey")
        static let value = NSUserInterfaceItemIdentifier("WINetworkBodyPreview.TreeValue")
        static let icon = NSUserInterfaceItemIdentifier("WINetworkBodyPreview.TreeIcon")
    }

    private let inspector: WINetworkModel
    private let role: NetworkBody.Role
    private let selectedEntryIDForPresentation: UUID

    private var mode: NetworkBodyPreviewRenderModel.Mode = .text
    private var hasUserSelectedMode = false
    private var renderModel: NetworkBodyPreviewRenderModel?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration: UInt64 = 0
    private var selectionObservationHandles: Set<ObservationHandle> = []
    private var entryObservationHandles: Set<ObservationHandle> = []
    private var bodyObservationHandles: Set<ObservationHandle> = []
    private var rootItems: [TreeItem] = []
    private weak var contextMenuItem: TreeItem?

    private let rootStack = NSStackView()
    private let contentContainer = NSView()
    private let modeControl = NSSegmentedControl(
        labels: [
            wiLocalized("network.body.preview.mode.text", default: "Text"),
            wiLocalized("network.body.preview.mode.json", default: "Object Tree")
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let textScrollView: NSScrollView
    private let textView: NSTextView
    private let outlineScrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let outlineColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WINetworkBodyPreview.TreeColumn"))
    private lazy var treeMenu: NSMenu = {
        let menu = NSMenu(title: "Tree")
        menu.delegate = self
        return menu
    }()

    init(inspector: WINetworkModel, role: NetworkBody.Role, selectedEntryIDForPresentation: UUID) {
        self.inspector = inspector
        self.role = role
        self.selectedEntryIDForPresentation = selectedEntryIDForPresentation

        let scrollableTextView = NSTextView.scrollableTextView()
        guard let textView = scrollableTextView.documentView as? NSTextView else {
            fatalError("Expected NSTextView.scrollableTextView() document view to be NSTextView")
        }
        self.textScrollView = scrollableTextView
        self.textView = textView

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        renderTask?.cancel()
        selectionObservationHandles.removeAll()
        entryObservationHandles.removeAll()
        bodyObservationHandles.removeAll()
    }

    var availableModesForTesting: [NetworkBodyPreviewRenderModel.Mode] {
        renderModel?.availableModes ?? []
    }

    var currentModeForTesting: NetworkBodyPreviewRenderModel.Mode {
        mode
    }

    var currentBodyIdentityForTesting: ObjectIdentifier? {
        currentBody.map(ObjectIdentifier.init)
    }

    var bodyRoleForTesting: NetworkBody.Role {
        role
    }

    var entryIDForTesting: UUID {
        selectedEntryIDForPresentation
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        applyTitle()
        startObservingSelectedEntry()
        rebindSelectedEntry()
    }

    private func configureHierarchy() {
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = NetworkBodyPreviewRenderModel.Mode.text.rawValue
        modeControl.isHidden = true

        textScrollView.translatesAutoresizingMaskIntoConstraints = false
        textScrollView.drawsBackground = false
        textScrollView.borderType = .noBorder
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)

        outlineScrollView.translatesAutoresizingMaskIntoConstraints = false
        outlineScrollView.drawsBackground = false
        outlineScrollView.borderType = .noBorder
        outlineScrollView.hasVerticalScroller = true
        outlineScrollView.autohidesScrollers = true

        outlineView.addTableColumn(outlineColumn)
        outlineView.outlineTableColumn = outlineColumn
        outlineView.headerView = nil
        outlineView.rowHeight = 28
        outlineView.selectionHighlightStyle = .regular
        outlineView.style = .fullWidth
        outlineView.menu = treeMenu
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineScrollView.documentView = outlineView

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(textScrollView)
        contentContainer.addSubview(outlineScrollView)

        NSLayoutConstraint.activate([
            textScrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            textScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            textScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            textScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            outlineScrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            outlineScrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            outlineScrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            outlineScrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            contentContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ])

        rootStack.addArrangedSubview(modeControl)
        rootStack.addArrangedSubview(contentContainer)

        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            contentContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
    }

    @objc
    private func modeChanged() {
        hasUserSelectedMode = true
        mode = modeControl.selectedSegment == NetworkBodyPreviewRenderModel.Mode.objectTree.rawValue
            ? .objectTree
            : .text
        applyVisibleMode()
    }

    private func startObservingSelectedEntry() {
        inspector.observe(
            [\.selectedEntry],
            onChange: { [weak self] in
                self?.rebindSelectedEntry()
            },
            isolation: MainActor.shared
        )
        .store(in: &selectionObservationHandles)
    }

    private func rebindSelectedEntry() {
        entryObservationHandles.removeAll()
        bodyObservationHandles.removeAll()

        guard let entry = currentEntry else {
            dismissIfSelectionIsUnavailable()
            return
        }

        requestRenderModelUpdate()

        let bodyKeyPath: KeyPath<NetworkEntry, NetworkBody?> = role == .request
            ? \.requestBody
            : \.responseBody

        let initialBodyIdentity = entry[keyPath: bodyKeyPath].map(ObjectIdentifier.init)
        var ignoresInitialEmission = true
        entry.observe(
            bodyKeyPath,
            onChange: { [weak self, weak entry] _ in
                guard let self, let entry else {
                    return
                }
                guard self.currentEntry?.id == entry.id else {
                    return
                }
                let currentBodyIdentity = self.currentBody.map(ObjectIdentifier.init)
                if ignoresInitialEmission {
                    ignoresInitialEmission = false
                    guard currentBodyIdentity != initialBodyIdentity else {
                        return
                    }
                }
                self.rebindSelectedEntry()
            },
            isolation: MainActor.shared
        )
        .store(in: &entryObservationHandles)

        guard let body = currentBody else {
            dismissIfSelectionIsUnavailable()
            return
        }

        let initialBodyState = makeObservedBodyState(from: body)
        var ignoresInitialBodyEmission = true
        body.observeTask(
            [
                \.role,
                \.kind,
                \.preview,
                \.full,
                \.size,
                \.isBase64Encoded,
                \.isTruncated,
                \.summary,
                \.reference,
                \.formEntries,
                \.fetchState
            ]
        ) { [weak self, weak entry] in
            guard let self, let entry else {
                return
            }
            guard self.currentEntry?.id == entry.id else {
                return
            }
            guard self.currentBody.map(ObjectIdentifier.init) == ObjectIdentifier(body) else {
                return
            }
            let currentBodyState = self.makeObservedBodyState(from: body)
            if ignoresInitialBodyEmission {
                ignoresInitialBodyEmission = false
                guard currentBodyState != initialBodyState else {
                    return
                }
            }
            self.requestRenderModelUpdate()
        }
        .store(in: &bodyObservationHandles)
    }

    private func requestRenderModelUpdate() {
        renderTask?.cancel()
        renderGeneration &+= 1
        let generation = renderGeneration
        guard let bodyState = currentBody else {
            dismissIfSelectionIsUnavailable()
            return
        }
        let input = NetworkBodyPreviewRenderModel.Input(
            body: bodyState,
            unavailableText: wiLocalized("network.body.unavailable", default: "Body unavailable")
        )
        renderTask = Task(priority: .userInitiated) { [weak self, generation, input] in
            let workerTask = Task.detached(priority: .userInitiated) {
                NetworkBodyPreviewRenderModel.make(from: input)
            }
            let model = await withTaskCancellationHandler {
                await workerTask.value
            } onCancel: {
                workerTask.cancel()
            }
            guard
                Task.isCancelled == false,
                let self,
                self.renderGeneration == generation
            else {
                return
            }
            self.applyRenderModel(model)
        }
    }

    private func applyRenderModel(_ model: NetworkBodyPreviewRenderModel) {
        renderModel = model
        applyTitle()
        let hasObjectTree = model.availableModes.contains(.objectTree)
        modeControl.isHidden = hasObjectTree == false

        if hasUserSelectedMode == false {
            mode = model.preferredMode
        } else if model.availableModes.contains(mode) == false {
            mode = model.preferredMode
            hasUserSelectedMode = false
        }

        modeControl.selectedSegment = mode.rawValue
        rootItems = buildTreeItems(from: model.objectTreeNodes)
        reloadOutlineView()
        updateTextView()
        applyVisibleMode()
    }

    private func applyVisibleMode() {
        let shouldShowTree = mode == .objectTree && (renderModel?.availableModes.contains(.objectTree) ?? false)
        outlineScrollView.isHidden = shouldShowTree == false
        textScrollView.isHidden = shouldShowTree
    }

    private func updateTextView() {
        let unavailableText = wiLocalized("network.body.unavailable", default: "Body unavailable")
        guard let model = renderModel else {
            textView.string = unavailableText
            return
        }

        textView.string = model.displayText(
            for: currentBody?.fetchState ?? .inline,
            fetchingText: wiLocalized("network.body.fetching", default: "Fetching body..."),
            unavailableText: unavailableText
        )
    }

    private func applyTitle() {
        title = role == .request
            ? wiLocalized("network.section.body.request", default: "Request Body")
            : wiLocalized("network.section.body.response", default: "Response Body")
    }

    private var currentEntry: NetworkEntry? {
        guard inspector.selectedEntry?.id == selectedEntryIDForPresentation else {
            return nil
        }
        return inspector.selectedEntry
    }

    private var currentBody: NetworkBody? {
        guard let entry = currentEntry else {
            return nil
        }
        switch role {
        case .request:
            return entry.requestBody
        case .response:
            return entry.responseBody
        }
    }

    private func dismissIfSelectionIsUnavailable() {
        guard currentBody == nil else {
            return
        }
        if isViewLoaded {
            dismiss(nil)
        }
    }

    private func reloadOutlineView() {
        let expandedPaths = currentExpandedPaths()
        outlineView.reloadData()
        if expandedPaths.isEmpty {
            for item in rootItems where item.children.isEmpty == false {
                outlineView.expandItem(item)
            }
        } else {
            restoreExpansion(for: rootItems, expandedPaths: expandedPaths)
        }
    }

    private func currentExpandedPaths() -> Set<String> {
        var paths: Set<String> = []
        for row in 0..<outlineView.numberOfRows {
            guard outlineView.isItemExpanded(outlineView.item(atRow: row)) else {
                continue
            }
            if let item = outlineView.item(atRow: row) as? TreeItem {
                paths.insert(item.path)
            }
        }
        return paths
    }

    private func restoreExpansion(for items: [TreeItem], expandedPaths: Set<String>) {
        for item in items {
            if expandedPaths.contains(item.path) {
                outlineView.expandItem(item)
            }
            restoreExpansion(for: item.children, expandedPaths: expandedPaths)
        }
    }

    private func buildTreeItems(
        from nodes: [NetworkJSONNode],
        parentPath: String = "$",
        pathComponents: [NetworkBodyPreviewTreeMenuSupport.PathComponent] = []
    ) -> [TreeItem] {
        nodes.map { node in
            let currentPathComponents = pathComponents + [
                NetworkBodyPreviewTreeMenuSupport.PathComponent(
                    key: node.key,
                    isIndex: node.isIndex
                )
            ]
            let itemPath = parentPath + treePathSegment(for: node)
            let children = buildTreeItems(
                from: node.children ?? [],
                parentPath: itemPath,
                pathComponents: currentPathComponents
            )
            return TreeItem(
                node: node,
                path: itemPath,
                pathComponents: currentPathComponents,
                children: children
            )
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? TreeItem else {
            return rootItems.count
        }
        return item.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        _ = outlineView
        guard let item = item as? TreeItem else {
            return false
        }
        return item.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        _ = outlineView
        guard let item = item as? TreeItem else {
            return rootItems[index]
        }
        return item.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        _ = tableColumn
        guard let item = item as? TreeItem else {
            return nil
        }

        let cellView: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: CellIdentifiers.tree, owner: nil) as? NSTableCellView {
            cellView = reused
        } else {
            cellView = makeTreeCellView()
        }

        let iconView = cellView.subviews.first(where: { $0.identifier == CellIdentifiers.icon }) as? NSImageView
        let keyLabel = cellView.subviews.first(where: { $0.identifier == CellIdentifiers.key }) as? NSTextField
        let valueLabel = cellView.subviews.first(where: { $0.identifier == CellIdentifiers.value }) as? NSTextField
        let display = treeDisplay(for: item.node)

        iconView?.image = treeSymbolImage(for: item.node)
        iconView?.contentTintColor = treeSymbolTintColor(for: item.node)
        keyLabel?.stringValue = display.key
        valueLabel?.stringValue = display.value

        return cellView
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outlineView.clickedRow >= 0,
              let item = outlineView.item(atRow: outlineView.clickedRow) as? TreeItem else {
            contextMenuItem = nil
            return
        }

        contextMenuItem = item
        let copyValueItem = NSMenuItem(
            title: wiLocalized("network.body.preview.context.copy.value", default: "Value"),
            action: #selector(copyTreeValue),
            keyEquivalent: ""
        )
        copyValueItem.target = self
        copyValueItem.isEnabled = NetworkBodyPreviewTreeMenuSupport.scalarCopyText(for: item.node) != nil
        menu.addItem(copyValueItem)

        let copyJSONItem = NSMenuItem(
            title: wiLocalized("network.body.preview.context.copy.json", default: "JSON"),
            action: #selector(copyTreeJSON),
            keyEquivalent: ""
        )
        copyJSONItem.target = self
        copyJSONItem.isEnabled = NetworkBodyPreviewTreeMenuSupport.subtreeCopyText(for: item.node) != nil
        menu.addItem(copyJSONItem)

        let copyPathItem = NSMenuItem(
            title: wiLocalized("network.body.preview.context.copy.path", default: "Path"),
            action: #selector(copyTreePath),
            keyEquivalent: ""
        )
        copyPathItem.target = self
        menu.addItem(copyPathItem)

        menu.addItem(.separator())

        let expandItem = NSMenuItem(
            title: wiLocalized("network.body.preview.context.expand_all", default: "Expand All"),
            action: #selector(expandTreeItem),
            keyEquivalent: ""
        )
        expandItem.target = self
        expandItem.isEnabled = item.children.isEmpty == false
        menu.addItem(expandItem)
    }

    @objc
    private func copyTreeValue() {
        guard let item = contextMenuItem,
              let text = NetworkBodyPreviewTreeMenuSupport.scalarCopyText(for: item.node) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc
    private func copyTreeJSON() {
        guard let item = contextMenuItem,
              let text = NetworkBodyPreviewTreeMenuSupport.subtreeCopyText(for: item.node) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc
    private func copyTreePath() {
        guard let item = contextMenuItem else {
            return
        }
        let path = NetworkBodyPreviewTreeMenuSupport.propertyPathString(from: item.pathComponents)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc
    private func expandTreeItem() {
        guard let item = contextMenuItem else {
            return
        }
        outlineView.expandItem(item, expandChildren: true)
    }

    private func makeTreeCellView() -> NSTableCellView {
        let cellView = NSTableCellView()
        cellView.identifier = CellIdentifiers.tree

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.identifier = CellIdentifiers.icon
        iconView.imageScaling = .scaleProportionallyDown

        let keyLabel = WINetworkAppKitViewFactory.makeLabel(
            "",
            font: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
        )
        keyLabel.identifier = CellIdentifiers.key
        keyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let valueLabel = WINetworkAppKitViewFactory.makeSecondaryLabel("", monospaced: true)
        valueLabel.identifier = CellIdentifiers.value
        valueLabel.alignment = .right
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        cellView.addSubview(iconView)
        cellView.addSubview(keyLabel)
        cellView.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            keyLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            keyLabel.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),

            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: keyLabel.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -6),
            valueLabel.centerYAnchor.constraint(equalTo: cellView.centerYAnchor)
        ])

        return cellView
    }

    private func treePathSegment(for node: NetworkJSONNode) -> String {
        if node.isIndex {
            return "/i:\(encodedPathComponent(node.key))"
        }
        return "/k:\(encodedPathComponent(node.key))"
    }

    private func encodedPathComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func treeDisplay(for node: NetworkJSONNode) -> (key: String, value: String) {
        let key = node.key.isEmpty ? "(root)" : node.key
        let value: String
        switch node.displayKind {
        case .object:
            value = "Object"
        case .array(let count):
            value = "Array (\(count))"
        case .string(let string):
            value = "\"\(truncate(string))\""
        case .number(let number):
            value = number
        case .bool(let flag):
            value = flag ? "true" : "false"
        case .null:
            value = "null"
        }
        return (key, value)
    }

    private func treeSymbolImage(for node: NetworkJSONNode) -> NSImage? {
        let symbolName: String
        switch node.displayKind {
        case .object:
            symbolName = "curlybraces"
        case .array:
            symbolName = "list.number"
        case .string:
            symbolName = "textformat.abc"
        case .number:
            symbolName = "number"
        case .bool(let flag):
            symbolName = flag ? "checkmark.circle" : "xmark.circle"
        case .null:
            symbolName = "nosign"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    private func treeSymbolTintColor(for node: NetworkJSONNode) -> NSColor {
        switch node.displayKind {
        case .object:
            return .systemBlue
        case .array:
            return .systemPurple
        case .string:
            return .systemOrange
        case .number:
            return .systemGreen
        case .bool:
            return .systemRed
        case .null:
            return .secondaryLabelColor
        }
    }

    private func truncate(_ value: String, limit: Int = 200) -> String {
        guard value.count > limit else {
            return value
        }
        let index = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<index]) + "..."
    }

    private func makeObservedBodyState(from body: NetworkBody) -> ObservedBodyState {
        ObservedBodyState(
            role: body.role,
            kind: body.kind,
            preview: body.preview,
            full: body.full,
            size: body.size,
            isBase64Encoded: body.isBase64Encoded,
            isTruncated: body.isTruncated,
            summary: body.summary,
            reference: body.reference,
            formEntries: body.formEntries.map {
                ObservedFormEntryState(
                    name: $0.name,
                    value: $0.value,
                    isFile: $0.isFile,
                    fileName: $0.fileName
                )
            },
            fetchState: body.fetchState
        )
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Network Body Preview Object Tree (AppKit)") {
    WIAppKitPreviewContainer {
        guard let context = WINetworkPreviewFixtures.makeBodyPreviewContext(textMode: false) else {
            return NSViewController()
        }
        return WINetworkBodyPreviewViewController(
            inspector: context.inspector,
            role: context.body.role,
            selectedEntryIDForPresentation: context.entry.id
        )
    }
}

#Preview("Network Body Preview Text (AppKit)") {
    WIAppKitPreviewContainer {
        guard let context = WINetworkPreviewFixtures.makeBodyPreviewContext(textMode: true) else {
            return NSViewController()
        }
        return WINetworkBodyPreviewViewController(
            inspector: context.inspector,
            role: context.body.role,
            selectedEntryIDForPresentation: context.entry.id
        )
    }
}
#endif
#endif
