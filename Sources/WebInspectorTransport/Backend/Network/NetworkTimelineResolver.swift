import Foundation
import WebInspectorEngine

@MainActor
package final class NetworkTimelineResolver {
    package struct RequestKey: Hashable {
        package let sessionID: String
        package let rawRequestID: String
    }

    private enum Phase {
        case idle
        case buffering
        case replaying
        case settled
    }

    private var contextID: UUID?
    private var phase: Phase = .idle
    private var bufferedEvents: [NetworkPendingEvent] = []
    private var exactBindings: [RequestKey: NetworkContinuationBinding] = [:]
    private var nextCanonicalRequestID = 1

    package var buffersPendingEvents: Bool {
        phase == .buffering
    }

    package init() {}

    package func begin(contextID: UUID) {
        self.contextID = contextID
        phase = .buffering
        bufferedEvents.removeAll(keepingCapacity: true)
        exactBindings.removeAll(keepingCapacity: true)
    }

    package func matches(contextID: UUID) -> Bool {
        self.contextID == contextID
    }

    package func allocateCanonicalRequestID() -> Int {
        defer { nextCanonicalRequestID += 1 }
        return nextCanonicalRequestID
    }

    package func buffer(_ event: NetworkPendingEvent) {
        guard phase == .buffering else {
            return
        }
        bufferedEvents.append(event)
    }

    package func applyBootstrapLoad(
        _ load: NetworkBootstrapLoad,
        into store: NetworkStore
    ) {
        let insertedEntries = store.applySeeds(load.seeds)
        let survivingRequestIDs = Set(insertedEntries.map(\.requestID))
        register(
            bindings: load.bindings.filter { survivingRequestIDs.contains($0.canonicalRequestID) }
        )
    }

    package func finish(
        replay: (NetworkPendingEvent) -> Void
    ) {
        guard phase != .idle else {
            return
        }

        phase = .replaying
        let bufferedEvents = bufferedEvents
        self.bufferedEvents.removeAll(keepingCapacity: true)
        for event in bufferedEvents {
            replay(event)
        }
        phase = .settled
    }

    package func reset() {
        contextID = nil
        phase = .idle
        bufferedEvents.removeAll(keepingCapacity: true)
        exactBindings.removeAll(keepingCapacity: true)
        nextCanonicalRequestID = 1
    }

    package func resolveRequestStart(
        sessionID: String,
        rawRequestID: String,
        url: String,
        requestType: String?,
        targetIdentifier: String?,
        store: NetworkStore
    ) -> Int {
        let key = RequestKey(sessionID: sessionID, rawRequestID: rawRequestID)
        if var existing = exactBindings[key] {
            syncTargetsIfNeeded(
                binding: &existing,
                sessionID: sessionID,
                targetIdentifier: targetIdentifier,
                store: store
            )
            exactBindings[key] = existing
            return existing.canonicalRequestID
        }
        if let rebound = rebindStableContinuation(
            sessionID: sessionID,
            rawRequestID: rawRequestID,
            url: url,
            requestType: requestType,
            targetIdentifier: targetIdentifier,
            store: store
        ) {
            return rebound.canonicalRequestID
        }

        let canonicalRequestID = allocateCanonicalRequestID()
        exactBindings[key] = NetworkContinuationBinding(
            seedKind: nil,
            allowsCrossTargetRebind: false,
            canonicalRequestID: canonicalRequestID,
            sessionID: sessionID,
            requestTargetIdentifier: targetIdentifier,
            responseTargetIdentifier: targetIdentifier,
            rawRequestID: rawRequestID,
            url: url,
            requestType: requestType
        )
        return canonicalRequestID
    }

    package func resolveEvent(
        sessionID: String,
        rawRequestID: String,
        url: String?,
        requestType: String?,
        targetIdentifier: String?,
        store: NetworkStore
    ) -> Int? {
        let key = RequestKey(sessionID: sessionID, rawRequestID: rawRequestID)
        if var exact = exactBindings[key] {
            syncTargetsIfNeeded(
                binding: &exact,
                sessionID: sessionID,
                targetIdentifier: targetIdentifier,
                store: store
            )
            exactBindings[key] = exact
            return exact.canonicalRequestID
        }
        return rebindStableContinuation(
            sessionID: sessionID,
            rawRequestID: rawRequestID,
            url: url,
            requestType: requestType,
            targetIdentifier: targetIdentifier,
            store: store
        )?.canonicalRequestID
    }

    package func resolveWebSocketRequestID(
        sessionID: String,
        rawRequestID: String
    ) -> Int? {
        exactBindings[RequestKey(sessionID: sessionID, rawRequestID: rawRequestID)]?.canonicalRequestID
    }

    package func knownTargetIdentifiers(
        sessionID: String,
        rawRequestID: String
    ) -> (request: String?, response: String?)? {
        guard let binding = exactBindings[RequestKey(sessionID: sessionID, rawRequestID: rawRequestID)] else {
            return nil
        }
        return (binding.requestTargetIdentifier, binding.responseTargetIdentifier)
    }

    package func complete(
        sessionID: String,
        rawRequestID: String
    ) {
        exactBindings.removeValue(
            forKey: RequestKey(sessionID: sessionID, rawRequestID: rawRequestID)
        )
    }
}

