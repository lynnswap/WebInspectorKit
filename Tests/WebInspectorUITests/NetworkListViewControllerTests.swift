#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import WebInspectorTestSupport
@testable import WebInspectorCore
@_spi(PreviewSupport) @testable import WebInspectorCore
@testable import WebInspectorUI

@MainActor
struct NetworkListViewControllerTests {
    @Test
    func listViewAppliesLatestSnapshotAfterRapidNetworkBursts() async {
        let store = WINetworkStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(store: store)
        let viewController = WINetworkListViewController(
            store: store,
            queryModel: queryModel
        )
        let snapshotRevisions = AsyncValueQueue<UInt64>()
        viewController.onSnapshotAppliedForTesting = { revision in
            Task {
                await snapshotRevisions.push(revision)
            }
        }
        let host = UINavigationController(rootViewController: viewController)
        let window = makeWindow(rootViewController: host)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        _ = await snapshotRevisions.next()
        #expect(viewController.collectionView.window != nil)

        for requestID in 1001...1003 {
            store.wiApplyPreviewBatch(
                makeResourceTimingBatchPayload(
                    seq: requestID - 1000,
                    requestID: requestID
                )
            )
        }

        while viewController.collectionView.numberOfItems(inSection: 0) != 3 {
            _ = await snapshotRevisions.next()
        }
        #expect(queryModel.displayEntries.map(\.requestID) == [1003, 1002, 1001])
        #expect(viewController.collectionView.numberOfSections == 1)
        #expect(viewController.collectionView.numberOfItems(inSection: 0) == 3)
        #expect(
            listCellText(
                in: viewController.collectionView,
                at: IndexPath(item: 0, section: 0)
            ) == "1003.json"
        )
    }

    @Test
    func filterMenuReflectsEffectiveFiltersAfterObservationUpdate() async {
        let store = WINetworkStore(session: WINetworkRuntime())
        let queryModel = WINetworkQueryState(store: store)
        let coordinator = WINetworkFilterMenuCoordinator(queryModel: queryModel)
        let menuStateRevisions = AsyncValueQueue<UInt64>()
        coordinator.onMenuStateUpdatedForTesting = { revision in
            Task {
                await menuStateRevisions.push(revision)
            }
        }

        #expect(coordinator.item.isSelected == false)

        queryModel.setFilter(.image, enabled: true)
        _ = await menuStateRevisions.next()
        #expect(coordinator.item.isSelected)

        queryModel.clearFilters()
        _ = await menuStateRevisions.next()
        #expect(coordinator.item.isSelected == false)
    }

    private func makeResourceTimingBatchPayload(
        seq: Int,
        requestID: Int
    ) -> NSDictionary {
        let start = Double(requestID)
        let end = start + 25
        return [
            "version": 1,
            "sessionId": "ui-test-session",
            "seq": seq,
            "events": [
                [
                    "kind": "resourceTiming",
                    "requestId": requestID,
                    "url": "https://example.com/\(requestID).json",
                    "method": "GET",
                    "status": 200,
                    "statusText": "OK",
                    "mimeType": "application/json",
                    "startTime": [
                        "monotonicMs": start,
                        "wallMs": 1_700_000_000_000.0 + start
                    ],
                    "endTime": [
                        "monotonicMs": end,
                        "wallMs": 1_700_000_000_000.0 + end
                    ],
                    "encodedBodyLength": 128,
                    "decodedBodySize": 128,
                    "initiator": "fetch"
                ],
            ]
        ]
    }

    private func listCellText(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> String? {
        collectionView.layoutIfNeeded()
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
}

@MainActor
private func makeWindow(rootViewController: UIViewController) -> UIWindow {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = rootViewController
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    return window
}

#endif
