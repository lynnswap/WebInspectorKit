import Foundation
import WebInspectorTransport

package struct CSSProtocolCommands {
    package func command(for intent: CSSCommandIntent) throws -> ProtocolCommand {
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

    package func matchedStyles(from result: ProtocolCommand.Result) throws -> CSSMatchedStylesPayload {
        try TransportMessageParser.decode(CSSMatchedStylesPayload.self, from: result.resultData)
    }

    package func inlineStyles(from result: ProtocolCommand.Result) throws -> CSSInlineStylesPayload {
        try TransportMessageParser.decode(CSSInlineStylesPayload.self, from: result.resultData)
    }

    package func computedStyles(from result: ProtocolCommand.Result) throws -> [CSSComputedStylePropertyPayload] {
        let payload = try TransportMessageParser.decode(ComputedStyleResult.self, from: result.resultData)
        return payload.computedStyle
    }

    package func setStyleTextResult(from result: ProtocolCommand.Result) throws -> CSSStylePayload {
        let payload = try TransportMessageParser.decode(SetStyleTextResult.self, from: result.resultData)
        return payload.style
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private func styleIDPayload(_ styleID: CSSStyleIdentifier) -> [String: Any] {
        [
            "styleSheetId": styleID.styleSheetID.rawValue,
            "ordinal": styleID.ordinal,
        ]
    }
}

@MainActor
package protocol CSSProtocolEventHandler: AnyObject {
    func cssStyleSheetChanged(targetID: ProtocolTarget.ID)
    func cssStyleSheetRemoved(styleSheetID: CSSStyleSheetIdentifier, targetID: ProtocolTarget.ID)
    func cssStyleSheetAdded(_ header: CSSStyleSheetHeaderPayload, targetID: ProtocolTarget.ID)
    func cssMediaQueryResultChanged(targetID: ProtocolTarget.ID)
    func cssNodeLayoutFlagsChanged(targetID: ProtocolTarget.ID, nodeID: DOMNode.ProtocolID)
}

@MainActor
package final class CSSProtocolEventDispatcher: ProtocolDomainEventDispatcher {
    private weak var handler: (any CSSProtocolEventHandler)?

    package init(handler: any CSSProtocolEventHandler) {
        self.handler = handler
    }

    package var domain: ProtocolDomain { .css }

    package func dispatch(_ event: ProtocolEvent) async throws {
        guard event.domain == .css,
              let targetID = event.targetID,
              let handler else {
            return
        }

        switch event.method {
        case "CSS.styleSheetChanged":
            handler.cssStyleSheetChanged(targetID: targetID)
        case "CSS.styleSheetRemoved":
            let params = try TransportMessageParser.decode(StyleSheetIdentifierParams.self, from: event.paramsData)
            handler.cssStyleSheetRemoved(styleSheetID: params.styleSheetId, targetID: targetID)
        case "CSS.styleSheetAdded":
            let params = try TransportMessageParser.decode(StyleSheetAddedParams.self, from: event.paramsData)
            handler.cssStyleSheetAdded(params.header, targetID: targetID)
        case "CSS.mediaQueryResultChanged":
            handler.cssMediaQueryResultChanged(targetID: targetID)
        case "CSS.nodeLayoutFlagsChanged":
            let params = try TransportMessageParser.decode(NodeLayoutFlagsChangedParams.self, from: event.paramsData)
            handler.cssNodeLayoutFlagsChanged(targetID: targetID, nodeID: params.nodeId)
        default:
            break
        }
    }
}

extension CSSSession: CSSProtocolEventHandler {
    package func cssStyleSheetChanged(targetID: ProtocolTarget.ID) {
        markNeedsRefresh(targetID: targetID)
    }

    package func cssStyleSheetRemoved(styleSheetID: CSSStyleSheetIdentifier, targetID: ProtocolTarget.ID) {
        removeStyleSheetHeader(styleSheetID: styleSheetID, targetID: targetID)
        markNeedsRefresh(targetID: targetID, styleSheetID: styleSheetID)
    }

    package func cssStyleSheetAdded(_ header: CSSStyleSheetHeaderPayload, targetID: ProtocolTarget.ID) {
        registerStyleSheetHeader(header, targetID: targetID)
        markNeedsRefresh(targetID: targetID)
    }

    package func cssMediaQueryResultChanged(targetID: ProtocolTarget.ID) {
        markNeedsRefresh(targetID: targetID)
    }

    package func cssNodeLayoutFlagsChanged(targetID: ProtocolTarget.ID, nodeID: DOMNode.ProtocolID) {
        markNeedsRefresh(targetID: targetID, nodeID: nodeID)
    }
}

extension DOMSession: CSSProtocolEventHandler {
    package func cssStyleSheetChanged(targetID: ProtocolTarget.ID) {
        elementStyles.cssStyleSheetChanged(targetID: targetID)
        reconcileSelectedNodeStyleHydrationIfNeeded()
    }

    package func cssStyleSheetRemoved(styleSheetID: CSSStyleSheetIdentifier, targetID: ProtocolTarget.ID) {
        elementStyles.cssStyleSheetRemoved(styleSheetID: styleSheetID, targetID: targetID)
        reconcileSelectedNodeStyleHydrationIfNeeded()
    }

    package func cssStyleSheetAdded(_ header: CSSStyleSheetHeaderPayload, targetID: ProtocolTarget.ID) {
        elementStyles.cssStyleSheetAdded(header, targetID: targetID)
        reconcileSelectedNodeStyleHydrationIfNeeded()
    }

    package func cssMediaQueryResultChanged(targetID: ProtocolTarget.ID) {
        elementStyles.cssMediaQueryResultChanged(targetID: targetID)
        reconcileSelectedNodeStyleHydrationIfNeeded()
    }

    package func cssNodeLayoutFlagsChanged(targetID: ProtocolTarget.ID, nodeID: DOMNode.ProtocolID) {
        elementStyles.cssNodeLayoutFlagsChanged(targetID: targetID, nodeID: nodeID)
        reconcileSelectedNodeStyleHydrationIfNeeded()
    }
}

private struct StyleSheetIdentifierParams: Decodable {
    var styleSheetId: CSSStyleSheetIdentifier
}

private struct StyleSheetAddedParams: Decodable {
    var header: CSSStyleSheetHeaderPayload
}

private struct ComputedStyleResult: Decodable {
    var computedStyle: [CSSComputedStylePropertyPayload]
}

private struct SetStyleTextResult: Decodable {
    var style: CSSStylePayload
}

private struct NodeLayoutFlagsChangedParams: Decodable {
    var nodeId: DOMNode.ProtocolID
}
