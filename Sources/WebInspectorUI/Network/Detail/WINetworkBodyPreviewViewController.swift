#if canImport(UIKit)
import Foundation
import UIKit
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
public final class WINetworkBodyPreviewViewController: UIViewController, UICollectionViewDelegate {
    private enum SectionIdentifier: Hashable {
        case main
    }

    private struct TreeItem: Hashable, Sendable {
        let path: String
    }

    private struct TreeItemPayload {
        let node: NetworkJSONNode
        let hasChildren: Bool
        let pathComponents: [NetworkBodyPreviewTreeMenuSupport.PathComponent]
    }

    private struct TypeBadgeStyle {
        let letter: String
        let fillColor: UIColor
    }

    private enum TypeBadgePaletteToken {
        case yellow
        case blue
        case purple
        case red
        case grey
    }

    private let entry: NetworkEntry
    private let inspector: WINetworkModel
    private let bodyState: NetworkBody

    private var mode: NetworkBodyPreviewRenderModel.Mode = .text
    private var hasUserSelectedMode = false
    private var renderModel: NetworkBodyPreviewRenderModel?

    private let renderGeneration = NetworkBodyPreviewRenderGeneration()
    private var renderTask: Task<Void, Never>?
    private var hasAppliedInitialTreeSnapshot = false

    private var treePayloadByItem: [TreeItem: TreeItemPayload] = [:]
    private lazy var treeDataSource = makeTreeDataSource()

