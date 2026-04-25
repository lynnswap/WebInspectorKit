#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
final class V2_NetworkNavigationItems: NSObject, UISearchResultsUpdating {
    private let inspector: WINetworkModel
    private var observationHandles: Set<ObservationHandle> = []

    private lazy var searchController: UISearchController = {
        let searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = wiLocalized("network.search.placeholder")
        searchController.searchBar.text = inspector.searchText
        searchController.searchResultsUpdater = self
        return searchController
    }()

    private lazy var filterItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: makeFilterMenu()
        )
        item.accessibilityIdentifier = "WI.Network.FilterButton"
        item.isSelected = inspector.effectiveResourceFilters.isEmpty == false
        return item
    }()

    init(inspector: WINetworkModel) {
        self.inspector = inspector
        super.init()
        startObservingInspector()
    }

    deinit {
        observationHandles.removeAll()
    }

    func install(on navigationItem: UINavigationItem) {
        navigationItem.style = .browser
        syncSearchTextFromInspector()
        syncFilterItem()
        if navigationItem.searchController !== searchController {
            navigationItem.searchController = searchController
        }
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.trailingItemGroups = [
            UIBarButtonItemGroup(
                barButtonItems: [filterItem],
                representativeItem: nil
            )
        ]
        navigationItem.additionalOverflowItems = makeOverflowMenuElement()
    }

    func updateSearchResults(for searchController: UISearchController) {
        inspector.setSearchText(searchController.searchBar.text ?? "")
    }

    private func startObservingInspector() {
        inspector.observe([\.activeResourceFilters, \.effectiveResourceFilters]) { [weak self] in
            self?.syncFilterItem()
        }
        .store(in: &observationHandles)
    }

    private func syncSearchTextFromInspector() {
        let text = inspector.searchText
        guard searchController.searchBar.text != text else {
            return
        }
        searchController.searchBar.text = text
    }

    private func syncFilterItem() {
        filterItem.isSelected = inspector.effectiveResourceFilters.isEmpty == false
        filterItem.menu = makeFilterMenu()
    }

    private func makeFilterMenu() -> UIMenu {
        let allAction = makeAllFilterAction()
        let resourceActions = NetworkResourceFilter.pickerCases.map(makeResourceFilterAction)
        let resourceSection = UIMenu(options: [.displayInline], children: resourceActions)
        return UIMenu(children: [allAction, resourceSection])
    }

    private func makeAllFilterAction() -> UIAction {
        UIAction(
            title: NetworkResourceFilter.all.localizedTitle,
            attributes: [.keepsMenuPresented],
            state: inspector.effectiveResourceFilters.isEmpty ? .on : .off
        ) { [weak self] _ in
            self?.inspector.clearResourceFilters()
        }
    }

    private func makeResourceFilterAction(_ filter: NetworkResourceFilter) -> UIAction {
        UIAction(
            title: filter.localizedTitle,
            attributes: [.keepsMenuPresented],
            state: inspector.activeResourceFilters.contains(filter) ? .on : .off
        ) { [weak self] _ in
            self?.inspector.toggleResourceFilter(filter)
        }
    }

    private func makeOverflowMenuElement() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            completion((self?.makeOverflowMenu() ?? UIMenu()).children)
        }
    }

    private func makeOverflowMenu() -> UIMenu {
        let hasEntries = inspector.store.entries.isEmpty == false
        let clearAction = UIAction(
            title: wiLocalized("network.controls.clear"),
            image: UIImage(systemName: "trash"),
            attributes: hasEntries ? [.destructive] : [.destructive, .disabled]
        ) { [weak self] _ in
            self?.clearEntries()
        }
        return UIMenu(children: [clearAction])
    }

    private func clearEntries() {
        Task { [inspector] in
            await inspector.clear()
        }
    }
}

#if DEBUG
extension V2_NetworkNavigationItems {
    var searchControllerForTesting: UISearchController {
        searchController
    }

    var filterItemForTesting: UIBarButtonItem {
        filterItem
    }

    var filterMenuForTesting: UIMenu {
        makeFilterMenu()
    }

    var overflowMenuForTesting: UIMenu {
        makeOverflowMenu()
    }
}
#endif
#endif
