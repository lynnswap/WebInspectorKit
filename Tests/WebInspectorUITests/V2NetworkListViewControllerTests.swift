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
    func networkQueryIntentAPIsUpdateDisplayEntries() {
        let inspector = WINetworkModel(session: NetworkSession())
        inspector.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/index.html", mimeType: "text/html"),
            makeSnapshot(requestID: 2, url: "https://cdn.example.com/app.js", mimeType: "text/javascript"),
            makeSnapshot(requestID: 3, url: "https://cdn.example.com/image.png", mimeType: "image/png")
        ])

        inspector.setSearchText("cdn")
        inspector.setResourceFilter(.script, enabled: true)

        #expect(inspector.searchText == "cdn")
        #expect(inspector.activeResourceFilters == [.script])
        #expect(inspector.effectiveResourceFilters == [.script])
        #expect(inspector.displayEntries.map(\.requestID) == [2])

        inspector.toggleResourceFilter(.script)
        #expect(inspector.activeResourceFilters.isEmpty)
        #expect(inspector.effectiveResourceFilters.isEmpty)
        #expect(inspector.displayEntries.map(\.requestID) == [3, 2])

        inspector.clearSearchText()
        #expect(inspector.searchText.isEmpty)
        #expect(inspector.displayEntries.map(\.requestID) == [3, 2, 1])

        inspector.setResourceFilter(.image, enabled: true)
        inspector.clearResourceFilters()
        #expect(inspector.activeResourceFilters.isEmpty)
        #expect(inspector.effectiveResourceFilters.isEmpty)
    }

    @Test
    func searchControllerFiltersDisplayedEntries() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        inspector.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/assets/app.js", mimeType: "text/javascript"),
            makeSnapshot(requestID: 2, url: "https://example.com/assets/image.png", mimeType: "image/png")
        ])
        let viewController = V2_NetworkListViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        updateSearchText("image", in: viewController)

        let collectionView = viewController.collectionViewForTesting
        let didFilter = await waitUntil {
            collectionView.numberOfSections == 1
                && collectionView.numberOfItems(inSection: 0) == 1
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "image.png"
        }

        #expect(didFilter)
        #expect(inspector.searchText == "image")
    }

    @Test
    func searchControllerTextSyncsFromNetworkModelChanges() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let viewController = V2_NetworkListViewController(inspector: inspector)

        viewController.loadViewIfNeeded()
        inspector.setSearchText("external-query")

        let didSync = await waitUntil {
            viewController.searchControllerForTesting.searchBar.text == "external-query"
        }

        #expect(didSync)

        inspector.clearSearchText()

        let didClear = await waitUntil {
            viewController.searchControllerForTesting.searchBar.text == ""
        }

        #expect(didClear)
    }

    @Test
    func searchTextSurvivesMovingCachedListBetweenNavigationContainers() {
        let inspector = WINetworkModel(session: NetworkSession())
        let viewController = V2_NetworkListViewController(inspector: inspector)
        let firstNavigationController = UINavigationController(rootViewController: viewController)
        let window = showInWindow(firstNavigationController)
        defer { window.isHidden = true }

        updateSearchText("persisted-query", in: viewController)
        let firstSearchController = viewController.searchControllerForTesting

        viewController.wiDetachFromV2ContainerForReuse()

        firstSearchController.searchBar.text = ""
        viewController.updateSearchResults(for: firstSearchController)

        #expect(inspector.searchText == "persisted-query")
        #expect(viewController.navigationItem.searchController == nil)

        let secondNavigationController = UINavigationController(rootViewController: viewController)
        window.rootViewController = secondNavigationController
        secondNavigationController.view.frame = window.bounds
        secondNavigationController.view.layoutIfNeeded()

        let secondSearchController = viewController.searchControllerForTesting

        #expect(secondSearchController !== firstSearchController)
        #expect(secondSearchController.searchBar.text == "persisted-query")
        #expect(inspector.searchText == "persisted-query")
    }

    @Test
    func filterMenuStateReflectsNetworkModelFilters() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let viewController = V2_NetworkListViewController(inspector: inspector)

        viewController.loadViewIfNeeded()

        #expect(viewController.filterItemForTesting.isSelected == false)
        #expect(try filterAction(.all, in: viewController.filterMenuForTesting).state == .on)

        inspector.toggleResourceFilter(.script)
        let didSelect = await waitUntil {
            viewController.filterItemForTesting.isSelected
        }

        #expect(didSelect)
        #expect(try filterAction(.all, in: viewController.filterMenuForTesting).state == .off)
        #expect(try filterAction(.script, in: viewController.filterMenuForTesting).state == .on)

        inspector.clearResourceFilters()
        let didClear = await waitUntil {
            viewController.filterItemForTesting.isSelected == false
        }

        #expect(didClear)
        #expect(try filterAction(.all, in: viewController.filterMenuForTesting).state == .on)
    }

    @Test
    func filterMenuSupportsMultipleResourceFilters() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let viewController = V2_NetworkListViewController(inspector: inspector)

        viewController.loadViewIfNeeded()

        try filterAction(.script, in: viewController.filterMenuForTesting).performWithSender(nil, target: nil)
        try filterAction(.image, in: viewController.filterMenuForTesting).performWithSender(nil, target: nil)

        let didSelectMultipleFilters = await waitUntil {
            inspector.activeResourceFilters == [.script, .image]
                && viewController.filterItemForTesting.isSelected
        }

        #expect(didSelectMultipleFilters)
        #expect(try filterAction(.script, in: viewController.filterMenuForTesting).state == .on)
        #expect(try filterAction(.image, in: viewController.filterMenuForTesting).state == .on)
    }

    @Test
    func resourceFilterUpdatesDisplayedEntries() async throws {
        let inspector = WINetworkModel(session: NetworkSession())
        inspector.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/assets/app.js", mimeType: "text/javascript"),
            makeSnapshot(requestID: 2, url: "https://example.com/assets/image.png", mimeType: "image/png")
        ])
        let viewController = V2_NetworkListViewController(inspector: inspector)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        inspector.toggleResourceFilter(.script)

        let collectionView = viewController.collectionViewForTesting
        let didFilter = await waitUntil {
            collectionView.numberOfSections == 1
                && collectionView.numberOfItems(inSection: 0) == 1
                && listCellText(in: collectionView, at: IndexPath(item: 0, section: 0)) == "app.js"
        }

        #expect(didFilter)
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

    @Test
    func listInstallsDisabledClearOverflowMenuWhenEmpty() throws {
        let inspector = WINetworkModel(session: NetworkSession())
        let viewController = V2_NetworkListViewController(inspector: inspector)

        viewController.loadViewIfNeeded()

        let clearAction = try #require(viewController.overflowMenuForTesting.children.first as? UIAction)
        #expect(viewController.navigationItem.additionalOverflowItems != nil)
        #expect(clearAction.attributes.contains(.disabled))
    }

    @Test
    func listInstallsEnabledClearOverflowMenuWhenEntriesExist() throws {
        let inspector = WINetworkModel(session: NetworkSession())
        inspector.store.applySnapshots([
            makeSnapshot(requestID: 1, url: "https://example.com/assets/app.js", mimeType: "text/javascript")
        ])
        let viewController = V2_NetworkListViewController(inspector: inspector)

        viewController.loadViewIfNeeded()

        let clearAction = try #require(viewController.overflowMenuForTesting.children.first as? UIAction)
        #expect(viewController.navigationItem.additionalOverflowItems != nil)
        #expect(clearAction.attributes.contains(.destructive))
        #expect(clearAction.attributes.contains(.disabled) == false)
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

    private func updateSearchText(
        _ text: String,
        in viewController: V2_NetworkListViewController
    ) {
        let searchController = viewController.searchControllerForTesting
        searchController.searchBar.text = text
        searchController.searchResultsUpdater?.updateSearchResults(for: searchController)
    }

    private func filterAction(
        _ filter: NetworkResourceFilter,
        in menu: UIMenu
    ) throws -> UIAction {
        try #require(action(title: filter.localizedTitle, in: menu))
    }

    private func action(title: String, in menu: UIMenu) -> UIAction? {
        for child in menu.children {
            if let action = child as? UIAction, action.title == title {
                return action
            }
            if let childMenu = child as? UIMenu,
               let action = action(title: title, in: childMenu) {
                return action
            }
        }
        return nil
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
