import Foundation
import ObservationsCompat
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
public final class WINetworkDetailViewController: UIViewController, UICollectionViewDelegate {
    private struct SectionIdentifier: Hashable, Sendable {
        let index: Int
        let title: String
    }

    private enum DetailItemID: Hashable, Sendable {
        case summary
        case requestHeader(index: Int)
        case requestHeadersEmpty
        case responseHeader(index: Int)
        case responseHeadersEmpty
        case requestBody
        case responseBody
        case error
    }

    private struct RenderSection {
        let sectionIdentifier: SectionIdentifier
        let itemIDs: [DetailItemID]
    }

    private let inspector: WINetworkModel
    private let showsNavigationControls: Bool

    private var needsSnapshotReloadOnNextAppearance = false
    private let contentUpdateCoalescer = UIUpdateCoalescer()
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
        
        inspector.observeTask([\.selectedEntry]) { [weak self] in
            self?.scheduleDisplayUpdate()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
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

        synchronizeDisplayWithInspector()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flushPendingSnapshotUpdateIfNeeded()
    }

    func display(_ entry: NetworkEntry?) {
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
            requestSnapshotUpdate()
            collectionView.isHidden = true
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = wiLocalized("network.empty.selection.title")
            configuration.secondaryText = wiLocalized("network.empty.selection.description")
            configuration.image = UIImage(systemName: "line.3.horizontal")
            contentUnavailableConfiguration = configuration
            return
        }

