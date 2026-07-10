import Foundation

/// A target-scoped handle for Web Inspector DOM commands and events.
public struct DOM: Sendable, WebInspectorEventDomainHandle {
    package static let commandDomain = WebInspectorProxyDomain.dom
    package static let eventDomain = WebInspectorProxyEventDomain.dom

    package let endpoint: DomainEndpoint

    package init(endpoint: DomainEndpoint) {
        self.endpoint = endpoint
    }

    package static func extractEvent(_ event: WebInspectorProxyEvent) -> Event? {
        guard case let .dom(value) = event else {
            return nil
        }
        return value
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
        try await dispatch(
            method: "getDocument",
            payload: GetDocumentPayload(),
            returning: Node.self
        )
    }

    /// Requests child-node events for a node up to the supplied depth.
    public func requestChildNodes(_ id: Node.ID, depth: Int = 1) async throws {
        try await dispatchVoid(
            method: "requestChildNodes",
            payload: RequestChildNodesPayload(id: id, depth: depth)
        )
    }

    /// Resolves a runtime object through the current page DOM agent.
    ///
    /// WebKit does not implement this command for frame targets. The returned
    /// identity therefore belongs to the unscoped current-page DOM namespace.
    public func requestNode(forRemoteObject objectID: Runtime.RemoteObject.ID) async throws -> Node.ID {
        try await dispatch(
            method: "requestNode",
            payload: RequestNodePayload(objectID: objectID),
            returning: Node.ID.self
        )
    }

    /// Returns serialized outer HTML for a node.
    public func outerHTML(of id: Node.ID) async throws -> String {
        try await dispatch(
            method: "getOuterHTML",
            payload: GetOuterHTMLPayload(id: id),
            returning: String.self
        )
    }

    /// Returns the current attributes for a node.
    public func attributes(of id: Node.ID) async throws -> [Attribute] {
        try await dispatch(
            method: "getAttributes",
            payload: GetAttributesPayload(id: id),
            returning: [Attribute].self
        )
    }

    /// Sets a single attribute value on a node.
    public func setAttributeValue(_ id: Node.ID, name: String, value: String) async throws {
        try await dispatchVoid(
            method: "setAttributeValue",
            payload: SetAttributeValuePayload(id: id, name: name, value: value)
        )
    }

    /// Replaces attributes on a node using raw attribute text.
    public func setAttributesAsText(_ id: Node.ID, text: String, name: String? = nil) async throws {
        try await dispatchVoid(
            method: "setAttributesAsText",
            payload: SetAttributesAsTextPayload(id: id, text: text, name: name)
        )
    }

    /// Removes an attribute from a node.
    public func removeAttribute(_ id: Node.ID, name: String) async throws {
        try await dispatchVoid(
            method: "removeAttribute",
            payload: RemoveAttributePayload(id: id, name: name)
        )
    }

    /// Replaces a node with the supplied outer HTML.
    public func setOuterHTML(_ id: Node.ID, html: String) async throws {
        try await dispatchVoid(
            method: "setOuterHTML",
            payload: SetOuterHTMLPayload(id: id, html: html)
        )
    }

    /// Removes a node from the document.
    public func removeNode(_ id: Node.ID) async throws {
        try await dispatchVoid(
            method: "removeNode",
            payload: RemoveNodePayload(id: id)
        )
    }

    /// Marks the current DOM state as an undoable editing checkpoint.
    public func markUndoableState() async throws {
        try await dispatchVoid(
            method: "markUndoableState",
            payload: MarkUndoableStatePayload()
        )
    }

    /// Highlights a DOM node in the inspected page.
    public func highlightNode(_ id: Node.ID) async throws {
        // WebKit cannot highlight frame-owned DOM nodes from frame targets
        // yet; its frontend intentionally no-ops these nodes instead of
        // routing a scoped id to the wrong page node.
        guard id.targetScopeRawValue == nil else {
            return
        }
        try await dispatchVoid(
            method: "highlightNode",
            payload: HighlightNodePayload(id: id)
        )
    }

    /// Clears the current DOM highlight.
    public func hideHighlight() async throws {
        try await dispatchVoid(
            method: "hideHighlight",
            payload: HideHighlightPayload()
        )
    }

    package func setInspectMode(enabled: Bool) async throws {
        try await dispatchVoid(
            method: "setInspectModeEnabled",
            payload: SetInspectModeEnabledPayload(enabled: enabled)
        )
    }

