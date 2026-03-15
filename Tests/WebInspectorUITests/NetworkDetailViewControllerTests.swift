#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import WebKit
import WebInspectorTestSupport
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorUI

@MainActor
@Suite(.serialized, .webKitIsolated)
struct NetworkDetailViewControllerTests {
    @Test
    func detailViewReflectsModelDrivenFetchForSelectedResponseBody() async throws {
        let fetcher = StubNetworkBodyFetcher { _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "eager response body",
                size: nil,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        }
        let store = WINetworkStore(session: WINetworkRuntime(bodyFetcher: fetcher))
        let webView = WKWebView(frame: .zero)
        store.attach(to: webView)
        let entry = makeEntry()
        entry.responseBody = makeBody(reference: "resp_ref")
        let responseBody = try #require(entry.responseBody)
        let bodyStates = fetchStateRecorder(for: responseBody)
        store.selectEntry(entry)

        let viewController = WINetworkDetailViewController(store: store)
        viewController.loadViewIfNeeded()

        _ = await bodyStates.next(where: { $0 == "full" })
        #expect(fetcher.fetchCount == 1)
        #expect(entry.responseBody?.full == "eager response body")
        #expect(viewController.navigationItem.additionalOverflowItems == nil)
    }

    @Test
    func detailViewUpdatesWhenModelFetchRunsAfterInspectorAttaches() async throws {
        let fetcher = StubNetworkBodyFetcher { _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "reattached response body",
                size: nil,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        }
        let store = WINetworkStore(session: WINetworkRuntime(bodyFetcher: fetcher))
        let entry = makeEntry()
        entry.responseBody = makeBody(reference: "resp_ref")
        let responseBody = try #require(entry.responseBody)
        let bodyStates = fetchStateRecorder(for: responseBody)
        store.selectEntry(entry)

        let viewController = WINetworkDetailViewController(store: store)
        viewController.loadViewIfNeeded()

        #expect(fetcher.fetchCount == 0)

        let webView = WKWebView(frame: .zero)
        store.attach(to: webView)

        _ = await bodyStates.next(where: { $0 == "full" })
        #expect(fetcher.fetchCount == 1)
        #expect(entry.responseBody?.full == "reattached response body")
    }

    @Test
    func detailViewUpdatesWhenResponseHeadersAndBodyAppear() async throws {
        let fetcher = StubNetworkBodyFetcher { _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "response body",
                size: nil,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        }
        let store = WINetworkStore(session: WINetworkRuntime(bodyFetcher: fetcher))
        let webView = WKWebView(frame: .zero)
        store.attach(to: webView)
        let entry = makeEntry()
        store.selectEntry(entry)

        let viewController = WINetworkDetailViewController(store: store)
        let snapshotRevisions = AsyncValueQueue<UInt64>()
        viewController.onSnapshotAppliedForTesting = { revision in
            Task {
                await snapshotRevisions.push(revision)
            }
        }
        viewController.loadViewIfNeeded()
        viewController.view.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        viewController.view.layoutIfNeeded()

        let collectionView = try #require(
            viewController.view.subviews.compactMap { $0 as? UICollectionView }.first
        )

