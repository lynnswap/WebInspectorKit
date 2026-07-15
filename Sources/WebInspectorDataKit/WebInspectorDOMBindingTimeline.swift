import Foundation
import Synchronization
import WebInspectorProxyKit

private struct WebInspectorDOMBindingTimelineRouteKey: Hashable, Sendable {
    let attachmentGeneration: WebInspectorAttachmentGeneration
    let pageGeneration: WebInspectorPageGeneration
    let semanticTargetID: WebInspectorTarget.ID
    let agentTargetID: WebInspectorTarget.ID
}

/// One DOM binding activated after a connection FIFO boundary.
package struct WebInspectorDOMBindingTimelineEntry: Equatable, Sendable {
    package let attachmentGeneration: WebInspectorAttachmentGeneration
    package let boundary: UInt64
    package let scope: WebInspectorCanonicalDOMEventScope

    package func owns(
        sequence: UInt64,
        attachmentGeneration: WebInspectorAttachmentGeneration
    ) -> Bool {
        self.attachmentGeneration == attachmentGeneration
            && sequence > boundary
    }
}

/// Store-owned issuer and sequence lookup for DOM identities shared with
/// Network initiator grouping.
package struct WebInspectorDOMBindingTimeline: Equatable, Sendable {
    private var lastScopeID: UInt64 = 0
    private var entries: [WebInspectorDOMBindingTimelineEntry] = []
    private var processedThroughByRoute: [
        WebInspectorDOMBindingTimelineRouteKey: UInt64
    ] = [:]

    package init() {}

    package mutating func issue(
        after boundary: UInt64,
        route: WebInspectorFeatureEventScope,
        attachmentGeneration: WebInspectorAttachmentGeneration
    ) throws -> WebInspectorCanonicalDOMEventScope {
        let (next, overflow) = lastScopeID.addingReportingOverflow(1)
        guard !overflow else {
            throw WebInspectorFeatureError.bootstrap(
                WebInspectorFailureDescription(
                    code: "dom.binding.exhausted",
                    phase: "bootstrap",
                    message: "DOM binding identity space was exhausted."
                )
            )
        }
        let scope = WebInspectorCanonicalDOMEventScope(
            modelScope: route,
            bindingScopeID: WebInspectorDOMBindingScopeID(rawValue: next)
        )
        lastScopeID = next
        entries.removeAll {
            $0.attachmentGeneration != attachmentGeneration
                || $0.scope.modelScope.generation != route.generation
                || $0.scope.semanticTargetID == route.semanticTargetID
                    && $0.scope.agentTargetID == route.agentTargetID
                    && $0.boundary >= boundary
        }
        processedThroughByRoute = processedThroughByRoute.filter {
            $0.key.attachmentGeneration == attachmentGeneration
                && $0.key.pageGeneration == route.generation
        }
        entries.append(
            WebInspectorDOMBindingTimelineEntry(
                attachmentGeneration: attachmentGeneration,
                boundary: boundary,
                scope: scope
            )
        )
        entries.sort { $0.boundary < $1.boundary }
        let key = routeKey(
            attachmentGeneration: attachmentGeneration,
            generation: route.generation,
            semanticTargetID: route.semanticTargetID,
            agentTargetID: route.agentTargetID
        )
        processedThroughByRoute[key] = max(
            processedThroughByRoute[key] ?? 0,
            boundary
        )
        return scope
    }

    package mutating func markProcessed(
        through boundary: UInt64,
        route: WebInspectorFeatureEventScope,
        attachmentGeneration: WebInspectorAttachmentGeneration
    ) {
        let key = routeKey(
            attachmentGeneration: attachmentGeneration,
            generation: route.generation,
            semanticTargetID: route.semanticTargetID,
            agentTargetID: route.agentTargetID
        )
        processedThroughByRoute[key] = max(
            processedThroughByRoute[key] ?? 0,
            boundary
        )
    }

    package func hasProcessed(
        through requiredBoundary: UInt64?,
        attachmentGeneration: WebInspectorAttachmentGeneration,
        generation: WebInspectorPageGeneration,
        semanticTargetID: WebInspectorTarget.ID,
        agentTargetID: WebInspectorTarget.ID
    ) -> Bool {
        let key = routeKey(
            attachmentGeneration: attachmentGeneration,
            generation: generation,
            semanticTargetID: semanticTargetID,
            agentTargetID: agentTargetID
        )
        guard let processedThrough = processedThroughByRoute[key] else {
            return false
        }
        return requiredBoundary.map { processedThrough >= $0 } ?? true
    }

    package func scope(
        at sequence: UInt64,
        attachmentGeneration: WebInspectorAttachmentGeneration,
        generation: WebInspectorPageGeneration,
        semanticTargetID: WebInspectorTarget.ID,
        agentTargetID: WebInspectorTarget.ID
    ) -> WebInspectorCanonicalDOMEventScope? {
        entries.last {
            $0.owns(
                sequence: sequence,
                attachmentGeneration: attachmentGeneration
            )
                && $0.scope.modelScope.generation == generation
                && $0.scope.semanticTargetID == semanticTargetID
                && $0.scope.agentTargetID == agentTargetID
        }?.scope
    }

    private func routeKey(
        attachmentGeneration: WebInspectorAttachmentGeneration,
        generation: WebInspectorPageGeneration,
        semanticTargetID: WebInspectorTarget.ID,
        agentTargetID: WebInspectorTarget.ID
    ) -> WebInspectorDOMBindingTimelineRouteKey {
        WebInspectorDOMBindingTimelineRouteKey(
            attachmentGeneration: attachmentGeneration,
            pageGeneration: generation,
            semanticTargetID: semanticTargetID,
            agentTargetID: agentTargetID
        )
    }
}

