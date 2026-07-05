import Foundation

public enum DOM {
    public struct Attribute: Hashable, Sendable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public struct Client: Sendable {
        package let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        public func getDocument() async throws -> Node {
            try await context.dispatch(
                domain: .dom,
                method: "getDocument",
                payload: GetDocumentPayload(),
                returning: Node.self
            )
        }

        public func requestChildNodes(_ id: Node.ID, depth: Int = 1) async throws {
            try await context.dispatchVoid(
                domain: .dom,
                method: "requestChildNodes",
                payload: RequestChildNodesPayload(id: id, depth: depth)
            )
        }

        public func requestNode(forRemoteObject objectID: Runtime.RemoteObject.ID) async throws -> Node.ID {
            try await context.dispatch(
                domain: .dom,
                method: "requestNode",
                payload: RequestNodePayload(objectID: objectID),
                returning: Node.ID.self
            )
        }

        public func outerHTML(of id: Node.ID) async throws -> String {
            try await context.dispatch(
                domain: .dom,
                method: "getOuterHTML",
                payload: GetOuterHTMLPayload(id: id),
                returning: String.self
            )
        }

        public func removeNode(_ id: Node.ID) async throws {
            try await context.dispatchVoid(
                domain: .dom,
                method: "removeNode",
                payload: RemoveNodePayload(id: id)
            )
        }

        public func highlightNode(_ id: Node.ID) async throws {
            // WebKit cannot highlight frame-owned DOM nodes from frame targets
            // yet; its frontend intentionally no-ops these nodes instead of
            // routing a scoped id to the wrong page node.
            guard id.targetScopeRawValue == nil else {
                return
            }
            try await context.dispatchVoid(
                domain: .dom,
                method: "highlightNode",
                payload: HighlightNodePayload(id: id)
            )
        }

        public func hideHighlight() async throws {
            try await context.dispatchVoid(
                domain: .dom,
                method: "hideHighlight",
                payload: HideHighlightPayload()
            )
        }

        public func setInspectMode(enabled: Bool) async throws {
            try await context.dispatchVoid(
                domain: .dom,
                method: "setInspectModeEnabled",
                payload: SetInspectModeEnabledPayload(enabled: enabled)
            )
        }

        public func undo() async throws {
            try await context.dispatchVoid(
                domain: .dom,
                method: "undo",
                payload: UndoPayload()
            )
        }

        public func redo() async throws {
            try await context.dispatchVoid(
                domain: .dom,
                method: "redo",
                payload: RedoPayload()
            )
        }

        public var events: EventStream {
            EventStream {
                context.domEvents()
            }
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

    package struct RemoveNodePayload: Sendable {
        package let id: Node.ID

        package init(id: Node.ID) {
            self.id = id
        }
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

    public struct Node: Identifiable, Sendable {
        public struct ID: Hashable, Sendable {
            package let rawValue: String

            package init(_ rawValue: String) {
                self.rawValue = rawValue
            }
        }

        public let id: ID
        public let nodeType: Int
        public let nodeName: String
        public let localName: String
        public let nodeValue: String
        public let frameID: FrameID?
        public let documentURL: String?
        public let baseURL: String?
        public var attributes: [String: String]
        public var attributeList: [DOM.Attribute]
        public var childNodeCount: Int
        public var children: [Node]?
        public var contentDocument: Node? { recursiveFields.contentDocument }
        public var shadowRoots: [Node]
        public var templateContent: Node? { recursiveFields.templateContent }
        public var beforePseudoElement: Node? { recursiveFields.beforePseudoElement }
        public var otherPseudoElements: [Node] { recursiveFields.otherPseudoElements }
        public var afterPseudoElement: Node? { recursiveFields.afterPseudoElement }
        public var pseudoType: PseudoType?
        public var shadowRootType: ShadowRootType?

        // Keeps recursive Node references out of direct value-type storage.
        private let recursiveFields: RecursiveFields

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

    public enum PseudoType: Hashable, Sendable {
        case before
        case after
        case other(String)
    }

    public enum ShadowRootType: Hashable, Sendable {
        case open
        case closed
        case userAgent
        case other(String)
    }

    public enum Event: Sendable {
        case documentUpdated
        case setChildNodes(parent: Node.ID, nodes: [Node])
        case detachedRoot(Node)
        case childNodeInserted(parent: Node.ID, previous: Node.ID?, node: Node)
        case childNodeRemoved(parent: Node.ID, node: Node.ID)
        case childNodeCountUpdated(Node.ID, count: Int)
        case attributeModified(Node.ID, name: String, value: String)
        case attributeRemoved(Node.ID, name: String)
        case characterDataModified(Node.ID, value: String)
        case shadowRootPushed(host: Node.ID, root: Node)
        case shadowRootPopped(host: Node.ID, root: Node.ID)
        case pseudoElementAdded(parent: Node.ID, element: Node)
        case pseudoElementRemoved(parent: Node.ID, element: Node.ID)
        case inspect(Node.ID)
        case unknown(RawEvent)
    }

    public struct EventStream: AsyncSequence, Sendable {
        public typealias Element = Event
        public typealias AsyncIterator = AsyncStream<Event>.Iterator

        private let makeStream: @Sendable () -> AsyncStream<Event>

        package init(
            _ makeStream: @escaping @Sendable () -> AsyncStream<Event> = {
                finishedStream(of: Event.self)
            }
        ) {
            self.makeStream = makeStream
        }

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