        while collectionView.numberOfSections != 3 {
            _ = await snapshotRevisions.next()
        }
        #expect(collectionView.numberOfSections == 3)
        #expect(viewController.navigationItem.additionalOverflowItems == nil)
        #expect(listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) != nil)
        #expect(
            listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) != "content-type"
        )

        entry.responseHeaders = NetworkHeaders([
            NetworkHeaderField(name: "content-type", value: "application/json")
        ])

        while self.listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) != "content-type" {
            _ = await snapshotRevisions.next()
        }
        #expect(self.listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "content-type")

        entry.responseBody = makeBody(reference: "resp_ref")
        let responseBody = try #require(entry.responseBody)
        let bodyStates = fetchStateRecorder(for: responseBody)

        while collectionView.numberOfSections != 4 {
            _ = await snapshotRevisions.next()
        }
        _ = await bodyStates.next(where: { $0 == "full" })
        #expect(fetcher.fetchCount == 1)
        #expect(collectionView.numberOfSections == 4)
        #expect(entry.responseBody?.full == "response body")
    }

    @Test
    func previewViewUpdatesWhenModelFetchRunsAfterInspectorAttaches() async {
        let fetcher = StubNetworkBodyFetcher { _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "reattached preview body",
                size: nil,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        }
        let store = WINetworkStore(session: WINetworkRuntime(bodyFetcher: fetcher))
        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref")
        entry.responseBody = body
        let bodyStates = fetchStateRecorder(for: body)
        store.selectEntry(entry)

        let viewController = WINetworkBodyPreviewViewController(
            entry: entry,
            store: store,
            bodyState: body
        )
        viewController.loadViewIfNeeded()

        #expect(fetcher.fetchCount == 0)

        let webView = WKWebView(frame: .zero)
        store.attach(to: webView)

        _ = await bodyStates.next(where: { $0 == "full" })
        #expect(fetcher.fetchCount == 1)
        #expect(body.full == "reattached preview body")
        #expect(viewController.navigationItem.additionalOverflowItems == nil)
    }

    @Test
    func previewViewDoesNotFetchOnLoadWithoutModelSelection() async {
        let fetcher = StubNetworkBodyFetcher { _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "preview body",
                size: nil,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                formEntries: [],
                fetchState: .full,
                role: role
            )
        }
        let store = WINetworkStore(session: WINetworkRuntime(bodyFetcher: fetcher))
        let webView = WKWebView(frame: .zero)
        store.attach(to: webView)
        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref")
        entry.responseBody = body

        let viewController = WINetworkBodyPreviewViewController(
            entry: entry,
            store: store,
            bodyState: body
        )
        viewController.loadViewIfNeeded()

        #expect(fetcher.fetchCount == 0)
        #expect(body.full == nil)
        #expect(viewController.navigationItem.additionalOverflowItems == nil)
    }

    private func makeEntry() -> NetworkEntry {
        NetworkEntry(
            sessionID: "session",
            requestID: 1,
            url: "https://example.com/detail",
            method: "GET",
            requestHeaders: NetworkHeaders(),
            startTimestamp: 0,
            wallTime: nil
        )
    }

    private func makeBody(reference: String) -> NetworkBody {
        NetworkBody(
            kind: .text,
            preview: "preview",
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            deferredLocator: .networkRequest(id: reference),
            formEntries: [],
            fetchState: .inline,
            role: .response
        )
    }

    private func listCellText(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> String? {
        guard
            let dataSource = collectionView.dataSource,
            indexPath.section < collectionView.numberOfSections,
            indexPath.item < collectionView.numberOfItems(inSection: indexPath.section),
            let cell = dataSource.collectionView(collectionView, cellForItemAt: indexPath) as? UICollectionViewListCell,
            let content = cell.contentConfiguration as? UIListContentConfiguration
        else {
            return nil
        }
        return content.text
    }
}

@MainActor
private func fetchStateRecorder(
    for body: NetworkBody
) -> ObservationRecorder<String> {
    let recorder = ObservationRecorder<String>()
    recorder.record { didChange in
        body.observe(\.fetchState, options: [.removeDuplicates]) { state in
            didChange(fetchStateLabel(state))
        }
    }
    return recorder
}

private func fetchStateLabel(_ state: NetworkBody.FetchState?) -> String {
    switch state {
    case .inline:
        "inline"
    case .fetching:
        "fetching"
    case .full:
        "full"
    case .failed(.unavailable):
        "failed:unavailable"
    case .failed(.decodeFailed):
        "failed:decodeFailed"
    case .failed(.unknown):
        "failed:unknown"
    case nil:
        "nil"
    }
}

@MainActor
private final class StubNetworkBodyFetcher: NetworkBodyFetching {
    private let onFetch: @MainActor (NetworkDeferredBodyLocator, NetworkBody.Role) async -> WINetworkBodyFetchResult
    private(set) var fetchCount = 0

    init(
        onFetch: @escaping @MainActor (NetworkDeferredBodyLocator, NetworkBody.Role) async -> NetworkBody?
    ) {
        self.onFetch = { locator, role in
            guard let body = await onFetch(locator, role) else {
                return .bodyUnavailable
            }
            return .fetched(body)
        }
    }

    func fetchBodyResult(locator: NetworkDeferredBodyLocator, role: NetworkBody.Role) async -> WINetworkBodyFetchResult {
        fetchCount += 1
        return await onFetch(locator, role)
    }
}
#endif
