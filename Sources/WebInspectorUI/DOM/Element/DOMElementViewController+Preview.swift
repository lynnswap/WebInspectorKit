#if canImport(UIKit)
import WebInspectorCore
import WebInspectorTransport
import UIKit

#Preview("DOM Element") {
    DOMElementViewControllerPreview.makeViewController()
}

@MainActor
private enum DOMElementViewControllerPreview {
    private static let targetID = ProtocolTargetIdentifier("preview-page")
    private static let frameID = DOMFrameIdentifier("preview-frame")
    private static let styleSheetID = CSSStyleSheetIdentifier("preview")
    private static let styleID = CSSStyleIdentifier(styleSheetID: styleSheetID, ordinal: 0)
    private static let ruleID = CSSRuleIdentifier(styleSheetID: styleSheetID, ordinal: 0)
    private static let previewCSSText = "margin: 0;\nbox-sizing: border-box;\nfont-size: 12px;"

    static func makeViewController() -> UINavigationController {
        let dom = DOMPreviewFixtures.makeDOMSession()
        dom.applyTargetCreated(
            ProtocolTargetRecord(
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
            let inline = CSSInlineStylesPayload()
            let computed: [CSSComputedStylePropertyPayload] = []
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
        let backend = DOMElementViewControllerPreviewTransportBackend(
            styleID: styleID,
            ruleID: ruleID,
            cssText: previewCSSText
        )
        let transport = TransportSession(backend: backend, responseTimeout: nil)
        backend.transport = transport
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

    nonisolated private static func previewProperties(from styleText: String) -> [CSSPropertyPayload] {
        styleText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap(previewProperty(from:))
    }

    nonisolated private static func previewStylePayload(
        styleID: CSSStyleIdentifier,
        cssText: String
    ) -> CSSStylePayload {
        let properties = previewProperties(from: cssText)
        return CSSStylePayload(
            id: styleID,
            cssProperties: properties,
            cssText: cssText
        )
    }

    nonisolated private static func previewMatchedStyles(
        ruleID: CSSRuleIdentifier,
        style: CSSStylePayload
    ) -> CSSMatchedStylesPayload {
        let selector = CSSSelector(text: "body")
        let selectorList = CSSSelectorList(selectors: [selector], text: "body")
        let rule = CSSRulePayload(
            id: ruleID,
            selectorList: selectorList,
            sourceURL: "preview.css",
            sourceLine: 1,
            origin: .author,
            style: style
        )
        let matchedRules = [
            CSSRuleMatchPayload(rule: rule, matchingSelectors: [0]),
        ]
        return CSSMatchedStylesPayload(matchedRules: matchedRules)
    }

    nonisolated private static func previewProperty(from declarationText: String) -> CSSPropertyPayload? {
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
        let status: CSSPropertyStatus
        if disabled {
            status = .disabled
        } else if name == "font-size" {
            status = .inactive
        } else {
            status = .active
        }
        return CSSPropertyPayload(
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

    private final class DOMElementViewControllerPreviewTransportBackend: TransportBackend, @unchecked Sendable {
        private struct TargetCommand {
            var targetID: ProtocolTargetIdentifier
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
            var style: CSSStylePayload
        }

        private struct ComputedStyleResult: Encodable {
            var computedStyle: [CSSComputedStylePropertyPayload]
        }

        private let lock = NSLock()
        private let styleID: CSSStyleIdentifier
        private let ruleID: CSSRuleIdentifier
        private var cssText: String
        private var properties: [CSSPropertyPayload]
        weak var transport: TransportSession?

        init(styleID: CSSStyleIdentifier, ruleID: CSSRuleIdentifier, cssText: String) {
            self.styleID = styleID
            self.ruleID = ruleID
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
                resultJSON = try Self.jsonString(CSSInlineStylesPayload())
            case "CSS.getComputedStyleForNode":
                resultJSON = try Self.jsonString(ComputedStyleResult(computedStyle: []))
            default:
                resultJSON = "{}"
            }

            await sendTargetReply(
                targetID: command.targetID,
                commandID: command.commandID,
                resultJSON: resultJSON
            )
        }

        func detach() async {
        }

        private func updateStyleText(_ text: String) -> CSSStylePayload {
            withLockedState {
                cssText = text
                properties = DOMElementViewControllerPreview.previewProperties(from: text)
                return currentStylePayload()
            }
        }

        private func matchedStyles() -> CSSMatchedStylesPayload {
            withLockedState {
                DOMElementViewControllerPreview.previewMatchedStyles(
                    ruleID: ruleID,
                    style: currentStylePayload()
                )
            }
        }

        private func currentStylePayload() -> CSSStylePayload {
            CSSStylePayload(
                id: styleID,
                cssProperties: properties,
                cssText: cssText
            )
        }

        private func withLockedState<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer {
                lock.unlock()
            }
            return try body()
        }

        private func sendTargetReply(
            targetID: ProtocolTargetIdentifier,
            commandID: UInt64,
            resultJSON: String
        ) async {
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
            await transport?.receiveRootMessage(message)
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
                targetID: ProtocolTargetIdentifier(envelope.params.targetId),
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
