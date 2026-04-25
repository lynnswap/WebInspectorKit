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

    fileprivate enum Item: Hashable {
        case element(DOMNodeModel)
        case selector(DOMNodeModel)
        case attribute(DOMAttribute)

        static func == (lhs: Item, rhs: Item) -> Bool {
            switch (lhs, rhs) {
            case let (.element(lhsNode), .element(rhsNode)):
                lhsNode == rhsNode
            case let (.selector(lhsNode), .selector(rhsNode)):
                lhsNode == rhsNode
            case let (.attribute(lhsAttribute), .attribute(rhsAttribute)):
                lhsAttribute.id == rhsAttribute.id
            default:
                false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case let .element(node):
                hasher.combine(0)
                hasher.combine(node)
            case let .selector(node):
                hasher.combine(1)
                hasher.combine(node)
            case let .attribute(attribute):
                hasher.combine(2)
                hasher.combine(attribute.id)
            }
        }

        func hasSameContent(as other: Item) -> Bool {
            switch (self, other) {
            case let (.element(lhsNode), .element(rhsNode)):
                lhsNode == rhsNode
            case let (.selector(lhsNode), .selector(rhsNode)):
                lhsNode == rhsNode
            case let (.attribute(lhsAttribute), .attribute(rhsAttribute)):
                lhsAttribute == rhsAttribute
            default:
                false
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
        let elementCellRegistration = UICollectionView.CellRegistration<V2_DOMElementPreviewCell, DOMNodeModel> { cell, _, node in
            cell.bind(node: node)
        }
        let selectorCellRegistration = UICollectionView.CellRegistration<V2_DOMElementSelectorCell, DOMNodeModel> { cell, _, node in
            cell.bind(node: node)
        }
        let attributeCellRegistration = UICollectionView.CellRegistration<V2_DOMElementAttributeCell, DOMAttribute> { cell, _, attribute in
            cell.bind(attribute)
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
            switch item {
            case let .element(node):
                collectionView.dequeueConfiguredReusableCell(
                    using: elementCellRegistration,
                    for: indexPath,
                    item: node
                )
            case let .selector(node):
                collectionView.dequeueConfiguredReusableCell(
                    using: selectorCellRegistration,
                    for: indexPath,
                    item: node
                )
            case let .attribute(attribute):
                collectionView.dequeueConfiguredReusableCell(
                    using: attributeCellRegistration,
                    for: indexPath,
                    item: attribute
                )
            }
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
            let currentItems = self.currentItems(in: .attributes)
            guard self.hasSameItemContent(nextItems, currentItems) == false else {
                return
            }

            guard self.hasSameItemIdentity(nextItems, currentItems) == false else {
                self.applyAttributeContentUpdate(selectedNode: selectedNode, items: nextItems)
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

    private func hasSameItemIdentity(_ lhs: [Item], _ rhs: [Item]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(==)
    }

    private func hasSameItemContent(_ lhs: [Item], _ rhs: [Item]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { lhsItem, rhsItem in
            lhsItem.hasSameContent(as: rhsItem)
        }
    }

    private func applyAttributeContentUpdate(selectedNode: DOMNodeModel, items: [Item]) {
        var snapshot = makeSnapshot(selectedNode: selectedNode)
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
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
            return [.element(selectedNode)]
        case .selector:
            return selectedNode.selectorPath.isEmpty ? [] : [.selector(selectedNode)]
        case .attributes:
            return selectedNode.attributes.map { .attribute($0) }
        }
    }
}

#if DEBUG
extension V2_DOMElementViewController {
    var isShowingEmptyStateForTesting: Bool {
        contentUnavailableConfiguration != nil
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