        if showsNavigationControls {
            title = entry.displayName
        } else {
            title = nil
        }
        collectionView.isHidden = false
        contentUnavailableConfiguration = nil
        requestSnapshotUpdate()
    }

    private func scheduleDisplayUpdate() {
        contentUpdateCoalescer.schedule { [weak self] in
            self?.synchronizeDisplayWithInspector()
        }
    }

    private func synchronizeDisplayWithInspector() {
        display(inspector.selectedEntry)
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

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionIdentifier, DetailItemID> {
        let listCellRegistration = UICollectionView.CellRegistration<WINetworkDetailObservingListCell, DetailItemID> { [weak self] cell, _, itemID in
            self?.configureListCell(cell, itemID: itemID)
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

        let dataSource = UICollectionViewDiffableDataSource<SectionIdentifier, DetailItemID>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
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
        Task {
            let snapshot = self.makeSnapshot()
            await self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func applySnapshotUsingReloadData() {
        Task {
            let snapshot = self.makeSnapshot()
            await self.dataSource.applySnapshotUsingReloadData(snapshot)
        }
    }

    private func makeSnapshot() -> NSDiffableDataSourceSnapshot<SectionIdentifier, DetailItemID> {
        let renderSections = makeRenderSections()
        let allItemIDs = renderSections.flatMap(\.itemIDs)
        precondition(
            allItemIDs.count == Set(allItemIDs).count,
            "Duplicate diffable IDs detected in WINetworkDetailViewController"
        )

        var snapshot = NSDiffableDataSourceSnapshot<SectionIdentifier, DetailItemID>()
        for renderSection in renderSections {
            snapshot.appendSections([renderSection.sectionIdentifier])
            snapshot.appendItems(renderSection.itemIDs, toSection: renderSection.sectionIdentifier)
        }
        if !allItemIDs.isEmpty {
            snapshot.reconfigureItems(allItemIDs)
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
        guard let entry else {
            return []
        }
        var renderSections: [RenderSection] = []
        var sectionIndex = 0

        func appendSection(_ title: String, itemIDs: [DetailItemID]) {
            guard !itemIDs.isEmpty else {
                return
            }
            renderSections.append(
                RenderSection(
                    sectionIdentifier: SectionIdentifier(index: sectionIndex, title: title),
                    itemIDs: itemIDs
                )
            )
            sectionIndex += 1
        }

        appendSection(
            wiLocalized("network.detail.section.overview", default: "Overview"),
            itemIDs: [.summary]
        )

        let requestHeaderItems: [DetailItemID]
        if entry.requestHeaders.fields.isEmpty {
            requestHeaderItems = [.requestHeadersEmpty]
        } else {
            requestHeaderItems = entry.requestHeaders.fields.indices.map { .requestHeader(index: $0) }
        }
        appendSection(
            wiLocalized("network.section.request", default: "Request"),
            itemIDs: requestHeaderItems
        )

        if entry.requestBody != nil {
            appendSection(
                wiLocalized("network.section.body.request", default: "Request Body"),
                itemIDs: [.requestBody]
            )
        }

        let responseHeaderItems: [DetailItemID]
        if entry.responseHeaders.fields.isEmpty {
            responseHeaderItems = [.responseHeadersEmpty]
        } else {
            responseHeaderItems = entry.responseHeaders.fields.indices.map { .responseHeader(index: $0) }
        }
        appendSection(
            wiLocalized("network.section.response", default: "Response"),
            itemIDs: responseHeaderItems
        )

        if entry.responseBody != nil {
            appendSection(
                wiLocalized("network.section.body.response", default: "Response Body"),
                itemIDs: [.responseBody]
            )
        }

        if let errorDescription = entry.errorDescription, !errorDescription.isEmpty {
            appendSection(
                wiLocalized("network.section.error", default: "Error"),
                itemIDs: [.error]
            )
        }

        return renderSections
    }

    private func makeSecondaryMenu() -> UIMenu {
        let fetchAction = UIAction(
            title: wiLocalized("network.body.fetch", default: "Fetch Body"),
            image: UIImage(systemName: "arrow.clockwise"),
            attributes: inspector.canFetchSelectedBodies ? [] : [.disabled]
        ) { [weak self] _ in
            self?.inspector.requestFetchSelectedBodies(force: true)
        }
        return UIMenu(children: [fetchAction])
    }

    private func configureListCell(_ cell: WINetworkDetailObservingListCell, itemID: DetailItemID) {
        guard let entry else {
            cell.contentConfiguration = nil
            cell.accessories = []
            return
        }
        cell.accessories = []

        switch itemID {
        case .summary:
            configureSummaryCell(cell, entry: entry)
        case let .requestHeader(index):
            guard entry.requestHeaders.fields.indices.contains(index) else {
                cell.contentConfiguration = nil
                return
            }
            let field = entry.requestHeaders.fields[index]
            cell.contentConfiguration = makeElementLikeSubtitleConfiguration(
                title: field.name,
                detail: field.value,
                titleColor: .secondaryLabel,
                detailColor: .label
            )
        case let .responseHeader(index):
            guard entry.responseHeaders.fields.indices.contains(index) else {
                cell.contentConfiguration = nil
                return
            }
            let field = entry.responseHeaders.fields[index]
            cell.contentConfiguration = makeElementLikeSubtitleConfiguration(
                title: field.name,
                detail: field.value,
                titleColor: .secondaryLabel,
                detailColor: .label
            )
        case .requestHeadersEmpty, .responseHeadersEmpty:
            var content = UIListContentConfiguration.cell()
            content.text = wiLocalized("network.headers.empty", default: "No headers")
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
        case .requestBody:
            guard let body = entry.requestBody else {
                cell.contentConfiguration = nil
                return
            }
            configureBodyCell(cell, entry: entry, body: body)
        case .responseBody:
            guard let body = entry.responseBody else {
                cell.contentConfiguration = nil
                return
            }
            configureBodyCell(cell, entry: entry, body: body)
        case .error:
            var content = UIListContentConfiguration.cell()
            content.text = entry.errorDescription ?? ""
            content.textProperties.color = .systemOrange
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
        }
    }

    private func configureSummaryCell(_ cell: WINetworkDetailObservingListCell, entry: NetworkEntry) {
        applySummaryCellContent(cell, entry: entry)
        cell.observeSummary(
            entry: entry,
            makeMetricsText: { [weak self] observedEntry in
                self?.makeOverviewMetricsAttributedText(for: observedEntry) ?? NSAttributedString(string: "")
            }
        )
    }

    private func configureBodyCell(_ cell: WINetworkDetailObservingListCell, entry: NetworkEntry, body: NetworkBody) {
        applyBodyCellContent(cell, entry: entry, body: body)
        cell.observeBody(
            entry: entry,
            body: body,
            makePrimaryText: { [weak self] observedEntry, observedBody in
                self?.makeBodyPrimaryText(entry: observedEntry, body: observedBody) ?? ""
            },
            makeSecondaryText: { [weak self] observedBody in
                self?.makeBodySecondaryText(observedBody) ?? ""
            }
        )
    }

    private func applySummaryCellContent(_ cell: UICollectionViewListCell, entry: NetworkEntry) {
        var content = makeOverviewSubtitleConfiguration(for: entry)
        content.secondaryText = entry.url
        content.attributedText = makeOverviewMetricsAttributedText(for: entry)
        cell.contentConfiguration = content
        cell.accessories = []
    }

    private func applyBodyCellContent(_ cell: UICollectionViewListCell, entry: NetworkEntry, body: NetworkBody) {
        var content = makeElementLikeSubtitleConfiguration(
            title: makeBodyPrimaryText(entry: entry, body: body),
            detail: makeBodySecondaryText(body),
            titleColor: .secondaryLabel,
            detailColor: .label,
            titleNumberOfLines: 1,
            detailNumberOfLines: 6
        )
        content.text = makeBodyPrimaryText(entry: entry, body: body)
        content.secondaryText = makeBodySecondaryText(body)
        cell.contentConfiguration = content
        cell.accessories = [.disclosureIndicator()]
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
        configuration.attributedText = makeOverviewMetricsAttributedText(for: entry)
        return configuration
    }

    private func makeOverviewMetricsAttributedText(for entry: NetworkEntry) -> NSAttributedString {
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
        return attributed
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
            let itemID = dataSource.itemIdentifier(for: indexPath),
            let entry
        else {
            return false
        }
        switch itemID {
        case .requestBody:
            return entry.requestBody != nil
        case .responseBody:
            return entry.responseBody != nil
        default:
            return false
        }
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
        guard
            let itemID = dataSource.itemIdentifier(for: indexPath),
            let entry
        else {
            return
        }
        let body: NetworkBody?
        switch itemID {
        case .requestBody:
            body = entry.requestBody
        case .responseBody:
            body = entry.responseBody
        default:
            body = nil
        }
        guard let body else {
            return
        }

        let preview = WINetworkBodyPreviewViewController(entry: entry, inspector: inspector, bodyState: body)
        if showsNavigationControls {
            navigationController?.pushViewController(preview, animated: true)
            return
        }
        let previewNavigationController = UINavigationController(rootViewController: preview)
        wiApplyClearNavigationBarStyle(to: previewNavigationController)
        present(previewNavigationController, animated: true)
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

@MainActor
private final class WINetworkDetailObservingListCell: UICollectionViewListCell {
    func observeSummary(
        entry: NetworkEntry,
        makeMetricsText: @escaping @MainActor (NetworkEntry) -> NSAttributedString
    ) {
        entry.observe(\.url) { [weak self] newURL in
            self?.updateSummaryURL(newURL)
        }

        entry.observe([\.method, \.statusCode, \.statusText, \.phase, \.duration, \.encodedBodyLength]) {
            [weak self, weak entry] in
            guard let self, let entry else { return }
            self.updateSummaryMetrics(makeMetricsText(entry))
        }
    }

    func observeBody(
        entry: NetworkEntry,
        body: NetworkBody,
        makePrimaryText: @escaping @MainActor (NetworkEntry, NetworkBody) -> String,
        makeSecondaryText: @escaping @MainActor (NetworkBody) -> String
    ) {
        entry.observe([\.mimeType, \.decodedBodyLength, \.encodedBodyLength, \.requestBodyBytesSent]) {
            [weak self, weak entry, weak body] in
            guard let self, let entry, let body else { return }
            self.updateBodyPrimaryText(makePrimaryText(entry, body))
        }

        body.observe([\.kind]) {
            [weak self, weak entry, weak body] in
            guard let self, let entry, let body else { return }
            self.updateBodyPrimaryText(makePrimaryText(entry, body))
            self.updateBodySecondaryText(makeSecondaryText(body))
        }
        body.observe([\.size]) {
            [weak self, weak entry, weak body] in
            guard let self, let entry, let body else { return }
            self.updateBodyPrimaryText(makePrimaryText(entry, body))
        }

        body.observe([\.preview, \.full, \.summary, \.formEntries, \.isBase64Encoded, \.isTruncated, \.fetchState, \.reference]) {
            [weak self, weak body] in
            guard let self, let body else { return }
            self.updateBodySecondaryText(makeSecondaryText(body))
        }
    }

    private func updateSummaryURL(_ url: String) {
        guard var content = contentConfiguration as? UIListContentConfiguration else {
            return
        }
        content.secondaryText = url
        contentConfiguration = content
    }

    private func updateSummaryMetrics(_ metricsText: NSAttributedString) {
        guard var content = contentConfiguration as? UIListContentConfiguration else {
            return
        }
        content.attributedText = metricsText
        contentConfiguration = content
    }

    private func updateBodyPrimaryText(_ text: String) {
        guard var content = contentConfiguration as? UIListContentConfiguration else {
            return
        }
        content.text = text
        contentConfiguration = content
    }

    private func updateBodySecondaryText(_ text: String) {
        guard var content = contentConfiguration as? UIListContentConfiguration else {
            return
        }
        content.secondaryText = text
        contentConfiguration = content
        accessories = [.disclosureIndicator()]
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Network Detail (UIKit)") {
    WIUIKitPreviewContainer {
        guard let context = WINetworkPreviewFixtures.makeDetailContext() else {
            return UIViewController()
        }
        return UINavigationController(
            rootViewController: WINetworkDetailViewController(inspector: context.inspector)
        )
    }
}
#endif
#endif
