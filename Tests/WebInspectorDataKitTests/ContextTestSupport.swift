import Foundation
import Observation
import ObservationBridge
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

func loadedResourceTree() throws -> Page.ResourceTree {
    try JSONDecoder().decode(Page.ResourceTree.self, from: Data(#"{"frame":{"id":"main-frame","loaderId":"main-loader","url":"https://example.test/","mimeType":"text/html"},"childFrames":[{"frame":{"id":"child-frame","loaderId":"child-loader","url":"https://example.test/child","mimeType":"text/html"},"resources":[{"url":"https://example.test/child.js","type":"Script","mimeType":"text/javascript"}]}],"resources":[{"url":"https://example.test/","type":"Document","mimeType":"text/html"},{"url":"https://example.test/loaded.css","type":"Stylesheet","mimeType":"text/css","sourceMapURL":"https://example.test/loaded.css.map"},{"url":"https://example.test/broken.png","type":"Image","mimeType":"image/png","canceled":true}]}"#.utf8))
}

@MainActor
func startContext(
    runtime: WebInspectorProxyTestRuntime,
    document: DOM.Node = DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
) async throws -> (WebInspectorTarget, WebInspectorContext) {
    let target = try await runtime.proxy.waitForCurrentPage()
    await enqueueStartupReplies(on: runtime.backend, document: document)

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForStartupSubscribers(runtime: runtime, target: target)
    try await waitUntil(in: context) { context.state == .attached }
    return (target, context)
}

var startupCommands: [RecordedCommand] {
    [
        RecordedCommand(domain: "Inspector", method: "enable"),
        RecordedCommand(domain: "Inspector", method: "initialized"),
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Network", method: "enable"),
        RecordedCommand(domain: "Page", method: "getResourceTree"),
        RecordedCommand(domain: "DOM", method: "getDocument"),
        RecordedCommand(domain: "Console", method: "enable"),
    ]
}

var shutdownCommands: [RecordedCommand] {
    [
        RecordedCommand(domain: "Console", method: "disable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Network", method: "disable"),
        RecordedCommand(domain: "Page", method: "disable"),
        RecordedCommand(domain: "Inspector", method: "disable"),
    ]
}

func enqueueStartupReplies(
    on backend: WebInspectorTestBackend,
    document: DOM.Node = DOM.Node(id: DOM.Node.ID("document"), nodeType: 9, nodeName: "#document")
) async {
    await enqueueDomainEnableReplies(on: backend)
    await backend.enqueue((), for: "CSS", method: "enable")
    await backend.enqueue(document, for: "DOM", method: "getDocument")
}

func enqueueDomainEnableReplies(on backend: WebInspectorTestBackend) async {
    await backend.enqueue((), for: "Inspector", method: "enable")
    await backend.enqueue((), for: "Inspector", method: "initialized")
    await backend.enqueue((), for: "Page", method: "enable")
    await backend.enqueue((), for: "Runtime", method: "enable")
    await backend.enqueue((), for: "Network", method: "enable")
    await backend.enqueue((), for: "Console", method: "enable")
}

func enqueueDomainDisableReplies(on backend: WebInspectorTestBackend) async {
    await backend.enqueue((), for: "Console", method: "disable")
    await backend.enqueue((), for: "Runtime", method: "disable")
    await backend.enqueue((), for: "Network", method: "disable")
    await backend.enqueue((), for: "Page", method: "disable")
    await backend.enqueue((), for: "Inspector", method: "disable")
}

func enqueueCSSStyleReplies(on backend: WebInspectorTestBackend) async {
    await backend.enqueue(
        CSS.MatchedStyles(matchedRules: [
            CSS.Rule(
                selectorList: CSS.Rule.SelectorList(selectors: [".card"], text: ".card"),
                origin: CSS.Origin(rawValue: "regular"),
                style: CSS.Style(
                    id: CSS.Style.ID("style-1"),
                    properties: [
                        CSS.Property(
                            id: CSS.Property.ID("property-1"),
                            name: "display",
                            value: "grid",
                            text: "display: grid;",
                            isEditable: true
                        )
                    ],
                    cssText: "display: grid;",
                    isEditable: true
                )
            )
        ]),
        for: "CSS",
        method: "getMatchedStylesForNode"
    )
    await backend.enqueue(
        CSS.InlineStyles(),
        for: "CSS",
        method: "getInlineStylesForNode"
    )
    await backend.enqueue(
        [
            CSS.ComputedProperty(name: "display", value: "grid")
        ],
        for: "CSS",
        method: "getComputedStyleForNode"
    )
}

func enqueueCSSStyleReplies(
    _ style: CSS.Style,
    on backend: WebInspectorTestBackend
) async {
    await enqueueCSSStyleReplies(cssMatchedStyles([style]), on: backend)
}

func enqueueCSSStyleReplies(
    _ matchedStyles: CSS.MatchedStyles,
    on backend: WebInspectorTestBackend
) async {
    await backend.enqueue(
        matchedStyles,
        for: "CSS",
        method: "getMatchedStylesForNode"
    )
    await backend.enqueue(
        CSS.InlineStyles(),
        for: "CSS",
        method: "getInlineStylesForNode"
    )
    await backend.enqueue(
        [CSS.ComputedProperty(name: "display", value: "grid")],
        for: "CSS",
        method: "getComputedStyleForNode"
    )
}

func cssRule(selector: String, style: CSS.Style) -> CSS.Rule {
    CSS.Rule(
        id: CSS.Rule.ID(style.id.rawValue),
        selectorList: CSS.Rule.SelectorList(selectors: [selector], text: selector),
        origin: CSS.Origin(rawValue: "author"),
        style: style
    )
}

func cssSinglePropertyStyle(
    id: CSS.Style.ID,
    name: String,
    value: String
) -> CSS.Style {
    CSS.Style(
        id: id,
        properties: [
            CSS.Property(
                id: CSS.Property.ID("\(id.rawValue)\u{1F}0"),
                name: name,
                value: value,
                text: "\(name): \(value);",
                isEditable: true
            )
        ],
        cssText: "\(name): \(value);",
        isEditable: true
    )
}

func cssMatchedStyles(_ styles: [CSS.Style]) -> CSS.MatchedStyles {
    CSS.MatchedStyles(
        matchedRules: styles.enumerated().map { index, style in
            CSS.Rule(
                id: CSS.Rule.ID("css-test-rule-\(index)"),
                selectorList: CSS.Rule.SelectorList(
                    selectors: [".css-test-\(index)"],
                    text: ".css-test-\(index)"
                ),
                origin: CSS.Origin(rawValue: "author"),
                style: style
            )
        }
    )
}

func cssBaselineStyle(
    id: CSS.Style.ID,
    properties: [(name: String, value: String)]
) -> CSS.Style {
    CSS.Style(
        id: id,
        properties: properties.enumerated().map { index, property in
            CSS.Property(
                id: CSS.Property.ID("\(id.rawValue)\u{1F}\(index)"),
                name: property.name,
                value: property.value,
                text: "\(property.name): \(property.value);",
                status: .active,
                isEditable: true
            )
        },
        cssText: properties
            .map { "\($0.name): \($0.value);" }
            .joined(separator: "\n"),
        isEditable: true
    )
}

func cssToggleStyle(
    margin: String,
    marginStatus: CSS.Status = .active,
    paddingStatus: CSS.Status
) -> CSS.Style {
    let styleID = CSS.Style.ID("queued-toggle-style\u{1F}0")
    let marginText = marginStatus == .disabled
        ? "/* margin: \(margin); */"
        : "margin: \(margin);"
    let paddingText = paddingStatus == .disabled
        ? "/* padding: 8px; */"
        : "padding: 8px;"
    return CSS.Style(
        id: styleID,
        properties: [
            CSS.Property(
                id: CSS.Property.ID("\(styleID.rawValue)\u{1F}0"),
                name: "margin",
                value: margin,
                text: marginText,
                status: marginStatus,
                isEditable: true
            ),
            CSS.Property(
                id: CSS.Property.ID("\(styleID.rawValue)\u{1F}1"),
                name: "padding",
                value: "8px",
                text: paddingText,
                status: paddingStatus,
                isEditable: true
            ),
        ],
        cssText: "\(marginText)\n\(paddingText)",
        isEditable: true
    )
}

func cssToggleStyleWithLeadingColor() -> CSS.Style {
    let styleID = CSS.Style.ID("queued-toggle-style\u{1F}0")
    return CSS.Style(
        id: styleID,
        properties: [
            CSS.Property(
                id: CSS.Property.ID("\(styleID.rawValue)\u{1F}0"),
                name: "color",
                value: "red",
                text: "color: red;",
                isEditable: true
            ),
            CSS.Property(
                id: CSS.Property.ID("\(styleID.rawValue)\u{1F}1"),
                name: "margin",
                value: "0",
                text: "margin: 0;",
                isEditable: true
            ),
            CSS.Property(
                id: CSS.Property.ID("\(styleID.rawValue)\u{1F}2"),
                name: "padding",
                value: "8px",
                text: "padding: 8px;",
                isEditable: true
            ),
        ],
        cssText: "color: red;\nmargin: 0;\npadding: 8px;",
        isEditable: true
    )
}

struct EditableCSSFixture {
    var styles: CSSStyles
    var propertyID: CSSStyleProperty.ID
}

@MainActor
func loadEditableCSSFixture(
    runtime: WebInspectorProxyTestRuntime,
    target: WebInspectorTarget,
    context: WebInspectorContext
) async throws -> EditableCSSFixture {
    let document = try #require(context.rootNode)
    let elementID = DOM.Node.ID("authority-styled-node")
    await runtime.backend.emit(
        .setChildNodes(parent: document.id.proxyID, nodes: [
            DOM.Node(id: elementID, nodeType: 1, nodeName: "DIV", localName: "div")
        ]),
        target: target
    )
    try await waitUntil(in: context) { context.node(for: DOMNode.ID(elementID)) != nil }
    let element = try #require(context.node(for: DOMNode.ID(elementID)))

    await enqueueCSSStyleReplies(on: runtime.backend)
    context.select(element)
    let styles = try #require(element.elementStyles)
    try await waitUntil { styles.phase == .loaded }
    let propertyID = try #require(styles.sections.first?.style.properties.first?.id)
    return EditableCSSFixture(styles: styles, propertyID: propertyID)
}

func waitForRecordedCommands(
    on backend: WebInspectorTestBackend,
    expected: [RecordedCommand]
) async throws {
    let deadline = ContinuousClock.now + .seconds(1)
    var counts: [String: [String: Int]] = [:]
    for command in expected {
        counts[command.domain, default: [:]][command.method, default: 0] += 1
    }
    for (domain, methods) in counts {
        for (method, count) in methods {
            _ = try await backend.waitForRecordedCommandsForTesting(
                domain: domain,
                method: method,
                count: count,
                timeout: ContinuousClock.now.duration(to: deadline)
            )
        }
    }
    let commands = await backend.recordedCommands()
    try #require(commands == expected)
}

func matchedStylesCommandCount(on backend: WebInspectorTestBackend) async -> Int {
    await backend.recordedCommands()
        .filter { $0 == RecordedCommand(domain: "CSS", method: "getMatchedStylesForNode") }
        .count
}

@MainActor
func waitForStartupSubscribers(
    runtime: WebInspectorProxyTestRuntime,
    target: WebInspectorTarget
) async throws {
    try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Inspector", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "CSS", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Console", target: target, count: 1)
    try await runtime.backend.waitForSubscribers(domain: "Runtime", target: target, count: 1)
}

func emitFinishedRequest(
    id: Network.Request.ID,
    target: WebInspectorTarget,
    backend: WebInspectorTestBackend
) async {
    await backend.emit(
        .requestWillBeSent(
            id: id,
            request: Network.Request(id: id, url: "https://example.com/\(id)", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ),
        target: target
    )
    await backend.emit(
        .responseReceived(
            id: id,
            response: Network.Response(status: 200, mimeType: "text/plain"),
            resourceType: .fetch,
            timestamp: 2
        ),
        target: target
    )
    await backend.emit(.loadingFinished(id: id, timestamp: 3, sourceMapURL: nil, metrics: nil), target: target)
}

@MainActor
func startTransportBackedContext(
    targetID: ProtocolTarget.ID,
    documentID: String,
    protocolProfile: WebInspectorProtocolProfile = .released26
) async throws -> (FakeTransportBackend, TransportSession, WebInspectorContext) {
    let backend = FakeTransportBackend()
    let transport = TransportSession(
        backend: backend,
        protocolProfile: protocolProfile
    )
    await installTransportPageTarget(in: transport, targetID: targetID)
    let proxy = try await WebInspectorProxy(transport: transport)
    let container = WebInspectorContainer(proxy: proxy)
    let context = container.mainContext

    try await replyTransportInspectorAndPageInitialization(backend, transport: transport, targetID: targetID)

    let runtimeEnable = try await waitForTransportTargetMessage(backend, method: "Runtime.enable")
    #expect(runtimeEnable.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try transportMessageID(runtimeEnable.message),
        result: "{}"
    )

    let networkEnable = try await waitForTransportTargetMessage(backend, method: "Network.enable")
    #expect(networkEnable.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: networkEnable.targetIdentifier,
        messageID: try transportMessageID(networkEnable.message),
        result: "{}"
    )

    try await replyTransportResourceTreeUnavailable(backend, transport: transport)

    let getDocument = try await waitForTransportTargetMessage(backend, method: "DOM.getDocument")
    #expect(getDocument.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try transportMessageID(getDocument.message),
        result: transportDocumentResult(nodeID: documentID)
    )

    let consoleEnable = try await waitForTransportTargetMessage(backend, method: "Console.enable")
    #expect(consoleEnable.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try transportMessageID(consoleEnable.message),
        result: "{}"
    )

    let startupTask = try #require(context.startupTaskForTesting())
    await startupTask.value
    #expect(context.state == .attached)
    return (backend, transport, context)
}

