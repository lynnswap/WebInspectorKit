import Foundation
import Observation
import WebInspectorProxyKit

/// Observable model for a DOM node owned by a ``WebInspectorModelContext``.
@Observable
public final class DOMNode: WebInspectorPersistentModel {
    /// Stable identity for a DOM node within a context.
    public struct ID: WebInspectorPersistentIdentifier {
        /// The persistent model identified by this value.
        public typealias Model = DOMNode

        package enum Storage: Hashable, Sendable {
            case legacyRaw(DOM.Node.ID)
            case canonical(WebInspectorDOMNodeIdentityStorage)
        }

        package let storage: Storage

        package init(_ proxyID: DOM.Node.ID) {
            storage = .legacyRaw(proxyID)
        }

        package init(canonical storage: WebInspectorDOMNodeIdentityStorage) {
            self.storage = .canonical(storage)
        }

        package var canonicalStorage: WebInspectorDOMNodeIdentityStorage? {
            guard case let .canonical(storage) = storage else {
                return nil
            }
            return storage
        }

        package var proxyID: DOM.Node.ID {
            switch storage {
            case let .legacyRaw(proxyID):
                proxyID
            case let .canonical(storage):
                storage.rawNodeID
            }
        }
    }

    /// Immutable DOM node fields available to typed fetch descriptors.
    public struct QueryValue: Identifiable, Sendable {
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
        public let frameID: FrameID?

        /// The document URL associated with the node.
        public let documentURL: String?

        /// The base URL associated with the node.
        public let baseURL: String?

        /// Attributes keyed by name.
        public let attributes: [String: String]

        /// The number of regular children reported by WebKit.
        public let childNodeCount: Int

        /// The node's pseudo-element kind.
        public let pseudoType: DOM.PseudoType?

        /// The node's shadow-root kind.
        public let shadowRootType: DOM.ShadowRootType?

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
            frameID: FrameID?,
            documentURL: String?,
            baseURL: String?,
            attributes: [String: String],
            childNodeCount: Int,
            pseudoType: DOM.PseudoType?,
            shadowRootType: DOM.ShadowRootType?
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
            self.childNodeCount = childNodeCount
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
    public private(set) var frameID: FrameID?

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
            return legacyChildren
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
            ?? legacyContentDocument
    }

    /// Shadow roots attached to the node.
    public var shadowRoots: [DOMNode] {
        canonicalTopology?.shadowRootIDs.map(requiredCanonicalModel)
            ?? legacyShadowRoots
    }

    /// Template content associated with the node.
    public var templateContent: DOMNode? {
        canonicalTopology?.templateContentID.map(requiredCanonicalModel)
            ?? legacyTemplateContent
    }

    /// The `::before` pseudo element, if present.
    public var beforePseudoElement: DOMNode? {
        canonicalTopology?.beforePseudoElementID.map(requiredCanonicalModel)
            ?? legacyBeforePseudoElement
    }

    /// Additional pseudo elements reported by WebKit.
    public var otherPseudoElements: [DOMNode] {
        canonicalTopology?.otherPseudoElementIDs.map(requiredCanonicalModel)
            ?? legacyOtherPseudoElements
    }

    /// The `::after` pseudo element, if present.
    public var afterPseudoElement: DOMNode? {
        canonicalTopology?.afterPseudoElementID.map(requiredCanonicalModel)
            ?? legacyAfterPseudoElement
    }

    /// The node's pseudo-element kind.
    public private(set) var pseudoType: DOM.PseudoType?

    /// The node's shadow-root kind.
    public private(set) var shadowRootType: DOM.ShadowRootType?

    /// CSS styles associated with the element, when styles have been requested.
    public private(set) var elementStyles: CSSStyles?

    private var legacyChildren: Children
    private var legacyContentDocument: DOMNode?
    private var legacyShadowRoots: [DOMNode]
    private var legacyTemplateContent: DOMNode?
    private var legacyBeforePseudoElement: DOMNode?
    private var legacyOtherPseudoElements: [DOMNode]
    private var legacyAfterPseudoElement: DOMNode?
    private var canonicalTopology: WebInspectorDOMModelTopology?

    @ObservationIgnored weak var modelContext: WebInspectorModelContext?

