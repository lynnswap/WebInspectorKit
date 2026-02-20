#if canImport(UIKit)
import Foundation
import UIKit
import WebInspectorKitCore

@MainActor
final class NetworkBodyPreviewViewController: UIViewController {
    private enum SectionIdentifier: Hashable {
        case main
    }

    private struct TreeItem: Hashable, Sendable {
        let path: String
    }

    private struct TreeItemPayload {
        let node: NetworkJSONNode
        let hasChildren: Bool
    }

    private struct TypeBadgeStyle {
        let letter: String
        let fillColor: UIColor
        let textColor: UIColor
    }

    private let entry: NetworkEntry
    private let inspector: WINetworkPaneViewModel
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
        view.keyboardDismissMode = .onDrag
        return view
    }()

    init(entry: NetworkEntry, inspector: WINetworkPaneViewModel, bodyState: NetworkBody) {
        self.entry = entry
        self.inspector = inspector
        self.bodyState = bodyState
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        renderTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.alwaysBounceVertical = true
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
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            treeView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
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
        let fetchAction = UIAction(
            title: wiLocalized("network.body.fetch", default: "Fetch Body"),
            image: UIImage(systemName: "arrow.clockwise"),
            attributes: bodyState.canFetchBody ? [] : [.disabled]
        ) { [weak self] _ in
            self?.fetch(force: true)
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: wiSecondaryActionSymbolName()),
            menu: UIMenu(children: [fetchAction])
        )
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
        configuration.imageProperties.reservedLayoutSize = CGSize(width: 22, height: 22)
        configuration.imageProperties.maximumSize = CGSize(width: 22, height: 22)
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

    private func appendNodes(
        _ nodes: [NetworkJSONNode],
        parent: TreeItem?,
        parentPath: String,
        rootItems: inout [TreeItem],
        sectionSnapshot: inout NSDiffableDataSourceSectionSnapshot<TreeItem>,
        payloadByItem: inout [TreeItem: TreeItemPayload]
    ) {
        for node in nodes {
            let segment = treePathSegment(for: node)
            let item = TreeItem(path: parentPath + segment)
            let children = node.children ?? []
            let hasChildren = !children.isEmpty

            payloadByItem[item] = TreeItemPayload(
                node: node,
                hasChildren: hasChildren
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
                fillColor: .systemBlue,
                textColor: .white
            )
        case .array(let count):
            value = "Array (\(count))"
            badgeStyle = TypeBadgeStyle(
                letter: "A",
                fillColor: .systemOrange,
                textColor: .white
            )
        case .string(let string):
            value = "\"\(truncate(string))\""
            badgeStyle = TypeBadgeStyle(
                letter: "S",
                fillColor: .systemPink,
                textColor: .white
            )
        case .number(let number):
            value = number
            badgeStyle = TypeBadgeStyle(
                letter: "N",
                fillColor: .systemTeal,
                textColor: .white
            )
        case .bool(let flag):
            value = flag ? "true" : "false"
            badgeStyle = TypeBadgeStyle(
                letter: "B",
                fillColor: .systemGreen,
                textColor: .white
            )
        case .null:
            value = "null"
            badgeStyle = TypeBadgeStyle(
                letter: "0",
                fillColor: .systemGray,
                textColor: .white
            )
        }

        return (key, value, badgeStyle)
    }

    private func makeTypeBadgeImage(style: TypeBadgeStyle) -> UIImage? {
        let badgeSize = CGSize(width: 18, height: 18)
        let image = UIGraphicsImageRenderer(size: badgeSize).image { _ in
            let rect = CGRect(origin: .zero, size: badgeSize)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 5)
            style.fillColor.setFill()
            path.fill()

            UIColor.black.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 0.5
            path.stroke()

            let font = UIFont.systemFont(ofSize: 10, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: style.textColor
            ]
            let letter = style.letter
            let textSize = (letter as NSString).size(withAttributes: attributes)
            let textRect = CGRect(
                x: (badgeSize.width - textSize.width) / 2,
                y: (badgeSize.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (letter as NSString).draw(in: textRect, withAttributes: attributes)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    private func truncate(_ value: String, limit: Int = 200) -> String {
        guard value.count > limit else {
            return value
        }
        let index = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<index]) + "..."
    }
}
#endif
