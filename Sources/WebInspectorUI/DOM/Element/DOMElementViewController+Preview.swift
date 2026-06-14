#if canImport(UIKit)
import WebInspectorCore
import WebInspectorTransport
import UIKit

#Preview("DOM Element") {
    DOMElementViewControllerPreview.makeViewController()
}

@MainActor
private enum DOMElementViewControllerPreview {
    private static let targetID = ProtocolTarget.ID("preview-page")
    private static let frameID = DOMFrame.ID("preview-frame")
    private static let styleSheetID = CSSStyleSheet.ID("preview")
    private static let styleID = CSSStyle.ID(styleSheetID: styleSheetID, ordinal: 0)
    private static let ruleID = CSSRule.ID(styleSheetID: styleSheetID, ordinal: 0)
    private static let previewCSSText = "margin: 0;\nbox-sizing: border-box;\nfont-size: 12px;"

    static func makeViewController() -> UINavigationController {
        let dom = DOMPreviewFixtures.makeDOMSession()
        dom.applyTargetCreated(
            ProtocolTarget.Record(
                id: targetID,
                kind: .page,
                frameID: frameID,
                capabilities: .pageDefault
            ),
            makeCurrentMainPage: true
        )
        if let body = firstElement(named: "body", in: dom) {
            dom.selectNode(body.id)
        }

        let css = dom.elementStyles
        if case let .success(identity) = dom.selectedCSSNodeStyleIdentity(),
           let token = css.beginRefresh(identity: identity) {
            let style = previewStylePayload(styleID: styleID, cssText: previewCSSText)
            let matched = previewMatchedStyles(ruleID: ruleID, style: style)
            let inline = CSSStyle.InlineStylesPayload()
            let computed: [CSSComputedStyleProperty.Payload] = []
            css.applyRefresh(
                token: token,
                matched: matched,
                inline: inline,
                computed: computed
            )
        }

        let inspection = AttachedInspection(dom: dom)
        installPreviewTransport(on: dom)
        return UINavigationController(rootViewController: DOMElementViewController(inspection: inspection))
    }

    private static func installPreviewTransport(on dom: DOMSession) {
        let replies = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        let backend = DOMElementViewControllerPreviewTransportBackend(
            styleID: styleID,
            ruleID: ruleID,
            cssText: previewCSSText,
            replyContinuation: replies.continuation
        )
        let transport = TransportSession(backend: backend, responseTimeout: nil)
        Task {
            for await message in replies.stream {
                await transport.receiveRootMessage(message)
            }
        }
        seedPreviewTarget(in: transport)
        let channel = ProtocolCommandChannel(
            transport: transport,
            isCurrent: { true },
            isAttached: { true },
            appliedSequence: { 0 },
            shouldEnableCompatibilityCSS: { _ in false },
            markTargetDomainEnabled: { _, _ in }
        )
        dom.bindProtocolChannel(channel, recordError: { _ in })
    }

    private static func seedPreviewTarget(in transport: TransportSession) {
        let message = targetCreatedMessage()
        Task {
            await transport.receiveRootMessage(message)
        }
    }

    nonisolated private static func previewProperties(from styleText: String) -> [CSSProperty.Payload] {
        styleText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap(previewProperty(from:))
    }

    nonisolated private static func previewStylePayload(
        styleID: CSSStyle.ID,
        cssText: String
    ) -> CSSStyle.Payload {
        let properties = previewProperties(from: cssText)
        return CSSStyle.Payload(
            id: styleID,
            cssProperties: properties,
            cssText: cssText
        )
    }

    nonisolated private static func previewMatchedStyles(
        ruleID: CSSRule.ID,
        style: CSSStyle.Payload
    ) -> CSSStyle.MatchedStylesPayload {
        let selector = CSSRule.Selector(text: "body")
        let selectorList = CSSRule.SelectorList(selectors: [selector], text: "body")
        let rule = CSSRule.Payload(
            id: ruleID,
            selectorList: selectorList,
            sourceURL: "preview.css",
            sourceLine: 1,
            origin: .author,
            style: style
        )
        let matchedRules = [
            CSSRule.MatchPayload(rule: rule, matchingSelectors: [0]),
        ]
        return CSSStyle.MatchedStylesPayload(matchedRules: matchedRules)
    }