// DOM and live-Network fixtures do not seed restored requests. Reply explicitly
// so startup and retargeting do not depend on a transport timeout to proceed.
func replyTransportResourceTreeUnavailable(
    _ backend: FakeTransportBackend,
    transport: TransportSession,
    after count: Int = 0,
    timeout: Duration = .seconds(1)
) async throws {
    let request = try await waitForTransportTargetMessage(
        backend,
        method: "Page.getResourceTree",
        after: count,
        timeout: timeout
    )
    let messageID = try transportMessageID(request.message)
    await transport.receiveRootMessage(transportTargetDispatchMessage(
        targetID: request.targetIdentifier,
        message: #"{"id":\#(messageID),"error":{"code":-32000,"message":"Resource tree unavailable in this fixture."}}"#
    ))
}

@discardableResult
func replyTransportInspectorAndPageInitialization(
    _ backend: FakeTransportBackend,
    transport: TransportSession,
    targetID: ProtocolTarget.ID,
    after count: Int = 0,
    timeout: Duration = .seconds(1),
    includePageEnable: Bool = true
) async throws -> (enable: SentTargetMessage, initialized: SentTargetMessage) {
    let inspectorEnable = try await waitForTransportTargetMessage(
        backend,
        method: "Inspector.enable",
        after: count,
        timeout: timeout
    )
    #expect(inspectorEnable.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: inspectorEnable.targetIdentifier,
        messageID: try transportMessageID(inspectorEnable.message),
        result: "{}"
    )

    let inspectorInitialized = try await waitForTransportTargetMessage(
        backend,
        method: "Inspector.initialized",
        after: count,
        timeout: timeout
    )
    #expect(inspectorInitialized.targetIdentifier == targetID)
    await receiveTransportTargetReply(
        transport,
        targetID: inspectorInitialized.targetIdentifier,
        messageID: try transportMessageID(inspectorInitialized.message),
        result: "{}"
    )

    if includePageEnable {
        let pageEnable = try await waitForTransportTargetMessage(
            backend,
            method: "Page.enable",
            after: count,
            timeout: timeout
        )
        #expect(pageEnable.targetIdentifier == targetID)
        await receiveTransportTargetReply(
            transport,
            targetID: pageEnable.targetIdentifier,
            messageID: try transportMessageID(pageEnable.message),
            result: "{}"
        )
    }

    return (enable: inspectorEnable, initialized: inspectorInitialized)
}

