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

    public enum Children {
        case unrequested(count: Int)
        case loaded([DOMNode])
    }

    public let id: ID
    public private(set) var nodeName: String
    public private(set) var localName: String
    public private(set) var nodeValue: String
    public private(set) var nodeType: Int
    public private(set) var attributes: [String: String]
    public private(set) var childNodeCount: Int
    public private(set) var children: Children
    public private(set) var elementStyles: CSSStyles?

    @ObservationIgnored weak var modelContext: WebInspectorContext?

    init(node: DOM.Node, modelContext: WebInspectorContext) {
        id = ID(node.id)
        nodeName = node.nodeName
        localName = node.localName
        nodeValue = node.nodeValue
        nodeType = node.nodeType
        attributes = node.attributes
        childNodeCount = node.childNodeCount
        children = .unrequested(count: node.childNodeCount)
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
        attributes = node.attributes
        childNodeCount = node.childNodeCount
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
    }

    func removeAttribute(name: String) {
        attributes[name] = nil
    }

    func setNodeValue(_ value: String) {
        nodeValue = value
    }

    func setElementStyles(_ styles: CSSStyles?) {
        elementStyles = styles
    }

    func setModelContext(_ context: WebInspectorContext) {
        modelContext = context
    }
}