    var isFrameOwner: Bool {
        let name = localName.isEmpty ? nodeName : localName
        let normalizedName = name.lowercased()
        return normalizedName == "iframe" || normalizedName == "frame"
    }

    init(node: DOM.Node) {
        id = ID(node.id)
        nodeName = node.nodeName
        localName = node.localName
        nodeValue = node.nodeValue
        nodeType = node.nodeType
        frameID = node.frameID
        documentURL = node.documentURL
        baseURL = node.baseURL
        attributes = node.attributes
        attributeList = node.attributeList.map(Attribute.init)
        childNodeCount = node.childNodeCount
        legacyChildren = .unrequested(count: node.childNodeCount)
        legacyContentDocument = nil
        legacyShadowRoots = []
        legacyTemplateContent = nil
        legacyBeforePseudoElement = nil
        legacyOtherPseudoElements = []
        legacyAfterPseudoElement = nil
        canonicalTopology = nil
        pseudoType = node.pseudoType
        shadowRootType = node.shadowRootType
        elementStyles = nil
        modelContext = nil
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
        frameID = record.canonical.frameID
        documentURL = record.canonical.documentURL
        baseURL = record.canonical.baseURL
        attributes = record.canonical.queryValue.attributes
        attributeList = record.canonical.attributes.map(Attribute.init)
        childNodeCount = record.canonical.children.count
        legacyChildren = .unrequested(count: record.canonical.children.count)
        legacyContentDocument = nil
        legacyShadowRoots = []
        legacyTemplateContent = nil
        legacyBeforePseudoElement = nil
        legacyOtherPseudoElements = []
        legacyAfterPseudoElement = nil
        canonicalTopology = record.topology
        pseudoType = record.canonical.pseudoType
        shadowRootType = record.canonical.shadowRootType
        elementStyles = nil
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
        guard id.canonicalStorage != nil else {
            preconditionFailure(
                "Canonical topology cannot be installed on a legacy DOMNode."
            )
        }
        canonicalTopology = topology
        childNodeCount = topology.children.count
    }

    package func resetCanonicalOwnerProjection() {
        guard id.canonicalStorage != nil else {
            return
        }
        canonicalTopology = nil
        invalidateCanonicalCSSResource()
    }

    package func invalidateCanonicalRecord() {
        resetCanonicalOwnerProjection()
        modelContext = nil
    }

    package func applyCanonicalResourceInvalidations(
        _ invalidations: Set<WebInspectorCanonicalResourceInvalidation>
    ) {
        guard let storage = id.canonicalStorage,
            invalidations.contains(where: {
                canonicalResourceInvalidation($0, affects: storage)
            })
        else {
            return
        }
        elementStyles?.markCanonicalNeedsRefresh()
    }

    package var canonicalAncestorIDsForTesting: [WebInspectorDOMNodeIdentityStorage] {
        canonicalTopology?.ancestorIDs ?? []
    }

    func update(from node: DOM.Node) {
        nodeName = node.nodeName
        localName = node.localName
        nodeValue = node.nodeValue
        nodeType = node.nodeType
        frameID = node.frameID
        documentURL = node.documentURL
        baseURL = node.baseURL
        attributes = node.attributes
        attributeList = node.attributeList.map(Attribute.init)
        childNodeCount = node.childNodeCount
        pseudoType = node.pseudoType
        shadowRootType = node.shadowRootType
    }

    func setChildren(_ nodes: [DOMNode]) {
        childNodeCount = nodes.count
        legacyChildren = .loaded(nodes)
    }

    func setChildrenUnrequested(count: Int) {
        childNodeCount = count
        legacyChildren = .unrequested(count: count)
    }

    func updateChildNodeCount(_ count: Int) {
        childNodeCount = count
        if case .unrequested = legacyChildren {
            legacyChildren = .unrequested(count: count)
        }
    }

    func setAttribute(name: String, value: String) {
        attributes[name] = value
        if let index = attributeList.firstIndex(where: { $0.name == name }) {
            attributeList[index] = Attribute(name: name, value: value)
        } else {
            attributeList.append(Attribute(name: name, value: value))
        }
    }

    func removeAttribute(name: String) {
        attributes[name] = nil
        attributeList.removeAll { $0.name == name }
    }