func installTransportPageTarget(
    in transport: TransportSession,
    targetID: ProtocolTarget.ID,
    frameID: String = "main-frame"
) async {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    let escapedFrameID = jsonEscapedString(frameID)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(escapedTargetID)","type":"page","isProvisional":false,"isPaused":false}}}"#
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Page.frameNavigated",
        params: #"{"frame":{"id":"\#(escapedFrameID)","loaderId":"main-loader","name":"Main","url":"https://example.test/","securityOrigin":"https://example.test","mimeType":"text/html"}}"#
    )
}

func installTransportFrameTarget(
    in transport: TransportSession,
    pageTargetID: ProtocolTarget.ID,
    targetID: ProtocolTarget.ID,
    frameID: String,
    parentFrameID: String
) async {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    let escapedFrameID = jsonEscapedString(frameID)
    let escapedParentFrameID = jsonEscapedString(parentFrameID)
    await receiveTransportTargetEvent(
        transport,
        targetID: pageTargetID,
        method: "Page.frameNavigated",
        params: #"{"frame":{"id":"\#(escapedFrameID)","parentId":"\#(escapedParentFrameID)","loaderId":"frame-loader","name":"Frame","url":"https://frame.example.test/","securityOrigin":"https://frame.example.test","mimeType":"text/html"}}"#
    )
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(escapedTargetID)","type":"frame","isProvisional":false,"isPaused":false}}}"#
    )
}

