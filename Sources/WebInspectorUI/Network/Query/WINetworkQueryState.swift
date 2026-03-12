import Foundation
import Observation
import ObservationBridge
import WebInspectorCore
import WebInspectorCore
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
public final class WINetworkQueryState {
    public let inspector: WINetworkInspectorStore
    public var searchText: String = ""
    public var activeFilters: Set<NetworkResourceFilter> = [] {
        didSet {
            let normalized = NetworkResourceFilter.normalizedSelection(activeFilters)
            if effectiveFilters != normalized {
                effectiveFilters = normalized
            }
        }
    }
    public private(set) var effectiveFilters: Set<NetworkResourceFilter> = []
    public var sortDescriptors: [SortDescriptor<NetworkEntry>] = [
        SortDescriptor<NetworkEntry>(\.createdAt, order: .reverse),
        SortDescriptor<NetworkEntry>(\.requestID, order: .reverse)
    ]

    @ObservationIgnored private var storeObservationHandles: Set<ObservationHandle> = []
    private(set) var displayEntriesRevision: UInt64 = 0

#if canImport(UIKit)
    @ObservationIgnored private lazy var searchCoordinator = WINetworkSearchControllerCoordinator(queryModel: self)
    @ObservationIgnored private lazy var filterMenuCoordinator = WINetworkFilterMenuCoordinator(queryModel: self)
#endif

    public var displayEntries: [NetworkEntry] {
        _ = displayEntriesRevision
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredEntries = inspector.store.entries.filter { entry in
            if !effectiveFilters.isEmpty,
               effectiveFilters.contains(entry.resourceFilter) == false {
                return false
            }
            if trimmedQuery.isEmpty {
                return true
            }
            return entry.matchesSearchText(trimmedQuery)
        }
        return filteredEntries.sorted(using: sortDescriptors)
    }

    public init(inspector: WINetworkInspectorStore) {
        self.inspector = inspector
        startObservingStore()
    }

    public func setSearchText(_ text: String) {
        guard searchText != text else {
            return
        }
        searchText = text
    }

    public func setFilter(_ filter: NetworkResourceFilter, enabled: Bool) {
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

    public func toggleFilter(_ filter: NetworkResourceFilter) {
        if filter == .all {
            clearFilters()
            return
        }
        let nextEnabled = !activeFilters.contains(filter)
        setFilter(filter, enabled: nextEnabled)
    }

    public func clearFilters() {
        guard !activeFilters.isEmpty else {
            return
        }
        activeFilters = []
    }

#if canImport(UIKit)
    public var searchController: UISearchController {
        searchCoordinator.searchController
    }

    public var filterBarButtonItem: UIBarButtonItem {
        filterMenuCoordinator.item
    }

    public func syncSearchControllerText() {
        searchCoordinator.syncTextFromQueryModel()
    }
#endif
}

private extension WINetworkQueryState {
    func startObservingStore() {
        inspector.store.observe(
            \.entries,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.invalidateDisplayEntries()
        }
        .store(in: &storeObservationHandles)
    }

    func invalidateDisplayEntries() {
        displayEntriesRevision &+= 1
        if displayEntriesRevision == 0 {
            displayEntriesRevision = 1
        }
    }
}

private extension NetworkEntry {
    func matchesSearchText(_ query: String) -> Bool {
        if query.isEmpty {
            return true
        }
        let statusCodeLabel = statusCode.map(String.init) ?? ""
        let candidates = [
            url,
            method,
            statusCodeLabel,
            statusText,
            fileTypeLabel
        ]
        return candidates.contains { $0.localizedStandardContains(query) }
    }
}
