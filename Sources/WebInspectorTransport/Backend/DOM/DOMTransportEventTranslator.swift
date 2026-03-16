import Foundation
import WebInspectorCore

package struct DOMSetChildNodesParams: Decodable {
    package let parentId: Int
    package let nodes: [WITransportDOMNode]
}

package struct DOMInspectParams: Decodable {
    package let nodeId: Int
}

package struct DOMChildNodeInsertedParams: Decodable {
    package let parentNodeId: Int
    package let previousNodeId: Int?
    package let node: WITransportDOMNode
}

package struct DOMChildNodeRemovedParams: Decodable {
    package let parentNodeId: Int
    package let nodeId: Int
}

package struct DOMChildNodeCountUpdatedParams: Decodable {
    package let nodeId: Int
    package let childNodeCount: Int
}

package struct DOMAttributeModifiedParams: Decodable {
    package let nodeId: Int
    package let name: String
    package let value: String
}

package struct DOMAttributeRemovedParams: Decodable {
    package let nodeId: Int
    package let name: String
}

package struct DOMCharacterDataModifiedParams: Decodable {
    package let nodeId: Int
    package let characterData: String
}

private extension DOMSetChildNodesParams {
    init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let parentId = transportInt(from: dictionary["parentId"]) else {
            throw WITransportError.invalidResponse("Invalid DOM.setChildNodes payload.")
        }

        let nodes = try transportArray(from: dictionary["nodes"])?.map {
            try WITransportDOMNode(wiTransportObject: $0)
        } ?? []
        self.init(parentId: parentId, nodes: nodes)
    }
}

package extension DOMInspectParams {
    init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let nodeId = transportInt(from: dictionary["nodeId"]) else {
            throw WITransportError.invalidResponse("Invalid DOM.inspect payload.")
        }

        self.init(nodeId: nodeId)
    }
}

extension DOMInspectParams: WITransportObjectDecodable {}

private extension DOMChildNodeInsertedParams {
    init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let parentNodeId = transportInt(from: dictionary["parentNodeId"]),
              let nodeObject = dictionary["node"] else {
            throw WITransportError.invalidResponse("Invalid DOM.childNodeInserted payload.")
        }

        self.init(
            parentNodeId: parentNodeId,
            previousNodeId: transportInt(from: dictionary["previousNodeId"]),
            node: try WITransportDOMNode(wiTransportObject: nodeObject)
        )
    }
}

package extension DOMChildNodeRemovedParams {
    init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let parentNodeId = transportInt(from: dictionary["parentNodeId"]),
              let nodeId = transportInt(from: dictionary["nodeId"]) else {
            throw WITransportError.invalidResponse("Invalid DOM.childNodeRemoved payload.")
        }

        self.init(parentNodeId: parentNodeId, nodeId: nodeId)
    }
}

extension DOMChildNodeRemovedParams: WITransportObjectDecodable {}

package extension DOMChildNodeCountUpdatedParams {
    init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let nodeId = transportInt(from: dictionary["nodeId"]),
              let childNodeCount = transportInt(from: dictionary["childNodeCount"]) else {
            throw WITransportError.invalidResponse("Invalid DOM.childNodeCountUpdated payload.")
        }

        self.init(nodeId: nodeId, childNodeCount: childNodeCount)
    }
}

extension DOMChildNodeCountUpdatedParams: WITransportObjectDecodable {}

package extension DOMAttributeModifiedParams {
    init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let nodeId = transportInt(from: dictionary["nodeId"]),
              let name = transportString(from: dictionary["name"]),
              let value = transportString(from: dictionary["value"]) else {
            throw WITransportError.invalidResponse("Invalid DOM.attributeModified payload.")
        }

        self.init(nodeId: nodeId, name: name, value: value)
    }
}

extension DOMAttributeModifiedParams: WITransportObjectDecodable {}

package extension DOMAttributeRemovedParams {
    init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let nodeId = transportInt(from: dictionary["nodeId"]),
              let name = transportString(from: dictionary["name"]) else {
            throw WITransportError.invalidResponse("Invalid DOM.attributeRemoved payload.")
        }

        self.init(nodeId: nodeId, name: name)
    }
}