@MainActor
func startAutoReplyingTransportTargetMessages(
    backend: FakeTransportBackend,
    transport: TransportSession,
    after count: Int = 0,
    documentNodeID: @escaping @MainActor @Sendable (ProtocolTarget.ID) -> String
) -> Task<Void, Never> {
    Task { @MainActor in
        var repliedTargetMessageCount = count
        while Task.isCancelled == false {
            do {
                let sentMessage = try await backend.waitForTargetMessage(after: repliedTargetMessageCount)
                repliedTargetMessageCount += 1

                let messageID = try transportMessageID(sentMessage.message)
                let method = try transportTargetMessageMethod(sentMessage.message)
                let result = method == "DOM.getDocument"
                    ? transportDocumentResult(nodeID: documentNodeID(sentMessage.targetIdentifier))
                    : "{}"

                await receiveTransportTargetReply(
                    transport,
                    targetID: sentMessage.targetIdentifier,
                    messageID: messageID,
                    result: result
                )
            } catch is CancellationError {
                return
            } catch {
                Issue.record("Failed to auto-reply to transport target message: \(error)")
                return
            }
        }
    }
}

func waitForTransportTargetMessage(
    _ backend: FakeTransportBackend,
    method: String,
    ordinal: Int = 0,
    after count: Int = 0,
    timeout: Duration = .seconds(1)
) async throws -> SentTargetMessage {
    try await withThrowingTaskGroup(of: SentTargetMessage.self) { group in
        group.addTask {
            try await backend.waitForTargetMessage(method: method, ordinal: ordinal, after: count)
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            let sentMethods = await backend.sentTargetMessages().enumerated().map { index, message in
                let method = (try? transportTargetMessageMethod(message.message)) ?? "<unknown>"
                return "#\(index):\(method)@\(message.targetIdentifier.rawValue)"
            }.joined(separator: ", ")
            throw TimedOut(
                "Timed out waiting for \(method) ordinal \(ordinal) after \(count) within \(timeout). "
                    + "Sent target messages: [\(sentMethods)]"
            )
        }
        guard let message = try await group.next() else {
            throw TimedOut()
        }
        group.cancelAll()
        return message
    }
}

