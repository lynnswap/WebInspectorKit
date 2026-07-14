import Foundation
import Observation
import WebInspectorProxyKit

/// A frame identity carried by immutable DOM projections.
public struct WebInspectorFrameID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    package init(_ frameID: FrameID) {
        rawValue = frameID.rawValue
    }
}

/// A protocol-independent pseudo-element kind.
public enum DOMPseudoElementKind: Hashable, Sendable {
    case before
    case after
    case marker
    case scrollbar
    case resizer
    case selection
    case other(String)

    public var rawValue: String {
        switch self {
        case .before: "before"
        case .after: "after"
        case .marker: "marker"
        case .scrollbar: "scrollbar"
        case .resizer: "resizer"
        case .selection: "selection"
        case let .other(rawValue): rawValue
        }
    }

    package init(_ value: DOM.PseudoType) {
        switch value {
        case .before:
            self = .before
        case .after:
            self = .after
        case let .other(rawValue):
            self = switch rawValue {
            case "marker": .marker
            case "scrollbar": .scrollbar
            case "resizer": .resizer
            case "selection": .selection
            default: .other(rawValue)
            }
        }
    }
}

/// A protocol-independent shadow-root kind.
public enum DOMShadowRootKind: Hashable, Sendable {
    case open
    case closed
    case userAgent
    case other(String)

    public var rawValue: String {
        switch self {
        case .open: "open"
        case .closed: "closed"
        case .userAgent: "user-agent"
        case let .other(rawValue): rawValue
        }
    }

    package init(_ value: DOM.ShadowRootType) {
        switch value {
        case .open:
            self = .open
        case .closed:
            self = .closed
        case .userAgent:
            self = .userAgent
        case let .other(rawValue):
            self = .other(rawValue)
        }
    }
}

/// Observable model for a DOM node owned by a ``WebInspectorModelContext``.
@Observable
public final class DOMNode: WebInspectorPersistentModel {
    /// Stable identity for a DOM node within a context.
    public struct ID: WebInspectorPersistentIdentifier {
        /// The persistent model identified by this value.
        public typealias Model = DOMNode

        package let canonicalStorage: WebInspectorDOMNodeIdentityStorage

        package init(canonical storage: WebInspectorDOMNodeIdentityStorage) {
            canonicalStorage = storage
        }
    }

    /// Immutable DOM node fields available to typed fetch descriptors.
    public struct QueryValue: Identifiable, Sendable {
        /// Query-visible regular-child loading state.
        public enum Children: Equatable, Sendable {
            case unrequested(count: Int)
            case loaded([DOMNode.ID])

            public var count: Int {
                switch self {
                case let .unrequested(count):
                    count
                case let .loaded(ids):
                    ids.count
                }
            }
        }

        /// The node identity.
        public let id: ID

        /// The protocol node name.
        public let nodeName: String

        /// The local element name, if available.
        public let localName: String

        /// The node value for text-like nodes.
        public let nodeValue: String

        /// The raw numeric DOM node type.
        public let nodeType: Int

        /// The frame that owns the node, if WebKit reported one.
        public let frameID: WebInspectorFrameID?

        /// The document URL associated with the node.
        public let documentURL: String?

        /// The base URL associated with the node.
        public let baseURL: String?

        /// Attributes keyed by name.
        public let attributes: [String: String]

        /// Attributes in protocol order.
        public let attributeList: [Attribute]

        /// Parent identity in the canonical document topology.
        public let parentID: ID?

        /// Document root identity for this node.
        public let documentRootID: ID?

        /// The single root displayed by the current primary DOM tree.
        ///
        /// Unlike ``documentRootID``, this value crosses embedded document,
        /// shadow-root, and pseudo-element boundaries. Every current
        /// projection from one DOM feature generation carries the same value.
        public let primaryDocumentRootID: ID?

        /// Regular child identities or the unloaded child count.
        public let children: Children

        /// Embedded content document identity.
        public let contentDocumentID: ID?

        /// Shadow-root identities in protocol order.
        public let shadowRootIDs: [ID]

