import Foundation
import Observation
import WebInspectorProxyKit

/// Observable model for a DOM node owned by a ``WebInspectorContext``.
@Observable
public final class DOMNode: WebInspectorPersistentModel {
    /// Stable identity for a DOM node within a context.
    public struct ID: Hashable, Sendable {
        let proxyID: DOM.Node.ID

        package init(_ proxyID: DOM.Node.ID) {
            self.proxyID = proxyID
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

    /// Loading state for regular child nodes.
    public private(set) var children: Children

    /// The content document for frame-like elements.
    public private(set) var contentDocument: DOMNode?

    /// Shadow roots attached to the node.
    public private(set) var shadowRoots: [DOMNode]

    /// Template content associated with the node.
    public private(set) var templateContent: DOMNode?

    /// The `::before` pseudo element, if present.
    public private(set) var beforePseudoElement: DOMNode?

    /// Additional pseudo elements reported by WebKit.
    public private(set) var otherPseudoElements: [DOMNode]

    /// The `::after` pseudo element, if present.
    public private(set) var afterPseudoElement: DOMNode?

    /// The node's pseudo-element kind.
    public private(set) var pseudoType: DOM.PseudoType?

    /// The node's shadow-root kind.
    public private(set) var shadowRootType: DOM.ShadowRootType?

    /// CSS styles associated with the element, when styles have been requested.
    public private(set) var elementStyles: CSSStyles?
    var isFrameOwner: Bool {
        let name = localName.isEmpty ? nodeName : localName
        let normalizedName = name.lowercased()
        return normalizedName == "iframe" || normalizedName == "frame"
    }

    @ObservationIgnored weak var modelContext: WebInspectorContext?

    init(node: DOM.Node, modelContext: WebInspectorContext) {
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
        children = .unrequested(count: node.childNodeCount)
        contentDocument = nil
        shadowRoots = []
        templateContent = nil
        beforePseudoElement = nil
        otherPseudoElements = []
        afterPseudoElement = nil
        pseudoType = node.pseudoType
        shadowRootType = node.shadowRootType
        elementStyles = nil
        self.modelContext = modelContext
    }

    /// Requests regular child nodes for this node.
    public func requestChildren(
        depth: Int = 1,
        isolation: isolated (any Actor) = #isolation
    ) async {
        guard let modelContext else {
            preconditionFailure("DOMNode is not registered in a WebInspectorContext.")
        }
        await modelContext.requestChildren(for: self, depth: depth, isolation: isolation)
    }

    /// Returns copied text for the node in the requested format.
    public func copyText(
        _ kind: CopyTextKind,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> String {
        guard let modelContext else {
            preconditionFailure("DOMNode is not registered in a WebInspectorContext.")
        }
        return try await modelContext.copyText(kind, for: self, isolation: isolation)
    }

    /// Removes this node from the inspected document.
    public func delete(isolation: isolated (any Actor) = #isolation) async throws {
        guard let modelContext else {
            preconditionFailure("DOMNode is not registered in a WebInspectorContext.")
        }
        try await modelContext.delete(self, isolation: isolation)
    }

    /// Highlights this node in the inspected page.
    public func highlight(isolation: isolated (any Actor) = #isolation) async throws {
        guard let modelContext else {
            preconditionFailure("DOMNode is not registered in a WebInspectorContext.")
        }
        try await modelContext.highlight(self, isolation: isolation)
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
        children = .loaded(nodes)
    }

    func setChildrenUnrequested(count: Int) {
        childNodeCount = count
        children = .unrequested(count: count)
    }

    func updateChildNodeCount(_ count: Int) {
        childNodeCount = count
        if case .unrequested = children {
            children = .unrequested(count: count)
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
        self.contentDocument = contentDocument
        self.shadowRoots = shadowRoots
        self.templateContent = templateContent
        self.beforePseudoElement = beforePseudoElement
        self.otherPseudoElements = otherPseudoElements
        self.afterPseudoElement = afterPseudoElement
    }

    func setContentDocument(_ node: DOMNode?) {
        contentDocument = node
    }

    func appendShadowRoot(_ node: DOMNode) {
        shadowRoots.removeAll { $0.id == node.id }
        shadowRoots.append(node)
    }

    func removeShadowRoot(id: ID) -> DOMNode? {
        guard let index = shadowRoots.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return shadowRoots.remove(at: index)
    }

    func setPseudoElement(_ node: DOMNode) -> DOMNode? {
        switch node.pseudoType {
        case .before:
            let previous = beforePseudoElement
            beforePseudoElement = node
            return previous?.id == node.id ? nil : previous
        case .after:
            let previous = afterPseudoElement
            afterPseudoElement = node
            return previous?.id == node.id ? nil : previous
        case .other(_), nil:
            if let index = otherPseudoElements.firstIndex(where: { $0.id == node.id }) {
                otherPseudoElements[index] = node
            } else {
                otherPseudoElements.append(node)
            }
            return nil
        }
    }

    func removePseudoElement(id: ID) -> DOMNode? {
        if beforePseudoElement?.id == id {
            let removed = beforePseudoElement
            beforePseudoElement = nil
            return removed
        }
        if afterPseudoElement?.id == id {
            let removed = afterPseudoElement
            afterPseudoElement = nil
            return removed
        }
        guard let index = otherPseudoElements.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return otherPseudoElements.remove(at: index)
    }

    func associatedSubtreeRoots() -> [DOMNode] {
        [contentDocument]
            .compactMap { $0 }
            + shadowRoots
            + [templateContent, beforePseudoElement]
            .compactMap { $0 }
            + otherPseudoElements
            + [afterPseudoElement]
            .compactMap { $0 }
    }

    func setModelContext(_ context: WebInspectorContext) {
        modelContext = context
    }
}

extension DOMNode.Attribute {
    init(_ attribute: DOM.Attribute) {
        self.init(name: attribute.name, value: attribute.value)
    }
}
