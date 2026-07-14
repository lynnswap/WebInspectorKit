import WebInspectorProxyKit

/// One DOM binding activated after a connection FIFO boundary.
package struct WebInspectorDOMBindingTimelineEntry: Equatable, Sendable {
    package let boundary: UInt64
    package let scope: WebInspectorCanonicalDOMEventScope

    package func owns(sequence: UInt64) -> Bool {
        sequence > boundary
    }
}

/// Store-owned issuer and sequence lookup for DOM identities shared with
/// Network initiator grouping.
package struct WebInspectorDOMBindingTimeline: Equatable, Sendable {
    private var lastScopeID: UInt64 = 0
    private var entries: [WebInspectorDOMBindingTimelineEntry] = []

    package init() {}

    package mutating func issue(
        after boundary: UInt64,
        route: WebInspectorFeatureEventScope
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
            $0.scope.modelScope.generation != route.generation
                || $0.scope.semanticTargetID == route.semanticTargetID
                    && $0.scope.agentTargetID == route.agentTargetID
                    && $0.boundary >= boundary
        }
        entries.append(
            WebInspectorDOMBindingTimelineEntry(
                boundary: boundary,
                scope: scope
            )
        )
        entries.sort { $0.boundary < $1.boundary }
        return scope
    }

    package func scope(
        at sequence: UInt64,
        generation: WebInspectorPageGeneration,
        semanticTargetID: WebInspectorTarget.ID,
        agentTargetID: WebInspectorTarget.ID
    ) -> WebInspectorCanonicalDOMEventScope? {
        entries.last {
            $0.owns(sequence: sequence)
                && $0.scope.modelScope.generation == generation
                && $0.scope.semanticTargetID == semanticTargetID
                && $0.scope.agentTargetID == agentTargetID
        }?.scope
    }
}

package let webInspectorDOMBindingTimelineKey =
    WebInspectorModelStoreMetadataKey<WebInspectorDOMBindingTimeline>()
