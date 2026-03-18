import Foundation
import WebInspectorEngine

@MainActor
package final class NetworkTimelineResolver {
    package struct Binding {
        package let allowsCrossTargetRebind: Bool
        package let canonicalRequestID: Int
        package var sessionID: String
        package var requestTargetIdentifier: String?
        package var responseTargetIdentifier: String?
        package let rawRequestID: String
        package let url: String
        package let requestType: String?

        package init(
            allowsCrossTargetRebind: Bool,
            canonicalRequestID: Int,
            sessionID: String,
            requestTargetIdentifier: String?,
            responseTargetIdentifier: String?,
            rawRequestID: String,
            url: String,
            requestType: String?
        ) {
            self.allowsCrossTargetRebind = allowsCrossTargetRebind
            self.canonicalRequestID = canonicalRequestID
            self.sessionID = sessionID
            self.requestTargetIdentifier = requestTargetIdentifier
            self.responseTargetIdentifier = responseTargetIdentifier
            self.rawRequestID = rawRequestID
            self.url = url
            self.requestType = requestType
        }
    }

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
    private var bufferedEnvelopes: [WITransportEventEnvelope] = []
    private var exactBindings: [RequestKey: Binding] = [:]
    private var committedTargetPredecessors: [String: String] = [:]
    private var committedTargetIdentifiers: Set<String> = []
    private var nextCanonicalRequestID = 1

    package var buffersPendingEnvelopes: Bool {
        phase == .buffering
    }

    package init() {}

    package func begin(contextID: UUID) {
        self.contextID = contextID
        phase = .buffering
        bufferedEnvelopes.removeAll(keepingCapacity: true)
        exactBindings.removeAll(keepingCapacity: true)
        committedTargetPredecessors.removeAll(keepingCapacity: true)
        committedTargetIdentifiers.removeAll(keepingCapacity: true)
    }

    package func matches(contextID: UUID) -> Bool {
        self.contextID == contextID
    }

    package func allocateCanonicalRequestID() -> Int {
        defer { nextCanonicalRequestID += 1 }
        return nextCanonicalRequestID
    }

    package func buffer(_ envelope: WITransportEventEnvelope) {
        guard phase == .buffering else {
            return
        }
        bufferedEnvelopes.append(envelope)
    }

    package func applyBootstrapLoad(
        _ load: NetworkBootstrapLoad,
        into store: NetworkStore
    ) {
        let insertedEntries = store.applySnapshots(load.snapshots)
        let survivingRequestIDs = Set(insertedEntries.map(\.requestID))
        register(
            bindings: load.bindings.filter { survivingRequestIDs.contains($0.canonicalRequestID) }
        )
    }

    package func finish(
        replay: (WITransportEventEnvelope) -> Void
    ) {
        guard phase != .idle else {
            return
        }

        phase = .replaying
        let bufferedEnvelopes = bufferedEnvelopes
        self.bufferedEnvelopes.removeAll(keepingCapacity: true)
        for envelope in bufferedEnvelopes {
            replay(envelope)
        }
        phase = .settled
    }

    package func reset() {
        contextID = nil
        phase = .idle
        bufferedEnvelopes.removeAll(keepingCapacity: true)
        exactBindings.removeAll(keepingCapacity: true)
        committedTargetPredecessors.removeAll(keepingCapacity: true)
        committedTargetIdentifiers.removeAll(keepingCapacity: true)
        nextCanonicalRequestID = 1
    }

    package func recordCommittedTargetTransition(
        from oldTargetIdentifier: String?,
        to newTargetIdentifier: String
    ) {
        committedTargetIdentifiers.insert(newTargetIdentifier)
        guard let oldTargetIdentifier,
              oldTargetIdentifier != newTargetIdentifier else {
            committedTargetPredecessors.removeValue(forKey: newTargetIdentifier)
            return
        }
        committedTargetIdentifiers.insert(oldTargetIdentifier)
        committedTargetPredecessors[newTargetIdentifier] = oldTargetIdentifier
    }

    package func recordCommittedTargetDestroyed(identifier: String) {
        let predecessor = committedTargetPredecessors.removeValue(forKey: identifier)
        committedTargetIdentifiers.remove(identifier)

        let descendants = committedTargetPredecessors
            .filter { $0.value == identifier }
            .map(\.key)

        for descendant in descendants {
            if let predecessor, predecessor != descendant {
                committedTargetPredecessors[descendant] = predecessor
            } else {
                committedTargetPredecessors.removeValue(forKey: descendant)
            }
        }
    }

    package func clearCommittedTargetTransitions() {
        committedTargetPredecessors.removeAll(keepingCapacity: true)
        committedTargetIdentifiers.removeAll(keepingCapacity: true)
    }

    package func hasPendingUncommittedTargetCandidate(
        sessionID: String,
        rawRequestID: String,
        url: String?,
        requestType: String?,
        targetIdentifier: String?,
        allowLiveBindings: Bool
    ) -> Bool {
        guard let targetIdentifier,
              committedTargetPredecessors[targetIdentifier] == nil,
              !committedTargetIdentifiers.contains(targetIdentifier) else {
            return false
        }
        guard exactBindings[RequestKey(sessionID: sessionID, rawRequestID: rawRequestID)] == nil else {
            return false
        }

        let candidates = matchingBindings(
            rawRequestID: rawRequestID,
            url: url,
            requestType: requestType,
            allowLiveBindings: allowLiveBindings
        ).filter { binding in
            binding.requestTargetIdentifier != targetIdentifier
                && binding.responseTargetIdentifier != targetIdentifier
        }

        return candidates.count == 1
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
        if let rebound = rebindCommittedContinuation(
            sessionID: sessionID,
            rawRequestID: rawRequestID,
            url: url,
            requestType: requestType,
            targetIdentifier: targetIdentifier,
            store: store,
            allowLiveBindings: false
        ) {
            return rebound.canonicalRequestID
        }

        let canonicalRequestID = allocateCanonicalRequestID()
        exactBindings[key] = Binding(
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
        return rebindCommittedContinuation(
            sessionID: sessionID,
            rawRequestID: rawRequestID,
            url: url,
            requestType: requestType,
            targetIdentifier: targetIdentifier,
            store: store,
            allowLiveBindings: true
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
    func register(bindings: [Binding]) {
        for binding in bindings {
            exactBindings[RequestKey(sessionID: binding.sessionID, rawRequestID: binding.rawRequestID)] = binding
        }
    }

    func rebindCommittedContinuation(
        sessionID: String,
        rawRequestID: String,
        url: String,
        requestType: String?,
        targetIdentifier: String?,
        store: NetworkStore,
        allowLiveBindings: Bool
    ) -> Binding? {
        rebindCommittedContinuation(
            sessionID: sessionID,
            rawRequestID: rawRequestID,
            url: url as String?,
            requestType: requestType,
            targetIdentifier: targetIdentifier,
            store: store,
            allowLiveBindings: allowLiveBindings
        )
    }

    func rebindCommittedContinuation(
        sessionID: String,
        rawRequestID: String,
        url: String?,
        requestType: String?,
        targetIdentifier: String?,
        store: NetworkStore,
        allowLiveBindings: Bool
    ) -> Binding? {
        let candidates = matchingBindings(
            rawRequestID: rawRequestID,
            url: url,
            requestType: requestType,
            allowLiveBindings: allowLiveBindings
        ).filter { binding in
            allowsCommittedTargetRebind(
                from: binding,
                to: targetIdentifier
            )
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

    func matchingBindings(
        rawRequestID: String,
        url: String?,
        requestType: String?,
        allowLiveBindings: Bool
    ) -> [Binding] {
        exactBindings.values.filter { binding in
            guard binding.rawRequestID == rawRequestID,
                  (allowLiveBindings || binding.allowsCrossTargetRebind) else {
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
    }

    func allowsCommittedTargetRebind(
        from binding: Binding,
        to targetIdentifier: String?
    ) -> Bool {
        guard let targetIdentifier else {
            return false
        }

        return isCommittedDescendant(targetIdentifier, of: binding.requestTargetIdentifier)
            || isCommittedDescendant(targetIdentifier, of: binding.responseTargetIdentifier)
    }

    func isCommittedDescendant(
        _ targetIdentifier: String,
        of ancestorIdentifier: String?
    ) -> Bool {
        guard let ancestorIdentifier else {
            return false
        }
        guard ancestorIdentifier != targetIdentifier else {
            return true
        }

        var currentIdentifier = targetIdentifier
        while let predecessor = committedTargetPredecessors[currentIdentifier] {
            if predecessor == ancestorIdentifier {
                return true
            }
            currentIdentifier = predecessor
        }
        return false
    }

    func syncTargetsIfNeeded(
        binding: inout Binding,
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
