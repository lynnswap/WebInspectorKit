#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import WebKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct NetworkDetailViewControllerTests {
    @Test
    func detailViewReflectsModelDrivenFetchForSelectedResponseBody() async throws {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "eager response body",
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
        let webView = WKWebView(frame: .zero)
        inspector.attach(to: webView)
        let entry = makeEntry()
        entry.responseBody = makeBody(reference: "resp_ref")
        inspector.selectEntry(entry)

        let viewController = WINetworkDetailViewController(inspector: inspector)
        viewController.loadViewIfNeeded()

        let fetched = await waitUntil {
            fetcher.fetchCount == 1 && entry.responseBody?.full == "eager response body"
        }
        #expect(fetched)
        #expect(viewController.navigationItem.additionalOverflowItems == nil)
    }

    @Test
    func detailViewUpdatesWhenModelFetchRunsAfterInspectorAttaches() async throws {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "reattached response body",
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
        let entry = makeEntry()
        entry.responseBody = makeBody(reference: "resp_ref")
        inspector.selectEntry(entry)

        let viewController = WINetworkDetailViewController(inspector: inspector)
        viewController.loadViewIfNeeded()

        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(fetcher.fetchCount == 0)

        let webView = WKWebView(frame: .zero)
        inspector.attach(to: webView)

        let fetched = await waitUntil {
            fetcher.fetchCount == 1 && entry.responseBody?.full == "reattached response body"
        }
        #expect(fetched)
    }

    @Test
    func detailViewUpdatesWhenResponseHeadersAndBodyAppear() async throws {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "response body",
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
        let webView = WKWebView(frame: .zero)
        inspector.attach(to: webView)
        let entry = makeEntry()
        inspector.selectEntry(entry)

        let viewController = WINetworkDetailViewController(inspector: inspector)
        viewController.loadViewIfNeeded()
        viewController.view.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        viewController.view.layoutIfNeeded()

        let collectionView = try #require(
            viewController.view.subviews.compactMap { $0 as? UICollectionView }.first
        )

        let initialSnapshotApplied = await waitUntil {
            collectionView.numberOfSections == 3
        }
        #expect(initialSnapshotApplied)
        #expect(viewController.navigationItem.additionalOverflowItems == nil)
        #expect(listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) != nil)
        #expect(
            listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) != "content-type"
        )

        entry.responseHeaders = NetworkHeaders([
            NetworkHeaderField(name: "content-type", value: "application/json")
        ])

        let headersUpdated = await waitUntil {
            self.listCellText(in: collectionView, at: IndexPath(item: 0, section: 2)) == "content-type"
        }
        #expect(headersUpdated)

        entry.responseBody = makeBody(reference: "resp_ref")

        let bodySectionAdded = await waitUntil {
            collectionView.numberOfSections == 4 && fetcher.fetchCount == 1
        }
        #expect(bodySectionAdded)
        #expect(entry.responseBody?.full == "response body")
    }

    @Test
    func previewViewUpdatesWhenModelFetchRunsAfterInspectorAttaches() async {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "reattached preview body",
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
        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref")
        entry.responseBody = body
        inspector.selectEntry(entry)

        let viewController = WINetworkBodyPreviewViewController(
            entry: entry,
            inspector: inspector,
            bodyState: body
        )
        viewController.loadViewIfNeeded()

        for _ in 0..<64 {
            await Task.yield()
        }

        #expect(fetcher.fetchCount == 0)

        let webView = WKWebView(frame: .zero)
        inspector.attach(to: webView)

        let fetched = await waitUntil {
            fetcher.fetchCount == 1 && body.full == "reattached preview body"
        }
        #expect(fetched)
        #expect(viewController.navigationItem.additionalOverflowItems == nil)
    }

    @Test
    func previewViewDoesNotFetchOnLoadWithoutModelSelection() async {
        let fetcher = StubNetworkBodyFetcher { ref, _, role in
            NetworkBody(
                kind: .text,
                preview: nil,
                full: "preview body",
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
        let webView = WKWebView(frame: .zero)
        inspector.attach(to: webView)
        let entry = makeEntry()
        let body = makeBody(reference: "resp_ref")
        entry.responseBody = body

        let viewController = WINetworkBodyPreviewViewController(
            entry: entry,
            inspector: inspector,
            bodyState: body
        )
        viewController.loadViewIfNeeded()

        for _ in 0..<64 {
            await Task.yield()
        }

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
            reference: reference,
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

    func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBodyFetchResult {
        fetchCount += 1
        return await onFetch(ref, handle, role)
    }
}
#endif