func waitForTransportTargetMessageReplyingToInterleavedGetDocuments(
    _ backend: FakeTransportBackend,
    transport: TransportSession,
    targetID: ProtocolTarget.ID,
    method expectedMethod: String,
    after count: Int,
    documentNodeID: String,
    repliedGetDocumentMessageIDs: Set<UInt64>,
    timeout: Duration = .seconds(1)
) async throws -> SentTargetMessage {
    try await withThrowingTaskGroup(of: SentTargetMessage.self) { group in
        group.addTask {
            var nextMessageIndex = count
            var repliedGetDocumentMessageIDs = repliedGetDocumentMessageIDs
            while true {
                let sentMessage = try await backend.waitForTargetMessage(after: nextMessageIndex)
                nextMessageIndex += 1
                guard sentMessage.targetIdentifier == targetID else {
                    continue
                }
                let method = try transportTargetMessageMethod(sentMessage.message)
                if method == expectedMethod {
                    return sentMessage
                }
                guard method == "DOM.getDocument" else {
                    continue
                }
                let messageID = try transportMessageID(sentMessage.message)
                guard repliedGetDocumentMessageIDs.insert(messageID).inserted else {
                    continue
                }
                await receiveTransportTargetReply(
                    transport,
                    targetID: sentMessage.targetIdentifier,
                    messageID: messageID,
                    result: transportDocumentResult(nodeID: documentNodeID)
                )
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            let sentMethods = try await backend.sentTargetMessages().enumerated().map { index, message in
                "#\(index):\(try transportTargetMessageMethod(message.message))@\(message.targetIdentifier.rawValue)"
            }.joined(separator: ", ")
            throw TimedOut(
                "Timed out waiting for \(expectedMethod) after \(count) within \(timeout). "
                    + "Sent target messages: [\(sentMethods)]"
            )
        }
        defer { group.cancelAll() }
        guard let message = try await group.next() else {
            throw TimedOut()
        }
        return message
    }
}

func receiveTransportTargetReply(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    messageID: UInt64,
    result: String
) async {
    await transport.receiveRootMessage(transportTargetDispatchMessage(
        targetID: targetID,
        message: #"{"id":\#(messageID),"result":\#(result)}"#
    ))
}

func receiveTransportTargetEvent(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    method: String,
    params: String
) async {
    await transport.receiveRootMessage(transportTargetDispatchMessage(
        targetID: targetID,
        message: #"{"method":"\#(method)","params":\#(params)}"#
    ))
}

func terminalProxyError(from proxy: WebInspectorProxy) async -> WebInspectorProxyError? {
    do {
        try await proxy.waitUntilClosed()
        Issue.record("Expected the proxy to close with a terminal failure.")
        return nil
    } catch let error as WebInspectorProxyError {
        return error
    } catch {
        Issue.record("Expected WebInspectorProxyError, got \(error).")
        return nil
    }
}

func emitTransportNetworkRequest(
    id: String,
    frameID: String,
    loaderID: String,
    timestamp: Double,
    targetID: ProtocolTarget.ID,
    transport: TransportSession
) async {
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Network.requestWillBeSent",
        params: #"{"requestId":"\#(jsonEscapedString(id))","frameId":"\#(jsonEscapedString(frameID))","loaderId":"\#(jsonEscapedString(loaderID))","request":{"url":"https://example.test/\#(jsonEscapedString(id))","method":"GET"},"initiator":{"type":"parser","nodeId":42},"type":"Fetch","timestamp":\#(timestamp)}"#
    )
}