        /// Template content identity.
        public let templateContentID: ID?

        /// The `::before` pseudo-element identity.
        public let beforePseudoElementID: ID?

        /// Other pseudo-element identities in protocol order.
        public let otherPseudoElementIDs: [ID]

        /// The `::after` pseudo-element identity.
        public let afterPseudoElementID: ID?

        /// The node's pseudo-element kind.
        public let pseudoType: DOMPseudoElementKind?

        /// The node's shadow-root kind.
        public let shadowRootType: DOMShadowRootKind?

        /// The number of regular children reported by WebKit.
        public var childNodeCount: Int { children.count }

        /// The DOM node kind derived from ``nodeType``.
        public var kind: Kind {
            Kind(rawValue: nodeType)
        }

        package init(
            id: ID,
            nodeName: String,
            localName: String,
            nodeValue: String,
            nodeType: Int,
            frameID: WebInspectorFrameID?,
            documentURL: String?,
            baseURL: String?,
            attributes: [String: String],
            attributeList: [Attribute],
            parentID: ID?,
            documentRootID: ID?,
            primaryDocumentRootID: ID?,
            children: Children,
            contentDocumentID: ID?,
            shadowRootIDs: [ID],
            templateContentID: ID?,
            beforePseudoElementID: ID?,
            otherPseudoElementIDs: [ID],
            afterPseudoElementID: ID?,
            pseudoType: DOMPseudoElementKind?,
            shadowRootType: DOMShadowRootKind?
        ) {
            self.id = id
            self.nodeName = nodeName
            self.localName = localName
            self.nodeValue = nodeValue
            self.nodeType = nodeType
            self.frameID = frameID
            self.documentURL = documentURL
            self.baseURL = baseURL
            self.attributes = attributes
            self.attributeList = attributeList
            self.parentID = parentID
            self.documentRootID = documentRootID
            self.primaryDocumentRootID = primaryDocumentRootID
            self.children = children
            self.contentDocumentID = contentDocumentID
            self.shadowRootIDs = shadowRootIDs
            self.templateContentID = templateContentID
            self.beforePseudoElementID = beforePseudoElementID
            self.otherPseudoElementIDs = otherPseudoElementIDs
            self.afterPseudoElementID = afterPseudoElementID
            self.pseudoType = pseudoType
            self.shadowRootType = shadowRootType
        }
    }

    /// Numeric DOM node kind.
    public struct Kind: RawRepresentable, Hashable, Sendable {
        /// The raw DOM node type value.
        public let rawValue: Int

        /// Creates a node kind from its raw DOM node type.
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// An element node.
        public static let element = Kind(rawValue: 1)

        /// An attribute node.
        public static let attribute = Kind(rawValue: 2)

        /// A text node.
        public static let text = Kind(rawValue: 3)

        /// A CDATA section node.
        public static let cdataSection = Kind(rawValue: 4)

        /// An entity reference node.
        public static let entityReference = Kind(rawValue: 5)

        /// An entity node.
        public static let entity = Kind(rawValue: 6)

        /// A processing instruction node.
        public static let processingInstruction = Kind(rawValue: 7)

        /// A comment node.
        public static let comment = Kind(rawValue: 8)

        /// A document node.
        public static let document = Kind(rawValue: 9)

        /// A document type node.
        public static let documentType = Kind(rawValue: 10)

        /// A document fragment node.
        public static let documentFragment = Kind(rawValue: 11)

        /// A notation node.
        public static let notation = Kind(rawValue: 12)
    }

    /// A DOM element attribute.
    public struct Attribute: Hashable, Sendable {
        /// The attribute name.
        public let name: String

        /// The attribute value.
        public let value: String

        /// Creates an attribute value.
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// Text formats available for copying a DOM node.
    public enum CopyTextKind: Hashable, Sendable {
        /// Serialized outer HTML.
        case html

        /// A CSS selector path.
        case selectorPath

        /// An XPath expression.
        case xPath
    }

    /// Loading state for a node's regular children.
    public enum Children {
        /// Children have not been requested yet, but WebKit reported a count.
        case unrequested(count: Int)

