#if canImport(AppKit)
import Testing
import AppKit
@testable import WebInspectorEngine
@testable import WebInspectorUI

@MainActor
struct WIDOMDetailViewControllerAppKitTests {
    @Test
    func detailViewRefreshesWhenSelectionSnapshotChanges() async {
        let inspector = WIDOMPreviewFixtures.makeInspector(mode: .selected)
        let viewController = WIDOMDetailViewController(inspector: inspector)
        let window = makeWindow(contentViewController: viewController)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }

        viewController.loadViewIfNeeded()
        let initialRefreshCount = viewController.testRenderRefreshCount

        inspector.session.graphStore.applySelectionSnapshot(
            .init(
                nodeID: 6,
                preview: "<span data-state=\"3\">Latest 3</span>",
                attributes: [
                    DOMAttribute(nodeId: 6, name: "aria-label", value: "スノーボード"),
                    DOMAttribute(nodeId: 6, name: "class", value: "hero-label"),
                    DOMAttribute(nodeId: 6, name: "data-state", value: "3")
                ],
                path: ["html", "body", "div", "span"],
                selectorPath: "#hplogo > span.state-3",
                styleRevision: 3
            )
        )

        let updated = await waitUntilAppKit {
            viewController.testRenderRefreshCount > initialRefreshCount
        }
        #expect(updated)
    }
}

@MainActor
private func makeWindow(contentViewController: NSViewController) -> NSWindow {
    let window = NSWindow(contentViewController: contentViewController)
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private func waitUntilAppKit(
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

#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorEngine
@testable import WebInspectorUI

@MainActor
struct WIDOMDetailViewControllerTests {
    @Test
    func detailViewAppliesLatestSelectionSnapshotAfterRapidDOMBursts() async {
        let inspector = WIDOMPreviewFixtures.makeInspector(mode: .selected)
        let viewController = WIDOMDetailViewController(inspector: inspector)
        let host = UINavigationController(rootViewController: viewController)
        let window = makeWindow(rootViewController: host)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let initial = await waitUntil {
            listCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) == "#hplogo > span"
        }
        #expect(initial)

        let graphStore = inspector.session.graphStore
        for revision in 1...3 {
            graphStore.applySelectionSnapshot(
                .init(
                    nodeID: 6,
                    preview: "<span data-state=\"\(revision)\">Latest \(revision)</span>",
                    attributes: [
                        DOMAttribute(nodeId: 6, name: "aria-label", value: "スノーボード"),
                        DOMAttribute(nodeId: 6, name: "class", value: "hero-label"),
                        DOMAttribute(nodeId: 6, name: "data-state", value: "\(revision)")
                    ],
                    path: ["html", "body", "div", "span"],
                    selectorPath: "#hplogo > span.state-\(revision)",
                    styleRevision: revision
                )
            )
        }

        let updated = await waitUntil {
            listCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) == "#hplogo > span.state-3"
        }
        #expect(updated)
        #expect(
            listCellText(
                in: viewController.collectionView,
                at: IndexPath(item: 0, section: 0)
            ) == "<span data-state=\"3\">Latest 3</span>"
        )
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
