import Foundation
import Observation
import WebKit
import WebInspectorEngine

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

    package private(set) var isAttachedToPage: Bool = false

    package init(session: NetworkSession) {
        self.session = session
    }

    public var store: NetworkStore {
        session.store
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
    }

    func suspend() {
        session.suspend()
        isAttachedToPage = false
    }

    func detach() {
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
        selectedEntry = entry
    }

    public func clear() {
        selectedEntry = nil
        session.clearNetworkLogs()
    }

    package func requestBodyIfNeeded(for entry: NetworkEntry, role: NetworkBody.Role) {
        session.requestBodyIfNeeded(for: entry, role: role)
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
