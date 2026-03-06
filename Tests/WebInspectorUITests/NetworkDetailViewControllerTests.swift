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
    func detailViewRequestsFetchForExistingResponseBodyOnDisplay() async throws {
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
        inspector.attach(to: WKWebView(frame: .zero))
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
        inspector.attach(to: WKWebView(frame: .zero))
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
    func previewViewRequestsFetchOnLoadAndDoesNotExposeFetchActions() async {
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
        inspector.attach(to: WKWebView(frame: .zero))
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

        #expect(fetcher.fetchCount == 1)
        #expect(body.full == "preview body")
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
    private let onFetch: @MainActor (String?, AnyObject?, NetworkBody.Role) async -> NetworkBody?
    private(set) var fetchCount = 0

    init(
        onFetch: @escaping @MainActor (String?, AnyObject?, NetworkBody.Role) async -> NetworkBody?
    ) {
        self.onFetch = onFetch
    }

    func fetchBody(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBody? {
        fetchCount += 1
        return await onFetch(ref, handle, role)
    }
}
#endif
