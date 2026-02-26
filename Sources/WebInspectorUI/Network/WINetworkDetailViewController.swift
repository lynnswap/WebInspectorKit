import Foundation
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

private protocol DiffableStableID: Hashable, Sendable {}
private protocol DiffableCellKind: Hashable, Sendable {}

private struct DiffableRenderState<ID: DiffableStableID, Payload> {
    let payloadByID: [ID: Payload]
    let revisionByID: [ID: Int]
}

@MainActor
public final class WINetworkDetailViewController: UIViewController, UICollectionViewDelegate {
    private enum BodyKind: String, Hashable, Sendable {
        case request
        case response
    }

    private struct SectionIdentifier: Hashable, Sendable {
        let index: Int
        let title: String
    }

    private enum DetailSectionKind: Hashable, Sendable {
        case overview
        case requestHeaders
        case requestBody
        case responseHeaders
        case responseBody
        case error
    }

    private enum ItemCellKind: String, DiffableCellKind {
        case list
    }

    private enum ItemStableKey: DiffableStableID {
        case summary(entryID: UUID)
        case requestHeader(name: String, ordinal: Int)
        case responseHeader(name: String, ordinal: Int)
        case requestBody(entryID: UUID)
        case responseBody(entryID: UUID)
        case error(entryID: UUID)
    }

    private struct ItemStableID: DiffableStableID {
        let key: ItemStableKey
        let cellKind: ItemCellKind
    }

    private struct ItemIdentifier: Hashable, Sendable {
        let stableID: ItemStableID
    }

    private enum DetailRow {
        case summary(NetworkEntry)
        case header(name: String, value: String)
        case emptyHeader
        case body(entry: NetworkEntry, body: NetworkBody)
        case error(entryID: UUID, message: String)
    }

    private struct DetailSection {
        let kind: DetailSectionKind
        let title: String
        let rows: [DetailRow]
    }

    private enum ItemPayload {
        case summary(entryID: UUID)
        case header(name: String, value: String)
        case emptyHeader
        case body(entryID: UUID, bodyKind: BodyKind)
        case error(message: String)
    }

    private struct RenderSection {
        let sectionIdentifier: SectionIdentifier
        let stableIDs: [ItemStableID]
    }

    private let inspector: WINetworkModel
    private let showsNavigationControls: Bool

