import Foundation
import WebInspectorTransport

package struct DOMProtocolCommands {
    package func command(for intent: DOMCommand.Intent) throws -> ProtocolCommand {
        switch intent {
        case let .getDocument(targetID):
            return ProtocolCommand(
                domain: .dom,
                method: "DOM.getDocument",
                routing: .target(targetID)
            )
        case let .requestChildNodes(targetID, nodeID, depth):
            return ProtocolCommand(
                domain: .dom,
                method: "DOM.requestChildNodes",
                routing: .target(targetID),
                parametersData: try data([
                    "nodeId": nodeID.rawValue,
                    "depth": max(1, depth),
                ])
            )
        case let .requestNode(_, targetID, objectID):
            return ProtocolCommand(
                domain: .dom,
                method: "DOM.requestNode",
                routing: .target(targetID),
                parametersData: try data(["objectId": objectID])
            )
        case let .highlightNode(target):
            return ProtocolCommand(
                domain: .dom,
                method: "DOM.highlightNode",
                routing: .target(target.commandTargetID),
                parametersData: try data([
                    "nodeId": nodeIDValue(target.commandNodeID),
                    "reveal": false,
                    "highlightConfig": highlightConfig(),
                ])
            )
        case let .hideHighlight(targetID):
            return ProtocolCommand(
                domain: .dom,
                method: "DOM.hideHighlight",
                routing: .target(targetID)
            )
        case let .setInspectModeEnabled(targetID, enabled):
            var parameters: [String: Any] = ["enabled": enabled]
            if enabled {
                parameters["highlightConfig"] = highlightConfig()
            }
            return ProtocolCommand(
                domain: .dom,
                method: "DOM.setInspectModeEnabled",
                routing: .target(targetID),
                parametersData: try data(parameters)
            )
        case let .getOuterHTML(target):
            return ProtocolCommand(
                domain: .dom,
                method: "DOM.getOuterHTML",
                routing: .target(target.commandTargetID),
                parametersData: try data(["nodeId": nodeIDValue(target.commandNodeID)])
            )
        case let .removeNode(target):
            return ProtocolCommand(
                domain: .dom,
                method: "DOM.removeNode",
                routing: .target(target.commandTargetID),
                parametersData: try data(["nodeId": nodeIDValue(target.commandNodeID)])
            )
        case let .undo(targetID):
            return ProtocolCommand(
                domain: .dom,
                method: "DOM.undo",
                routing: .target(targetID)
            )
        case let .redo(targetID):
            return ProtocolCommand(
                domain: .dom,
                method: "DOM.redo",
                routing: .target(targetID)
            )
        }
    }

    @MainActor
    @discardableResult
    package func applyGetDocumentResult(
        _ result: ProtocolCommand.Result,
        to session: DOMSession
    ) throws -> DOMNode.ID? {
        guard let targetID = result.targetID else {
            return nil
        }
        let payload = try TransportMessageParser.decode(GetDocumentResult.self, from: result.resultData)
        return session.replaceDocumentRoot(payload.root.payload, targetID: targetID)
    }

    @MainActor
    package func applyRequestNodeResult(
        _ result: ProtocolCommand.Result,
        selectionRequestID: DOMSelection.Request.ID,
        to session: DOMSession
    ) throws -> DOMNode.RequestResolution {
        guard let targetID = result.targetID else {
            return .failed(.targetMismatch(expected: ProtocolTarget.ID(""), received: ProtocolTarget.ID("")))
        }
        let payload = try TransportMessageParser.decode(RequestNodeResult.self, from: result.resultData)
        return session.applyRequestNodeResult(
            selectionRequestID: selectionRequestID,
            targetID: targetID,
            nodeID: payload.nodeId
        )
    }

    package func outerHTML(from result: ProtocolCommand.Result) throws -> String {
        let payload = try TransportMessageParser.decode(GetOuterHTMLResult.self, from: result.resultData)
        return payload.outerHTML
    }

    package func inspectEvent(from event: ProtocolEvent) throws -> DOMInspectEvent? {
        switch event.method {
        case "DOM.inspect":
            guard let targetID = event.targetID else {
                return nil
            }
            let payload = try TransportMessageParser.decode(DOMInspectParams.self, from: event.paramsData)
            return .protocolNode(targetID: targetID, nodeID: payload.nodeId)
        case "Inspector.inspect":
            let payload = try TransportMessageParser.decode(InspectorInspectParams.self, from: event.paramsData)
            return .remoteObject(
                targetID: event.targetID,
                remoteObject: DOMInspectEvent.RemoteObject(
                    objectID: payload.object.objectId,
                    injectedScriptID: injectedScriptID(from: payload.object.objectId)
                )
            )
        default:
            return nil
        }
    }

    @MainActor
    package func applyDOMEvent(_ event: ProtocolEvent, to session: DOMSession) throws {
        guard let targetID = event.targetID else {
            return
        }
        switch event.method {
        case "DOM.setChildNodes":
            let params = try TransportMessageParser.decode(SetChildNodesParams.self, from: event.paramsData)
            if params.parentId.rawValue == 0 {
                guard let detachedRoot = params.nodes.first?.payload else {
                    return
                }
                session.applyDetachedRoot(targetID: targetID, payload: detachedRoot, eventSequence: event.sequence)
                return
            }
            if let parentID = session.currentNodeID(targetID: targetID, rawNodeID: params.parentId) {
                session.applySetChildNodes(parent: parentID, children: params.nodes.map(\.payload), eventSequence: event.sequence)
            } else {
                session.applySetChildNodes(
                    targetID: targetID,
                    parentRawNodeID: params.parentId,
                    children: params.nodes.map(\.payload),
                    eventSequence: event.sequence
                )
            }
        case "DOM.childNodeInserted":
            let params = try TransportMessageParser.decode(ChildNodeInsertedParams.self, from: event.paramsData)
            guard let parentID = session.currentNodeID(targetID: targetID, rawNodeID: params.parentNodeId) else {
                return
            }
            let previousSiblingID = params.previousNodeId.flatMap {
                session.currentNodeID(targetID: targetID, rawNodeID: $0)
            }
            _ = session.applyChildInserted(parent: parentID, previousSibling: previousSiblingID, child: params.node.payload)
        case "DOM.childNodeRemoved":
            let params = try TransportMessageParser.decode(ChildNodeRemovedParams.self, from: event.paramsData)
            guard let nodeID = session.currentNodeID(targetID: targetID, rawNodeID: params.nodeId) else {
                return
            }
            session.applyNodeRemoved(nodeID)
        case "DOM.childNodeCountUpdated":
            let params = try TransportMessageParser.decode(ChildNodeCountUpdatedParams.self, from: event.paramsData)
            guard let nodeID = session.currentNodeID(targetID: targetID, rawNodeID: params.nodeId) else {
                return
            }
            session.applyChildNodeCountUpdated(nodeID, count: params.childNodeCount)
        case "DOM.attributeModified":
            let params = try TransportMessageParser.decode(AttributeModifiedParams.self, from: event.paramsData)
            guard let nodeID = session.currentNodeID(targetID: targetID, rawNodeID: params.nodeId) else {
                return
            }
            session.applyAttributeModified(nodeID, name: params.name, value: params.value)
        case "DOM.attributeRemoved":
            let params = try TransportMessageParser.decode(AttributeRemovedParams.self, from: event.paramsData)
            guard let nodeID = session.currentNodeID(targetID: targetID, rawNodeID: params.nodeId) else {
                return
            }
            session.applyAttributeRemoved(nodeID, name: params.name)
        default:
            break
        }
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private func nodeIDValue(_ nodeID: DOMCommand.NodeID) -> Any {
        switch nodeID {
        case let .protocolNode(nodeID):
            return nodeID.rawValue
        case let .scoped(targetID, nodeID):
            return "\(targetID.rawValue):\(nodeID.rawValue)"
        }
    }

    private func highlightConfig() -> [String: Any] {
        [
            "showInfo": false,
            "contentColor": highlightColor(red: 111, green: 168, blue: 220, alpha: 0.66),
            "paddingColor": highlightColor(red: 147, green: 196, blue: 125, alpha: 0.66),
            "borderColor": highlightColor(red: 255, green: 229, blue: 153, alpha: 0.66),
            "marginColor": highlightColor(red: 246, green: 178, blue: 107, alpha: 0.66),
        ]
    }

    private func highlightColor(red: Int, green: Int, blue: Int, alpha: Double) -> [String: Any] {
        [
            "r": red,
            "g": green,
            "b": blue,
            "a": alpha,
        ]
    }

    private func injectedScriptID(from objectID: String) -> RuntimeContext.ID? {
        guard let data = objectID.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let injectedScriptID = object["injectedScriptId"] as? Int {
            return RuntimeContext.ID(injectedScriptID)
        }
        if let injectedScriptID = object["injectedScriptId"] as? NSNumber,
           CFGetTypeID(injectedScriptID) != CFBooleanGetTypeID() {
            return RuntimeContext.ID(injectedScriptID.intValue)
        }
        if let injectedScriptID = object["injectedScriptId"] as? String,
           let rawValue = Int(injectedScriptID) {
            return RuntimeContext.ID(rawValue)
        }
        return nil
    }
}

@MainActor
package final class DOMProtocolEventDispatcher: ProtocolDomainEventDispatcher {
    private weak var session: DOMSession?

    package init(session: DOMSession) {
        self.session = session
    }

    package var domain: ProtocolDomain { .dom }

    package func dispatch(_ event: ProtocolEvent) async throws {
        try await session?.handleDOMProtocolEvent(event)
    }
}

@MainActor
package final class InspectorProtocolEventDispatcher: ProtocolDomainEventDispatcher {
    private weak var session: DOMSession?

    package init(session: DOMSession) {
        self.session = session
    }

    package var domain: ProtocolDomain { .inspector }

    package func dispatch(_ event: ProtocolEvent) async throws {
        guard let session,
              let inspectEvent = try session.inspectEvent(from: event) else {
            return
        }
        await session.handleInspectProtocolEvent(inspectEvent)
    }
}

extension DOMSession: RuntimeProtocolEventHandler {
    package func runtimeExecutionContextCreated(_ record: RuntimeContext.Record) {
        applyExecutionContextCreated(record)
    }

    package func runtimeExecutionContextDestroyed(_ key: RuntimeContext.Key) {
        applyExecutionContextDestroyed(key)
    }

    package func runtimeExecutionContextsCleared(runtimeAgentTargetID: ProtocolTarget.ID) {
        applyExecutionContextsCleared(runtimeAgentTargetID: runtimeAgentTargetID)
    }
}

private struct GetDocumentResult: Decodable {
    var root: DOMNodeWirePayload
}

private struct RequestNodeResult: Decodable {
    var nodeId: DOMNode.ProtocolID
}

private struct GetOuterHTMLResult: Decodable {
    var outerHTML: String
}

private struct DOMInspectParams: Decodable {
    var nodeId: DOMNode.ProtocolID
}

private struct InspectorInspectParams: Decodable {
    var object: InspectorRemoteObject
}

private struct InspectorRemoteObject: Decodable {
    var objectId: String
}

private struct SetChildNodesParams: Decodable {
    var parentId: DOMNode.ProtocolID
    var nodes: [DOMNodeWirePayload]
}

private struct ChildNodeInsertedParams: Decodable {
    var parentNodeId: DOMNode.ProtocolID
    var previousNodeId: DOMNode.ProtocolID?
    var node: DOMNodeWirePayload
}

private struct ChildNodeRemovedParams: Decodable {
    var nodeId: DOMNode.ProtocolID
}

private struct ChildNodeCountUpdatedParams: Decodable {
    var nodeId: DOMNode.ProtocolID
    var childNodeCount: Int
}

private struct AttributeModifiedParams: Decodable {
    var nodeId: DOMNode.ProtocolID
    var name: String
    var value: String
}

private struct AttributeRemovedParams: Decodable {
    var nodeId: DOMNode.ProtocolID
    var name: String
}

private final class DOMNodeWirePayload: Decodable {
    var nodeId: DOMNode.ProtocolID
    var nodeType: Int
    var nodeName: String
    var localName: String?
    var nodeValue: String?
    var frameId: DOMFrame.ID?
    var documentURL: String?
    var baseURL: String?
    var attributes: [String]?
    var childNodeCount: Int?
    var children: [DOMNodeWirePayload]?
    var contentDocument: DOMNodeWirePayload?
    var shadowRoots: [DOMNodeWirePayload]?
    var templateContent: DOMNodeWirePayload?
    var pseudoElements: [DOMNodeWirePayload]?
    var pseudoType: String?
    var shadowRootType: String?

    var payload: DOMNode.Payload {
        let pseudoElements = pseudoElements ?? []
        let beforePseudoElement = pseudoElements.first { $0.pseudoType == "before" }?.payload
        let afterPseudoElement = pseudoElements.first { $0.pseudoType == "after" }?.payload
        let otherPseudoElements = pseudoElements
            .filter { $0.pseudoType != "before" && $0.pseudoType != "after" }
            .map(\.payload)
        let regularChildren: DOMNode.ChildrenPayload
        if let children {
            regularChildren = .loaded(children.map(\.payload))
        } else {
            regularChildren = .unrequested(count: childNodeCount ?? 0)
        }
        return DOMNode.Payload(
            nodeID: nodeId,
            nodeType: DOMNode.Kind(rawValue: nodeType) ?? .element,
            nodeName: nodeName,
            localName: localName ?? "",
            nodeValue: nodeValue ?? "",
            ownerFrameID: frameId,
            documentURL: documentURL,
            baseURL: baseURL,
            attributes: attributePairs(attributes ?? []),
            regularChildren: regularChildren,
            contentDocument: contentDocument?.payload,
            shadowRoots: shadowRoots?.map(\.payload) ?? [],
            templateContent: templateContent?.payload,
            beforePseudoElement: beforePseudoElement,
            otherPseudoElements: otherPseudoElements,
            afterPseudoElement: afterPseudoElement,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType
        )
    }

    private func attributePairs(_ values: [String]) -> [DOMNode.Attribute] {
        stride(from: 0, to: values.count, by: 2).map { index in
            DOMNode.Attribute(
                name: values[index],
                value: values.indices.contains(index + 1) ? values[index + 1] : ""
            )
        }
    }
}
