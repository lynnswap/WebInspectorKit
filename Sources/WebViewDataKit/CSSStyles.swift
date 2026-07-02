import Foundation
import Observation
import WebViewProxyKit

@MainActor
@Observable
public final class CSSStyles: Identifiable {
    public struct ID: Hashable, Sendable {
        package let nodeID: DOMNode.ID

        package init(nodeID: DOMNode.ID) {
            self.nodeID = nodeID
        }
    }

    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case needsRefresh
        case unavailable
        case failed(WebViewProxyError)
    }

    public let id: ID
    public private(set) var phase: Phase
    public private(set) var sections: [CSS.Rule]
    public private(set) var computedProperties: [CSS.ComputedProperty]

    package init(nodeID: DOMNode.ID) {
        id = ID(nodeID: nodeID)
        phase = .loading
        sections = []
        computedProperties = []
    }

    package func markLoading() {
        phase = .loading
    }

    package func load(matchedStyles: CSS.MatchedStyles, computedProperties: [CSS.ComputedProperty]) {
        sections = matchedStyles.matchedRules
        self.computedProperties = computedProperties
        phase = .loaded
    }

    package func markNeedsRefresh() {
        phase = .needsRefresh
    }

    package func markUnavailable() {
        sections = []
        computedProperties = []
        phase = .unavailable
    }

    package func fail(_ error: WebViewProxyError) {
        sections = []
        computedProperties = []
        phase = .failed(error)
    }
}