    /// Runs an operation while WebKit's element picker is enabled.
    ///
    /// The Inspector capability and its event subscriber are installed before
    /// inspect mode is enabled. The scope disables inspect mode and releases
    /// the capability on success, failure, and cancellation.
    public func withElementPicker<Output>(
        buffering: WebInspectorEventBufferingPolicy = .bounded(16),
        isolation: isolated (any Actor)? = #isolation,
        _ operation: (
            AsyncThrowingStream<WebInspectorPageEvent<Node.ID>, any Error>
        ) async throws -> Output
    ) async throws -> Output {
        let inspector = Inspector(endpoint: endpoint)
        return try await inspector._withEvents(
            buffering: buffering,
            isolation: isolation
        ) { inspectorEvents in
            let pair = AsyncThrowingStream.makeStream(
                of: WebInspectorPageEvent<Node.ID>.self
            )
            let projectionTask = Task {
                do {
                    for try await pageEvent in inspectorEvents {
                        switch pageEvent {
                        case let .reset(generation):
                            pair.continuation.yield(.reset(generation))
                        case let .event(generation, event):
                            guard case let .inspect(object, _) = event,
                                  object.subtype?.rawValue == "node",
                                  let objectID = object.id else {
                                continue
                            }
                            let nodeID: Node.ID
                            do {
                                nodeID = try await requestNode(
                                    forRemoteObject: objectID
                                )
                            } catch WebInspectorProxyError.staleIdentifier {
                                continue
                            } catch WebInspectorProxyError.pageUnavailable {
                                continue
                            }
                            pair.continuation.yield(
                                .event(generation, nodeID)
                            )
                        }
                    }
                    pair.continuation.finish()
                } catch {
                    pair.continuation.finish(throwing: error)
                }
            }
            pair.continuation.onTermination = { _ in
                projectionTask.cancel()
            }

            let operationResult: Result<Output, any Error>
            do {
                operationResult = .success(
                    try await operation(pair.stream)
                )
            } catch {
                operationResult = .failure(error)
            }

            projectionTask.cancel()
            await projectionTask.value
            pair.continuation.finish()
            switch operationResult {
            case let .success(output):
                return output
            case let .failure(error):
                throw error
            }
        }
    }

    /// Undoes the most recent DOM edit recorded by WebKit.
    public func undo() async throws {
        try await dispatchVoid(
            method: "undo",
            payload: UndoPayload()
        )
    }

    /// Redoes the most recent DOM edit recorded by WebKit.
    public func redo() async throws {
        try await dispatchVoid(
            method: "redo",
            payload: RedoPayload()
        )
    }

    /// DOM domain events emitted by this target.
    public var events: EventStream {
        EventStream {
            endpoint.domEvents()
        }
    }

    package struct GetDocumentPayload: Sendable {
        package init() {}
    }

    package struct RequestChildNodesPayload: Sendable {
        package let id: Node.ID
        package let depth: Int

        package init(id: Node.ID, depth: Int) {
            self.id = id
            self.depth = depth
        }
    }

    package struct RequestNodePayload: Sendable {
        package let objectID: Runtime.RemoteObject.ID

        package init(objectID: Runtime.RemoteObject.ID) {
            self.objectID = objectID
        }
    }

    package struct GetOuterHTMLPayload: Sendable {
        package let id: Node.ID

        package init(id: Node.ID) {
            self.id = id
        }
    }

    package struct GetAttributesPayload: Sendable {
        package let id: Node.ID

        package init(id: Node.ID) {
            self.id = id
        }
    }

    package struct SetAttributeValuePayload: Sendable {
        package let id: Node.ID
        package let name: String
        package let value: String

        package init(id: Node.ID, name: String, value: String) {
            self.id = id
            self.name = name
            self.value = value
        }
    }

    package struct SetAttributesAsTextPayload: Sendable {
        package let id: Node.ID
        package let text: String
        package let name: String?

        package init(id: Node.ID, text: String, name: String?) {
            self.id = id
            self.text = text
            self.name = name
        }
    }

    package struct RemoveAttributePayload: Sendable {
        package let id: Node.ID
        package let name: String

        package init(id: Node.ID, name: String) {
            self.id = id
            self.name = name
        }
    }

    package struct SetOuterHTMLPayload: Sendable {
        package let id: Node.ID
        package let html: String

        package init(id: Node.ID, html: String) {
            self.id = id
            self.html = html
        }
    }

    package struct RemoveNodePayload: Sendable {
        package let id: Node.ID

        package init(id: Node.ID) {
            self.id = id
        }
    }

    package struct MarkUndoableStatePayload: Sendable {
        package init() {}
    }

    package struct HighlightNodePayload: Sendable {
        package let id: Node.ID

        package init(id: Node.ID) {
            self.id = id
        }
    }

    package struct HideHighlightPayload: Sendable {
        package init() {}
    }

    package struct SetInspectModeEnabledPayload: Sendable {
        package let enabled: Bool

        package init(enabled: Bool) {
            self.enabled = enabled
        }
    }

    package struct UndoPayload: Sendable {
        package init() {}
    }

    package struct RedoPayload: Sendable {
        package init() {}
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

    /// An asynchronous stream of DOM domain events.
    public struct EventStream: AsyncSequence, Sendable {
        /// The event yielded by the stream.
        public typealias Element = Event

        /// The iterator type used by the stream.
        public typealias AsyncIterator = AsyncStream<Event>.Iterator

        private let makeStream: @Sendable () -> AsyncStream<Event>

        package init(
            _ makeStream: @escaping @Sendable () -> AsyncStream<Event> = {
                finishedStream(of: Event.self)
            }
        ) {
            self.makeStream = makeStream
        }

        /// Creates an iterator over DOM events.
        public func makeAsyncIterator() -> AsyncIterator {
            makeStream().makeAsyncIterator()
        }
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