    private var sections: [DetailSection] = []
    private var payloadByStableID: [ItemStableID: ItemPayload] = [:]
    private var revisionByStableID: [ItemStableID: Int] = [:]
    private var needsSnapshotReloadOnNextAppearance = false
    private var pendingReloadDataTask: Task<Void, Never>?
    private var snapshotTaskGeneration: UInt64 = 0
    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        return collectionView
    }()
    private lazy var dataSource = makeDataSource()
    private var entry: NetworkEntry?

    public init(inspector: WINetworkModel, showsNavigationControls: Bool = true) {
        self.inspector = inspector
        self.showsNavigationControls = showsNavigationControls
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        pendingReloadDataTask?.cancel()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        display(nil, hasEntries: false)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flushPendingSnapshotUpdateIfNeeded()
    }

    func display(_ entry: NetworkEntry?, hasEntries: Bool = false) {
        self.entry = entry
        if showsNavigationControls {
            navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] completion in
                completion((self?.makeSecondaryMenu() ?? UIMenu()).children)
            }
        } else {
            navigationItem.additionalOverflowItems = nil
        }
        guard let entry else {
            title = nil
            sections = []
            requestSnapshotUpdate()
            collectionView.isHidden = true
            return
        }

        title = entry.displayName
        sections = makeSections(for: entry)
        collectionView.isHidden = false
        requestSnapshotUpdate()
    }

    private func makeLayout() -> UICollectionViewLayout {
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

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, ItemIdentifier> {
        let listCellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ItemIdentifier> { [weak self] cell, _, item in
            self?.configureListCell(cell, item: item)
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
        ) { collectionView, indexPath, item in
            guard item.stableID.cellKind == .list else {
                assertionFailure("Unexpected cell kind for network detail list registration")
                return UICollectionViewCell()
            }
            return collectionView.dequeueConfiguredReusableCell(
                using: listCellRegistration,
                for: indexPath,
                item: item
            )
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            return collectionView.dequeueConfiguredReusableSupplementary(
                using: headerRegistration,
                for: indexPath
            )
        }
        return dataSource
    }

    private func applySnapshot() {
        pendingReloadDataTask?.cancel()
        snapshotTaskGeneration &+= 1
        let generation = snapshotTaskGeneration
        let snapshot = makeSnapshot()
        pendingReloadDataTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.snapshotTaskGeneration == generation {
                    self.pendingReloadDataTask = nil
                }
            }
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
            await self.dataSource.apply(snapshot, animatingDifferences: false)
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
        }
    }

    private func applySnapshotUsingReloadData() {
        pendingReloadDataTask?.cancel()
        snapshotTaskGeneration &+= 1
        let generation = snapshotTaskGeneration
        let snapshot = makeSnapshot()
        pendingReloadDataTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.snapshotTaskGeneration == generation {
                    self.pendingReloadDataTask = nil
                }
            }
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
            guard !Task.isCancelled, self.snapshotTaskGeneration == generation else {
                return
            }
        }
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier> {
        let renderSections = makeRenderSections()
        let allStableIDs = renderSections.flatMap(\.stableIDs)
        precondition(
            allStableIDs.count == Set(allStableIDs).count,
            "Duplicate diffable IDs detected in WINetworkDetailViewController"
        )
        let renderState = makeRenderState(for: renderSections)
        let previousRevisionByStableID = revisionByStableID
        payloadByStableID = renderState.payloadByID
        revisionByStableID = renderState.revisionByID

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, ItemIdentifier>()
        for renderSection in renderSections {
            snapshot.appendSections([renderSection.sectionIdentifier])
            let identifiers = renderSection.stableIDs.map { stableID in
                ItemIdentifier(stableID: stableID)
            }
            snapshot.appendItems(identifiers, toSection: renderSection.sectionIdentifier)
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
        return snapshot
    }

    private var isCollectionViewVisible: Bool {
        isViewLoaded && view.window != nil
    }

    private func requestSnapshotUpdate() {
        guard isCollectionViewVisible else {
            needsSnapshotReloadOnNextAppearance = true
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        applySnapshot()
    }

    private func flushPendingSnapshotUpdateIfNeeded() {
        guard needsSnapshotReloadOnNextAppearance, isCollectionViewVisible else {
            return
        }
        needsSnapshotReloadOnNextAppearance = false
        applySnapshotUsingReloadData()
    }

    private func makeRenderSections() -> [RenderSection] {
        let currentEntryID = entry?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        return sections.enumerated().map { sectionIndex, section in
            let sectionID = SectionIdentifier(index: sectionIndex, title: section.title)
            var headerOrdinals: [String: Int] = [:]
            let stableIDs = section.rows.map { row in
                itemStableID(
                    for: row,
                    sectionKind: section.kind,
                    currentEntryID: currentEntryID,
                    headerOrdinals: &headerOrdinals
                )
            }
            return RenderSection(sectionIdentifier: sectionID, stableIDs: stableIDs)
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
                let rendered = payloadAndRevision(for: row)
                payloadByID[stableID] = rendered.payload
                revisionByID[stableID] = rendered.revision
            }
        }

        return DiffableRenderState(payloadByID: payloadByID, revisionByID: revisionByID)
    }

    private func itemStableID(
        for row: DetailRow,
        sectionKind: DetailSectionKind,
        currentEntryID: UUID,
        headerOrdinals: inout [String: Int]
    ) -> ItemStableID {
        let key: ItemStableKey
        switch row {
        case let .summary(entry):
            key = .summary(entryID: entry.id)
        case let .header(name, _):
            let ordinal = headerOrdinals[name, default: 0]
            headerOrdinals[name] = ordinal + 1
            switch sectionKind {
            case .requestHeaders:
                key = .requestHeader(name: name, ordinal: ordinal)
            case .responseHeaders:
                key = .responseHeader(name: name, ordinal: ordinal)
            default:
                assertionFailure("Header row placed in non-header section")
                key = .requestHeader(name: name, ordinal: ordinal)
            }
        case .emptyHeader:
            switch sectionKind {
            case .requestHeaders:
                key = .requestHeader(name: "", ordinal: 0)
            case .responseHeaders:
                key = .responseHeader(name: "", ordinal: 0)
            default:
                assertionFailure("Empty header row placed in non-header section")
                key = .requestHeader(name: "", ordinal: 0)
            }
        case let .body(entry, body):
            let bodyKind: BodyKind = body.role == .request ? .request : .response
            key = bodyKind == .request
                ? .requestBody(entryID: entry.id)
                : .responseBody(entryID: entry.id)
        case .error:
            key = .error(entryID: currentEntryID)
        }
        return ItemStableID(key: key, cellKind: .list)
    }

    private func payloadAndRevision(for row: DetailRow) -> (payload: ItemPayload, revision: Int) {
        switch row {
        case let .summary(entry):
            return (
                payload: .summary(entryID: entry.id),
                revision: summaryRenderHash(for: entry)
            )
        case let .header(name, value):
            var hasher = Hasher()
            hasher.combine(name)
            hasher.combine(value)
            return (
                payload: .header(name: name, value: value),
                revision: hasher.finalize()
            )
        case .emptyHeader:
            return (
                payload: .emptyHeader,
                revision: 0
            )
        case let .body(entry, body):
            let bodyKind: BodyKind = body.role == .request ? .request : .response
            return (
                payload: .body(entryID: entry.id, bodyKind: bodyKind),
                revision: bodyRenderHash(entry: entry, body: body)
            )
        case let .error(_, message):
            var hasher = Hasher()
            hasher.combine(message)
            return (
                payload: .error(message: message),
                revision: hasher.finalize()
            )
        }
    }

    private func makeSections(for entry: NetworkEntry) -> [DetailSection] {
        var sections: [DetailSection] = [
            DetailSection(
                kind: .overview,
                title: wiLocalized("network.detail.section.overview", default: "Overview"),
                rows: [.summary(entry)]
            )
        ]

        let requestHeaderRows: [DetailRow]
        if entry.requestHeaders.isEmpty {
            requestHeaderRows = [.emptyHeader]
        } else {
            requestHeaderRows = entry.requestHeaders.fields.map { .header(name: $0.name, value: $0.value) }
        }
        sections.append(DetailSection(
            kind: .requestHeaders,
            title: wiLocalized("network.section.request", default: "Request"),
            rows: requestHeaderRows
        ))

        if let requestBody = entry.requestBody {
            sections.append(DetailSection(
                kind: .requestBody,
                title: wiLocalized("network.section.body.request", default: "Request Body"),
                rows: [.body(entry: entry, body: requestBody)]
            ))
        }

        let responseHeaderRows: [DetailRow]
        if entry.responseHeaders.isEmpty {
            responseHeaderRows = [.emptyHeader]
        } else {
            responseHeaderRows = entry.responseHeaders.fields.map { .header(name: $0.name, value: $0.value) }
        }
        sections.append(DetailSection(
            kind: .responseHeaders,
            title: wiLocalized("network.section.response", default: "Response"),
            rows: responseHeaderRows
        ))

        if let responseBody = entry.responseBody {
            sections.append(DetailSection(
                kind: .responseBody,
                title: wiLocalized("network.section.body.response", default: "Response Body"),
                rows: [.body(entry: entry, body: responseBody)]
            ))
        }

        if let errorDescription = entry.errorDescription, !errorDescription.isEmpty {
            sections.append(DetailSection(
                kind: .error,
                title: wiLocalized("network.section.error", default: "Error"),
                rows: [.error(entryID: entry.id, message: errorDescription)]
            ))
        }

        return sections
    }

    private func makeSecondaryMenu() -> UIMenu {
        let canFetch: Bool
        if let entry {
            canFetch = canFetchBodies(for: entry)
        } else {
            canFetch = false
        }
        let fetchAction = UIAction(
            title: wiLocalized("network.body.fetch", default: "Fetch Body"),
            image: UIImage(systemName: "arrow.clockwise"),
            attributes: canFetch ? [] : [.disabled]
        ) { [weak self] _ in
            self?.fetchBodies(force: true)
        }
        return UIMenu(children: [fetchAction])
    }

    private func canFetchBodies(for entry: NetworkEntry) -> Bool {
        if let requestBody = entry.requestBody, requestBody.canFetchBody {
            return true
        }
        if let responseBody = entry.responseBody, responseBody.canFetchBody {
            return true
        }
        return false
    }

    private func fetchBodies(force: Bool) {
        guard let entry else {
            return
        }
        let entryID = entry.id

        Task {
            if let requestBody = entry.requestBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: requestBody, force: force)
            }
            if let responseBody = entry.responseBody {
                await inspector.fetchBodyIfNeeded(for: entry, body: responseBody, force: force)
            }
            guard self.inspector.selectedEntry?.id == entryID else {
                return
            }
            self.display(entry)
        }
    }

    private func configureListCell(_ cell: UICollectionViewListCell, item: ItemIdentifier) {
        guard item.stableID.cellKind == .list else {
            assertionFailure("List registration mismatch in WINetworkDetailViewController")
            cell.contentConfiguration = nil
            return
        }
        guard let payload = payloadByStableID[item.stableID] else {
            cell.contentConfiguration = nil
            return
        }
        cell.accessories = []
        var content = UIListContentConfiguration.cell()

        switch payload {
        case let .summary(entryID):
            guard let entry, entry.id == entryID else {
                cell.contentConfiguration = nil
                return
            }
            content = makeOverviewSubtitleConfiguration(for: entry)
        case let .header(name, value):
            content = makeElementLikeSubtitleConfiguration(
                title: name,
                detail: value,
                titleColor: .secondaryLabel,
                detailColor: .label
            )
        case .emptyHeader:
            content = UIListContentConfiguration.cell()
            content.text = wiLocalized("network.headers.empty", default: "No headers")
            content.textProperties.color = .secondaryLabel
        case let .body(entryID, bodyKind):
            guard
                let entry,
                entry.id == entryID,
                let body = body(for: bodyKind, in: entry)
            else {
                cell.contentConfiguration = nil
                return
            }
            content = makeElementLikeSubtitleConfiguration(
                title: makeBodyPrimaryText(entry: entry, body: body),
                detail: makeBodySecondaryText(body),
                titleColor: .secondaryLabel,
                detailColor: .label,
                titleNumberOfLines: 1,
                detailNumberOfLines: 6
            )
            cell.accessories = [.disclosureIndicator()]
        case let .error(error):
            content = UIListContentConfiguration.cell()
            content.text = error
            content.textProperties.color = .systemOrange
            content.textProperties.numberOfLines = 0
        }
        cell.contentConfiguration = content
    }

    private func makeElementLikeSubtitleConfiguration(
        title: String,
        detail: String,
        titleColor: UIColor,
        detailColor: UIColor,
        titleNumberOfLines: Int = 1,
        detailNumberOfLines: Int = 0
    ) -> UIListContentConfiguration {
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = title
        configuration.secondaryText = detail
        configuration.textProperties.numberOfLines = titleNumberOfLines
        configuration.secondaryTextProperties.numberOfLines = detailNumberOfLines
        configuration.textProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )
        configuration.textToSecondaryTextVerticalPadding = 8
        configuration.textProperties.color = titleColor
        configuration.secondaryTextProperties.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular
            )
        )
        configuration.secondaryTextProperties.color = detailColor
        return configuration
    }

    private func makeOverviewSubtitleConfiguration(for entry: NetworkEntry) -> UIListContentConfiguration {
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.textProperties.numberOfLines = 1
        configuration.secondaryText = entry.url
        configuration.secondaryTextProperties.numberOfLines = 4
        configuration.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        configuration.secondaryTextProperties.color = .label
        configuration.textToSecondaryTextVerticalPadding = 8

        let metricsFont = UIFont.preferredFont(forTextStyle: .footnote)
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(attachment: makeStatusBadgeAttachment(for: entry, baselineFont: metricsFont)))

        if let duration = entry.duration {
            appendOverviewMetric(
                symbolName: "clock",
                text: entry.durationText(for: duration),
                to: attributed,
                font: metricsFont,
                color: .secondaryLabel
            )
        }
        if let encodedBodyLength = entry.encodedBodyLength {
            appendOverviewMetric(
                symbolName: "arrow.down.to.line",
                text: entry.sizeText(for: encodedBodyLength),
                to: attributed,
                font: metricsFont,
                color: .secondaryLabel
            )
        }

        configuration.attributedText = attributed
        return configuration
    }

    private func makeStatusBadgeAttachment(for entry: NetworkEntry, baselineFont: UIFont) -> NSTextAttachment {
        let tint = networkStatusColor(for: entry.statusSeverity)
        let badgeFont = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: .semibold
            )
        )
        let badgeText = entry.statusLabel as NSString
        let textSize = badgeText.size(withAttributes: [.font: badgeFont])
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 4
        let badgeSize = CGSize(
            width: ceil(textSize.width + horizontalPadding * 2),
            height: ceil(textSize.height + verticalPadding * 2)
        )

        let badgeImage = UIGraphicsImageRenderer(size: badgeSize).image { _ in
            let rect = CGRect(origin: .zero, size: badgeSize)
            let cornerRadius = min(8, badgeSize.height / 2)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
            tint.withAlphaComponent(0.14).setFill()
            path.fill()

            let textRect = CGRect(
                x: (badgeSize.width - textSize.width) / 2,
                y: (badgeSize.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            badgeText.draw(
                in: textRect,
                withAttributes: [
                    .font: badgeFont,
                    .foregroundColor: tint
                ]
            )
        }

        let attachment = NSTextAttachment()
        attachment.image = badgeImage
        let baselineOffset = (baselineFont.capHeight - badgeSize.height) / 2
        attachment.bounds = CGRect(x: 0, y: baselineOffset, width: badgeSize.width, height: badgeSize.height)
        return attachment
    }

    private func appendOverviewMetric(
        symbolName: String,
        text: String,
        to attributed: NSMutableAttributedString,
        font: UIFont,
        color: UIColor
    ) {
        attributed.append(NSAttributedString(string: "  "))
        if let symbol = makeSymbolAttachment(symbolName: symbolName, baselineFont: font, tintColor: color) {
            attributed.append(symbol)
            attributed.append(NSAttributedString(string: " "))
        }
        attributed.append(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: color
                ]
            )
        )
    }

    private func makeSymbolAttachment(
        symbolName: String,
        baselineFont: UIFont,
        tintColor: UIColor
    ) -> NSAttributedString? {
        let symbolConfiguration = UIImage.SymbolConfiguration(font: baselineFont)
        guard
            let symbolImage = UIImage(systemName: symbolName, withConfiguration: symbolConfiguration)?
                .withTintColor(tintColor, renderingMode: .alwaysOriginal)
        else {
            return nil
        }
        let attachment = NSTextAttachment()
        attachment.image = symbolImage
        let symbolSize = symbolImage.size
        let baselineOffset = (baselineFont.capHeight - symbolSize.height) / 2
        attachment.bounds = CGRect(x: 0, y: baselineOffset, width: symbolSize.width, height: symbolSize.height)
        return NSAttributedString(attachment: attachment)
    }

    public func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard
            let item = dataSource.itemIdentifier(for: indexPath),
            let payload = payloadByStableID[item.stableID],
            case .body = payload
        else {
            return false
        }
        return true
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
        guard
            let item = dataSource.itemIdentifier(for: indexPath),
            let payload = payloadByStableID[item.stableID],
            case let .body(entryID, bodyKind) = payload,
            let entry,
            entry.id == entryID,
            let body = body(for: bodyKind, in: entry)
        else {
            return
        }

        let preview = WINetworkBodyPreviewViewController(entry: entry, inspector: inspector, bodyState: body)
        navigationController?.pushViewController(preview, animated: true)
    }

    private func body(for bodyKind: BodyKind, in entry: NetworkEntry) -> NetworkBody? {
        switch bodyKind {
        case .request:
            return entry.requestBody
        case .response:
            return entry.responseBody
        }
    }

    private func summaryRenderHash(for entry: NetworkEntry) -> Int {
        var hasher = Hasher()
        hasher.combine(entry.url)
        hasher.combine(entry.method)
        hasher.combine(entry.statusLabel)
        hasher.combine(entry.statusSeverity)
        hasher.combine(entry.duration)
        hasher.combine(entry.encodedBodyLength)
        hasher.combine(entry.phase.rawValue)
        return hasher.finalize()
    }

    private func bodyRenderHash(entry: NetworkEntry, body: NetworkBody) -> Int {
        var hasher = Hasher()
        hasher.combine(entry.id)
        hasher.combine(body.role)
        hasher.combine(body.kind.rawValue)
        hasher.combine(body.size)
        hasher.combine(body.summary)
        hasher.combine(body.preview)
        hasher.combine(body.full)
        hasher.combine(body.reference)
        hasher.combine(bodyFetchStateKey(body.fetchState))
        return hasher.finalize()
    }

    private func bodyFetchStateKey(_ state: NetworkBody.FetchState) -> String {
        switch state {
        case .inline:
            return "inline"
        case .fetching:
            return "fetching"
        case .full:
            return "full"
        case let .failed(error):
            return "failed.\(String(describing: error))"
        }
    }

    private func makeBodyPrimaryText(entry: NetworkEntry, body: NetworkBody) -> String {
        var parts: [String] = []
        if let typeLabel = networkBodyTypeLabel(entry: entry, body: body) {
            parts.append(typeLabel)
        }
        if let size = networkBodySize(entry: entry, body: body) {
            parts.append(entry.sizeText(for: size))
        }
        if parts.isEmpty {
            return wiLocalized("network.body.unavailable", default: "Body unavailable")
        }
        return parts.joined(separator: "  ")
    }

    private func makeBodySecondaryText(_ body: NetworkBody) -> String {
        switch body.fetchState {
        case .fetching:
            return wiLocalized("network.body.fetching", default: "Fetching body...")
        case .failed(let error):
            return error.localizedDescriptionText
        default:
            if body.kind == .form, !body.formEntries.isEmpty {
                return body.formEntries.prefix(4).map {
                    let value: String
                    if $0.isFile, let fileName = $0.fileName, !fileName.isEmpty {
                        value = fileName
                    } else {
                        value = $0.value
                    }
                    return "\($0.name): \(value)"
                }.joined(separator: "\n")
            }
            return networkBodyPreviewText(body) ?? wiLocalized("network.body.unavailable", default: "Body unavailable")
        }
    }
}
#endif