    func setNodeValue(_ value: String) {
        nodeValue = value
    }

    func setElementStyles(_ styles: CSSStyles?) {
        elementStyles = styles
    }

    func setAssociatedNodes(
        contentDocument: DOMNode?,
        shadowRoots: [DOMNode],
        templateContent: DOMNode?,
        beforePseudoElement: DOMNode?,
        otherPseudoElements: [DOMNode],
        afterPseudoElement: DOMNode?
    ) {
        legacyContentDocument = contentDocument
        legacyShadowRoots = shadowRoots
        legacyTemplateContent = templateContent
        legacyBeforePseudoElement = beforePseudoElement
        legacyOtherPseudoElements = otherPseudoElements
        legacyAfterPseudoElement = afterPseudoElement
    }

    func setContentDocument(_ node: DOMNode?) {
        legacyContentDocument = node
    }

    func appendShadowRoot(_ node: DOMNode) {
        legacyShadowRoots.removeAll { $0.id == node.id }
        legacyShadowRoots.append(node)
    }

    func removeShadowRoot(id: ID) -> DOMNode? {
        guard let index = legacyShadowRoots.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return legacyShadowRoots.remove(at: index)
    }

    func setPseudoElement(_ node: DOMNode) -> DOMNode? {
        switch node.pseudoType {
        case .before:
            let previous = legacyBeforePseudoElement
            legacyBeforePseudoElement = node
            return previous?.id == node.id ? nil : previous
        case .after:
            let previous = legacyAfterPseudoElement
            legacyAfterPseudoElement = node
            return previous?.id == node.id ? nil : previous
        case .other(_), nil:
            if let index = legacyOtherPseudoElements.firstIndex(where: { $0.id == node.id }) {
                legacyOtherPseudoElements[index] = node
            } else {
                legacyOtherPseudoElements.append(node)
            }
            return nil
        }
    }

    func removePseudoElement(id: ID) -> DOMNode? {
        if legacyBeforePseudoElement?.id == id {
            let removed = legacyBeforePseudoElement
            legacyBeforePseudoElement = nil
            return removed
        }
        if legacyAfterPseudoElement?.id == id {
            let removed = legacyAfterPseudoElement
            legacyAfterPseudoElement = nil
            return removed
        }
        guard let index = legacyOtherPseudoElements.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return legacyOtherPseudoElements.remove(at: index)
    }

    func associatedSubtreeRoots() -> [DOMNode] {
        [legacyContentDocument]
            .compactMap { $0 }
            + legacyShadowRoots
            + [legacyTemplateContent, legacyBeforePseudoElement]
            .compactMap { $0 }
            + legacyOtherPseudoElements
            + [legacyAfterPseudoElement]
            .compactMap { $0 }
    }

    private func replaceCanonicalContent(
        with record: WebInspectorCanonicalDOMRecord
    ) {
        nodeName = record.nodeName
        localName = record.localName
        nodeValue = record.nodeValue
        nodeType = record.nodeType
        frameID = record.frameID
        documentURL = record.documentURL
        baseURL = record.baseURL
        attributes = record.queryValue.attributes
        attributeList = record.attributes.map(Attribute.init)
        childNodeCount = record.children.count
        pseudoType = record.pseudoType
        shadowRootType = record.shadowRootType
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
                frameID = value
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
                pseudoType = value
            case let .shadowRootType(value):
                shadowRootType = value
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

    private func canonicalResourceInvalidation(
        _ invalidation: WebInspectorCanonicalResourceInvalidation,
        affects storage: WebInspectorDOMNodeIdentityStorage
    ) -> Bool {
        switch invalidation {
        case let .target(scope):
            storage.documentScope == scope
        case let .subtree(rootID):
            rootID.documentScope == storage.documentScope
                && (storage == rootID
                    || canonicalTopology?.ancestorIDs.contains(rootID) == true)
        case let .nodes(nodeIDs):
            nodeIDs.contains(storage)
        }
    }

    private func invalidateCanonicalCSSResource() {
        elementStyles?.invalidateCanonicalOwner()
        elementStyles = nil
    }

}

extension DOMNode.Attribute {
    init(_ attribute: DOM.Attribute) {
        self.init(name: attribute.name, value: attribute.value)
    }
}
