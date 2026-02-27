import Foundation
import Observation
import WebKit
import WebInspectorModel
import WebInspectorEngine

@MainActor
@Observable
public final class WINetworkModel {
    let session: NetworkSession

    public var selectedEntry: NetworkEntry?
    package var searchText: String = ""
    @ObservationIgnored var commandSink: ((WINetworkCommand) -> Void)?

    package var activeResourceFilters: Set<NetworkResourceFilter> = [] {
        didSet {
            let normalized = NetworkResourceFilter.normalizedSelection(activeResourceFilters)
            if effectiveResourceFilters != normalized {
                effectiveResourceFilters = normalized
            }
        }
    }

    package private(set) var effectiveResourceFilters: Set<NetworkResourceFilter> = []

    public var sortDescriptors: [SortDescriptor<NetworkEntry>] = [
        SortDescriptor<NetworkEntry>(\.createdAt, order: .reverse),
        SortDescriptor<NetworkEntry>(\.requestID, order: .reverse)
    ]

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
    }

    func suspend() {
        session.suspend()
    }

    func detach() {
        selectedEntry = nil
        session.detach()
    }

    public func selectEntry(id: UUID?) {
        if dispatch(.selectEntry(id: id)) {
            return
        }
        selectEntryImpl(id: id)
    }

    public func clear() {
        if dispatch(.clear) {
            return
        }
        clearImpl()
    }

    public func fetchBodyIfNeeded(
        for entry: NetworkEntry,
        body: NetworkBody,
        force: Bool = false
    ) async {
        if dispatch(.fetchBody(entry: entry, body: body, force: force)) {
            return
        }
        await fetchBodyIfNeededImpl(for: entry, body: body, force: force)
    }

    func execute(_ command: WINetworkCommand) async {
        switch command {
        case let .selectEntry(id):
            selectEntryImpl(id: id)
        case .clear:
            clearImpl()
        case let .fetchBody(entry, body, force):
            await fetchBodyIfNeededImpl(for: entry, body: body, force: force)
        }
    }

    func applyFetchedBody(_ fetched: NetworkBody, to target: NetworkBody, entry: NetworkEntry) {
        applyFetchedBodyImpl(fetched, to: target, entry: entry)
    }
}

private extension WINetworkModel {
    func dispatch(_ command: WINetworkCommand) -> Bool {
        guard let commandSink else {
            return false
        }
        commandSink(command)
        return true
    }

    func selectEntryImpl(id: UUID?) {
        guard let id else {
            selectedEntry = nil
            return
        }
        selectedEntry = store.entries.first(where: { $0.id == id })
    }

    func clearImpl() {
        selectedEntry = nil
        session.clearNetworkLogs()
    }

    func fetchBodyIfNeededImpl(
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
}

private extension WINetworkModel {
    func fetchBody(for entry: NetworkEntry, body: NetworkBody) async {
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
        applyFetchedBodyImpl(fetched, to: body, entry: entry)
    }

    func applyFetchedBodyImpl(_ fetched: NetworkBody, to target: NetworkBody, entry: NetworkEntry) {
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
