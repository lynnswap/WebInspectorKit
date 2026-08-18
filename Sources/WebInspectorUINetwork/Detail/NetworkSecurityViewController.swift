#if canImport(UIKit)
import UIKit
import WebInspectorDataKit
import WebInspectorUIBase

@MainActor
final class NetworkSecurityViewController: UICollectionViewController {
    private lazy var dataSource = makeDataSource()
    private var currentSummary: NetworkSecuritySummary?
    private var currentEpoch: NetworkSecurityRequestEpoch?
    private var currentDocument = NetworkSecurityDocument(
        itemsBySection: [:],
        rowsByItemID: [:]
    )
    private var expandedLists: Set<NetworkSecurityListKind> = []

    init() {
        super.init(collectionViewLayout: Self.makeLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        _ = dataSource
        collectionView.alwaysBounceVertical = true
        collectionView.allowsSelection = true
        collectionView.allowsMultipleSelection = false
        collectionView.accessibilityIdentifier = "WebInspector.Network.Security"
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        shouldSelectItemAt indexPath: IndexPath
    ) -> Bool {
        guard let itemID = dataSource.itemIdentifier(for: indexPath) else {
            return false
        }
        return currentDocument.rowsByItemID[itemID]?.disclosureList != nil
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        defer {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        guard let itemID = dataSource.itemIdentifier(for: indexPath),
              let listKind = currentDocument.rowsByItemID[itemID]?.disclosureList else {
            return
        }
        if expandedLists.remove(listKind) == nil {
            expandedLists.insert(listKind)
        }
        renderCurrent(animatingDifferences: true)
    }

    func render(
        _ summary: NetworkSecuritySummary,
        epoch: NetworkSecurityRequestEpoch,
        completion: (() -> Void)? = nil
    ) {
        loadViewIfNeeded()
        let isSameEpoch = currentEpoch == epoch
        if isSameEpoch == false {
            expandedLists.removeAll(keepingCapacity: true)
        }
        currentSummary = summary
        currentEpoch = epoch
        renderCurrent(
            animatingDifferences: isSameEpoch,
            completion: completion
        )
    }

    func clear(completion: (() -> Void)? = nil) {
        loadViewIfNeeded()
        currentSummary = nil
        currentEpoch = nil
        currentDocument = NetworkSecurityDocument(itemsBySection: [:], rowsByItemID: [:])
        expandedLists.removeAll(keepingCapacity: false)
        dataSource.apply(
            NSDiffableDataSourceSnapshot<NetworkSecuritySectionID, NetworkSecurityItemID>(),
            animatingDifferences: false,
            completion: completion
        )
    }

    private func renderCurrent(
        animatingDifferences: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard let currentSummary, let currentEpoch else {
            clear(completion: completion)
            return
        }
        let previousItemIDs = Set(dataSource.snapshot().itemIdentifiers)
        let document = NetworkSecurityDocumentBuilder(
            summary: currentSummary,
            epoch: currentEpoch,
            expandedLists: expandedLists
        ).makeDocument()
        currentDocument = document

        var snapshot = NSDiffableDataSourceSnapshot<NetworkSecuritySectionID, NetworkSecurityItemID>()
        snapshot.appendSections(NetworkSecuritySectionID.allCases)
        for section in NetworkSecuritySectionID.allCases {
            snapshot.appendItems(document.itemsBySection[section] ?? [], toSection: section)
        }
        let retainedItemIDs = snapshot.itemIdentifiers.filter(previousItemIDs.contains)
        snapshot.reconfigureItems(retainedItemIDs)
        dataSource.apply(
            snapshot,
            animatingDifferences: animatingDifferences,
            completion: completion
        )
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<
        NetworkSecuritySectionID,
        NetworkSecurityItemID
    > {
        let cellRegistration = UICollectionView.CellRegistration<
            UICollectionViewListCell,
            NetworkSecurityItemID
        > { [weak self] cell, _, itemID in
            guard let self,
                  let content = currentDocument.rowsByItemID[itemID] else {
                cell.contentConfiguration = nil
                cell.accessories = []
                cell.accessibilityLabel = nil
                cell.accessibilityValue = nil
                cell.accessibilityHint = nil
                cell.accessibilityTraits = []
                return
            }
            configure(cell, content: content)
        }
        let dataSource = UICollectionViewDiffableDataSource<
            NetworkSecuritySectionID,
            NetworkSecurityItemID
        >(collectionView: collectionView) { collectionView, indexPath, itemID in
            collectionView.dequeueConfiguredReusableCell(
                using: cellRegistration,
                for: indexPath,
                item: itemID
            )
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak dataSource] header, _, indexPath in
            guard let dataSource,
                  dataSource.snapshot().sectionIdentifiers.indices.contains(indexPath.section) else {
                Self.configure(header, for: nil)
                return
            }
            let section = dataSource.snapshot().sectionIdentifiers[indexPath.section]
            Self.configure(header, for: section)
        }
        dataSource.supplementaryViewProvider = { collectionView, elementKind, indexPath in
            guard elementKind == UICollectionView.elementKindSectionHeader else {
                return nil
            }
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
        return dataSource
    }

    private static func configure(
        _ header: UICollectionViewListCell,
        for section: NetworkSecuritySectionID?
    ) {
        guard let section else {
            header.contentConfiguration = nil
            header.isAccessibilityElement = false
            header.accessibilityLabel = nil
            header.accessibilityTraits = []
            return
        }
        let title = sectionTitle(section)
        var content = UIListContentConfiguration.header()
        content.text = title
        header.contentConfiguration = content
        header.isAccessibilityElement = true
        header.accessibilityLabel = title
        header.accessibilityTraits = .header
    }

    private func configure(
        _ cell: UICollectionViewListCell,
        content: NetworkSecurityRowContent
    ) {
        if let disclosureList = content.disclosureList {
            var configuration = UIListContentConfiguration.cell()
            configuration.text = content.label
            configuration.textProperties.adjustsFontForContentSizeCategory = true
            cell.contentConfiguration = configuration
            let imageView = UIImageView(image: UIImage(
                systemName: content.isExpanded ? "chevron.up" : "chevron.down"
            ))
            imageView.tintColor = .secondaryLabel
            imageView.isAccessibilityElement = false
            cell.accessories = [.customView(configuration: .init(
                customView: imageView,
                placement: .trailing()
            ))]
            cell.accessibilityLabel = content.label
            cell.accessibilityValue = content.isExpanded ? expandedText : collapsedText
            cell.accessibilityHint = toggleHint
            cell.accessibilityTraits = .button
            cell.accessibilityIdentifier = disclosureList == .dnsNames
                ? "WebInspector.Network.Security.DNSDisclosure"
                : "WebInspector.Network.Security.IPDisclosure"
            return
        }

        var configuration = UIListContentConfiguration.valueCell()
        configuration.text = content.label
        configuration.textProperties.numberOfLines = 0
        configuration.textProperties.adjustsFontForContentSizeCategory = true
        if let value = content.value {
            if content.usesTechnicalValueDirection {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.baseWritingDirection = .leftToRight
                configuration.secondaryAttributedText = NSAttributedString(
                    string: value,
                    attributes: [.paragraphStyle: paragraphStyle]
                )
            } else {
                configuration.secondaryText = value
            }
        }
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.secondaryTextProperties.lineBreakMode = content.usesTechnicalValueDirection
            ? .byCharWrapping
            : .byWordWrapping
        configuration.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        cell.contentConfiguration = configuration
        cell.accessories = []
        cell.accessibilityLabel = [content.label, content.value]
            .compactMap { $0 }
            .joined(separator: ", ")
        cell.accessibilityValue = nil
        cell.accessibilityHint = nil
        cell.accessibilityTraits = .staticText
        cell.accessibilityIdentifier = nil
    }

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let configuration = listConfiguration
            let section = NSCollectionLayoutSection.list(
                using: configuration,
                layoutEnvironment: environment
            )
            var insets = section.contentInsets
            insets.top = 0
            section.contentInsets = insets
            return section
        }
    }

    private static var listConfiguration: UICollectionLayoutListConfiguration {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.showsSeparators = true
        return configuration
    }

    private static func sectionTitle(_ section: NetworkSecuritySectionID) -> String {
        switch section {
        case .status:
            String(
                localized: "network.security.section.status",
                defaultValue: "Status",
                bundle: WebInspectorUILocalization.bundle
            )
        case .connection:
            String(
                localized: "network.security.section.connection",
                defaultValue: "Connection",
                bundle: WebInspectorUILocalization.bundle
            )
        case .certificate:
            String(
                localized: "network.security.section.certificate",
                defaultValue: "Certificate",
                bundle: WebInspectorUILocalization.bundle
            )
        }
    }

    private var expandedText: String {
        String(
            localized: "network.security.accessibility.expanded",
            defaultValue: "Expanded",
            bundle: WebInspectorUILocalization.bundle
        )
    }

    private var collapsedText: String {
        String(
            localized: "network.security.accessibility.collapsed",
            defaultValue: "Collapsed",
            bundle: WebInspectorUILocalization.bundle
        )
    }

    private var toggleHint: String {
        String(
            localized: "network.security.accessibility.toggle_hint",
            defaultValue: "Double-tap to show or hide reported values.",
            bundle: WebInspectorUILocalization.bundle
        )
    }
}

#if DEBUG
extension NetworkSecurityViewController {
    var snapshotForTesting: NSDiffableDataSourceSnapshot<
        NetworkSecuritySectionID,
        NetworkSecurityItemID
    > {
        dataSource.snapshot()
    }

