import Foundation
import WebInspectorCore

package enum CSSTransportAdapter {
    package static func command(for intent: CSSCommandIntent) throws -> ProtocolCommand {
        switch intent {
        case let .enable(targetID):
            return ProtocolCommand(
                domain: .css,
                method: "CSS.enable",
                routing: .target(targetID)
            )
        case let .getMatchedStyles(identity, includePseudo, includeInherited):
            return ProtocolCommand(
                domain: .css,
                method: "CSS.getMatchedStylesForNode",
                routing: .target(identity.targetID),
                parametersData: try data([
                    "nodeId": identity.protocolNodeID.rawValue,
                    "includePseudo": includePseudo,
                    "includeInherited": includeInherited,
                ])
            )
        case let .getInlineStyles(identity):
            return ProtocolCommand(
                domain: .css,
                method: "CSS.getInlineStylesForNode",
                routing: .target(identity.targetID),
                parametersData: try data(["nodeId": identity.protocolNodeID.rawValue])
            )
        case let .getComputedStyle(identity):
            return ProtocolCommand(
                domain: .css,
                method: "CSS.getComputedStyleForNode",
                routing: .target(identity.targetID),
                parametersData: try data(["nodeId": identity.protocolNodeID.rawValue])
            )
        case let .setStyleText(targetID, styleID, text):
            return ProtocolCommand(
                domain: .css,
                method: "CSS.setStyleText",
                routing: .target(targetID),
                parametersData: try data([
                    "styleId": styleIDPayload(styleID),
                    "text": text,
                ])
            )
        }
    }

    package static func matchedStyles(from result: ProtocolCommandResult) throws -> CSSMatchedStylesPayload {
        try TransportMessageParser.decode(CSSMatchedStylesPayload.self, from: result.resultData)
    }

    package static func inlineStyles(from result: ProtocolCommandResult) throws -> CSSInlineStylesPayload {
        try TransportMessageParser.decode(CSSInlineStylesPayload.self, from: result.resultData)
    }

    package static func computedStyles(from result: ProtocolCommandResult) throws -> [CSSComputedStyleProperty] {
        let payload = try TransportMessageParser.decode(ComputedStyleResult.self, from: result.resultData)
        return payload.computedStyle
    }

    package static func setStyleTextResult(from result: ProtocolCommandResult) throws -> CSSStyle {
        let payload = try TransportMessageParser.decode(SetStyleTextResult.self, from: result.resultData)
        return payload.style
    }

    @MainActor
    package static func applyCSSEvent(_ event: ProtocolEventEnvelope, to session: CSSSession) throws {
        guard event.domain == .css,
              let targetID = event.targetID else {
            return
        }

        switch event.method {
        case "CSS.styleSheetChanged",
             "CSS.styleSheetAdded",
             "CSS.styleSheetRemoved",
             "CSS.mediaQueryResultChanged":
            session.markNeedsRefresh(targetID: targetID)
        case "CSS.nodeLayoutFlagsChanged":
            let params = try TransportMessageParser.decode(NodeLayoutFlagsChangedParams.self, from: event.paramsData)
            session.markNeedsRefresh(targetID: targetID, nodeID: params.nodeId)
        default:
            break
        }
    }

    private static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func styleIDPayload(_ styleID: CSSStyleIdentifier) -> [String: Any] {
        [
            "styleSheetId": styleID.styleSheetID.rawValue,
            "ordinal": styleID.ordinal,
        ]
    }
}

private struct ComputedStyleResult: Decodable {
    var computedStyle: [CSSComputedStyleProperty]
}

private struct SetStyleTextResult: Decodable {
    var style: CSSStyle
}

private struct NodeLayoutFlagsChangedParams: Decodable {
    var nodeId: DOMProtocolNodeID
}
