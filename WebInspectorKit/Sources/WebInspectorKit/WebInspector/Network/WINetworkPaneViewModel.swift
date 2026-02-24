import Foundation
import Observation
import WebKit
import WebInspectorKitCore

@MainActor
@Observable
public final class WINetworkPaneViewModel {
    let session: NetworkSession

    public var selectedEntry: NetworkEntry?
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

    init(session: NetworkSession) {
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
    }

    func suspend() {
        session.suspend()
    }

    func detach() {
        selectedEntry = nil
        session.detach()
    }

    public func clear() {
        selectedEntry = nil
        session.clearNetworkLogs()
    }

    public func setResourceFilter(_ filter: NetworkResourceFilter, isEnabled: Bool) {
        if filter == .all {
            if isEnabled {
                activeResourceFilters.removeAll()
            }
            return
        }

        if isEnabled {
            activeResourceFilters.insert(filter)
        } else {
            activeResourceFilters.remove(filter)
        }
    }

    public func fetchBodyIfNeeded(
        for entry: NetworkEntry,
        body: NetworkBody,
        force: Bool = false
    ) async {
        if body.fetchState == .fetching {
            return
        }
        if !body.canFetchBody {
            return
        }
        if !force && body.fetchState == .full {
            return
        }

        await fetchBody(for: entry, body: body)
    }

    private func fetchBody(for entry: NetworkEntry, body: NetworkBody) async {
        guard body.fetchState != .fetching else {
            return
        }
        let bodyRef = body.reference
        let bodyHandle = body.handle
        let hasReference = bodyRef?.isEmpty == false
        let hasHandle = bodyHandle != nil
        guard hasReference || hasHandle else {
            body.markFailed(.unavailable)
            return
        }

        body.markFetching()
        guard let fetched = await session.fetchBody(ref: bodyRef, handle: bodyHandle, role: body.role) else {
            body.markFailed(.unavailable)
            return
        }
        applyFetchedBody(fetched, to: body, entry: entry)
    }

    func applyFetchedBody(_ fetched: NetworkBody, to target: NetworkBody, entry: NetworkEntry) {
        if let fullText = fetched.full ?? fetched.preview, !fullText.isEmpty {
            target.applyFullBody(
                fullText,
                isBase64Encoded: fetched.isBase64Encoded,
                isTruncated: fetched.isTruncated,
                size: fetched.size ?? fullText.count
            )
        }

        target.summary = fetched.summary ?? target.summary
        target.formEntries = fetched.formEntries
        target.kind = fetched.kind
        target.isTruncated = fetched.isTruncated
        target.isBase64Encoded = fetched.isBase64Encoded
        target.fetchState = .full
        if let size = target.size ?? target.full?.count ?? target.preview?.count {
            target.size = size
        }
        entry.applyFetchedBodySizeMetadata(from: target)
    }
}

private extension NetworkEntry {
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