        /// Children have been loaded into DataKit models.
        case loaded([DOMNode])
    }

    /// The stable node identity.
    public let id: ID

    /// The protocol node name.
    public private(set) var nodeName: String

    /// The local element name, if available.
    public private(set) var localName: String

    /// The node value for text-like nodes.
    public private(set) var nodeValue: String

    /// The raw numeric DOM node type.
    public private(set) var nodeType: Int

    /// The DOM node kind derived from ``nodeType``.
    public var kind: Kind {
        Kind(rawValue: nodeType)
    }

    /// The frame that owns the node, if WebKit reported one.
    public private(set) var frameID: WebInspectorFrameID?

    /// The document URL associated with the node.
    public private(set) var documentURL: String?

    /// The base URL associated with the node.
    public private(set) var baseURL: String?

    /// Attributes keyed by name.
    public private(set) var attributes: [String: String]

    /// Attributes in protocol order.
    public private(set) var attributeList: [Attribute]

    /// The number of regular children reported by WebKit.
    public private(set) var childNodeCount: Int

    /// The node's parent in the canonical DOM topology.
    ///
    /// Relationship access resolves only this identifier through the owning
    /// model context. Materializing a node never materializes its children.
    public var parent: DOMNode? {
        canonicalTopology?.parentID.map(requiredCanonicalModel)
    }

    /// The document root in the node's canonical document scope.
    public var documentRoot: DOMNode? {
        canonicalTopology?.documentRootID.map(requiredCanonicalModel)
    }

    /// Loading state for regular child nodes.
    public var children: Children {
        guard let canonicalTopology else {
            return .unrequested(count: childNodeCount)
        }
        switch canonicalTopology.children {
        case let .unrequested(count):
            return .unrequested(count: count)
        case let .loaded(ids):
            return .loaded(ids.map(requiredCanonicalModel))
        }
    }

    /// The content document for frame-like elements.
    public var contentDocument: DOMNode? {
        canonicalTopology?.contentDocumentID.map(requiredCanonicalModel)
    }

    /// Shadow roots attached to the node.
    public var shadowRoots: [DOMNode] {
        canonicalTopology?.shadowRootIDs.map(requiredCanonicalModel) ?? []
    }

    /// Template content associated with the node.
    public var templateContent: DOMNode? {
        canonicalTopology?.templateContentID.map(requiredCanonicalModel)
    }

    /// The `::before` pseudo element, if present.
    public var beforePseudoElement: DOMNode? {
        canonicalTopology?.beforePseudoElementID.map(requiredCanonicalModel)
    }

    /// Additional pseudo elements reported by WebKit.
    public var otherPseudoElements: [DOMNode] {
        canonicalTopology?.otherPseudoElementIDs.map(requiredCanonicalModel) ?? []
    }

    /// The `::after` pseudo element, if present.
    public var afterPseudoElement: DOMNode? {
        canonicalTopology?.afterPseudoElementID.map(requiredCanonicalModel)
    }

    /// The node's pseudo-element kind.
    public private(set) var pseudoType: DOMPseudoElementKind?

    /// The node's shadow-root kind.
    public private(set) var shadowRootType: DOMShadowRootKind?

    private var canonicalTopology: WebInspectorDOMModelTopology?

    @ObservationIgnored weak var modelContext: WebInspectorModelContext?

    var isFrameOwner: Bool {
        let name = localName.isEmpty ? nodeName : localName
        let normalizedName = name.lowercased()
        return normalizedName == "iframe" || normalizedName == "frame"
    }

    package init(
        id: ID,
        record: WebInspectorDOMModelRecord,
        modelContext: WebInspectorModelContext
    ) {
        precondition(
            id.canonicalStorage == record.canonical.id,
            "A canonical DOMNode must use its record identity."
        )
        self.id = id
        nodeName = record.canonical.nodeName
        localName = record.canonical.localName
        nodeValue = record.canonical.nodeValue
        nodeType = record.canonical.nodeType
        frameID = record.canonical.frameID.map(WebInspectorFrameID.init)
        documentURL = record.canonical.documentURL
        baseURL = record.canonical.baseURL
        attributes = record.canonical.queryValue.attributes
        attributeList = record.canonical.attributes.map(Attribute.init)
        childNodeCount = record.canonical.children.count
        canonicalTopology = record.topology
        pseudoType = record.canonical.pseudoType.map(DOMPseudoElementKind.init)
        shadowRootType = record.canonical.shadowRootType.map(DOMShadowRootKind.init)
        self.modelContext = modelContext
    }

