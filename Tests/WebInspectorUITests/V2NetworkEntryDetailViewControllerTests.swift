#if canImport(UIKit)
import SyntaxEditorUI
import Testing
import UIKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct V2NetworkEntryDetailViewControllerTests {
    @Test
    func detailShowsEmptyStateWithoutSelection() {
        let inspector = WINetworkModel(session: NetworkSession())
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)

        viewController.loadViewIfNeeded()

        #expect(viewController.collectionViewForTesting.isHidden)
        #expect(viewController.contentUnavailableConfiguration != nil)
    }

    @Test
    func detailDataSourceDoesNotRetainViewController() async {
        let inspector = WINetworkModel(session: NetworkSession())
        weak var weakViewController: V2_NetworkEntryDetailViewController?
        var viewController: V2_NetworkEntryDetailViewController? = V2_NetworkEntryDetailViewController(
            inspector: inspector
        )
        weakViewController = viewController

        viewController?.loadViewIfNeeded()
        for _ in 0..<64 {
            await Task.yield()
        }

        viewController = nil
        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(weakViewController == nil)
    }

    @Test
    func detailRendersOverviewRequestAndResponseHeaders() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entry = try #require(
            inspector.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/api/data.json",
                    requestHeaders: NetworkHeaders([
                        NetworkHeaderField(name: "accept", value: "application/json")
                    ]),
                    responseHeaders: NetworkHeaders([
                        NetworkHeaderField(name: "content-type", value: "application/json")
                    ])
                )
            ]).first
        )
        inspector.selectEntry(entry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let didRender = await waitUntil {
            collectionView.numberOfSections == 3
                && collectionView.numberOfItems(inSection: 0) == 1
                && collectionView.numberOfItems(inSection: 1) == 1
                && collectionView.numberOfItems(inSection: 2) == 1
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "https://example.com/api/data.json"
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "accept"
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "application/json"
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "content-type"
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "application/json"
        }

        #expect(didRender)
        #expect(viewController.contentUnavailableConfiguration == nil)
    }

    @Test
    func detailShowsNoHeadersRowsWhenHeadersAreEmpty() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entry = try #require(
            inspector.store.applySnapshots([
                makeSnapshot(requestID: 1, url: "https://example.com/empty")
            ]).first
        )
        inspector.selectEntry(entry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let noHeadersText = wiLocalized("network.headers.empty", default: "No headers")
        let didRender = await waitUntil {
            collectionView.numberOfSections == 3
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 1)) == noHeadersText
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) == noHeadersText
        }

        #expect(didRender)
    }

    @Test
    func detailDoesNotCreateBodySectionsOrFetchBodies() async throws {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "body for \(ref ?? "unknown")",
                size: nil,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                reference: ref,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        }
        let inspector = WINetworkModel(session: NetworkSession(bodyFetcher: fetcher))
        let entry = try #require(
            inspector.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/body",
                    requestHeaders: NetworkHeaders([
                        NetworkHeaderField(name: "content-type", value: "application/json")
                    ]),
                    responseHeaders: NetworkHeaders([
                        NetworkHeaderField(name: "content-type", value: "application/json")
                    ]),
                    requestBody: makeBody(reference: "request-ref", role: .request),
                    responseBody: makeBody(reference: "response-ref", role: .response)
                )
            ]).first
        )
        inspector.selectEntry(entry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let didRenderOnlyHeaderSections = await waitUntil {
            collectionView.numberOfSections == 3
                && collectionView.numberOfItems(inSection: 0) == 1
                && collectionView.numberOfItems(inSection: 1) == 1
                && collectionView.numberOfItems(inSection: 2) == 1
        }

        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(didRenderOnlyHeaderSections)
        #expect(fetcher.fetchCount == 0)
    }

    @Test
    func detailModeMenuReflectsBodyAvailability() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entry = try #require(
            inspector.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/body",
                    requestBody: makeBody(
                        full: "request-body",
                        role: .request
                    ),
                    responseBody: nil
                )
            ]).first
        )
        inspector.selectEntry(entry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRender = await waitUntil {
            viewController.collectionViewForTesting.numberOfSections == 3
        }
        #expect(didRender)

        let overviewAction = try action(for: .overview, in: viewController.modeMenuForTesting)
        let requestAction = try action(for: .requestBody, in: viewController.modeMenuForTesting)
        let responseAction = try action(for: .responseBody, in: viewController.modeMenuForTesting)

        #expect(overviewAction.state == .on)
        #expect(overviewAction.attributes.contains(.disabled) == false)
        #expect(requestAction.attributes.contains(.disabled) == false)
        #expect(responseAction.attributes.contains(.disabled))
        #expect(menuActionTitles(in: viewController.modeMenuForTesting) == V2_NetworkEntryDetailMode.allCases.map(\.title))

        requestAction.performWithSender(nil, target: nil)

        let didSwitch = await waitUntil {
            viewController.currentModeForTesting == .requestBody
                && viewController.bodyTextViewForTesting.text == "request-body"
        }
        #expect(didSwitch)
        #expect(try action(for: .requestBody, in: viewController.modeMenuForTesting).state == .on)
        #expect(menuActionTitles(in: viewController.modeMenuForTesting) == V2_NetworkEntryDetailMode.allCases.map(\.title))
    }

    @Test
    func responseBodyModeRendersPrettyPrintedJSONInReadOnlySyntaxEditor() async throws {
        let compactJSON = "{\"name\":\"codex\",\"value\":42}"
        let inspector = WINetworkModel(session: NetworkSession())
        let entry = try #require(
            inspector.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/api/data.json",
                    responseHeaders: NetworkHeaders([
                        NetworkHeaderField(name: "content-type", value: "application/json")
                    ]),
                    responseBody: makeBody(full: compactJSON, role: .response)
                )
            ]).first
        )
        inspector.selectEntry(entry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        viewController.setModeForTesting(.responseBody)

        let didRender = await waitUntil {
            viewController.bodyTextViewForTesting.text.contains("\n")
                && viewController.bodyTextViewForTesting.text.contains("\"name\"")
        }
        #expect(didRender)

        let syntaxView = viewController.bodyTextViewForTesting
        #expect(syntaxView.isEditable == false)
        #expect(syntaxView.isSelectable)
        #expect(syntaxView.model.lineWrappingEnabled)
        #expect(syntaxView.model.language == .json)
        #expect(syntaxView.model.colorTheme == .xcode)
    }

    @Test
    func requestBodyModeFormatsFormEntriesAsPlainText() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let body = NetworkBody(
            kind: .form,
            preview: nil,
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: false,
            summary: "FormData",
            reference: nil,
            formEntries: [
                NetworkBody.FormEntry(name: "token", value: "abc", isFile: false, fileName: nil),
                NetworkBody.FormEntry(name: "upload", value: "<file payload.txt>", isFile: true, fileName: "payload.txt"),
            ],
            fetchState: .full,
            role: .request
        )
        let entry = try #require(
            inspector.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/upload",
                    method: "POST",
                    requestBody: body
                )
            ]).first
        )
        inspector.selectEntry(entry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        viewController.setModeForTesting(.requestBody)

        let didRender = await waitUntil {
            viewController.bodyTextViewForTesting.text == "token=abc\nupload=<file payload.txt>"
        }
        #expect(didRender)
        let syntaxView = viewController.bodyTextViewForTesting
        #expect(syntaxView.model.colorTheme == .webInspectorPlainText)
    }

    @Test
    func requestBodyModeFormatsURLEncodedFormText() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entry = try #require(
            inspector.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/form",
                    method: "POST",
                    requestHeaders: NetworkHeaders([
                        NetworkHeaderField(name: "content-type", value: "application/x-www-form-urlencoded")
                    ]),
                    requestBody: makeBody(
                        full: "name=Jane+Doe&city=Tokyo%20East",
                        role: .request
                    )
                )
            ]).first
        )
        inspector.selectEntry(entry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        viewController.setModeForTesting(.requestBody)

        let didRender = await waitUntil {
            viewController.bodyTextViewForTesting.text == "name=Jane Doe\ncity=Tokyo East"
        }
        #expect(didRender)
        #expect(viewController.bodyTextViewForTesting.model.colorTheme == .webInspectorPlainText)
    }

    @Test
    func responseBodyModeUsesNoHighlightThemeForPlainText() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entry = try #require(
            inspector.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/download.bin",
                    responseHeaders: NetworkHeaders([
                        NetworkHeaderField(name: "content-type", value: "application/octet-stream")
                    ]),
                    responseBody: makeBody(full: "plain payload", role: .response)
                )
            ]).first
        )
        inspector.selectEntry(entry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        viewController.setModeForTesting(.responseBody)

        let didRender = await waitUntil {
            viewController.bodyTextViewForTesting.text == "plain payload"
        }
        #expect(didRender)
        #expect(viewController.bodyTextViewForTesting.model.colorTheme == .webInspectorPlainText)
    }

    @Test
    func bodyModePersistsAcrossSelectedEntryChanges() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entries = inspector.store.applySnapshots([
            makeSnapshot(
                requestID: 1,
                url: "https://example.com/first.json",
                responseBody: makeBody(full: "{\"first\":true}", role: .response)
            ),
            makeSnapshot(
                requestID: 2,
                url: "https://example.com/second.json",
                responseBody: nil
            ),
        ])
        let firstEntry = try #require(entries.first)
        let secondEntry = try #require(entries.dropFirst().first)
        inspector.selectEntry(firstEntry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        viewController.setModeForTesting(.responseBody)
        let didRenderFirst = await waitUntil {
            viewController.bodyTextViewForTesting.text.contains("\"first\"")
        }
        #expect(didRenderFirst)

        inspector.selectEntry(secondEntry)

        let didKeepMode = await waitUntil {
            viewController.currentModeForTesting == .responseBody
                && viewController.title == "second.json"
                && viewController.bodyTextViewForTesting.text == wiLocalized(
                    "network.body.unavailable",
                    default: "Body unavailable"
                )
        }
        #expect(didKeepMode)
    }

    @Test
    func bodyViewUpdatesWhenBodyFetchStateAndTextChange() async throws {
        let body = NetworkBody(
            kind: .text,
            preview: nil,
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            reference: "response-ref",
            formEntries: [],
            fetchState: .inline,
            role: .response
        )
        let inspector = WINetworkModel(session: NetworkSession())
        let entry = try #require(
            inspector.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/fetch.json",
                    responseHeaders: NetworkHeaders([
                        NetworkHeaderField(name: "content-type", value: "application/json")
                    ]),
                    responseBody: body
                )
            ]).first
        )
        inspector.selectEntry(entry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        viewController.setModeForTesting(.responseBody)
        body.fetchState = .fetching

        let didShowFetching = await waitUntil {
            viewController.bodyTextViewForTesting.text == wiLocalized(
                "network.body.fetching",
                default: "Fetching body..."
            )
        }
        #expect(didShowFetching)

        body.applyFullBody(
            "{\"updated\":true}",
            isBase64Encoded: false,
            isTruncated: false,
            size: nil
        )

        let didShowUpdatedText = await waitUntil {
            viewController.bodyTextViewForTesting.text.contains("\"updated\"")
                && viewController.bodyTextViewForTesting.text.contains("\n")
        }
        #expect(didShowUpdatedText)
    }

    @Test
    func selectedEntryChangeReloadsDetail() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entries = inspector.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/first.json"),
            makeSnapshot(requestID: 2, url: "https://example.com/second.json")
        ])
        let firstEntry = try #require(entries.first)
        let secondEntry = try #require(entries.dropFirst().first)
        inspector.selectEntry(firstEntry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let didRenderFirst = await waitUntil {
            listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "https://example.com/first.json"
        }
        #expect(didRenderFirst)

        inspector.selectEntry(secondEntry)

        let didRenderSecond = await waitUntil {
            viewController.title == "second.json"
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "https://example.com/second.json"
        }

        #expect(didRenderSecond)
    }

    @Test
    func headerChangesUpdateHeaderRows() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entry = try #require(
            inspector.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/headers",
                    requestHeaders: NetworkHeaders([
                        NetworkHeaderField(name: "accept", value: "text/html")
                    ]),
                    responseHeaders: NetworkHeaders([
                        NetworkHeaderField(name: "cache-control", value: "no-cache")
                    ])
                )
            ]).first
        )
        inspector.selectEntry(entry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let didRenderInitialHeaders = await waitUntil {
            listCellText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "accept"
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "cache-control"
        }
        #expect(didRenderInitialHeaders)

        entry.requestHeaders = NetworkHeaders([
            NetworkHeaderField(name: "x-request-id", value: "abc")
        ])
        entry.responseHeaders = NetworkHeaders([
            NetworkHeaderField(name: "content-type", value: "application/json")
        ])

        let didUpdateHeaders = await waitUntil {
            listCellText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "x-request-id"
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 1)) == "abc"
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "content-type"
                && listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "application/json"
        }

        #expect(didUpdateHeaders)
    }

    @Test
    func overviewCellUpdatesObservedEntryMetrics() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entry = try #require(
            inspector.store.applySnapshots([
                makeSnapshot(
                    requestID: 1,
                    url: "https://example.com/metrics",
                    statusCode: 200,
                    duration: 1,
                    encodedBodyLength: 128
                )
            ]).first
        )
        inspector.selectEntry(entry)
        let viewController = V2_NetworkEntryDetailViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let didRenderInitialMetrics = await waitUntil {
            overviewAttributedText(in: collectionView)?.string.contains("1.00 s") == true
        }
        #expect(didRenderInitialMetrics)

        entry.url = "https://example.com/metrics-updated"
        entry.statusCode = 404
        entry.duration = 0.25
        entry.encodedBodyLength = 1024

        let didUpdateMetrics = await waitUntil {
            listCellSecondaryText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "https://example.com/metrics-updated"
                && overviewAttributedText(in: collectionView)?.string.contains("250 ms") == true
                && overviewAttributedText(in: collectionView)?.string.contains("1 KB") == true
        }

        #expect(didUpdateMetrics)
    }

    private func showInWindow(_ viewController: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.view.frame = window.bounds
        viewController.view.layoutIfNeeded()
        return window
    }

    private func makeSnapshot(
        requestID: Int,
        url: String,
        method: String = "GET",
        statusCode: Int? = 200,
        statusText: String = "OK",
        mimeType: String = "application/json",
        requestHeaders: NetworkHeaders = NetworkHeaders(),
        responseHeaders: NetworkHeaders = NetworkHeaders(),
        requestBody: NetworkBody? = nil,
        responseBody: NetworkBody? = nil,
        duration: TimeInterval? = 1,
        encodedBodyLength: Int? = 128,
        phase: NetworkEntry.Phase = .completed
    ) -> NetworkEntry.Snapshot {
        NetworkEntry.Snapshot(
            sessionID: "test-session",
            requestID: requestID,
            request: NetworkEntry.Request(
                url: url,
                method: method,
                headers: requestHeaders,
                body: requestBody,
                bodyBytesSent: nil,
                type: nil,
                wallTime: nil
            ),
            response: NetworkEntry.Response(
                statusCode: statusCode,
                statusText: statusText,
                mimeType: mimeType,
                headers: responseHeaders,
                body: responseBody,
                blockedCookies: [],
                errorDescription: nil
            ),
            transfer: NetworkEntry.Transfer(
                startTimestamp: 0,
                endTimestamp: duration,
                duration: duration,
                encodedBodyLength: encodedBodyLength,
                decodedBodyLength: encodedBodyLength,
                phase: phase
            )
        )
    }

    private func makeBody(
        reference: String? = nil,
        full: String? = nil,
        preview: String? = "preview",
        role: NetworkBody.Role
    ) -> NetworkBody {
        NetworkBody(
            kind: .text,
            preview: preview,
            full: full,
            size: nil,
            isBase64Encoded: false,
            isTruncated: full == nil,
            summary: nil,
            reference: reference,
            formEntries: [],
            fetchState: full == nil ? .inline : .full,
            role: role
        )
    }

    private func action(
        for mode: V2_NetworkEntryDetailMode,
        in menu: UIMenu
    ) throws -> UIAction {
        try #require(action(title: mode.title, in: menu))
    }

    private func action(title: String, in menu: UIMenu) -> UIAction? {
        for child in menu.children {
            if let action = child as? UIAction, action.title == title {
                return action
            }
            if let submenu = child as? UIMenu, let nested = action(title: title, in: submenu) {
                return nested
            }
        }
        return nil
    }

    private func menuActionTitles(in menu: UIMenu) -> [String] {
        menu.children.compactMap { ($0 as? UIAction)?.title }
    }

    private func listCellText(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> String? {
        contentConfiguration(in: collectionView, at: indexPath)?.text
    }

    private func listCellSecondaryText(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> String? {
        contentConfiguration(in: collectionView, at: indexPath)?.secondaryText
    }

    private func overviewAttributedText(in collectionView: UICollectionView) -> NSAttributedString? {
        contentConfiguration(in: collectionView, at: IndexPath(item: 0, section: 0))?.attributedText
    }

    private func contentConfiguration(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> UIListContentConfiguration? {
        guard
            indexPath.section < collectionView.numberOfSections,
            indexPath.item < collectionView.numberOfItems(inSection: indexPath.section),
            let cell = listCell(in: collectionView, at: indexPath),
            let content = cell.contentConfiguration as? UIListContentConfiguration
        else {
            return nil
        }
        return content
    }

    private func listCell(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> UICollectionViewListCell? {
        if let visibleCell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell {
            return visibleCell
        }
        return collectionView.dataSource?.collectionView(
            collectionView,
            cellForItemAt: indexPath
        ) as? UICollectionViewListCell
    }

    private func waitUntil(
        maxTicks: Int = 512,
        _ condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }
}

@MainActor
private final class StubNetworkBodyFetcher: NetworkBodyFetching {
    private let onFetch: @MainActor (String?, AnyObject?, NetworkBody.Role) async -> NetworkBodyFetchResult
    private(set) var fetchCount = 0

    init(
        onFetch: @escaping @MainActor (String?, AnyObject?, NetworkBody.Role) async -> NetworkBody?
    ) {
        self.onFetch = { ref, handle, role in
            guard let body = await onFetch(ref, handle, role) else {
                return .bodyUnavailable
            }
            return .fetched(body)
        }
    }

    func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool {
        switch role {
        case .request, .response:
            true
        }
    }

    func fetchBodyResult(locator: NetworkDeferredBodyLocator, role: NetworkBody.Role) async -> NetworkBodyFetchResult {
        fetchCount += 1
        return await onFetch(locator.reference, locator.handle, role)
    }
}
#endif
