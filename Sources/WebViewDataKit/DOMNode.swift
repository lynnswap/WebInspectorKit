import Foundation
import Observation
import WebViewProxyKit

@MainActor
@Observable
public final class DOMNode: Identifiable {
    public struct ID: Hashable, Sendable {
        package let proxyID: DOM.Node.ID

        package init(_ proxyID: DOM.Node.ID) {
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

    @ObservationIgnored package weak var modelContext: WebViewModelContext?

    package init(node: DOM.Node, modelContext: WebViewModelContext) {
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

    public func requestChildren(depth: Int = 1) async {
        guard let modelContext else {
            preconditionFailure("DOMNode is not registered in a WebViewModelContext.")
        }
        await modelContext.requestChildren(for: self, depth: depth)
    }

    package func update(from node: DOM.Node) {
        nodeName = node.nodeName
        localName = node.localName
        nodeValue = node.nodeValue
        nodeType = node.nodeType
        attributes = node.attributes
        childNodeCount = node.childNodeCount
    }

    package func setChildren(_ nodes: [DOMNode]) {
        childNodeCount = nodes.count
        children = .loaded(nodes)
    }

    package func setChildrenUnrequested(count: Int) {
        childNodeCount = count
        children = .unrequested(count: count)
    }

    package func updateChildNodeCount(_ count: Int) {
        childNodeCount = count
        if case .unrequested = children {
            children = .unrequested(count: count)
        }
    }

    package func setAttribute(name: String, value: String) {
        attributes[name] = value
    }

    package func removeAttribute(name: String) {
        attributes[name] = nil
    }

    package func setNodeValue(_ value: String) {
        nodeValue = value
    }

    package func setElementStyles(_ styles: CSSStyles?) {
        elementStyles = styles
    }
}
