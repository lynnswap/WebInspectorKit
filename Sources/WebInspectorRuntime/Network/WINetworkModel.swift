import Foundation
import Observation
import ObservationsCompat
import WebKit
import WebInspectorModel
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

    @ObservationIgnored var commandSink: ((WINetworkCommand) -> Void)?
    @ObservationIgnored private var selectedEntryFetchTask: Task<Void, Never>?

    package init(session: NetworkSession) {
        self.session = session
    }

    isolated deinit {
        selectedEntryFetchTask?.cancel()
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

    public var canFetchSelectedBodies: Bool {
        guard let selectedEntry else {
            return false
        }
        return canFetchBodies(for: selectedEntry)
    }

    func attach(to webView: WKWebView) {
        session.attach(pageWebView: webView)
    }

    func suspend() {
        session.suspend()
    }

    func detach() {
        selectedEntryFetchTask?.cancel()
        selectedEntryFetchTask = nil
        selectedEntry = nil
        session.detach()
    }

    public func selectEntry(_ entry: NetworkEntry?) {
        selectedEntry = entry
        if entry == nil {
            selectedEntryFetchTask?.cancel()
            selectedEntryFetchTask = nil
            return
        }
        requestFetchSelectedBodies(force: false)
    }

    public func clear() {
        selectedEntryFetchTask?.cancel()
        selectedEntryFetchTask = nil
        selectedEntry = nil
        session.clearNetworkLogs()
    }

    public func requestFetchSelectedBodies(force: Bool = false) {
        selectedEntryFetchTask?.cancel()
        selectedEntryFetchTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.fetchSelectedBodiesIfNeeded(force: force)
        }
    }

    public func requestFetchBody(
        entryID: UUID,
        role: NetworkBody.Role,
        force: Bool = false
    ) {
        Task { [weak self] in
            guard let self else {
                return
            }
            await self.fetchBodyIfNeeded(entryID: entryID, role: role, force: force)
        }
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
        case let .fetchBody(entry, body, force):
            await fetchBodyIfNeededImpl(for: entry, body: body, force: force)
        }
    }

    func applyFetchedBody(_ fetched: NetworkBody, to target: NetworkBody, entry: NetworkEntry) {
        applyFetchedBodyImpl(fetched, to: target, entry: entry)
    }
}

private extension WINetworkModel {
    func fetchSelectedBodiesIfNeeded(force: Bool) async {
        guard let selectedEntry else {
            return
        }
        let selectedEntryID = selectedEntry.id

        if let requestBody = selectedEntry.requestBody {
            await fetchBodyIfNeeded(for: selectedEntry, body: requestBody, force: force)
        }

        guard self.selectedEntry?.id == selectedEntryID else {
            return
        }

        if let responseBody = selectedEntry.responseBody {
            await fetchBodyIfNeeded(for: selectedEntry, body: responseBody, force: force)
        }
    }

    func fetchBodyIfNeeded(
        entryID: UUID,
        role: NetworkBody.Role,
        force: Bool
    ) async {
        guard let entry = store.entries.first(where: { $0.id == entryID }) else {
            return
        }
        let body: NetworkBody?
        switch role {
        case .request:
            body = entry.requestBody
        case .response:
            body = entry.responseBody
        }
        guard let body else {
            return
        }
        await fetchBodyIfNeeded(for: entry, body: body, force: force)
    }

    func canFetchBodies(for entry: NetworkEntry) -> Bool {
        if let requestBody = entry.requestBody, requestBody.canFetchBody {
            return true
        }
        if let responseBody = entry.responseBody, responseBody.canFetchBody {
            return true
        }
        return false
    }

    func dispatch(_ command: WINetworkCommand) -> Bool {
        guard let commandSink else {
            return false
        }
        commandSink(command)
        return true
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