    private lazy var modeControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [
            wiLocalized("network.body.preview.mode.text", default: "Text"),
            wiLocalized("network.body.preview.mode.json", default: "Object Tree")
        ])
        control.selectedSegmentIndex = NetworkBodyPreviewRenderModel.Mode.text.rawValue
        control.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        return control
    }()

    private let textView = UITextView()
    private lazy var treeView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: makeTreeLayout())
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alwaysBounceVertical = true
        view.contentInsetAdjustmentBehavior = .automatic
        view.keyboardDismissMode = .onDrag
        view.delegate = self
        return view
    }()

    public init(entry: NetworkEntry, inspector: WINetworkModel, bodyState: NetworkBody) {
        self.entry = entry
        self.inspector = inspector
        self.bodyState = bodyState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        renderTask?.cancel()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.contentInsetAdjustmentBehavior = .automatic
        textView.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular
        )
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        view.addSubview(textView)

        treeView.backgroundColor = .clear
        view.addSubview(treeView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            treeView.topAnchor.constraint(equalTo: view.topAnchor),
            treeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            treeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            treeView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        modeControl.isHidden = true
        navigationItem.titleView = modeControl
        applyTitle()
        updateSecondaryMenu()
        requestRenderModelUpdate()

        Task {
            await inspector.fetchBodyIfNeeded(for: entry, body: bodyState)
            self.requestRenderModelUpdate()
        }
    }

    @objc
    private func modeChanged() {
        hasUserSelectedMode = true
        mode = modeControl.selectedSegmentIndex == NetworkBodyPreviewRenderModel.Mode.objectTree.rawValue
            ? .objectTree
            : .text
        applyVisibleMode()
    }

    private func requestRenderModelUpdate() {
        renderTask?.cancel()
        let generation = renderGeneration.advance()
        let input = NetworkBodyPreviewRenderModel.Input(
            body: bodyState,
            unavailableText: wiLocalized("network.body.unavailable", default: "Body unavailable")
        )

        renderTask = Task { [weak self] in
            let model = await Task.detached(priority: .userInitiated) {
                NetworkBodyPreviewRenderModel.make(from: input)
            }.value

            guard let self, !Task.isCancelled else {
                return
            }
            guard self.renderGeneration.shouldApply(generation) else {
                return
            }
            self.applyRenderModel(model)
        }
    }

    private func applyRenderModel(_ model: NetworkBodyPreviewRenderModel) {
        renderModel = model
        applyTitle()
        updateSecondaryMenu()

        let hasObjectTree = model.availableModes.contains(.objectTree)
        modeControl.isHidden = !hasObjectTree
        modeControl.setEnabled(hasObjectTree, forSegmentAt: NetworkBodyPreviewRenderModel.Mode.objectTree.rawValue)

        if !hasUserSelectedMode {
            mode = model.preferredMode
        } else if !model.availableModes.contains(mode) {
            mode = model.preferredMode
            hasUserSelectedMode = false
        }

        modeControl.selectedSegmentIndex = mode.rawValue
        applyTreeSnapshot(nodes: model.objectTreeNodes)
        applyVisibleMode()
    }

    private func applyVisibleMode() {
        let shouldShowTree = mode == .objectTree && (renderModel?.availableModes.contains(.objectTree) ?? false)
        treeView.isHidden = !shouldShowTree
        textView.isHidden = shouldShowTree
        updateTextView()
    }

    private func updateTextView() {
        let unavailableText = wiLocalized("network.body.unavailable", default: "Body unavailable")
        guard let model = renderModel else {
            textView.text = unavailableText
            return
        }
        textView.text = model.displayText(
            for: bodyState.fetchState,
            fetchingText: wiLocalized("network.body.fetching", default: "Fetching body..."),
            unavailableText: unavailableText
        )
    }

    private func applyTitle() {
        title = bodyState.role == .request
            ? wiLocalized("network.section.body.request", default: "Request Body")
            : wiLocalized("network.section.body.response", default: "Response Body")
    }

    private func updateSecondaryMenu() {
        navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] completion in
            completion((self?.makeSecondaryMenu() ?? UIMenu()).children)
        }
    }

    private func makeSecondaryMenu() -> UIMenu {
        let fetchAction = UIAction(
            title: wiLocalized("network.body.fetch", default: "Fetch Body"),
            image: UIImage(systemName: "arrow.clockwise"),
            attributes: bodyState.canFetchBody ? [] : [.disabled]
        ) { [weak self] _ in
            self?.fetch(force: true)
        }
        return UIMenu(children: [fetchAction])
    }

    private func fetch(force: Bool) {
        guard bodyState.canFetchBody else {
            return
        }
        Task {
            self.requestRenderModelUpdate()
            await inspector.fetchBodyIfNeeded(for: entry, body: bodyState, force: force)
            self.requestRenderModelUpdate()
        }
    }

    private func makeTreeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.showsSeparators = true
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func makeTreeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, TreeItem> {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, TreeItem> { [weak self] cell, _, item in
            self?.configureTreeCell(cell, item: item)
        }

        let dataSource = UICollectionViewDiffableDataSource<SectionIdentifier, TreeItem>(
            collectionView: treeView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: registration,
                for: indexPath,
                item: item
            )
        }

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, TreeItem>()
        snapshot.appendSections([.main])
        dataSource.apply(snapshot, animatingDifferences: false)
        return dataSource
    }

    private func configureTreeCell(_ cell: UICollectionViewListCell, item: TreeItem) {
        guard let payload = treePayloadByItem[item] else {
            cell.contentConfiguration = nil
            cell.accessories = []
            return
        }
        
        let display = treeDisplay(node: payload.node)

        var configuration = UIListContentConfiguration.valueCell()
        configuration.text = display.key
        configuration.secondaryText = display.value
        configuration.image = makeTypeBadgeImage(style: display.badgeStyle)
        configuration.textProperties.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular
        )
        configuration.secondaryTextProperties.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular
        )
        configuration.secondaryTextProperties.color = .secondaryLabel
        configuration.textToSecondaryTextHorizontalPadding = 6
        cell.contentConfiguration = configuration
        cell.accessories = payload.hasChildren ? [.outlineDisclosure()] : []
    }

    private func applyTreeSnapshot(nodes: [NetworkJSONNode]) {
        let expandedPaths = currentExpandedTreePaths()
        var rootItems: [TreeItem] = []
        var payloadByItem: [TreeItem: TreeItemPayload] = [:]
        var sectionSnapshot = NSDiffableDataSourceSectionSnapshot<TreeItem>()

        appendNodes(
            nodes,
            parent: nil,
            parentPath: "$",
            pathComponents: [],
            rootItems: &rootItems,
            sectionSnapshot: &sectionSnapshot,
            payloadByItem: &payloadByItem
        )

        if hasAppliedInitialTreeSnapshot, !expandedPaths.isEmpty {
            let restoreItems = sectionSnapshot.items.filter { expandedPaths.contains($0.path) }
            sectionSnapshot.expand(restoreItems)
        } else {
            let initialExpanded = rootItems.filter { payloadByItem[$0]?.hasChildren == true }
            sectionSnapshot.expand(initialExpanded)
            hasAppliedInitialTreeSnapshot = true
        }

        treePayloadByItem = payloadByItem
        treeDataSource.apply(sectionSnapshot, to: .main, animatingDifferences: false)
    }

    private func currentExpandedTreePaths() -> Set<String> {
        let snapshot = treeDataSource.snapshot(for: .main)
        return Set(snapshot.items.filter { snapshot.isExpanded($0) }.map(\.path))
    }

    private func toggleDisclosure(for item: TreeItem, animated: Bool) {
        guard let payload = treePayloadByItem[item], payload.hasChildren else {
            return
        }

        var snapshot = treeDataSource.snapshot(for: .main)
        if snapshot.isExpanded(item) {
            snapshot.collapse([item])
        } else {
            snapshot.expand([item])
        }
        treeDataSource.apply(snapshot, to: .main, animatingDifferences: animated)
    }

    private func expandAllDescendants(of item: TreeItem) {
        guard let payload = treePayloadByItem[item], payload.hasChildren else {
            return
        }

        var snapshot = treeDataSource.snapshot(for: .main)
        let descendants = descendants(of: item, in: snapshot)
        let expandableDescendants = descendants.filter { treePayloadByItem[$0]?.hasChildren == true }
        snapshot.expand([item] + expandableDescendants)
        treeDataSource.apply(snapshot, to: .main, animatingDifferences: true)
    }

    private func descendants(
        of item: TreeItem,
        in snapshot: NSDiffableDataSourceSectionSnapshot<TreeItem>
    ) -> [TreeItem] {
        let prefix = item.path + "/"
        return snapshot.items
            .filter { $0.path.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                if lhs.path.count != rhs.path.count {
                    return lhs.path.count < rhs.path.count
                }
                return lhs.path < rhs.path
            }
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    private func makeContextMenu(for item: TreeItem, payload: TreeItemPayload) -> UIMenu {
        let scalarText = NetworkBodyPreviewTreeMenuSupport.scalarCopyText(for: payload.node)
        let copyValueAction = UIAction(
            title: wiLocalized("network.body.preview.context.copy.value", default: "Value"),
            attributes: scalarText == nil ? [.disabled] : []
        ) { [weak self] _ in
            guard let self, let scalarText else {
                return
            }
            self.copyToPasteboard(scalarText)
        }

        let subtreeText = NetworkBodyPreviewTreeMenuSupport.subtreeCopyText(for: payload.node)
        let copySubtreeAction = UIAction(
            title: wiLocalized("network.body.preview.context.copy.json", default: "JSON"),
            attributes: subtreeText == nil ? [.disabled] : []
        ) { [weak self] _ in
            guard let self, let subtreeText else {
                return
            }
            self.copyToPasteboard(subtreeText)
        }

        let propertyPath = NetworkBodyPreviewTreeMenuSupport.propertyPathString(from: payload.pathComponents)
        let copyPathAction = UIAction(
            title: wiLocalized("network.body.preview.context.copy.path", default: "Path"),
            attributes: []
        ) { [weak self] _ in
            self?.copyToPasteboard(propertyPath)
        }

        let expandAction = UIAction(
            title: wiLocalized("network.body.preview.context.expand_all", default: "Expand All"),
            attributes: payload.hasChildren ? [] : [.disabled]
        ) { [weak self] _ in
            self?.expandAllDescendants(of: item)
        }

        let copyMenu = UIMenu(
            title: wiLocalized("Copy"),
            image: UIImage(systemName: "document.on.document"),
            children: [
                copyValueAction,
                copySubtreeAction,
                copyPathAction
            ]
        )
        let disclosureSection = UIMenu(options: .displayInline, children: [
            expandAction
        ])
        return UIMenu(children: [copyMenu, disclosureSection])
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard collectionView === treeView else {
            return
        }
        defer {
            collectionView.deselectItem(at: indexPath, animated: false)
        }

        guard
            let item = treeDataSource.itemIdentifier(for: indexPath),
            let payload = treePayloadByItem[item],
            payload.hasChildren
        else {
            return
        }
        toggleDisclosure(for: item, animated: true)
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard collectionView === treeView else {
            return nil
        }
        guard
            let item = treeDataSource.itemIdentifier(for: indexPath),
            let payload = treePayloadByItem[item]
        else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: item.path as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else {
                return nil
            }
            return self.makeContextMenu(for: item, payload: payload)
        }
    }

    private func appendNodes(
        _ nodes: [NetworkJSONNode],
        parent: TreeItem?,
        parentPath: String,
        pathComponents: [NetworkBodyPreviewTreeMenuSupport.PathComponent],
        rootItems: inout [TreeItem],
        sectionSnapshot: inout NSDiffableDataSourceSectionSnapshot<TreeItem>,
        payloadByItem: inout [TreeItem: TreeItemPayload]
    ) {
        for node in nodes {
            let segment = treePathSegment(for: node)
            let item = TreeItem(path: parentPath + segment)
            let children = node.children ?? []
            let hasChildren = !children.isEmpty
            let currentPathComponents = pathComponents + [
                NetworkBodyPreviewTreeMenuSupport.PathComponent(
                    key: node.key,
                    isIndex: node.isIndex
                )
            ]

            payloadByItem[item] = TreeItemPayload(
                node: node,
                hasChildren: hasChildren,
                pathComponents: currentPathComponents
            )

            if let parent {
                sectionSnapshot.append([item], to: parent)
            } else {
                sectionSnapshot.append([item])
                rootItems.append(item)
            }

            if hasChildren {
                appendNodes(
                    children,
                    parent: item,
                    parentPath: item.path,
                    pathComponents: currentPathComponents,
                    rootItems: &rootItems,
                    sectionSnapshot: &sectionSnapshot,
                    payloadByItem: &payloadByItem
                )
            }
        }
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

    private func treeDisplay(node: NetworkJSONNode) -> (key: String, value: String, badgeStyle: TypeBadgeStyle) {
        let key = node.key.isEmpty ? "(root)" : node.key
        let value: String
        let badgeStyle: TypeBadgeStyle

        switch node.displayKind {
        case .object:
            value = "Object"
            badgeStyle = TypeBadgeStyle(
                letter: "O",
                fillColor: Self.badgeFillColor(for: .yellow)
            )
        case .array(let count):
            value = "Array (\(count))"
            badgeStyle = TypeBadgeStyle(
                letter: "A",
                fillColor: Self.badgeFillColor(for: .yellow)
            )
        case .string(let string):
            value = "\"\(truncate(string))\""
            badgeStyle = TypeBadgeStyle(
                letter: "S",
                fillColor: Self.badgeFillColor(for: .red)
            )
        case .number(let number):
            value = number
            badgeStyle = TypeBadgeStyle(
                letter: "N",
                fillColor: Self.badgeFillColor(for: .blue)
            )
        case .bool(let flag):
            value = flag ? "true" : "false"
            badgeStyle = TypeBadgeStyle(
                letter: "B",
                fillColor: Self.badgeFillColor(for: .purple)
            )
        case .null:
            value = "null"
            badgeStyle = TypeBadgeStyle(
                letter: "0",
                fillColor: Self.badgeFillColor(for: .grey)
            )
        }

        return (key, value, badgeStyle)
    }

    private func makeTypeBadgeImage(style: TypeBadgeStyle) -> UIImage? {
        let symbolName = "\(style.letter.lowercased()).square.fill"
        let image = UIImage(systemName: symbolName)
            ?? UIImage(systemName: "square.fill")
        return image?.withTintColor(style.fillColor.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
    }


    private static func badgeFillColor(for token: TypeBadgePaletteToken) -> UIColor {
        switch token {
        case .yellow:
            return .systemYellow
        case .blue:
            return .systemBlue
        case .purple:
            return .systemPurple
        case .red:
            return .systemPink
        case .grey:
            return .systemGray
        }
    }

    private func truncate(_ value: String, limit: Int = 200) -> String {
        guard value.count > limit else {
            return value
        }
        let index = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<index]) + "..."
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Network Body Preview Object Tree (UIKit)") {
    WIUIKitPreviewContainer {
        guard let context = WINetworkPreviewFixtures.makeBodyPreviewContext(textMode: false) else {
            return UIViewController()
        }
        let preview = WINetworkBodyPreviewViewController(
            entry: context.entry,
            inspector: context.inspector,
            bodyState: context.body
        )
        return UINavigationController(rootViewController: preview)
    }
}

#Preview("Network Body Preview Text (UIKit)") {
    WIUIKitPreviewContainer {
        guard let context = WINetworkPreviewFixtures.makeBodyPreviewContext(textMode: true) else {
            return UIViewController()
        }
        let preview = WINetworkBodyPreviewViewController(
            entry: context.entry,
            inspector: context.inspector,
            bodyState: context.body
        )
        return UINavigationController(rootViewController: preview)
    }
}
#endif
#endif