func emitOriginatedNetworkRequest(
    id: String,
    frameID: String = "main-frame",
    loaderID: String,
    originTargetID: String?,
    timestamp: Double,
    target: WebInspectorTarget,
    backend: WebInspectorTestBackend
) async {
    let requestID = Network.Request.ID(id)
    await backend.emit(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.test/\(id)",
                method: "GET",
                origin: Network.Request.Origin(
                    frameID: FrameID(frameID),
                    loaderID: loaderID,
                    targetID: originTargetID
                )
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: timestamp
        ),
        target: target
    )
}

@MainActor
func applyOriginatedNetworkRequest(
    id: String,
    frameID: String = "main-frame",
    loaderID: String,
    originTargetID: String?,
    timestamp: Double,
    context: WebInspectorContext
) async {
    let requestID = Network.Request.ID(id)
    await context.apply(.requestWillBeSent(
        id: requestID,
        request: Network.Request(
            id: requestID,
            url: "https://example.test/\(id)",
            method: "GET",
            origin: Network.Request.Origin(
                frameID: FrameID(frameID),
                loaderID: loaderID,
                targetID: originTargetID
            )
        ),
        resourceType: .fetch,
        redirectResponse: nil,
        timestamp: timestamp
    ))
}

enum NetworkTopLevelCommitOrder {
    case targetThenFrame
    case frameThenTarget
}

@MainActor
func networkVisitsAcrossTopLevelCommit(
    order: NetworkTopLevelCommitOrder,
    provisionalOriginTargetID: String? = "page-next",
    currentLoaderID: String = "reused-loader",
    provisionalLoaderID: String = "reused-loader"
) async throws -> (provisional: NetworkNavigationVisit, committed: NetworkNavigationVisit) {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)

    await emitOriginatedNetworkRequest(
        id: "commit-order-current",
        loaderID: currentLoaderID,
        originTargetID: "page-current",
        timestamp: 1,
        target: target,
        backend: runtime.backend
    )
    await emitOriginatedNetworkRequest(
        id: "commit-order-provisional",
        loaderID: provisionalLoaderID,
        originTargetID: provisionalOriginTargetID,
        timestamp: 2,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { context.network.requests.count == 2 }
    let provisionalVisit = try #require(context.network.requests[1].navigationVisit)

    switch order {
    case .targetThenFrame:
        try await emitTopLevelTargetCommit(
            target: target,
            context: context,
            backend: runtime.backend,
            documentID: "target-before-frame-root"
        )
        try await emitTopLevelFrameCommit(
            target: target,
            context: context,
            backend: runtime.backend,
            documentID: "frame-after-target-root",
            loaderID: provisionalLoaderID
        )
    case .frameThenTarget:
        try await emitTopLevelFrameCommit(
            target: target,
            context: context,
            backend: runtime.backend,
            documentID: "frame-before-target-root",
            loaderID: provisionalLoaderID
        )
        try await emitTopLevelTargetCommit(
            target: target,
            context: context,
            backend: runtime.backend,
            documentID: "target-after-frame-root"
        )
    }

    await emitOriginatedNetworkRequest(
        id: "commit-order-committed",
        loaderID: provisionalLoaderID,
        originTargetID: provisionalOriginTargetID,
        timestamp: 3,
        target: target,
        backend: runtime.backend
    )
    try await waitUntil { context.network.requests.count == 3 }
    return (provisionalVisit, try #require(context.network.requests[2].navigationVisit))
}

@MainActor
func emitTopLevelTargetCommit(
    target: WebInspectorTarget,
    context: WebInspectorContext,
    backend: WebInspectorTestBackend,
    documentID: String,
    pageBindingID: String = "page-next"
) async throws {
    await enqueueStartupReplies(
        on: backend,
        document: DOM.Node(id: DOM.Node.ID(documentID), nodeType: 9, nodeName: "#document")
    )
    await backend.emit(
        .didCommitProvisionalTarget(WebInspectorTargetCommitLifecycle(
            oldTargetID: .currentPage,
            newTarget: WebInspectorLifecycleTarget(
                id: .currentPage,
                kind: .page,
                frameID: FrameID("main-frame"),
                isProvisional: false,
                pageBindingID: pageBindingID
            )
        )),
        target: target
    )
    try await waitUntil(in: context) {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID(documentID))
            && context.state == .attached
    }
}

