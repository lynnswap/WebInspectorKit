import Foundation
import Observation
import ObservationBridge
import WebKit
import WebInspectorEngine
import WebInspectorTransport

@MainActor
@Observable
public final class WINetworkModel {
    let session: NetworkSession

    public private(set) weak var selectedEntry: NetworkEntry?
    public var searchText: String = ""
    public var activeResourceFilters: Set<NetworkResourceFilter> = [] {
        didSet {
            let normalized = NetworkResourceFilter.normalizedSelection(activeResourceFilters)
            if effectiveResourceFilters != normalized {
                effectiveResourceFilters = normalized
            }
        }
    }
    public private(set) var effectiveResourceFilters: Set<NetworkResourceFilter> = []
    public var sortDescriptors: [SortDescriptor<NetworkEntry>] = [
        SortDescriptor<NetworkEntry>(\.createdAt, order: .reverse),
        SortDescriptor<NetworkEntry>(\.requestID, order: .reverse)
    ]

    @ObservationIgnored private var selectedEntryFetchTask: Task<Void, Never>?
    @ObservationIgnored private var selectedEntryObservationHandles: Set<ObservationHandle> = []
    package private(set) var isAttachedToPage: Bool = false

    package init(session: NetworkSession) {
        self.session = session
    }

    isolated deinit {
        selectedEntryFetchTask?.cancel()
    }

    public var store: NetworkStore {
        session.store
    }

    public var transportSupportSnapshot: WITransportSupportSnapshot? {
        session.transportSupportSnapshot
    }

    public var displayEntries: [NetworkEntry] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredEntries = store.entries.filter { entry in
            if !effectiveResourceFilters.isEmpty,
               effectiveResourceFilters.contains(entry.resourceFilter) == false {
                return false
            }
            if trimmedQuery.isEmpty {
                return true
            }
            return entry.matchesSearchText(trimmedQuery)
        }
        return filteredEntries.sorted(using: sortDescriptors)
    }

    func attach(to webView: WKWebView) {
        session.attach(pageWebView: webView)
        isAttachedToPage = true
        scheduleSelectedEntryBodyFetch()
    }

    func suspend() {
        selectedEntryFetchTask?.cancel()
        if let selectedEntry {
            session.cancelBodyFetches(for: selectedEntry)
        }
        session.suspend()
        isAttachedToPage = false
    }

    func detach() {
        selectedEntryFetchTask?.cancel()
        if let selectedEntry {
            session.cancelBodyFetches(for: selectedEntry)
        }
        selectedEntryObservationHandles.removeAll()
        selectedEntry = nil
        session.detach()
        isAttachedToPage = false
    }

    func setMode(_ mode: NetworkLoggingMode) {
        guard isAttachedToPage else {
            return
        }
        session.setMode(mode)
    }

    public func selectEntry(_ entry: NetworkEntry?) {
        if let previousSelection = selectedEntry,
           previousSelection.id != entry?.id {
            session.cancelBodyFetches(for: previousSelection)
        }
        selectedEntry = entry
        startObservingSelectedEntry(entry)
        scheduleSelectedEntryBodyFetch()
    }

    public func clear() {
        selectedEntryFetchTask?.cancel()
        if let selectedEntry {
            session.cancelBodyFetches(for: selectedEntry)
        }
        selectedEntryObservationHandles.removeAll()
        selectedEntry = nil
        session.clearNetworkLogs()
    }

    package func requestBodyIfNeeded(for entry: NetworkEntry, role: NetworkBody.Role) {
        session.requestBodyIfNeeded(for: entry, role: role)
    }
}

private extension WINetworkModel {
    func startObservingSelectedEntry(_ entry: NetworkEntry?) {
        selectedEntryObservationHandles.removeAll()
        guard let entry else {
            return
        }

        entry.observe([\.requestBody, \.responseBody]) { [weak self, weak entry] in
            guard let self, let entry else {
                return
            }
            guard self.selectedEntry?.id == entry.id else {
                return
            }
            self.scheduleSelectedEntryBodyFetch()
        }
        .store(in: &selectedEntryObservationHandles)
    }

    func scheduleSelectedEntryBodyFetch() {
        selectedEntryFetchTask?.cancel()
        guard isAttachedToPage, let selectedEntry else {
            selectedEntryFetchTask = nil
            return
        }

        let selectedEntryID = selectedEntry.id
        selectedEntryFetchTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isAttachedToPage else {
                return
            }
            guard let selectedEntry = self.selectedEntry, selectedEntry.id == selectedEntryID else {
                return
            }

            if selectedEntry.requestBody != nil {
                self.requestBodyIfNeeded(for: selectedEntry, role: .request)
            }
            guard !Task.isCancelled else {
                return
            }
            guard self.isAttachedToPage else {
                return
            }
            guard let currentSelection = self.selectedEntry, currentSelection.id == selectedEntryID else {
                return
            }
            if currentSelection.responseBody != nil {
                self.requestBodyIfNeeded(for: currentSelection, role: .response)
            }
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