/// Cancellation-safe change notification for readers waiting on the
/// store-owned timeline. It owns no binding identity or processed watermark.
package final class WebInspectorDOMBindingBarrier: Sendable {
    package struct Observation: Sendable {
        package let version: UInt64
        package let isUnavailable: Bool
    }

    private struct Waiter: Sendable {
        let version: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State: Sendable {
        var version: UInt64 = 0
        var unavailableAttachments: Set<WebInspectorAttachmentGeneration> = []
        var waiters: [UInt64: Waiter] = [:]
        var registeringWaiterIDs: Set<UInt64> = []
        var nextWaiterID: UInt64 = 0
    }

    private enum RegistrationAction {
        case wait
        case changed
        case cancelled
    }

    private let state = Mutex(State())

    package init() {}

    package func observation(
        for attachmentGeneration: WebInspectorAttachmentGeneration
    ) -> Observation {
        state.withLock {
            Observation(
                version: $0.version,
                isUnavailable: $0.unavailableAttachments.contains(
                    attachmentGeneration
                )
            )
        }
    }

    package func signalTimelineChange() {
        signal { _ in }
    }

    package func markUnavailable(
        _ attachmentGeneration: WebInspectorAttachmentGeneration
    ) {
        let inserted = state.withLock {
            $0.unavailableAttachments.insert(attachmentGeneration).inserted
        }
        if inserted { signal { _ in } }
    }

    package func waitForChange(after version: UInt64) async throws {
        try Task.checkCancellation()
        let waiterID = state.withLock { state -> UInt64 in
            let (next, overflow) = state.nextWaiterID.addingReportingOverflow(1)
            precondition(!overflow, "DOM binding barrier exhausted its waiter identity space.")
            state.nextWaiterID = next
            state.registeringWaiterIDs.insert(next)
            return next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action = state.withLock { state -> RegistrationAction in
                    guard state.registeringWaiterIDs.remove(waiterID) != nil else {
                        return .cancelled
                    }
                    guard state.version == version else { return .changed }
                    state.waiters[waiterID] = Waiter(
                        version: version,
                        continuation: continuation
                    )
                    return .wait
                }
                switch action {
                case .wait:
                    break
                case .changed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                state.registeringWaiterIDs.remove(waiterID)
                return state.waiters.removeValue(forKey: waiterID)?.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func signal(_ update: (inout State) -> Void) {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            update(&state)
            let (next, overflow) = state.version.addingReportingOverflow(1)
            precondition(!overflow, "DOM binding barrier exhausted its version space.")
            state.version = next
            let continuations = state.waiters.values.map(\.continuation)
            state.waiters.removeAll(keepingCapacity: true)
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }
}

package let webInspectorDOMBindingTimelineKey =
    WebInspectorModelStoreMetadataKey<WebInspectorDOMBindingTimeline>()