@MainActor
func emitTopLevelFrameCommit(
    target: WebInspectorTarget,
    context: WebInspectorContext,
    backend: WebInspectorTestBackend,
    documentID: String,
    loaderID: String
) async throws {
    await backend.enqueue(
        DOM.Node(id: DOM.Node.ID(documentID), nodeType: 9, nodeName: "#document"),
        for: "DOM",
        method: "getDocument"
    )
    await backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: FrameID("main-frame"),
            parentID: nil,
            loaderID: loaderID,
            name: "Main",
            url: "https://example.test/next",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: target
    )
    try await waitUntil(in: context) {
        context.rootNode?.id == DOMNode.ID(DOM.Node.ID(documentID))
    }
}

func emitTransportFrameNavigated(
    frameID: String,
    loaderID: String,
    targetID: ProtocolTarget.ID,
    transport: TransportSession
) async {
    await receiveTransportTargetEvent(
        transport,
        targetID: targetID,
        method: "Page.frameNavigated",
        params: #"{"frame":{"id":"\#(jsonEscapedString(frameID))","parentId":"main-frame","loaderId":"\#(jsonEscapedString(loaderID))","name":"","url":"https://example.test/","securityOrigin":"https://example.test","mimeType":"text/html"}}"#
    )
}

func transportDocumentResult(nodeID: String) -> String {
    let escapedNodeID = jsonEscapedString(nodeID)
    return ##"{"root":{"nodeId":"\##(escapedNodeID)","nodeType":9,"nodeName":"#document","localName":"","nodeValue":"","frameId":"main-frame","childNodeCount":0}}"##
}

func transportTargetDispatchMessage(targetID: ProtocolTarget.ID, message: String) -> String {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    let escapedMessage = jsonEscapedString(message)
    return #"{"method":"Target.dispatchMessageFromTarget","params":{"targetId":"\#(escapedTargetID)","message":"\#(escapedMessage)"}}"#
}