    nonisolated private static func previewProperty(from declarationText: String) -> CSSProperty.Payload? {
        let disabled = declarationText.hasPrefix("/*") && declarationText.hasSuffix("*/")
        let sourceText = disabled
            ? String(declarationText.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            : declarationText
        guard let separatorIndex = sourceText.firstIndex(of: ":") else {
            return nil
        }
        let name = sourceText[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = sourceText[sourceText.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(";") {
            value.removeLast()
        }
        let status: CSSProperty.Status
        if disabled {
            status = .disabled
        } else if name == "font-size" {
            status = .inactive
        } else {
            status = .active
        }
        return CSSProperty.Payload(
            name: name,
            value: value,
            text: declarationText,
            status: status
        )
    }

    private static func firstElement(named localName: String, in dom: DOMSession) -> DOMNode? {
        guard let rootNode = dom.currentPageRootNode else {
            return nil
        }
        var stack = [rootNode]
        while let node = stack.popLast() {
            if node.localName == localName {
                return node
            }
            stack.append(contentsOf: dom.visibleDOMTreeChildren(of: node).reversed())
        }
        return nil
    }

    private static func targetCreatedMessage() -> String {
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(targetID.rawValue)","type":"page","frameId":"\#(frameID.rawValue)","domains":["DOM","Runtime","Target","Inspector","Network","CSS"],"isProvisional":false}}}"#
    }

    private actor DOMElementViewControllerPreviewTransportBackend: TransportBackend {
        private struct TargetCommand {
            var targetID: ProtocolTarget.ID
            var commandID: UInt64
            var method: String
            var message: String
        }

        private struct TargetSendMessageEnvelope: Decodable {
            var method: String
            var params: TargetSendMessageParameters
        }

        private struct TargetSendMessageParameters: Decodable {
            var targetId: String
            var message: String
        }

        private struct TargetInnerCommandEnvelope: Decodable {
            var id: UInt64
            var method: String
        }

        private struct SetStyleTextCommand: Decodable {
            var params: SetStyleTextParameters
        }

        private struct SetStyleTextParameters: Decodable {
            var text: String
        }

        private struct TargetDispatchMessage: Encodable {
            var method = "Target.dispatchMessageFromTarget"
            var params: TargetDispatchParameters
        }

        private struct TargetDispatchParameters: Encodable {
            var targetId: String
            var message: String
        }

        private struct SetStyleTextResult: Encodable {
            var style: CSSStyle.Payload
        }

        private struct ComputedStyleResult: Encodable {
            var computedStyle: [CSSComputedStyleProperty.Payload]
        }

        private let styleID: CSSStyle.ID
        private let ruleID: CSSRule.ID
        private let replyContinuation: AsyncStream<String>.Continuation
        private var cssText: String
        private var properties: [CSSProperty.Payload]

        init(
            styleID: CSSStyle.ID,
            ruleID: CSSRule.ID,
            cssText: String,
            replyContinuation: AsyncStream<String>.Continuation
        ) {
            self.styleID = styleID
            self.ruleID = ruleID
            self.replyContinuation = replyContinuation
            self.cssText = cssText
            self.properties = DOMElementViewControllerPreview.previewProperties(from: cssText)
        }

        func sendJSONString(_ message: String) async throws {
            guard let command = Self.targetCommand(from: message) else {
                return
            }

            let resultJSON: String
            switch command.method {
            case "CSS.setStyleText":
                guard let text = Self.setStyleText(from: command.message) else {
                    return
                }
                resultJSON = try Self.jsonString(
                    SetStyleTextResult(style: updateStyleText(text))
                )
            case "CSS.getMatchedStylesForNode":
                resultJSON = try Self.jsonString(matchedStyles())
            case "CSS.getInlineStylesForNode":
                resultJSON = try Self.jsonString(CSSStyle.InlineStylesPayload())
            case "CSS.getComputedStyleForNode":
                resultJSON = try Self.jsonString(ComputedStyleResult(computedStyle: []))
            default:
                resultJSON = "{}"
            }

            sendTargetReply(
                targetID: command.targetID,
                commandID: command.commandID,
                resultJSON: resultJSON
            )
        }

        func detach() async {
            replyContinuation.finish()
        }

        private func updateStyleText(_ text: String) -> CSSStyle.Payload {
            cssText = text
            properties = DOMElementViewControllerPreview.previewProperties(from: text)
            return currentStylePayload()
        }

        private func matchedStyles() -> CSSStyle.MatchedStylesPayload {
            DOMElementViewControllerPreview.previewMatchedStyles(
                ruleID: ruleID,
                style: currentStylePayload()
            )
        }

        private func currentStylePayload() -> CSSStyle.Payload {
            CSSStyle.Payload(
                id: styleID,
                cssProperties: properties,
                cssText: cssText
            )
        }

        private func sendTargetReply(
            targetID: ProtocolTarget.ID,
            commandID: UInt64,
            resultJSON: String
        ) {
            let targetMessage = #"{"id":\#(commandID),"result":\#(resultJSON)}"#
            let rootMessage = TargetDispatchMessage(
                params: TargetDispatchParameters(
                    targetId: targetID.rawValue,
                    message: targetMessage
                )
            )
            guard let data = try? JSONEncoder().encode(rootMessage),
                  let message = String(data: data, encoding: .utf8) else {
                return
            }
            replyContinuation.yield(message)
        }

        private static func targetCommand(from message: String) -> TargetCommand? {
            guard let data = message.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(TargetSendMessageEnvelope.self, from: data),
                  envelope.method == "Target.sendMessageToTarget",
                  let innerData = envelope.params.message.data(using: .utf8),
                  let inner = try? JSONDecoder().decode(TargetInnerCommandEnvelope.self, from: innerData) else {
                return nil
            }
            return TargetCommand(
                targetID: ProtocolTarget.ID(envelope.params.targetId),
                commandID: inner.id,
                method: inner.method,
                message: envelope.params.message
            )
        }

        private static func setStyleText(from message: String) -> String? {
            guard let data = message.data(using: .utf8),
                  let command = try? JSONDecoder().decode(SetStyleTextCommand.self, from: data) else {
                return nil
            }
            return command.params.text
        }

        private static func jsonString<T: Encodable>(_ value: T) throws -> String {
            let data = try JSONEncoder().encode(value)
            return String(decoding: data, as: UTF8.self)
        }
    }
}
#endif