private extension NetworkTimelineResolver {
    func register(bindings: [NetworkContinuationBinding]) {
        for binding in bindings {
            exactBindings[RequestKey(sessionID: binding.sessionID, rawRequestID: binding.rawRequestID)] = binding
        }
    }

    func rebindStableContinuation(
        sessionID: String,
        rawRequestID: String,
        url: String,
        requestType: String?,
        targetIdentifier: String?,
        store: NetworkStore
    ) -> NetworkContinuationBinding? {
        rebindStableContinuation(
            sessionID: sessionID,
            rawRequestID: rawRequestID,
            url: url as String?,
            requestType: requestType,
            targetIdentifier: targetIdentifier,
            store: store
        )
    }

    func rebindStableContinuation(
        sessionID: String,
        rawRequestID: String,
        url: String?,
        requestType: String?,
        targetIdentifier: String?,
        store: NetworkStore
    ) -> NetworkContinuationBinding? {
        let candidates = exactBindings.values.filter { binding in
            guard binding.rawRequestID == rawRequestID,
                  binding.allowsCrossTargetRebind else {
                return false
            }
            if let url, binding.url != url {
                return false
            }
            if let requestType,
               let existingRequestType = binding.requestType,
               existingRequestType != requestType {
                return false
            }
            return true
        }

        guard candidates.count == 1, var binding = candidates.first else {
            return nil
        }

        let previousKey = RequestKey(sessionID: binding.sessionID, rawRequestID: binding.rawRequestID)
        exactBindings.removeValue(forKey: previousKey)
        _ = store.moveEntrySession(
            requestID: binding.canonicalRequestID,
            from: binding.sessionID,
            to: sessionID,
            previousRequestTargetIdentifier: binding.requestTargetIdentifier,
            requestTargetIdentifier: targetIdentifier ?? binding.requestTargetIdentifier,
            previousResponseTargetIdentifier: binding.responseTargetIdentifier,
            responseTargetIdentifier: targetIdentifier ?? binding.responseTargetIdentifier
        )
        binding.sessionID = sessionID
        binding.requestTargetIdentifier = targetIdentifier ?? binding.requestTargetIdentifier
        binding.responseTargetIdentifier = targetIdentifier ?? binding.responseTargetIdentifier
        let reboundKey = RequestKey(sessionID: sessionID, rawRequestID: rawRequestID)
        exactBindings[reboundKey] = binding
        return binding
    }

    func syncTargetsIfNeeded(
        binding: inout NetworkContinuationBinding,
        sessionID: String,
        targetIdentifier: String?,
        store: NetworkStore
    ) {
        let resolvedRequestTargetIdentifier = targetIdentifier ?? binding.requestTargetIdentifier
        let resolvedResponseTargetIdentifier = targetIdentifier ?? binding.responseTargetIdentifier
        guard binding.requestTargetIdentifier != resolvedRequestTargetIdentifier
                || binding.responseTargetIdentifier != resolvedResponseTargetIdentifier else {
            return
        }

        store.updateEntrySession(
            requestID: binding.canonicalRequestID,
            from: sessionID,
            to: sessionID,
            previousRequestTargetIdentifier: binding.requestTargetIdentifier,
            requestTargetIdentifier: resolvedRequestTargetIdentifier,
            previousResponseTargetIdentifier: binding.responseTargetIdentifier,
            responseTargetIdentifier: resolvedResponseTargetIdentifier
        )
        binding.requestTargetIdentifier = resolvedRequestTargetIdentifier
        binding.responseTargetIdentifier = resolvedResponseTargetIdentifier
    }
}
