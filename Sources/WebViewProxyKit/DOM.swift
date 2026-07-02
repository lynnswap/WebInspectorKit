import Foundation

public enum DOM {
    public struct Client: Sendable {
        package let context: DomainClientContext

        package init(context: DomainClientContext) {
            self.context = context
        }

        public func getDocument() async throws -> Node {
            throw unimplementedCommand(domain: "DOM", method: "getDocument")
        }

        public func requestChildNodes(_ id: Node.ID, depth: Int = 1) async throws {
            throw unimplementedCommand(domain: "DOM", method: "requestChildNodes")
        }

        public func requestNode(forRemoteObject objectID: Runtime.RemoteObject.ID) async throws -> Node.ID {
            throw unimplementedCommand(domain: "DOM", method: "requestNode")
        }

        public func outerHTML(of id: Node.ID) async throws -> String {
            throw unimplementedCommand(domain: "DOM", method: "getOuterHTML")
        }

        public func removeNode(_ id: Node.ID) async throws {
            throw unimplementedCommand(domain: "DOM", method: "removeNode")
        }

        public func highlightNode(_ id: Node.ID) async throws {
            throw unimplementedCommand(domain: "DOM", method: "highlightNode")
        }

        public func hideHighlight() async throws {
            throw unimplementedCommand(domain: "DOM", method: "hideHighlight")
        }

        public func setInspectMode(enabled: Bool) async throws {
            throw unimplementedCommand(domain: "DOM", method: "setInspectModeEnabled")
        }

        public func undo() async throws {
            throw unimplementedCommand(domain: "DOM", method: "undo")
        }

        public func redo() async throws {
            throw unimplementedCommand(domain: "DOM", method: "redo")
        }

        public var events: EventStream {
            EventStream()
        }
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

    public enum PseudoType: Sendable {
        case before
        case after
        case other(String)
    }

    public enum ShadowRootType: Sendable {
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