    package func replace(
        with record: WebInspectorDOMModelRecord,
        modelContext: WebInspectorModelContext
    ) {
        precondition(
            id.canonicalStorage == record.canonical.id,
            "A DOMNode replacement must preserve canonical identity."
        )
        replaceCanonicalContent(with: record.canonical)
        canonicalTopology = record.topology
        self.modelContext = modelContext
    }

    package func applyCanonicalRecordPatch(
        _ patch: WebInspectorCanonicalDOMRecordPatch
    ) {
        applyCanonicalPatch(patch)
    }

    package func applyCanonicalTopology(
        _ topology: WebInspectorDOMModelTopology
    ) {
        canonicalTopology = topology
        childNodeCount = topology.children.count
    }

    package func resetCanonicalOwnerProjection() {
        canonicalTopology = nil
    }

    package func invalidateCanonicalRecord() {
        resetCanonicalOwnerProjection()
        modelContext = nil
    }

    package var canonicalAncestorIDsForTesting: [WebInspectorDOMNodeIdentityStorage] {
        canonicalTopology?.ancestorIDs ?? []
    }

    private func replaceCanonicalContent(
        with record: WebInspectorCanonicalDOMRecord
    ) {
        nodeName = record.nodeName
        localName = record.localName
        nodeValue = record.nodeValue
        nodeType = record.nodeType
        frameID = record.frameID.map(WebInspectorFrameID.init)
        documentURL = record.documentURL
        baseURL = record.baseURL
        attributes = record.queryValue.attributes
        attributeList = record.attributes.map(Attribute.init)
        childNodeCount = record.children.count
        pseudoType = record.pseudoType.map(DOMPseudoElementKind.init)
        shadowRootType = record.shadowRootType.map(DOMShadowRootKind.init)
    }

    private func applyCanonicalPatch(
        _ patch: WebInspectorCanonicalDOMRecordPatch
    ) {
        precondition(
            id.canonicalStorage == patch.id,
            "A DOMNode patch must preserve canonical identity."
        )
        for field in patch.fields {
            switch field {
            case let .nodeName(value):
                nodeName = value
            case let .localName(value):
                localName = value
            case let .nodeValue(value):
                nodeValue = value
            case let .nodeType(value):
                nodeType = value
            case let .frameID(value):
                frameID = value.map(WebInspectorFrameID.init)
            case let .documentURL(value):
                documentURL = value
            case let .baseURL(value):
                baseURL = value
            case let .attributes(value):
                attributes = Dictionary(
                    uniqueKeysWithValues: value.map {
                        ($0.name, $0.value)
                    }
                )
                attributeList = value.map(Attribute.init)
            case let .pseudoType(value):
                pseudoType = value.map(DOMPseudoElementKind.init)
            case let .shadowRootType(value):
                shadowRootType = value.map(DOMShadowRootKind.init)
            case .children,
                .contentDocument,
                .shadowRoots,
                .templateContent,
                .beforePseudoElement,
                .otherPseudoElements,
                .afterPseudoElement:
                break
            }
        }
    }

    private func requiredCanonicalModel(
        _ storage: WebInspectorDOMNodeIdentityStorage
    ) -> DOMNode {
        guard let modelContext,
            let model = modelContext.model(
                for: DOMNode.ID(canonical: storage)
            )
        else {
            preconditionFailure(
                "Canonical DOM topology referenced a missing current model."
            )
        }
        return model
    }

}

extension DOMNode.Attribute {
    init(_ attribute: DOM.Attribute) {
        self.init(name: attribute.name, value: attribute.value)
    }
}
