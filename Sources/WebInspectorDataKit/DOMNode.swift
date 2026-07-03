import Foundation
import Observation
import WebInspectorProxyKit

@Observable
public final class DOMNode: WebInspectorPersistentModel {
    public struct ID: Hashable, Sendable {
        let proxyID: DOM.Node.ID

        init(_ proxyID: DOM.Node.ID) {
            self.proxyID = proxyID
        }
    }

    public struct Kind: RawRepresentable, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let element = Kind(rawValue: 1)
        public static let attribute = Kind(rawValue: 2)
        public static let text = Kind(rawValue: 3)
        public static let cdataSection = Kind(rawValue: 4)
        public static let entityReference = Kind(rawValue: 5)
        public static let entity = Kind(rawValue: 6)
        public static let processingInstruction = Kind(rawValue: 7)
        public static let comment = Kind(rawValue: 8)
        public static let document = Kind(rawValue: 9)
        public static let documentType = Kind(rawValue: 10)
        public static let documentFragment = Kind(rawValue: 11)
        public static let notation = Kind(rawValue: 12)
    }

    public struct Attribute: Hashable, Sendable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public enum Children {
        case unrequested(count: Int)
        case loaded([DOMNode])
    }

    public let id: ID
    public private(set) var nodeName: String
    public private(set) var localName: String
    public private(set) var nodeValue: String
    public private(set) var nodeType: Int
    public var kind: Kind {
        Kind(rawValue: nodeType)
    }
    public private(set) var frameID: FrameID?
    public private(set) var documentURL: String?
    public private(set) var baseURL: String?
    public private(set) var attributes: [String: String]
    public private(set) var attributeList: [Attribute]
    public private(set) var childNodeCount: Int
    public private(set) var children: Children
    public private(set) var contentDocument: DOMNode?
    public private(set) var shadowRoots: [DOMNode]
    public private(set) var templateContent: DOMNode?
    public private(set) var beforePseudoElement: DOMNode?
    public private(set) var otherPseudoElements: [DOMNode]
    public private(set) var afterPseudoElement: DOMNode?
    public private(set) var pseudoType: DOM.PseudoType?
    public private(set) var shadowRootType: DOM.ShadowRootType?
    public private(set) var elementStyles: CSSStyles?

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

    public func requestChildren(
        depth: Int = 1,
        isolation: isolated (any Actor) = #isolation
    ) async {
        guard let modelContext else {
            preconditionFailure("DOMNode is not registered in a WebInspectorContext.")
        }
        await modelContext.requestChildren(for: self, depth: depth, isolation: isolation)
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
