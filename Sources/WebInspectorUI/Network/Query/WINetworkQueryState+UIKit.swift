#if canImport(UIKit)
import UIKit
import WebInspectorResources

@MainActor
final class WINetworkSearchControllerCoordinator: NSObject, UISearchResultsUpdating {
    let searchController: UISearchController
    private unowned let queryModel: WINetworkQueryState

    init(queryModel: WINetworkQueryState) {
        self.queryModel = queryModel
        let searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = wiLocalized("network.search.placeholder")
        searchController.searchBar.text = queryModel.searchText
        self.searchController = searchController
        super.init()
        searchController.searchResultsUpdater = self
    }

    func updateSearchResults(for searchController: UISearchController) {
        queryModel.setSearchText(searchController.searchBar.text ?? "")
    }

    func syncTextFromQueryModel() {
        let text = queryModel.searchText
        guard searchController.searchBar.text != text else {
            return
        }
        searchController.searchBar.text = text
    }
}
#endif
