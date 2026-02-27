import Foundation
import Observation
import WebInspectorEngine
import WebInspectorRuntime
import ObservationsCompat
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class WINetworkQueryModel {
    let inspector: WINetworkModel

#if canImport(UIKit)
    @ObservationIgnored private lazy var searchCoordinator = WINetworkSearchControllerCoordinator(queryModel: self)
    @ObservationIgnored private lazy var filterMenuCoordinator = WINetworkFilterMenuCoordinator(queryModel: self)
#endif

    var searchText: String {
        inspector.searchText
    }

    var activeFilters: Set<NetworkResourceFilter> {
        get {
            inspector.activeResourceFilters
        }
        set {
            inspector.activeResourceFilters = newValue
        }
    }

    var effectiveFilters: Set<NetworkResourceFilter> {
        inspector.effectiveResourceFilters
    }

    var displayEntries: [NetworkEntry] {
        inspector.displayEntries
    }

    init(inspector: WINetworkModel) {
        self.inspector = inspector
    }

    func setSearchText(_ text: String) {
        guard inspector.searchText != text else {
            return
        }
        inspector.searchText = text
    }

    func setFilter(_ filter: NetworkResourceFilter, enabled: Bool) {
        if filter == .all {
            if enabled {
                clearFilters()
            }
            return
        }

        var next = activeFilters
        if enabled {
            next.insert(filter)
        } else {
            next.remove(filter)
        }
        guard next != activeFilters else {
            return
        }
        activeFilters = next
    }

    func toggleFilter(_ filter: NetworkResourceFilter) {
        if filter == .all {
            clearFilters()
            return
        }
        let nextEnabled = !activeFilters.contains(filter)
        setFilter(filter, enabled: nextEnabled)
    }

    func clearFilters() {
        guard !activeFilters.isEmpty else {
            return
        }
        activeFilters = []
    }

#if canImport(UIKit)
    var searchController: UISearchController {
        searchCoordinator.searchController
    }

    var filterBarButtonItem: UIBarButtonItem {
        filterMenuCoordinator.item
    }

    func syncSearchControllerText() {
        searchCoordinator.syncTextFromQueryModel()
    }
#endif
}
