import Foundation
import V2_WebInspectorCore

package enum DOMTransportAdapter {
    package static func command(for intent: DOMCommandIntent) throws -> ProtocolCommand {
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
        case let .highlightNode(targetID, nodeID):
            return ProtocolCommand(
                domain: .dom,
                method: "DOM.highlightNode",
                routing: .target(targetID),
                parametersData: try data([
                    "nodeId": nodeID.rawValue,
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
        }
    }

    @MainActor
    package static func applyTargetEvent(_ event: ProtocolEventEnvelope, to session: DOMSession) throws {
        switch event.method {
        case "Target.targetCreated":
            let params = try TransportMessageParser.decode(TargetCreatedParams.self, from: event.paramsData)
            let snapshot = session.snapshot()
            let record = params.targetInfo.record(currentMainFrameID: snapshot.currentPage?.mainFrameID)
            let makeCurrentMainPage = snapshot.currentPage == nil
                && record.kind == .page
                && record.parentFrameID == nil
                && !record.isProvisional
            session.applyTargetCreated(record, makeCurrentMainPage: makeCurrentMainPage)
        case "Target.targetDestroyed":
            let params = try TransportMessageParser.decode(TargetDestroyedParams.self, from: event.paramsData)
            session.applyTargetDestroyed(params.targetId)
        case "Target.didCommitProvisionalTarget":
            let params = try TransportMessageParser.decode(TargetCommittedParams.self, from: event.paramsData)
            let snapshotBeforeCommit = session.snapshot()
            if let oldTargetId = params.oldTargetId ?? inferredOldTargetIDForOldlessCommit(params, snapshot: snapshotBeforeCommit) {
                session.applyTargetCommitted(oldTargetID: oldTargetId, newTargetID: params.newTargetId)
            } else {
                session.applyTargetCommitted(targetID: params.newTargetId)
            }
            let snapshot = session.snapshot()
            if snapshotBeforeCommit.currentPage == nil,
               let target = snapshot.targetsByID[params.newTargetId],
               target.kind == .page,
               target.parentFrameID == nil {
                session.promoteTargetToCurrentPage(params.newTargetId)
            }
        default:
            break
        }
    }

    @MainActor
    package static func applyRuntimeEvent(_ event: ProtocolEventEnvelope, to session: DOMSession) throws {
        guard event.method == "Runtime.executionContextCreated",
              let targetID = event.targetID else {
            return
        }
        let params = try TransportMessageParser.decode(RuntimeExecutionContextCreatedParams.self, from: event.paramsData)
        session.applyExecutionContextCreated(
            .init(id: params.context.id, targetID: targetID, frameID: params.context.frameId)
        )
    }

    @MainActor
    @discardableResult
    package static func applyGetDocumentResult(
        _ result: ProtocolCommandResult,
        to session: DOMSession
    ) throws -> DOMNodeIdentifier? {
        guard let targetID = result.targetID else {
            return nil
        }
        let payload = try TransportMessageParser.decode(GetDocumentResult.self, from: result.resultData)
        return session.replaceDocumentRoot(payload.root.payload, targetID: targetID)
    }

    @MainActor
    package static func applyRequestNodeResult(
        _ result: ProtocolCommandResult,
        selectionRequestID: SelectionRequestIdentifier,
        to session: DOMSession
    ) throws -> Result<DOMNodeIdentifier, SelectionResolutionFailure> {
        guard let targetID = result.targetID else {
            return .failure(.targetMismatch(expected: ProtocolTargetIdentifier(""), received: ProtocolTargetIdentifier("")))
        }
        let payload = try TransportMessageParser.decode(RequestNodeResult.self, from: result.resultData)
        return session.applyRequestNodeResult(
            selectionRequestID: selectionRequestID,
            targetID: targetID,
            nodeID: payload.nodeId
        )
    }

    @MainActor
    package static func applyDOMEvent(_ event: ProtocolEventEnvelope, to session: DOMSession) throws {
        guard let targetID = event.targetID else {
            return
        }
        switch event.method {
        case "DOM.setChildNodes":
            let params = try TransportMessageParser.decode(SetChildNodesParams.self, from: event.paramsData)
            let snapshot = session.snapshot()
            guard let parentID = snapshot.currentNodeIDByKey[.init(targetID: targetID, nodeID: params.parentId)] else {
                return
            }
            session.applySetChildNodes(parent: parentID, children: params.nodes.map(\.payload))
        case "DOM.childNodeInserted":
            let params = try TransportMessageParser.decode(ChildNodeInsertedParams.self, from: event.paramsData)
            let snapshot = session.snapshot()
            guard let parentID = snapshot.currentNodeIDByKey[.init(targetID: targetID, nodeID: params.parentNodeId)] else {
                return
            }
            let previousSiblingID = params.previousNodeId.flatMap {
                snapshot.currentNodeIDByKey[.init(targetID: targetID, nodeID: $0)]
            }
            _ = session.applyChildInserted(parent: parentID, previousSibling: previousSiblingID, child: params.node.payload)
        case "DOM.childNodeRemoved":
            let params = try TransportMessageParser.decode(ChildNodeRemovedParams.self, from: event.paramsData)
            let snapshot = session.snapshot()
            guard let nodeID = snapshot.currentNodeIDByKey[.init(targetID: targetID, nodeID: params.nodeId)] else {
                return
            }
            session.applyNodeRemoved(nodeID)
        default:
            break
        }
    }

    private static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func highlightConfig() -> [String: Any] {
        [
            "showInfo": false,
            "contentColor": highlightColor(red: 111, green: 168, blue: 220, alpha: 0.66),
            "paddingColor": highlightColor(red: 147, green: 196, blue: 125, alpha: 0.66),
            "borderColor": highlightColor(red: 255, green: 229, blue: 153, alpha: 0.66),
            "marginColor": highlightColor(red: 246, green: 178, blue: 107, alpha: 0.66),
        ]
    }

    private static func highlightColor(red: Int, green: Int, blue: Int, alpha: Double) -> [String: Any] {
        [
            "r": red,
            "g": green,
            "b": blue,
            "a": alpha,
        ]
    }

    private static func inferredOldTargetIDForOldlessCommit(
        _ params: TargetCommittedParams,
        snapshot: DOMSessionSnapshot
    ) -> ProtocolTargetIdentifier? {
        guard params.oldTargetId == nil,
              snapshot.targetsByID[params.newTargetId] == nil else {
            return nil
        }

        let provisionalTargetIDs = snapshot.targetsByID
            .filter { $0.value.isProvisional }
            .map(\.key)
        return provisionalTargetIDs.count == 1 ? provisionalTargetIDs[0] : nil
    }
}

private struct TargetCreatedParams: Decodable {
    var targetInfo: TargetInfoPayload
}

private struct TargetInfoPayload: Decodable {
    var targetId: ProtocolTargetIdentifier
    var type: String
    var frameId: DOMFrameIdentifier?
    var parentFrameId: DOMFrameIdentifier?
    var isProvisional: Bool?
    var isPaused: Bool?

    func record(currentMainFrameID: DOMFrameIdentifier?) -> ProtocolTargetRecord {
        ProtocolTargetRecord(
            id: targetId,
            kind: targetKind(currentMainFrameID: currentMainFrameID),
            frameID: frameId,
            parentFrameID: parentFrameId,
            isProvisional: isProvisional ?? false,
            isPaused: isPaused ?? false
        )
    }

    private func targetKind(currentMainFrameID: DOMFrameIdentifier?) -> ProtocolTargetKind {
        let protocolKind = ProtocolTargetKind(protocolType: type)
        guard protocolKind == .page else {
            return protocolKind
        }
        if parentFrameId != nil {
            return .frame
        }
        if let currentMainFrameID,
           let frameId,
           frameId != currentMainFrameID {
            return .frame
        }
        if currentMainFrameID == nil,
           isProvisional == true {
            return .frame
        }
        return .page
    }
}

private struct TargetDestroyedParams: Decodable {
    var targetId: ProtocolTargetIdentifier
}

private struct TargetCommittedParams: Decodable {
    var oldTargetId: ProtocolTargetIdentifier?
    var newTargetId: ProtocolTargetIdentifier
}

private struct RuntimeExecutionContextCreatedParams: Decodable {
    struct Context: Decodable {
        var id: ExecutionContextID
        var frameId: DOMFrameIdentifier?
    }

    var context: Context
}

private struct GetDocumentResult: Decodable {
    var root: DOMNodeWirePayload
}

private struct RequestNodeResult: Decodable {
    var nodeId: DOMProtocolNodeID
}

private struct SetChildNodesParams: Decodable {
    var parentId: DOMProtocolNodeID
    var nodes: [DOMNodeWirePayload]
}

private struct ChildNodeInsertedParams: Decodable {
    var parentNodeId: DOMProtocolNodeID
    var previousNodeId: DOMProtocolNodeID?
    var node: DOMNodeWirePayload
}

private struct ChildNodeRemovedParams: Decodable {
    var nodeId: DOMProtocolNodeID
}

private final class DOMNodeWirePayload: Decodable {
    var nodeId: DOMProtocolNodeID
    var nodeType: Int
    var nodeName: String
    var localName: String?
    var nodeValue: String?
    var frameId: DOMFrameIdentifier?
    var attributes: [String]?
    var childNodeCount: Int?
    var children: [DOMNodeWirePayload]?
    var contentDocument: DOMNodeWirePayload?
    var shadowRoots: [DOMNodeWirePayload]?
    var templateContent: DOMNodeWirePayload?
    var pseudoElements: [DOMNodeWirePayload]?
    var pseudoType: String?
    var shadowRootType: String?

    var payload: DOMNodePayload {
        let pseudoElements = pseudoElements ?? []
        let beforePseudoElement = pseudoElements.first { $0.pseudoType == "before" }?.payload
        let afterPseudoElement = pseudoElements.first { $0.pseudoType == "after" }?.payload
        let otherPseudoElements = pseudoElements
            .filter { $0.pseudoType != "before" && $0.pseudoType != "after" }
            .map(\.payload)
        let regularChildren: DOMRegularChildrenPayload
        if let children {
            regularChildren = .loaded(children.map(\.payload))
        } else {
            regularChildren = .unrequested(count: childNodeCount ?? 0)
        }
        return DOMNodePayload(
            nodeID: nodeId,
            nodeType: DOMNodeType(rawValue: nodeType) ?? .element,
            nodeName: nodeName,
            localName: localName ?? "",
            nodeValue: nodeValue ?? "",
            frameID: frameId,
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

    private func attributePairs(_ values: [String]) -> [DOMAttribute] {
        stride(from: 0, to: values.count, by: 2).map { index in
            DOMAttribute(
                name: values[index],
                value: values.indices.contains(index + 1) ? values[index + 1] : ""
            )
        }
    }
}
