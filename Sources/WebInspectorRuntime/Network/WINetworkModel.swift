import Foundation
import Observation
import ObservationBridge
import OSLog
import WebKit
import WebInspectorEngine

private let networkViewLogger = Logger(subsystem: "WebInspectorKit", category: "WINetworkModel")

@MainActor
@Observable
public final class WINetworkModel {
    private struct ObservedSelectedBodyState: Equatable {
        let requestIdentity: ObjectIdentifier?
        let requestLocator: NetworkDeferredBodyLocator?
        let responseIdentity: ObjectIdentifier?
        let responseLocator: NetworkDeferredBodyLocator?
    }

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
    @ObservationIgnored private var observedSelectedBodyState: ObservedSelectedBodyState?
    package private(set) var isAttachedToPage: Bool = false

    package init(session: NetworkSession) {
        self.session = session
        self.session.onPrepareForNavigationReconnect = { [weak self] in
            self?.cancelSelectedEntryBodyFetch()
        }
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

    func attach(to webView: WKWebView) async {
        await session.attach(pageWebView: webView)
        isAttachedToPage = true
        restartSelectedEntryBodyFetch()
    }

    func suspend() async {
        cancelSelectedEntryBodyFetch()
        await session.suspend()
        isAttachedToPage = false
    }

    func detach() async {
        cancelSelectedEntryBodyFetch()
        selectedEntryObservationHandles.removeAll()
        observedSelectedBodyState = nil
        selectedEntry = nil
        await session.detach()
        isAttachedToPage = false
    }

    func setMode(_ mode: NetworkLoggingMode) async {
        guard isAttachedToPage else {
            return
        }
        await session.setMode(mode)
    }

    public func selectEntry(_ entry: NetworkEntry?) {
        cancelSelectedEntryBodyFetch()
        selectedEntry = entry
        startObservingSelectedEntry(entry)
        restartSelectedEntryBodyFetch()
    }

    public func clear() async {
        cancelSelectedEntryBodyFetch()
        selectedEntryObservationHandles.removeAll()
        observedSelectedBodyState = nil
        selectedEntry = nil
        await session.clearNetworkLogs()
    }

    package func loadBodyIfNeeded(for entry: NetworkEntry, role: NetworkBody.Role) async throws -> NetworkBody {
        try await session.loadBodyIfNeeded(for: entry, role: role)
    }

    func tearDownForDeinit() {
        cancelSelectedEntryBodyFetch()
        selectedEntryObservationHandles.removeAll()
        observedSelectedBodyState = nil
        selectedEntry = nil
        session.tearDownForDeinit()
        isAttachedToPage = false
    }
}

private extension WINetworkModel {
    func startObservingSelectedEntry(_ entry: NetworkEntry?) {
        selectedEntryObservationHandles.removeAll()
        observedSelectedBodyState = bodyState(for: entry)
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
            let currentBodyState = self.bodyState(for: entry)
            guard self.observedSelectedBodyState != currentBodyState else {
                return
            }
            self.observedSelectedBodyState = currentBodyState
            self.restartSelectedEntryBodyFetch()
        }
        .store(in: &selectedEntryObservationHandles)
    }

    func restartSelectedEntryBodyFetch() {
        selectedEntryFetchTask?.cancel()
        selectedEntryFetchTask = nil
        guard isAttachedToPage, let selectedEntry else {
            return
        }

        selectedEntryFetchTask = Task { [weak self, selectedEntry] in
            guard let self else {
                return
            }
            do {
                try await self.preloadSelectedEntryBodies(for: selectedEntry)
            } catch is CancellationError {
                return
            } catch {
                networkViewLogger.error("body preload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelSelectedEntryBodyFetch() {
        resetFetchingBodyStateIfNeeded(for: selectedEntry?.requestBody)
        resetFetchingBodyStateIfNeeded(for: selectedEntry?.responseBody)
        selectedEntryFetchTask?.cancel()
        selectedEntryFetchTask = nil
    }

    func preloadSelectedEntryBodies(for entry: NetworkEntry) async throws {
        try await preloadBodyIfNeeded(for: entry, body: entry.responseBody)
        try Task.checkCancellation()
        try await preloadBodyIfNeeded(for: entry, body: entry.requestBody)
    }

    func preloadBodyIfNeeded(for entry: NetworkEntry, body: NetworkBody?) async throws {
        guard let body else {
            return
        }
        do {
            _ = try await session.loadBodyIfNeeded(for: entry, body: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch WINetworkBodyLoadError.agentUnavailable,
                WINetworkBodyLoadError.bodyUnavailable {
            return
        }
    }

    func resetFetchingBodyStateIfNeeded(for body: NetworkBody?) {
        guard let body else {
            return
        }
        if case .fetching = body.fetchState {
            body.fetchState = .inline
        }
    }

    private func bodyState(for entry: NetworkEntry?) -> ObservedSelectedBodyState? {
        guard let entry else {
            return nil
        }
        return ObservedSelectedBodyState(
            requestIdentity: entry.requestBody.map(ObjectIdentifier.init),
            requestLocator: entry.requestBody?.deferredLocator,
            responseIdentity: entry.responseBody.map(ObjectIdentifier.init),
            responseLocator: entry.responseBody?.deferredLocator
        )
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
