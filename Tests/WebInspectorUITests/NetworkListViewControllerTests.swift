#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import WebInspectorEngine
@_spi(PreviewSupport) @testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct NetworkListViewControllerTests {
    @Test
    func listViewAppliesLatestSnapshotAfterRapidNetworkBursts() async {
        let inspector = WINetworkModel(session: NetworkSession())
        let viewController = WINetworkListViewController(inspector: inspector)
        let host = UINavigationController(rootViewController: viewController)
        let window = makeWindow(rootViewController: host)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let visible = await waitUntil {
            viewController.collectionView.window != nil
        }
        #expect(visible)

        for requestID in 1001...1003 {
            inspector.wiApplyPreviewBatch(
                makeResourceTimingBatchPayload(
                    seq: requestID - 1000,
                    requestID: requestID
                )
            )
        }

        let updated = await waitUntil {
            viewController.collectionView.numberOfSections == 1
                && viewController.collectionView.numberOfItems(inSection: 0) == 3
        }
        #expect(updated)
        #expect(inspector.displayEntries.map(\.requestID) == [1003, 1002, 1001])
        #expect(
            listCellText(
                in: viewController.collectionView,
                at: IndexPath(item: 0, section: 0)
            ) == "1003.json"
        )
    }

    @Test
    func filterMenuReflectsEffectiveFiltersAfterObservationUpdate() async {
        let inspector = WINetworkModel(session: NetworkSession())
        let queryModel = WINetworkQueryModel(inspector: inspector)
        let coordinator = WINetworkFilterMenuCoordinator(queryModel: queryModel)

        #expect(coordinator.item.isSelected == false)

        queryModel.setFilter(.image, enabled: true)
        let selected = await waitUntil {
            coordinator.item.isSelected
        }
        #expect(selected)

        queryModel.clearFilters()
        let cleared = await waitUntil {
            coordinator.item.isSelected == false
        }
        #expect(cleared)
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

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    return condition()
}
#endif
