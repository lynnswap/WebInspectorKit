#if canImport(UIKit)
import Foundation
import WebInspectorDataKit
import WebInspectorUIBase
import UIKit

@MainActor
package final class NetworkCookiesViewController: UICollectionViewController {
    package struct RequestEpoch: Hashable, Sendable {
        private enum Storage: Hashable, Sendable {
            case request(
                id: NetworkRequest.ID,
                instance: ObjectIdentifier,
                lifecycleRevision: UInt64,
                redirectCount: Int
            )
            case testing(ObjectIdentifier)
        }

        private let storage: Storage

        private init(storage: Storage) {
            self.storage = storage
        }

        package init(request: NetworkRequest) {
            storage = .request(
                id: request.id,
                instance: ObjectIdentifier(request),
                lifecycleRevision: request.lifecycleRevision,
                redirectCount: request.redirects.count
            )
        }

#if DEBUG
        package static func testing(_ owner: AnyObject) -> RequestEpoch {
            RequestEpoch(storage: .testing(ObjectIdentifier(owner)))
        }
#endif
    }

    package struct CookieKey: Hashable, Sendable {
        package let name: String
        package let duplicateOccurrence: Int

        package init(name: String, duplicateOccurrence: Int) {
            self.name = name
            self.duplicateOccurrence = duplicateOccurrence
        }
    }

    package enum SectionID: Int, CaseIterable, Hashable, Sendable {
        case request
        case response
    }

    package enum ItemID: Hashable, Sendable {
        case requestCookie(epoch: RequestEpoch, key: CookieKey)
        case responseCookie(epoch: RequestEpoch, key: CookieKey)
        case state(epoch: RequestEpoch, section: SectionID, kind: StateKind)
        case diagnostic(epoch: RequestEpoch, section: SectionID, ordinal: Int)
    }

    package enum StateKind: Hashable, Sendable {
        case requestNotCaptured
        case requestMemoryCache
        case requestEmpty
        case responseLoading
        case responseMissing
        case responseEmpty
    }

    package struct MessageContent: Hashable, Sendable {
        package enum Kind: Hashable, Sendable {
            case information
            case loading
            case warning
        }

        package let kind: Kind
        package let title: String
        package let detail: String?
    }

    private enum RowContent: Hashable, Sendable {
        case cookie(NetworkCookieRowContent)
        case message(MessageContent)
    }

    private var rowContents: [ItemID: RowContent] = [:]
    private lazy var dataSource = makeDataSource()

    package init() {
        super.init(collectionViewLayout: Self.makeLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        _ = dataSource
        collectionView.allowsSelection = false
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "WebInspector.Network.CookiesList"
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
        }
        applySnapshot(rows: emptyRows(), animatingDifferences: false)
    }

    package func render(
        _ sections: NetworkCookieSections,
        requestEpoch: RequestEpoch,
        completion: (@MainActor () -> Void)? = nil
    ) {
        loadViewIfNeeded()
        applySnapshot(
            rows: rows(for: sections, requestEpoch: requestEpoch),
            animatingDifferences: view.window != nil,
            completion: completion
        )
    }

    package func clear(completion: (@MainActor () -> Void)? = nil) {
        loadViewIfNeeded()
        applySnapshot(
            rows: emptyRows(),
            animatingDifferences: false,
            completion: completion
        )
    }

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let configuration = Self.listLayoutConfiguration
            let section = NSCollectionLayoutSection.list(
                using: configuration,
                layoutEnvironment: environment
            )
            var contentInsets = section.contentInsets
            contentInsets.top = 0
            section.contentInsets = contentInsets
            return section
        }
    }

    private static var listLayoutConfiguration: UICollectionLayoutListConfiguration {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.showsSeparators = true
        return configuration
    }

    private func applyBackgroundFromTraits() {
        let backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        view.backgroundColor = backgroundColor
        collectionView.backgroundColor = backgroundColor
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<SectionID, ItemID> {
        let cookieRegistration = UICollectionView.CellRegistration<NetworkCookieCell, ItemID> {
            [weak self] cell, _, itemID in
            guard let self,
                  case let .cookie(content) = rowContents[itemID] else {
                cell.clear()
                return
            }
            cell.bind(content)
        }
        let messageRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ItemID> {
            [weak self] cell, _, itemID in
            guard let self,
                  case let .message(content) = rowContents[itemID] else {
                Self.clearMessageCell(cell)
                return
            }
            configureMessageCell(cell, content: content)
        }

        let dataSource = UICollectionViewDiffableDataSource<SectionID, ItemID>(
            collectionView: collectionView
        ) { collectionView, indexPath, itemID in
            switch itemID {
            case .requestCookie, .responseCookie:
                collectionView.dequeueConfiguredReusableCell(
                    using: cookieRegistration,
                    for: indexPath,
                    item: itemID
                )
            case .state, .diagnostic:
                collectionView.dequeueConfiguredReusableCell(
                    using: messageRegistration,
                    for: indexPath,
                    item: itemID
                )
            }
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak dataSource] header, _, indexPath in
            guard let dataSource,
                  dataSource.snapshot().sectionIdentifiers.indices.contains(indexPath.section) else {
                header.contentConfiguration = nil
                header.accessibilityLabel = nil
                return
            }
            let section = dataSource.snapshot().sectionIdentifiers[indexPath.section]
            var content = UIListContentConfiguration.header()
            content.text = Self.title(for: section)
            header.contentConfiguration = content
            header.isAccessibilityElement = true
            header.accessibilityLabel = content.text
            header.accessibilityTraits = .header
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

    private func rows(
        for sections: NetworkCookieSections,
        requestEpoch: RequestEpoch
    ) -> [(SectionID, [(ItemID, RowContent)])] {
        [
            (.request, requestRows(for: sections.request, requestEpoch: requestEpoch)),
            (.response, responseRows(for: sections.response, requestEpoch: requestEpoch)),
        ]
    }

    private func emptyRows() -> [(SectionID, [(ItemID, RowContent)])] {
        [
            (.request, []),
            (.response, []),
        ]
    }

    private func requestRows(
        for section: NetworkRequestCookieSection,
        requestEpoch: RequestEpoch
    ) -> [(ItemID, RowContent)] {
        switch section {
        case .unavailable(.notCaptured):
            return [stateRow(
                requestEpoch: requestEpoch,
                section: .request,
                kind: .requestNotCaptured,
                title: localized(
                    "network.cookies.request.not_captured",
                    defaultValue: "Request cookies were not captured"
                )
            )]
        case .unavailable(.servedFromMemoryCache):
            return [stateRow(
                requestEpoch: requestEpoch,
                section: .request,
                kind: .requestMemoryCache,
                title: localized(
                    "network.cookies.request.memory_cache",
                    defaultValue: "No request, served from the memory cache"
                )
            )]
        case .empty:
            return [stateRow(
                requestEpoch: requestEpoch,
                section: .request,
                kind: .requestEmpty,
                title: localized(
                    "network.cookies.request.empty",
                    defaultValue: "No request cookies"
                )
            )]
        case .values(let report):
            var rows = identifiedCookies(report.cookies, name: \NetworkRequestCookie.name)
                .sorted { cookieSort($0.cookie, $1.cookie) }
                .map { cookie, key in
                    (
                        ItemID.requestCookie(epoch: requestEpoch, key: key),
                        RowContent.cookie(requestRowContent(cookie))
                    )
                }
            rows.append(contentsOf: diagnosticRows(
                report.diagnostics,
                status: report.status,
                rawHeaderValues: report.rawHeaderValues,
                section: .request,
                requestEpoch: requestEpoch
            ))
            return rows
        }
    }

    private func responseRows(
        for section: NetworkResponseCookieSection,
        requestEpoch: RequestEpoch
    ) -> [(ItemID, RowContent)] {
        switch section {
        case .loading:
            return [stateRow(
                requestEpoch: requestEpoch,
                section: .response,
                kind: .responseLoading,
                title: localized(
                    "network.cookies.response.loading",
                    defaultValue: "Waiting for response"
                ),
                messageKind: .loading
            )]
        case .noResponse:
            return [stateRow(
                requestEpoch: requestEpoch,
                section: .response,
                kind: .responseMissing,
                title: localized(
                    "network.cookies.response.missing",
                    defaultValue: "No response was received"
                )
            )]
        case .empty:
            return [stateRow(
                requestEpoch: requestEpoch,
                section: .response,
                kind: .responseEmpty,
                title: localized(
                    "network.cookies.response.empty",
                    defaultValue: "No response cookies"
                )
            )]
        case .values(let report):
            var rows = identifiedCookies(report.cookies, name: \NetworkResponseCookie.name)
                .sorted { cookieSort($0.cookie, $1.cookie) }
                .map { cookie, key in
                    (
                        ItemID.responseCookie(epoch: requestEpoch, key: key),
                        RowContent.cookie(responseRowContent(cookie))
                    )
                }
            rows.append(contentsOf: diagnosticRows(
                report.diagnostics,
                status: report.status,
                rawHeaderValues: report.rawHeaderValues,
                section: .response,
                requestEpoch: requestEpoch
            ))
            return rows
        }
    }

    private func stateRow(
        requestEpoch: RequestEpoch,
        section: SectionID,
        kind: StateKind,
        title: String,
        messageKind: MessageContent.Kind = .information
    ) -> (ItemID, RowContent) {
        (
            .state(epoch: requestEpoch, section: section, kind: kind),
            .message(MessageContent(kind: messageKind, title: title, detail: nil))
        )
    }

    private func diagnosticRows(
        _ diagnostics: [NetworkCookieParseDiagnostic],
        status: NetworkCookieParseStatus,
        rawHeaderValues: [String],
        section: SectionID,
        requestEpoch: RequestEpoch
    ) -> [(ItemID, RowContent)] {
        let title: String
        switch status {
        case .ambiguousCombined:
            title = localized(
                "network.cookies.warning.ambiguous_combined",
                defaultValue: "Combined cookie header cannot be parsed safely"
            )
        case .partial:
            title = localized(
                "network.cookies.warning.partial",
                defaultValue: "Some cookie data could not be parsed"
            )
        case .unparsed:
            title = localized(
                "network.cookies.warning.unparsed",
                defaultValue: "Cookie header could not be parsed"
            )
        case .complete:
            title = localized(
                "network.cookies.warning.unparsed",
                defaultValue: "Cookie header could not be parsed"
            )
        }

        if diagnostics.isEmpty {
            guard status != .complete else {
                return []
            }
            return [(
                .diagnostic(epoch: requestEpoch, section: section, ordinal: 0),
                .message(MessageContent(
                    kind: .warning,
                    title: title,
                    detail: rawHeaderValues.joined(separator: "\n")
                ))
            )]
        }
        return diagnostics.enumerated().map { index, diagnostic in
            (
                .diagnostic(epoch: requestEpoch, section: section, ordinal: index),
                .message(MessageContent(
                    kind: .warning,
                    title: title,
                    detail: diagnostic.rawFragment
                ))
            )
        }
    }

    private func requestRowContent(_ cookie: NetworkRequestCookie) -> NetworkCookieRowContent {
        NetworkCookieRowContent(
            fields: [
                field("network.cookies.field.name", defaultValue: "Name", value: cookie.name),
                field("network.cookies.field.value", defaultValue: "Value", value: cookie.value),
            ],
            accessibilityIdentifier: "WebInspector.Network.RequestCookie.\(cookie.ordinal)"
        )
    }

    private func responseRowContent(_ cookie: NetworkResponseCookie) -> NetworkCookieRowContent {
        let missingValue = localized("network.cookies.value.unavailable", defaultValue: "Not reported")
        var fields = [
            field("network.cookies.field.name", defaultValue: "Name", value: cookie.name),
            field("network.cookies.field.value", defaultValue: "Value", value: cookie.value),
            field("network.cookies.field.domain", defaultValue: "Domain", value: cookie.domain ?? missingValue),
            field("network.cookies.field.path", defaultValue: "Path", value: cookie.path ?? missingValue),
            field(
                "network.cookies.field.partitioned",
                defaultValue: "Partitioned",
                value: booleanText(cookie.isPartitioned)
            ),
            field(
                "network.cookies.field.expires",
                defaultValue: "Expires",
                value: expiresText(cookie, missingValue: missingValue)
            ),
            field(
                "network.cookies.field.max_age",
                defaultValue: "Max-Age",
                value: cookie.maxAgeSeconds.map(String.init) ?? cookie.rawMaxAge ?? missingValue
            ),
            field(
                "network.cookies.field.secure",
                defaultValue: "Secure",
                value: booleanText(cookie.isSecure)
            ),
            field(
                "network.cookies.field.http_only",
                defaultValue: "HttpOnly",
                value: booleanText(cookie.isHTTPOnly)
            ),
            field(
                "network.cookies.field.same_site",
                defaultValue: "SameSite",
                value: sameSiteText(cookie.sameSite, missingValue: missingValue)
            ),
        ]
        fields.append(contentsOf: cookie.unknownAttributes.map { attribute in
            field(
                "network.cookies.field.unknown_attribute",
                defaultValue: "Unknown Attribute",
                value: attribute.raw,
                isFullWidth: true
            )
        })
        return NetworkCookieRowContent(
            fields: fields,
            accessibilityIdentifier: "WebInspector.Network.ResponseCookie.\(cookie.ordinal)"
        )
    }

    private func field(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        value: String,
        isFullWidth: Bool = false
    ) -> NetworkCookieFieldContent {
        NetworkCookieFieldContent(
            label: localized(key, defaultValue: defaultValue),
            value: value,
            isFullWidth: isFullWidth
        )
    }

    private func expiresText(_ cookie: NetworkResponseCookie, missingValue: String) -> String {
        if let expires = cookie.expires {
            return expires.formatted(date: .abbreviated, time: .standard)
        }
        return cookie.rawExpires ?? missingValue
    }

    private func sameSiteText(_ sameSite: NetworkCookieSameSite, missingValue: String) -> String {
        switch sameSite {
        case .absent:
            missingValue
        case .none:
            "None"
        case .lax:
            "Lax"
        case .strict:
            "Strict"
        case .other(let rawValue):
            rawValue
        }
    }

    private func booleanText(_ value: Bool) -> String {
        value
            ? localized("network.cookies.value.yes", defaultValue: "Yes")
            : localized("network.cookies.value.no", defaultValue: "No")
    }

    private func cookieSort(_ lhs: NetworkRequestCookie, _ rhs: NetworkRequestCookie) -> Bool {
        cookieSort(name: lhs.name, ordinal: lhs.ordinal, name: rhs.name, ordinal: rhs.ordinal)
    }

    private func cookieSort(_ lhs: NetworkResponseCookie, _ rhs: NetworkResponseCookie) -> Bool {
        cookieSort(name: lhs.name, ordinal: lhs.ordinal, name: rhs.name, ordinal: rhs.ordinal)
    }

    private func identifiedCookies<Cookie>(
        _ cookies: [Cookie],
        name: KeyPath<Cookie, String>
    ) -> [(cookie: Cookie, key: CookieKey)] {
        var duplicateOccurrences: [String: Int] = [:]
        return cookies.map { cookie in
            let name = cookie[keyPath: name]
            let duplicateOccurrence = duplicateOccurrences[name, default: 0]
            duplicateOccurrences[name] = duplicateOccurrence + 1
            return (
                cookie,
                CookieKey(name: name, duplicateOccurrence: duplicateOccurrence)
            )
        }
    }

    private func cookieSort(
        name lhsName: String,
        ordinal lhsOrdinal: Int,
        name rhsName: String,
        ordinal rhsOrdinal: Int
    ) -> Bool {
        switch lhsName.localizedStandardCompare(rhsName) {
        case .orderedAscending:
            true
        case .orderedDescending:
            false
        case .orderedSame:
            lhsOrdinal < rhsOrdinal
        }
    }

    private func applySnapshot(
        rows: [(SectionID, [(ItemID, RowContent)])],
        animatingDifferences: Bool,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let oldItemIDs = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<SectionID, ItemID>()
        var nextRowContents: [ItemID: RowContent] = [:]
        for (section, items) in rows {
            snapshot.appendSections([section])
            let itemIDs = items.map(\.0)
            snapshot.appendItems(itemIDs, toSection: section)
            for (itemID, content) in items {
                nextRowContents[itemID] = content
            }
        }
        let retainedItemIDs = Set(snapshot.itemIdentifiers).intersection(oldItemIDs)
        snapshot.reconfigureItems(Array(retainedItemIDs))
        rowContents = nextRowContents
        dataSource.apply(
            snapshot,
            animatingDifferences: animatingDifferences,
            completion: completion
        )
    }

    private func configureMessageCell(
        _ cell: UICollectionViewListCell,
        content: MessageContent
    ) {
        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = content.title
        configuration.secondaryText = content.detail
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.secondaryTextProperties.lineBreakMode = .byCharWrapping
        if content.kind == .warning {
            configuration.image = UIImage(systemName: "exclamationmark.triangle")
            configuration.imageProperties.tintColor = .systemOrange
        }
        cell.contentConfiguration = configuration
        cell.accessories = content.kind == .loading ? [Self.loadingAccessory()] : []
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .staticText
        cell.accessibilityLabel = content.title
        cell.accessibilityValue = content.detail
    }

    private static func clearMessageCell(_ cell: UICollectionViewListCell) {
        cell.contentConfiguration = nil
        cell.accessories = []
        cell.accessibilityLabel = nil
        cell.accessibilityValue = nil
    }

    private static func loadingAccessory() -> UICellAccessory {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        return .customView(configuration: .init(
            customView: indicator,
            placement: .trailing()
        ))
    }

    private static func title(for section: SectionID) -> String {
        switch section {
        case .request:
            String(
                localized: "network.cookies.section.request",
                defaultValue: "Request Cookies",
                bundle: WebInspectorUILocalization.bundle
            )
        case .response:
            String(
                localized: "network.cookies.section.response",
                defaultValue: "Response Cookies",
                bundle: WebInspectorUILocalization.bundle
            )
        }
    }

    private func localized(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: WebInspectorUILocalization.bundle)
    }
}

#if DEBUG
extension NetworkCookiesViewController {
    package static var listLayoutConfigurationForTesting: UICollectionLayoutListConfiguration {
        listLayoutConfiguration
    }

    package var snapshotForTesting: NSDiffableDataSourceSnapshot<SectionID, ItemID> {
        dataSource.snapshot()
    }

    package func cookieContentForTesting(_ itemID: ItemID) -> NetworkCookieRowContent? {
        guard case let .cookie(content) = rowContents[itemID] else {
            return nil
        }
        return content
    }

    package func messageContentForTesting(_ itemID: ItemID) -> MessageContent? {
        guard case let .message(content) = rowContents[itemID] else {
            return nil
        }
        return content
    }

    package static func sectionTitleForTesting(_ section: SectionID) -> String {
        title(for: section)
    }
}
#endif
#endif
