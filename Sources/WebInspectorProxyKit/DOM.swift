import Foundation

/// A target-scoped handle for Web Inspector DOM commands and events.
public struct DOM: Sendable, WebInspectorEventDomainHandle {
    package static let eventDecoder = DOMWireCoding.eventDecoder
    package static let eventCapability = DOMWireCoding.capability

    package let endpoint: DomainEndpoint

    package init(endpoint: DomainEndpoint) {
        self.endpoint = endpoint
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

    /// Runs an operation with an atomically registered DOM event scope.
    public func withEvents<Output>(
        buffering: WebInspectorEventBufferingPolicy = .bounded(256),
        isolation: isolated (any Actor)? = #isolation,
        _ operation: (
            AsyncThrowingStream<WebInspectorPageEvent<DOM.Event>, any Error>
        ) async throws -> Output
    ) async throws -> Output {
        try await _withEvents(
            buffering: buffering,
            isolation: isolation,
            operation
        )
    }

    /// Returns the root document node for the target.
    public func getDocument() async throws -> Node {
        try await endpoint.dispatch(DOMWireCoding.getDocument())
    }

    /// Requests child-node events for a node up to the supplied depth.
    public func requestChildNodes(_ id: Node.ID, depth: Int = 1) async throws {
        try await endpoint.dispatch(DOMWireCoding.requestChildNodes(id, depth: depth))
    }

    /// Resolves a runtime object through the DOM agent that owns it.
    ///
    /// An unscoped object is resolved by the current-page target. A
    /// target-scoped object is resolved by that target, and the returned node
    /// identity preserves the decoded target scope.
    public func requestNode(forRemoteObject objectID: Runtime.RemoteObject.ID) async throws -> Node.ID {
        try await endpoint.dispatch(DOMWireCoding.requestNode(objectID))
    }

    /// Returns serialized outer HTML for a node.
    public func outerHTML(of id: Node.ID) async throws -> String {
        try await endpoint.dispatch(DOMWireCoding.outerHTML(id))
    }

    /// Returns the current attributes for a node.
    public func attributes(of id: Node.ID) async throws -> [Attribute] {
        try await endpoint.dispatch(DOMWireCoding.attributes(id))
    }

    /// Sets a single attribute value on a node.
    public func setAttributeValue(_ id: Node.ID, name: String, value: String) async throws {
        try await endpoint.dispatch(DOMWireCoding.setAttribute(id, name: name, value: value))
    }

    /// Replaces attributes on a node using raw attribute text.
    public func setAttributesAsText(_ id: Node.ID, text: String, name: String? = nil) async throws {
        try await endpoint.dispatch(DOMWireCoding.setAttributes(id, text: text, name: name))
    }

    /// Removes an attribute from a node.
    public func removeAttribute(_ id: Node.ID, name: String) async throws {
        try await endpoint.dispatch(DOMWireCoding.removeAttribute(id, name: name))
    }

    /// Replaces a node with the supplied outer HTML.
    public func setOuterHTML(_ id: Node.ID, html: String) async throws {
        try await endpoint.dispatch(DOMWireCoding.setOuterHTML(id, html: html))
    }

    /// Removes a node from the document.
    public func removeNode(_ id: Node.ID) async throws {
        try await endpoint.dispatch(DOMWireCoding.removeNode(id))
    }

    /// Marks the current DOM state as an undoable editing checkpoint.
    public func markUndoableState() async throws {
        try await endpoint.dispatch(DOMWireCoding.markUndoableState)
    }

    /// Highlights a DOM node in the inspected page.
    ///
    /// WebKit cannot highlight frame-owned nodes from frame targets. Such
    /// nodes are intentionally ignored instead of being routed into the
    /// current page's unrelated node namespace.
    public func highlightNode(_ id: Node.ID) async throws {
        guard id.targetScopeRawValue == nil else { return }
        try await endpoint.dispatch(DOMWireCoding.highlightNode(id))
    }

    /// Clears the current DOM highlight.
    public func hideHighlight() async throws {
        try await endpoint.dispatch(DOMWireCoding.hideHighlight)
    }

    package func setInspectMode(enabled: Bool) async throws {
        try await endpoint.dispatch(DOMWireCoding.setInspectMode(enabled))
    }

    /// Undoes the most recent DOM edit recorded by WebKit.
    public func undo() async throws {
        try await endpoint.dispatch(DOMWireCoding.undo)
    }

    /// Redoes the most recent DOM edit recorded by WebKit.
    public func redo() async throws {
        try await endpoint.dispatch(DOMWireCoding.redo)
    }

    /// A DOM node payload returned by the inspector protocol.
    public struct Node: Identifiable, Sendable {
        /// Stable identity for a DOM node within one target.
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        /// The backend identity for the node.
        public let id: ID

        /// The numeric DOM node type.
        public let nodeType: Int

        /// The protocol node name.
        public let nodeName: String

        /// The local element name, if available.
        public let localName: String

        /// The node value for text-like nodes.
        public let nodeValue: String

        /// The frame that owns the node, if WebKit reported one.
        public let frameID: FrameID?

        /// The document URL associated with the node.
        public let documentURL: String?

        /// The base URL associated with the node.
        public let baseURL: String?

        /// Attributes keyed by name.
        public var attributes: [String: String]

        /// Attributes in protocol order.
        public var attributeList: [DOM.Attribute]

        /// The number of regular children reported by WebKit.
        public var childNodeCount: Int

        /// Regular child nodes when they have been loaded.
        public var children: [Node]?

        /// The content document for frame-like elements.
        public var contentDocument: Node? { recursiveFields.contentDocument }

        /// Shadow roots attached to the node.
        public var shadowRoots: [Node]

        /// Template content associated with the node.
        public var templateContent: Node? { recursiveFields.templateContent }

        /// The `::before` pseudo element, if present.
        public var beforePseudoElement: Node? { recursiveFields.beforePseudoElement }

        /// Additional pseudo elements reported by WebKit.
        public var otherPseudoElements: [Node] { recursiveFields.otherPseudoElements }

        /// The `::after` pseudo element, if present.
        public var afterPseudoElement: Node? { recursiveFields.afterPseudoElement }

        /// The node's pseudo-element kind.
        public var pseudoType: PseudoType?

        /// The node's shadow-root kind.
        public var shadowRootType: ShadowRootType?

        // Keeps recursive Node references out of direct value-type storage.
        private let recursiveFields: RecursiveFields

        /// Creates a DOM node payload.
        public init(
            id: ID,
            nodeType: Int,
            nodeName: String,
            localName: String = "",
            nodeValue: String = "",
            frameID: FrameID? = nil,
            documentURL: String? = nil,
            baseURL: String? = nil,
            attributes: [String: String] = [:],
            attributeList: [DOM.Attribute]? = nil,
            childNodeCount: Int = 0,
            children: [Node]? = nil,
            contentDocument: Node? = nil,
            shadowRoots: [Node] = [],
            templateContent: Node? = nil,
            beforePseudoElement: Node? = nil,
            otherPseudoElements: [Node] = [],
            afterPseudoElement: Node? = nil,
            pseudoType: PseudoType? = nil,
            shadowRootType: ShadowRootType? = nil
        ) {
            self.id = id
            self.nodeType = nodeType
            self.nodeName = nodeName
            self.localName = localName
            self.nodeValue = nodeValue
            self.frameID = frameID
            self.documentURL = documentURL
            self.baseURL = baseURL
            self.attributes = attributes
            self.attributeList = attributeList ?? attributes.map { DOM.Attribute(name: $0.key, value: $0.value) }
            self.childNodeCount = childNodeCount
            self.children = children
            self.shadowRoots = shadowRoots
            self.pseudoType = pseudoType
            self.shadowRootType = shadowRootType
            recursiveFields = RecursiveFields(
                contentDocument: contentDocument,
                templateContent: templateContent,
                beforePseudoElement: beforePseudoElement,
                otherPseudoElements: otherPseudoElements,
                afterPseudoElement: afterPseudoElement
            )
        }

        private final class RecursiveFields: Sendable {
            let contentDocument: Node?
            let templateContent: Node?
            let beforePseudoElement: Node?
            let otherPseudoElements: [Node]
            let afterPseudoElement: Node?

            init(
                contentDocument: Node?,
                templateContent: Node?,
                beforePseudoElement: Node?,
                otherPseudoElements: [Node],
                afterPseudoElement: Node?
            ) {
                self.contentDocument = contentDocument
                self.templateContent = templateContent
                self.beforePseudoElement = beforePseudoElement
                self.otherPseudoElements = otherPseudoElements
                self.afterPseudoElement = afterPseudoElement
            }
        }
    }

    /// Pseudo-element type reported for a DOM node.
    public enum PseudoType: Hashable, Sendable {
        /// The `::before` pseudo element.
        case before

        /// The `::after` pseudo element.
        case after

        /// A pseudo-element type that is not modeled by this package.
        case other(String)
    }

    /// Shadow-root type reported for a DOM node.
    public enum ShadowRootType: Hashable, Sendable {
        /// An open author shadow root.
        case open

        /// A closed author shadow root.
        case closed

        /// A user-agent shadow root.
        case userAgent

        /// A shadow-root type that is not modeled by this package.
        case other(String)
    }

    /// Events emitted by the DOM domain.
    public enum Event: Sendable {
        /// The document was replaced or invalidated.
        case documentUpdated

        /// Child nodes were supplied for a parent.
        case setChildNodes(parent: Node.ID, nodes: [Node])

        /// A detached root was reported by WebKit.
        case detachedRoot(Node)

        /// A child node was inserted under a parent.
        case childNodeInserted(parent: Node.ID, previous: Node.ID?, node: Node)

        /// A child node was removed from a parent.
        case childNodeRemoved(parent: Node.ID, node: Node.ID)

        /// The child count for a node changed.
        case childNodeCountUpdated(Node.ID, count: Int)

        /// An attribute was added or changed.
        case attributeModified(Node.ID, name: String, value: String)

        /// An attribute was removed.
        case attributeRemoved(Node.ID, name: String)

        /// Inline style state was invalidated for nodes.
        case inlineStyleInvalidated([Node.ID])

        /// Text-like node data changed.
        case characterDataModified(Node.ID, value: String)

        /// A shadow root was attached to a host node.
        case shadowRootPushed(host: Node.ID, root: Node)

        /// A shadow root was removed from a host node.
        case shadowRootPopped(host: Node.ID, root: Node.ID)

        /// A pseudo element was added to a parent node.
        case pseudoElementAdded(parent: Node.ID, element: Node)

        /// A pseudo element was removed from a parent node.
        case pseudoElementRemoved(parent: Node.ID, element: Node.ID)

        /// WebKit announced that a DOM node will be destroyed.
        case willDestroyDOMNode(Node.ID)

        /// WebKit requested that the frontend inspect a node.
        case inspect(Node.ID)

        /// An event that is not modeled by this package.
        case unknown(RawEvent)
    }

}


package extension DOM.Node.ID {
    private static var targetScopeSeparator: Character { "\u{1E}" }

    init(_ rawValue: String, scopedToTargetRawValue targetRawValue: String) {
        self.init("\(targetRawValue)\(Self.targetScopeSeparator)\(rawValue)")
    }

    var targetScopeRawValue: String? {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        return String(parts[0])
    }

    var unscopedRawValue: String {
        let parts = rawValue.split(separator: Self.targetScopeSeparator, maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return rawValue
        }
        return String(parts[1])
    }
}