    var expandedListsForTesting: Set<NetworkSecurityListKind> {
        expandedLists
    }

    var currentEpochForTesting: NetworkSecurityRequestEpoch? {
        currentEpoch
    }

    func rowContentForTesting(_ itemID: NetworkSecurityItemID) -> NetworkSecurityRowContent? {
        currentDocument.rowsByItemID[itemID]
    }

    func cellForTesting(_ itemID: NetworkSecurityItemID) -> UICollectionViewListCell? {
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: itemID) else {
            return nil
        }
        return collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell
    }

    func technicalValueUsesLTRForTesting(_ itemID: NetworkSecurityItemID) -> Bool {
        guard let cell = cellForTesting(itemID),
              let content = cell.contentConfiguration as? UIListContentConfiguration,
              let attributedText = content.secondaryAttributedText,
              attributedText.length > 0 else {
            return false
        }
        let paragraphStyle = unsafe attributedText.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        return paragraphStyle?.baseWritingDirection == .leftToRight
    }

    func toggleDisclosureForTesting(
        _ kind: NetworkSecurityListKind,
        completion: (() -> Void)? = nil
    ) {
        guard dataSource.snapshot().itemIdentifiers.contains(where: {
            $0.kind == .disclosure(kind)
        }) else {
            preconditionFailure("Expected a visible Network security disclosure.")
        }
        if expandedLists.remove(kind) == nil {
            expandedLists.insert(kind)
        }
        renderCurrent(animatingDifferences: true, completion: completion)
    }

    static var listConfigurationForTesting: UICollectionLayoutListConfiguration {
        listConfiguration
    }

    static func sectionTitleForTesting(_ section: NetworkSecuritySectionID) -> String {
        sectionTitle(section)
    }

    func sectionHeaderForTesting(
        _ section: NetworkSecuritySectionID
    ) -> UICollectionViewListCell? {
        collectionView.layoutIfNeeded()
        guard let sectionIndex = dataSource.snapshot().sectionIdentifiers.firstIndex(of: section)
        else {
            return nil
        }
        return collectionView.supplementaryView(
            forElementKind: UICollectionView.elementKindSectionHeader,
            at: IndexPath(item: 0, section: sectionIndex)
        ) as? UICollectionViewListCell
    }

    static func clearSectionHeaderForTesting(_ header: UICollectionViewListCell) {
        configure(header, for: nil)
    }
}
#endif
#endif
