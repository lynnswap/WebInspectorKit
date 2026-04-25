#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct V2NetworkListViewControllerTests {
    @Test
    func listShowsEmptyStateWhenThereAreNoEntries() {
        let inspector = WINetworkModel(session: NetworkSession())
        let viewController = V2_NetworkListViewController(inspector: inspector)

        viewController.loadViewIfNeeded()

        #expect(viewController.collectionViewForTesting.isHidden)
        #expect(viewController.contentUnavailableConfiguration != nil)
    }

    @Test
    func listDisplaysNetworkEntries() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        inspector.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/assets/app.js", mimeType: "text/javascript")
        ])
        let viewController = V2_NetworkListViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let indexPath = IndexPath(item: 0, section: 0)
        let didRender = await waitUntil {
            collectionView.numberOfSections == 1
                && collectionView.numberOfItems(inSection: 0) == 1
                && listCellText(in: collectionView, at: indexPath) == "app.js"
        }

        #expect(didRender)
        #expect(viewController.contentUnavailableConfiguration == nil)
    }

    @Test
    func listCellTextUpdatesWhenEntryDisplayNameChanges() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entries = inspector.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/assets/app.js", mimeType: "text/javascript")
        ])
        let entry = try #require(entries.first)
        let viewController = V2_NetworkListViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let indexPath = IndexPath(item: 0, section: 0)
        let didRender = await waitUntil {
            collectionView.cellForItem(at: indexPath) is UICollectionViewListCell
        }
        #expect(didRender)

        entry.url = "https://example.com/styles/site.css"

        let didUpdate = await waitUntil {
            guard
                let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
                let content = cell.contentConfiguration as? UIListContentConfiguration
            else {
                return false
            }
            return content.text == "site.css"
        }

        #expect(didUpdate)
    }

    @Test
    func listCellAccessoriesUpdateWhenEntryMetadataChanges() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entries = inspector.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/assets/app.js", mimeType: "text/javascript")
        ])
        let entry = try #require(entries.first)
        let viewController = V2_NetworkListViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let indexPath = IndexPath(item: 0, section: 0)
        let didRender = await waitUntil {
            collectionView.cellForItem(at: indexPath) is UICollectionViewListCell
        }
        #expect(didRender)

        entry.mimeType = "image/png"
        entry.statusCode = 404
        entry.refreshFileTypeLabel()

        let didUpdate = await waitUntil {
            guard let cell = collectionView.cellForItem(at: indexPath) as? V2_NetworkObservingListCell else {
                return false
            }
            return cell.fileTypeLabelTextForTesting == "png"
                && cell.statusIndicatorColorForTesting == .systemOrange
        }

        #expect(didUpdate)
    }

    @Test
    func selectingEntryUpdatesNetworkSelection() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let entries = inspector.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/assets/app.js", mimeType: "text/javascript")
        ])
        let entry = try #require(entries.first)
        let viewController = V2_NetworkListViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let collectionView = viewController.collectionViewForTesting
        let didRender = await waitUntil {
            collectionView.numberOfSections == 1
                && collectionView.numberOfItems(inSection: 0) == 1
        }
        #expect(didRender)

        viewController.collectionView(collectionView, didSelectItemAt: IndexPath(item: 0, section: 0))

        #expect(inspector.selectedEntry === entry)
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
        mimeType: String,
        statusCode: Int = 200
    ) -> NetworkEntry.Snapshot {
        NetworkEntry.Snapshot(
            sessionID: "test-session",
            requestID: requestID,
            request: NetworkEntry.Request(
                url: url,
                method: "GET",
                headers: NetworkHeaders(),
                body: nil,
                bodyBytesSent: nil,
                type: nil,
                wallTime: nil
            ),
            response: NetworkEntry.Response(
                statusCode: statusCode,
                statusText: "OK",
                mimeType: mimeType,
                headers: NetworkHeaders(),
                body: nil,
                blockedCookies: [],
                errorDescription: nil
            ),
            transfer: NetworkEntry.Transfer(
                startTimestamp: 0,
                endTimestamp: 1,
                duration: 1,
                encodedBodyLength: 128,
                decodedBodyLength: 128,
                phase: .completed
            )
        )
    }

    private func listCellText(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> String? {
        guard
            indexPath.section < collectionView.numberOfSections,
            indexPath.item < collectionView.numberOfItems(inSection: indexPath.section),
            let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
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
#endif
