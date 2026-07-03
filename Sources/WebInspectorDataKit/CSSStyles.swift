import Foundation
import Observation
import WebInspectorProxyKit

@Observable
public final class CSSStyles: WebInspectorPersistentModel {
    public struct ID: Hashable, Sendable {
        let nodeID: DOMNode.ID

        init(nodeID: DOMNode.ID) {
            self.nodeID = nodeID
        }
    }

    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case needsRefresh
        case unavailable
        case failed(WebInspectorProxyError)
    }

    public let id: ID
    public private(set) var phase: Phase
    public private(set) var sections: [CSS.Rule]
    public private(set) var computedProperties: [CSS.ComputedProperty]

    @ObservationIgnored weak var modelContext: WebInspectorContext?

    init(nodeID: DOMNode.ID, modelContext: WebInspectorContext) {
        id = ID(nodeID: nodeID)
        phase = .loading
        sections = []
        computedProperties = []
        self.modelContext = modelContext
    }

    func markLoading() {
        phase = .loading
    }

    func load(matchedStyles: CSS.MatchedStyles, computedProperties: [CSS.ComputedProperty]) {
        sections = matchedStyles.matchedRules
        self.computedProperties = computedProperties
        phase = .loaded
    }

    func markNeedsRefresh() {
        phase = .needsRefresh
    }

    func markUnavailable() {
        sections = []
        computedProperties = []
        phase = .unavailable
    }

    func fail(_ error: WebInspectorProxyError) {
        sections = []
        computedProperties = []
        phase = .failed(error)
    }
}
