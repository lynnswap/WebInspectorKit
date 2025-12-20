import WebKit
import SwiftUI
import Observation

@MainActor
@Observable
public final class WINetworkViewModel {
    public let session: WINetworkSession
    public var selectedEntryID: UUID?
    public var store: WINetworkStore {
        session.store
    }
    public var searchText: String = ""
    public var activeResourceFilters: Set<WINetworkResourceFilter> = [] {
        didSet {
            let normalized = WINetworkResourceFilter.normalizedSelection(activeResourceFilters)
            if effectiveResourceFilters != normalized {
                effectiveResourceFilters = normalized
            }
        }
    }
    public private(set) var effectiveResourceFilters: Set<WINetworkResourceFilter> = []
    public var sortDescriptors: [SortDescriptor<WINetworkEntry>] = [
        SortDescriptor<WINetworkEntry>(\.createdAt, order: .reverse),
        SortDescriptor<WINetworkEntry>(\.requestID, order: .reverse)
    ]
    public var displayEntries: [WINetworkEntry] {
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

    public init(session: WINetworkSession = WINetworkSession()) {
        self.session = session
    }

    public func attach(to webView: WKWebView) {
        session.attach(pageWebView: webView)
    }

    public func setRecording(_ mode: WINetworkLoggingMode) {
        session.setRecording(mode)
    }

    public func fetchRequestBody(for entry: WINetworkEntry) async {
        guard let body = entry.requestBody else { return }
        if body.isFetching {
            return
        }
        body.markFetching()
        let error = await session.fetchBody(for: entry, role: .request)
        if let error {
            body.markFailed(error)
        }
    }

    public func fetchResponseBody(for entry: WINetworkEntry) async {
        guard let body = entry.responseBody else { return }
        if body.isFetching {
            return
        }
        body.markFetching()
        let error = await session.fetchBody(for: entry, role: .response)
        if let error {
            body.markFailed(error)
        }
    }

    public func clearNetworkLogs() {
        selectedEntryID = nil
        session.clearNetworkLogs()
    }

    public func suspend() {
        session.suspend()
    }

    public func detach() {
        session.detach()
    }
    
    public func willAppear() {
        session.willAppear()
    }
    
    public func willDisappear() {
        session.willDisappear()
    }

    public var isShowingDetail: Binding<Bool> {
        Binding(
            get: { self.selectedEntryID != nil },
            set: { newValue in
                if !newValue {
                    self.selectedEntryID = nil
                }
            }
        )
    }

    public var tableSelection: Binding<Set<WINetworkEntry.ID>> {
        Binding(
            get: {
                guard let selectedEntryID = self.selectedEntryID else {
                    return Set()
                }
                return Set([selectedEntryID])
            },
            set: { newSelection in
                self.selectedEntryID = newSelection.first
            }
        )
    }

    func bindingForAllResourceFilters() -> Binding<Bool> {
        Binding(
            get: {
                self.effectiveResourceFilters.isEmpty
            },
            set: { isOn in
                if isOn {
                    self.activeResourceFilters.removeAll()
                }
            }
        )
    }

    func bindingForResourceFilter(_ filter: WINetworkResourceFilter) -> Binding<Bool> {
        Binding(
            get: {
                self.activeResourceFilters.contains(filter)
            },
            set: { isOn in
                if isOn {
                    self.activeResourceFilters.insert(filter)
                } else {
                    self.activeResourceFilters.remove(filter)
                }
            }
        )
    }
}

private extension WINetworkEntry {
    func matchesSearchText(_ query: String) -> Bool {
        if query.isEmpty {
            return true
        }
        let candidates = [
            url,
            method,
            statusLabel,
            statusText,
            fileTypeLabel
        ]
        return candidates.contains { $0.localizedStandardContains(query) }
    }
}
