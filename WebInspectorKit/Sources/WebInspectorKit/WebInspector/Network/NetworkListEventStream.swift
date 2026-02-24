import Foundation
import ObservationsCompat
import WebInspectorKitCore

@MainActor
struct NetworkListRenderModel: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let id: UUID
        let revision: Int
    }

    let entries: [Entry]
    let selectedEntryIdentity: UUID?
    let searchText: String
    let effectiveFilterRawValues: [String]
    let storeEntryCount: Int
}

@MainActor
struct NetworkDetailRenderModel: Sendable, Equatable {
    let selectedEntryIdentity: UUID?
    let selectedEntryRevision: Int?
    let storeEntryCount: Int
}

@MainActor
enum NetworkListSelectionPolicy {
    enum MissingSelectionBehavior: Sendable, Equatable {
        case none
        case firstEntry
    }

    static func resolvedSelection(
        current selectedEntry: NetworkEntry?,
        entries: [NetworkEntry],
        whenMissing missingSelectionBehavior: MissingSelectionBehavior = .firstEntry
    ) -> NetworkEntry? {
        guard !entries.isEmpty else {
            return nil
        }
        if let selectedEntry,
           let matchedEntry = entries.first(where: { $0.id == selectedEntry.id }) {
            return matchedEntry
        }
        switch missingSelectionBehavior {
        case .none:
            return nil
        case .firstEntry:
            return entries.first
        }
    }
}

@MainActor
enum NetworkListEventStream {
    static func makeListStream(
        inspector: WINetworkPaneViewModel,
        backend: ObservationsCompatBackend = .automatic
    ) -> ObservationsCompatStream<NetworkListRenderModel> {
        makeObservationsCompatStream(backend: backend) {
            let entries = inspector.displayEntries
            return NetworkListRenderModel(
                entries: entries.map {
                    NetworkListRenderModel.Entry(id: $0.id, revision: networkListRevision(for: $0))
                },
                selectedEntryIdentity: inspector.selectedEntry?.id,
                searchText: inspector.searchText,
                effectiveFilterRawValues: inspector.effectiveResourceFilters.map(\.rawValue).sorted(),
                storeEntryCount: inspector.store.entries.count
            )
        }
    }

    static func makeDetailStream(
        inspector: WINetworkPaneViewModel,
        backend: ObservationsCompatBackend = .automatic
    ) -> ObservationsCompatStream<NetworkDetailRenderModel> {
        makeObservationsCompatStream(backend: backend) {
            let selected = inspector.selectedEntry
            return NetworkDetailRenderModel(
                selectedEntryIdentity: selected?.id,
                selectedEntryRevision: selected.map(networkDetailRevision(for:)),
                storeEntryCount: inspector.store.entries.count
            )
        }
    }
}

@MainActor
private func networkListRevision(for entry: NetworkEntry) -> Int {
    var hasher = Hasher()
    hasher.combine(entry.id)
    hasher.combine(entry.displayName)
    hasher.combine(entry.method)
    hasher.combine(entry.fileTypeLabel)
    hasher.combine(entry.statusLabel)
    hasher.combine(entry.statusSeverity)
    hasher.combine(entry.phase)
    return hasher.finalize()
}

@MainActor
private func networkDetailRevision(for entry: NetworkEntry) -> Int {
    var hasher = Hasher()
    hasher.combine(entry.id)
    hasher.combine(entry.url)
    hasher.combine(entry.method)
    hasher.combine(entry.statusCode)
    hasher.combine(entry.statusText)
    hasher.combine(entry.fileTypeLabel)
    hasher.combine(entry.duration)
    hasher.combine(entry.encodedBodyLength)
    hasher.combine(entry.decodedBodyLength)
    hasher.combine(entry.errorDescription)
    hasher.combine(entry.requestHeaders)
    hasher.combine(entry.responseHeaders)
    hasher.combine(entry.phase)
    combine(body: entry.requestBody, into: &hasher)
    combine(body: entry.responseBody, into: &hasher)
    return hasher.finalize()
}

@MainActor
private func combine(body: NetworkBody?, into hasher: inout Hasher) {
    guard let body else {
        hasher.combine(0)
        return
    }
    hasher.combine(1)
    hasher.combine(body.preview)
    hasher.combine(body.full)
    hasher.combine(body.summary)
    hasher.combine(bodyFetchStateKey(body.fetchState))
    hasher.combine(body.isBase64Encoded)
}

@MainActor
private func bodyFetchStateKey(_ fetchState: NetworkBody.FetchState) -> Int {
    switch fetchState {
    case .inline:
        return 0
    case .fetching:
        return 1
    case .full:
        return 2
    case .failed(let error):
        switch error {
        case .unavailable:
            return 3
        case .decodeFailed:
            return 4
        case .unknown:
            return 5
        }
    }
}