extension DOMAttributeRemovedParams: WITransportObjectDecodable {}

package extension DOMCharacterDataModifiedParams {
    init(wiTransportObject: Any) throws {
        guard let dictionary = transportDictionary(from: wiTransportObject),
              let nodeId = transportInt(from: dictionary["nodeId"]),
              let characterData = transportString(from: dictionary["characterData"]) else {
            throw WITransportError.invalidResponse("Invalid DOM.characterDataModified payload.")
        }

        self.init(nodeId: nodeId, characterData: characterData)
    }
}

extension DOMCharacterDataModifiedParams: WITransportObjectDecodable {}

package enum DOMTransportUpdate {
    case setChildNodes(parentNodeID: Int, nodes: [WITransportDOMNode])
    case inspect(nodeID: Int)
    case documentUpdated
    case mutation(DOMGraphMutationEvent)
    case styleSheetChanged
    case mediaQueryResultChanged
}

package struct DOMTransportEventTranslator {
    package init() {}

    package func translate(
        _ envelope: WITransportEventEnvelope,
        nodeDescriptor: (WITransportDOMNode) -> DOMGraphNodeDescriptor
    ) -> DOMTransportUpdate? {
        switch envelope.method {
        case "DOM.setChildNodes":
            guard let params = try? envelope.decodeParams(DOMSetChildNodesParams.self) else {
                return nil
            }
            return .setChildNodes(parentNodeID: params.parentId, nodes: params.nodes)
        case "DOM.inspect":
            guard let params = try? envelope.decodeParams(DOMInspectParams.self) else {
                return nil
            }
            return .inspect(nodeID: params.nodeId)
        case "DOM.documentUpdated":
            return .documentUpdated
        case "DOM.childNodeInserted":
            guard let params = try? envelope.decodeParams(DOMChildNodeInsertedParams.self) else {
                return nil
            }
            return .mutation(
                .childNodeInserted(
                    parentNodeID: params.parentNodeId,
                    previousNodeID: params.previousNodeId,
                    node: nodeDescriptor(params.node)
                )
            )
        case "DOM.childNodeRemoved":
            guard let params = try? envelope.decodeParams(DOMChildNodeRemovedParams.self) else {
                return nil
            }
            return .mutation(.childNodeRemoved(parentNodeID: params.parentNodeId, nodeID: params.nodeId))
        case "DOM.childNodeCountUpdated":
            guard let params = try? envelope.decodeParams(DOMChildNodeCountUpdatedParams.self) else {
                return nil
            }
            return .mutation(
                .childNodeCountUpdated(
                    nodeID: params.nodeId,
                    childCount: params.childNodeCount,
                    layoutFlags: nil,
                    isRendered: nil
                )
            )
        case "DOM.attributeModified":
            guard let params = try? envelope.decodeParams(DOMAttributeModifiedParams.self) else {
                return nil
            }
            return .mutation(
                .attributeModified(
                    nodeID: params.nodeId,
                    name: params.name,
                    value: params.value,
                    layoutFlags: nil,
                    isRendered: nil
                )
            )
        case "DOM.attributeRemoved":
            guard let params = try? envelope.decodeParams(DOMAttributeRemovedParams.self) else {
                return nil
            }
            return .mutation(
                .attributeRemoved(
                    nodeID: params.nodeId,
                    name: params.name,
                    layoutFlags: nil,
                    isRendered: nil
                )
            )
        case "DOM.characterDataModified":
            guard let params = try? envelope.decodeParams(DOMCharacterDataModifiedParams.self) else {
                return nil
            }
            return .mutation(
                .characterDataModified(
                    nodeID: params.nodeId,
                    value: params.characterData,
                    layoutFlags: nil,
                    isRendered: nil
                )
            )
        case "CSS.styleSheetChanged":
            return .styleSheetChanged
        case "CSS.mediaQueryResultChanged":
            return .mediaQueryResultChanged
        default:
            return nil
        }
    }
}
