import Observation

/// Observable CSS projection for one persistent DOM node identity.
@Observable
public final class CSSStyles: WebInspectorPersistentModel {
    public struct ID: WebInspectorPersistentIdentifier {
        public typealias Model = CSSStyles

        public let nodeID: DOMNode.ID

        package init(nodeID: DOMNode.ID) {
            self.nodeID = nodeID
        }
    }

    public struct QueryValue: Identifiable, Sendable {
        public let id: ID
        public let nodeID: DOMNode.ID

        package init(id: ID, nodeID: DOMNode.ID) {
            self.id = id
            self.nodeID = nodeID
        }
    }

    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case needsRefresh
        case unavailable
        case failed(WebInspectorFeatureError)
    }

    public nonisolated let id: ID
    public let nodeID: DOMNode.ID
    public private(set) var phase: Phase
    public private(set) var sections: [CSSStyleSection]
    public private(set) var computedProperties: [CSSComputedProperty]

    package init(id: ID, record: WebInspectorCSSStylesRecord) {
        self.id = id
        nodeID = record.nodeID
        phase = record.phase
        sections = record.sections
        computedProperties = record.computedProperties
    }

    package func replace(with record: WebInspectorCSSStylesRecord) {
        phase = record.phase
        sections = record.sections
        computedProperties = record.computedProperties
    }

    package func invalidate() {
        phase = .unavailable
        sections = []
        computedProperties = []
    }
}

package struct WebInspectorCSSStylesRecord: Sendable {
    package let nodeID: DOMNode.ID
    package let phase: CSSStyles.Phase
    package let sections: [CSSStyleSection]
    package let computedProperties: [CSSComputedProperty]
    package let cascadeRevision: UInt64
}

package let webInspectorCSSStylesSchema = WebInspectorModelSchema<
    CSSStyles,
    WebInspectorCSSStylesRecord
>(
    featureID: .dom,
    makeModel: { _, id, record in
        CSSStyles(id: id, record: record)
    },
    updateModel: { _, model, record in
        model.replace(with: record)
    },
    invalidateModel: { _, model in
        model.invalidate()
    }
)

package func webInspectorCSSStylesMutation(
    id: CSSStyles.ID,
    record: WebInspectorCSSStylesRecord,
    canonicalRank: UInt64
) -> WebInspectorModelMutation<CSSStyles> {
    webInspectorCSSStylesSchema.upsert(
        record: record,
        queryValue: CSSStyles.QueryValue(id: id, nodeID: record.nodeID),
        canonicalRank: WebInspectorModelCanonicalRank(rawValue: canonicalRank)
    )
}
