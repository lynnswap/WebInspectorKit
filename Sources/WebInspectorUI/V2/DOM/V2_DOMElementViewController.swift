#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
final class V2_DOMElementViewController: UICollectionViewController {
    private enum Section: Hashable, Sendable {
        case element
        case selector
        case attributes

        var title: String {
            switch self {
            case .element:
                wiLocalized("dom.element.section.element")
            case .selector:
                wiLocalized("dom.element.section.selector")
            case .attributes:
                wiLocalized("dom.element.section.attributes")
            }
        }
    }

    fileprivate enum Item: Hashable, Sendable {
        case element(nodeID: DOMNodeModel.ID)
        case selector(nodeID: DOMNodeModel.ID)
        case attribute(nodeID: DOMNodeModel.ID, name: String)

        var nodeID: DOMNodeModel.ID {
            switch self {
            case let .element(nodeID), let .selector(nodeID), let .attribute(nodeID, _):
                nodeID
            }
        }
    }

    private let dom: V2_WIDOMRuntime

    private lazy var dataSource = makeDataSource()

    private var nodeHandles: Set<ObservationHandle> = []
    private var sectionHandles: Set<ObservationHandle> = []

    init(dom: V2_WIDOMRuntime) {
        self.dom = dom
        super.init(collectionViewLayout: Self.makeLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        _ = dataSource

        nodeHandles.removeAll()
        dom.document.observe(\.selectedNode) { [weak self] node in
            self?.applyNode(node)
        }
        .store(in: &nodeHandles)
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        false
    }

    private static func makeLayout() -> UICollectionViewLayout {
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

    private func makeDataSource() -> UICollectionViewDiffableDataSource<Section, Item> {
        let cellRegistration = UICollectionView.CellRegistration<V2_DOMElementListCell, Item> { [weak self] cell, _, item in
            cell.bind(item, node: self?.dom.document.node(id: item.nodeID))
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard let section = self?.dataSource.sectionIdentifier(for: indexPath.section) else {
                return
            }
            var configuration = UIListContentConfiguration.header()
            configuration.text = section.title
            header.contentConfiguration = configuration
        }

        let dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration,
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

    private func applyNode(_ selectedNode: DOMNodeModel?) {
        sectionHandles.removeAll()
        if let selectedNode {
            if contentUnavailableConfiguration != nil {
                contentUnavailableConfiguration = nil
            }
            dataSource.applySnapshotUsingReloadData(makeSnapshot(selectedNode: selectedNode))

            observeAttributeSection(of: selectedNode)
        } else {
            if contentUnavailableConfiguration == nil {
                var configuration = UIContentUnavailableConfiguration.empty()
                configuration.text = wiLocalized("dom.element.select_prompt")
                configuration.secondaryText = wiLocalized("dom.element.hint")
                configuration.image = UIImage(systemName: "cursorarrow.rays")
                contentUnavailableConfiguration = configuration
            }
            let snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
            dataSource.applySnapshotUsingReloadData(snapshot)
        }
    }

    private func observeAttributeSection(of selectedNode: DOMNodeModel) {
        selectedNode.observe(\.attributes) { [weak self, weak selectedNode] _ in
            guard let self, let selectedNode, self.dom.document.selectedNode === selectedNode else {
                return
            }

            let nextItems = self.items(in: .attributes, for: selectedNode)
            guard nextItems != self.currentItems(in: .attributes) else {
                return
            }

            guard self.applySection(.attributes, items: nextItems, animatingDifferences: true) else {
                self.applyNode(selectedNode)
                return
            }
        }
        .store(in: &sectionHandles)
    }

    @discardableResult
    private func applySection(
        _ section: Section,
        items: [Item],
        animatingDifferences: Bool
    ) -> Bool {
        guard canApplySectionSnapshot(to: section, items: items) else {
            return false
        }

        var sectionSnapshot = NSDiffableDataSourceSectionSnapshot<Item>()
        sectionSnapshot.append(items)
        dataSource.apply(
            sectionSnapshot,
            to: section,
            animatingDifferences: animatingDifferences
        )
        return true
    }

    private func canApplySectionSnapshot(to section: Section, items: [Item]) -> Bool {
        dataSource.snapshot().sectionIdentifiers.contains(section) && items.isEmpty == false
    }

    private func currentItems(in section: Section) -> [Item] {
        let snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(section) else {
            return []
        }
        return snapshot.itemIdentifiers(inSection: section)
    }

    private func makeSnapshot(selectedNode: DOMNodeModel) -> NSDiffableDataSourceSnapshot<Section, Item> {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

        for section in sections(for: selectedNode) {
            snapshot.appendSections([section])
            snapshot.appendItems(items(in: section, for: selectedNode), toSection: section)
        }

        return snapshot
    }

    private func sections(for selectedNode: DOMNodeModel) -> [Section] {
        var sections: [Section] = [.element]
        if selectedNode.selectorPath.isEmpty == false {
            sections.append(.selector)
        }
        if selectedNode.attributes.isEmpty == false {
            sections.append(.attributes)
        }
        return sections
    }

    private func items(in section: Section, for selectedNode: DOMNodeModel) -> [Item] {
        switch section {
        case .element:
            return [.element(nodeID: selectedNode.id)]
        case .selector:
            return selectedNode.selectorPath.isEmpty ? [] : [.selector(nodeID: selectedNode.id)]
        case .attributes:
            return selectedNode.attributes.map { .attribute(nodeID: selectedNode.id, name: $0.name) }
        }
    }
}

private final class V2_DOMElementListCell: UICollectionViewListCell {
    private var observationHandles: Set<ObservationHandle> = []
    private var item: V2_DOMElementViewController.Item?
    private weak var node: DOMNodeModel?

    override func prepareForReuse() {
        super.prepareForReuse()
        observationHandles.removeAll()
        item = nil
        node = nil
    }

    func bind(_ item: V2_DOMElementViewController.Item, node: DOMNodeModel?) {
        observationHandles.removeAll()
        self.item = item
        self.node = node
        render(item, node: node)
        startObserving(item, node: node)
    }

    private func startObserving(_ item: V2_DOMElementViewController.Item, node: DOMNodeModel?) {
        guard let node else {
            return
        }

        switch item {
        case .element:
            node.observe(
                [\.preview, \.nodeType, \.nodeName, \.localName, \.nodeValue, \.attributes],
                onChange: { [weak self] in
                    self?.renderCurrentItem()
                }
            )
            .store(in: &observationHandles)
        case .selector:
            node.observe(
                \.selectorPath,
                onChange: { [weak self] _ in
                    self?.renderCurrentItem()
                }
            )
            .store(in: &observationHandles)
        case .attribute:
            node.observe(
                \.attributes,
                onChange: { [weak self] _ in
                    self?.renderCurrentItem()
                }
            )
            .store(in: &observationHandles)
        }
    }

    private func renderCurrentItem() {
        guard let item else {
            return
        }
        render(item, node: node)
    }

    private func render(_ item: V2_DOMElementViewController.Item, node: DOMNodeModel?) {
        var configuration = UIListContentConfiguration.cell()
        accessories = []

        switch item {
        case .element:
            guard let node else {
                contentConfiguration = nil
                return
            }
            configuration.text = node.preview.isEmpty ? Self.defaultPreview(for: node) : node.preview
            configuration.textProperties.numberOfLines = 0
            configuration.textProperties.font = Self.monospacedFootnoteFont
            configuration.textProperties.color = .label
        case .selector:
            guard let node else {
                contentConfiguration = nil
                return
            }
            configuration.text = node.selectorPath
            configuration.textProperties.numberOfLines = 0
            configuration.textProperties.font = Self.monospacedFootnoteFont
            configuration.textProperties.color = .label
        case let .attribute(_, name):
            guard let node else {
                contentConfiguration = nil
                return
            }
            configuration.text = name
            configuration.secondaryText = node.attributes.first { $0.name == name }?.value
            configuration.textProperties.color = .secondaryLabel
            configuration.secondaryTextProperties.numberOfLines = 0
            configuration.secondaryTextProperties.font = Self.monospacedFootnoteFont
            configuration.secondaryTextProperties.color = .label
        }

        contentConfiguration = configuration
    }

    private static var monospacedFootnoteFont: UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
        )
    }

    private static func defaultPreview(for node: DOMNodeModel) -> String {
        switch node.nodeType {
        case 3:
            return node.nodeValue
        case 8:
            return "<!-- \(node.nodeValue) -->"
        default:
            let name = node.localName.isEmpty ? node.nodeName : node.localName
            let attributes = node.attributes.map { attribute in
                "\(attribute.name)=\"\(attribute.value)\""
            }.joined(separator: " ")
            let suffix = attributes.isEmpty ? "" : " \(attributes)"
            return "<\(name)\(suffix)>"
        }
    }
}

#if DEBUG
extension V2_DOMElementViewController {
    var isShowingEmptyStateForTesting: Bool {
        contentUnavailableConfiguration != nil && collectionView.isHidden
    }

    var renderedSectionIdentifiersForTesting: [String] {
        dataSource.snapshot().sectionIdentifiers.map { section in
            switch section {
            case .element:
                "element"
            case .selector:
                "selector"
            case .attributes:
                "attributes"
            }
        }
    }
}
#endif
#endif