func jsonEscapedString(_ string: String) -> String {
    string
        .replacingOccurrences(of: #"\"#, with: #"\\"#)
        .replacingOccurrences(of: #"""#, with: #"\""#)
}

func transportMessageID(_ message: String) throws -> UInt64 {
    let object = try transportMessageObject(message)
    if let number = object["id"] as? NSNumber {
        return number.uint64Value
    }
    if let string = object["id"] as? String,
       let id = UInt64(string) {
        return id
    }
    throw TransportSession.Error.malformedMessage
}

func transportTargetMessageMethod(_ message: String) throws -> String {
    let object = try transportMessageObject(message)
    guard let method = object["method"] as? String else {
        throw TransportSession.Error.malformedMessage
    }
    return method
}

func transportTargetMessageParameters(_ message: String) throws -> [String: Any] {
    let object = try transportMessageObject(message)
    return try #require(object["params"] as? [String: Any])
}

func transportMessageObject(_ message: String) throws -> [String: Any] {
    let data = try #require(message.data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@MainActor
@Observable
final class DOMTreeUpdateRecorder {
    private(set) var updates: [DOMTreeUpdate] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    private var hasStarted = false

    init(stream: AsyncStream<DOMTreeUpdate>) {
        task = Task { @MainActor [weak self] in
            self?.hasStarted = true
            for await update in stream {
                self?.updates.append(update)
            }
        }
    }

    func waitUntilStarted() async throws {
        try await waitUntil { self.hasStarted }
    }

    func waitForUpdateCount(_ count: Int) async throws {
        try await waitUntil { self.updates.count >= count }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
@Observable
final class DOMTreeRevealRequestRecorder {
    private(set) var requests: [DOMTreeRevealRequest] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    private var hasStarted = false

    init(stream: AsyncStream<DOMTreeRevealRequest>) {
        task = Task { @MainActor [weak self] in
            self?.hasStarted = true
            for await request in stream {
                self?.requests.append(request)
            }
        }
    }

    func waitUntilStarted() async throws {
        try await waitUntil { self.hasStarted }
    }

    func waitForRequestCount(_ count: Int) async throws {
        try await waitUntil { self.requests.count >= count }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
@Observable
final class CollectionChangeRecorder<Model: Hashable & Sendable> {
    private(set) var changes: [WebInspectorCollectionChange<Model>] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    private var hasStarted = false

    init(stream: AsyncStream<WebInspectorCollectionChange<Model>>) {
        task = Task { @MainActor [weak self] in
            self?.hasStarted = true
            for await change in stream {
                self?.changes.append(change)
            }
        }
    }

    func waitUntilStarted() async throws {
        try await waitUntil { self.hasStarted }
    }

    func waitForChangeCount(
        _ count: Int,
        timeout: Duration = .seconds(1)
    ) async throws {
        try await waitUntil(timeout: timeout) {
            self.changes.count >= count
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

/// Returns the Network request changes that `changes` received since it was
/// created. Clearing the requests publishes a reset, which ends the window.
@MainActor
func changesBeforeClearingRequests(
    in context: WebInspectorContext,
    _ changes: AsyncStream<WebInspectorCollectionChange<NetworkRequest>>
) async -> [WebInspectorCollectionChange<NetworkRequest>] {
    context.clearNetworkRequests()
    var received: [WebInspectorCollectionChange<NetworkRequest>] = []
    for await change in changes {
        if change == .removedAll {
            break
        }
        received.append(change)
    }
    return received
}

@MainActor
func waitForChild(in context: WebInspectorContext) async throws -> DOMNode {
    try await waitUntil(in: context) {
        guard let root = context.rootNode else {
            return false
        }
        guard case let .loaded(children) = root.children else {
            return false
        }
        return children.isEmpty == false
    }

    let root = try #require(context.rootNode)
    guard case let .loaded(children) = root.children else {
        Issue.record("Expected loaded root children.")
        throw TestFailure()
    }
    return try #require(children.first)
}

struct TestFailure: Error {}

struct TimedOut: Error, CustomStringConvertible {
    var description: String

    init(_ description: String = "Timed out") {
        self.description = description
    }
}

@MainActor
@Observable
final class ResponseBodyFetchCompletionProbe {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}

final class CancellationProbe: Sendable {
    private let startedSignal = ReplyPromise<Void>()
    private let cancelledSignal = ReplyPromise<Void>()

    func markStarted() {
        startedSignal.fulfill(.success(()))
    }

    func markCancelled() {
        cancelledSignal.fulfill(.success(()))
    }

    func waitUntilStarted(timeout: Duration = .seconds(1)) async throws {
        try await wait(for: startedSignal, timeout: timeout)
    }

    func waitUntilCancelled(timeout: Duration = .seconds(1)) async throws {
        try await wait(for: cancelledSignal, timeout: timeout)
    }

    private func wait(for signal: ReplyPromise<Void>, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await signal.value() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
        try Task.checkCancellation()
    }
}

final class SynchronousObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false

    var hasChanged: Bool {
        lock.lock()
        defer { lock.unlock() }
        return changed
    }

    func markChanged() {
        lock.lock()
        defer { lock.unlock() }
        changed = true
    }
}

@MainActor
@Observable
final class ContextChangeRevision {
    var value = 0
}

@MainActor
func waitUntil(
    in contexts: WebInspectorContext...,
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor @Sendable () -> Bool
) async throws {
    if condition() {
        return
    }
    let revision = ContextChangeRevision()
    let contextTasks = contexts.map { context in
        let changes = context.stateChangeStreamForTesting()
        return Task { @MainActor in
            for await _ in changes {
                revision.value += 1
            }
        }
    }
    defer { contextTasks.forEach { $0.cancel() } }

    let observation = withPortableContinuousObservation { _ in
        _ = revision.value
        for context in contexts {
            _ = context.network.requests
        }
        _ = condition()
    }
    defer { observation.cancel() }
    let values = await observation.values { condition() }
    defer { values.cancel() }
    guard await values.waitUntil(timeout: timeout, { $0 }) != nil else {
        if let error = observation.error {
            throw error
        }
        throw TimedOut()
    }
}

@MainActor
func waitForResponseBodyWaiters(in body: NetworkBody, count: Int) async throws {
    try Task.checkCancellation()
    let (registrations, continuation) = AsyncStream<Bool>.makeStream()
    body.responseFetchWaiterDidRegisterForTesting = { continuation.yield(true) }
    let timeoutTask = Task {
        do {
            try await Task.sleep(for: .seconds(1))
        } catch {
            return
        }
        continuation.yield(false)
    }
    defer {
        timeoutTask.cancel()
        body.responseFetchWaiterDidRegisterForTesting = nil
        continuation.finish()
    }
    if body.responseFetchWaiterCountForTesting >= count {
        return
    }
    for await didRegister in registrations {
        guard didRegister else {
            throw TimedOut("Timed out waiting for response body waiter registration.")
        }
        if body.responseFetchWaiterCountForTesting >= count {
            return
        }
    }
    try Task.checkCancellation()
    throw TimedOut("Response body waiter registration ended before the expected count.")
}
