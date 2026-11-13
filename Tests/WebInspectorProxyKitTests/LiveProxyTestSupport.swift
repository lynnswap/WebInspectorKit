import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

let transportCommandBackendWaitTimeout: Duration = .milliseconds(750)

func pageTarget(proxy: WebInspectorProxy) -> WebInspectorTarget {
    WebInspectorTarget(
        id: WebInspectorTarget.ID("page-main"),
        kind: .page,
        frameID: FrameID("main-frame"),
        isProvisional: false,
        proxy: proxy,
        route: RoutingTargetID("page-main")
    )
}

func installPageTarget(
    in transport: TransportSession,
    targetID: ProtocolTarget.ID = ProtocolTarget.ID("page-main"),
    frameID: String? = nil
) async {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    await transport.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(escapedTargetID)","type":"page","isProvisional":false,"isPaused":false}}}"#
    )
    if let frameID {
        await receiveTargetEvent(
            transport,
            targetID: targetID,
            method: "Page.frameNavigated",
            params: #"{"frame":{"id":"\#(jsonEscapedString(frameID))"}}"#
        )
    }
}

func installMainPageFrame(
    in transport: TransportSession,
    frameID: ProtocolFrame.ID = ProtocolFrame.ID("frame-7.1")
) async {
    await installFrame(frameID, parentFrameID: nil, in: transport)
}

func installFrame(
    _ frameID: ProtocolFrame.ID,
    parentFrameID: ProtocolFrame.ID?,
    in transport: TransportSession
) async {
    let frameID = jsonEscapedString(frameID.rawValue)
    let parent = parentFrameID.map {
        #","parentId":"\#(jsonEscapedString($0.rawValue))""#
    } ?? ""
    await receiveTargetEvent(
        transport,
        targetID: ProtocolTarget.ID("page-main"),
        method: "Page.frameNavigated",
        params: #"{"frame":{"id":"\#(frameID)"\#(parent)}}"#
    )
}

func waitForEventSubscription(
    _ target: WebInspectorTarget,
    domain: WebInspectorProxyEventDomain
) async {
    await target.proxy.waitForEventSubscription(targetID: target.id, route: target.route, domain: domain)
}

func receiveTargetEvent(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    method: String,
    params: String
) async {
    await transport.receiveRootMessage(targetDispatchMessage(
        targetID: targetID,
        message: #"{"method":"\#(method)","params":\#(params)}"#
    ))
}

func waitForTargetMessage(
    _ backend: FakeTransportBackend,
    method: String,
    ordinal: Int = 0,
    after count: Int = 0
) async throws -> SentTargetMessage {
    try await withThrowingTaskGroup(of: SentTargetMessage.self) { group in
        defer {
            group.cancelAll()
        }

        group.addTask {
            try await backend.waitForTargetMessage(method: method, ordinal: ordinal, after: count)
        }
        group.addTask {
            try await Task.sleep(for: transportCommandBackendWaitTimeout)
            throw WebInspectorProxyError.timeout(domain: "test", method: method)
        }

        guard let message = try await group.next() else {
            throw WebInspectorProxyError.timeout(domain: "test", method: method)
        }
        return message
    }
}

func receiveTargetReply(
    _ transport: TransportSession,
    targetID: ProtocolTarget.ID,
    messageID: UInt64,
    result: String
) async {
    await transport.receiveRootMessage(targetDispatchMessage(
        targetID: targetID,
        message: #"{"id":\#(messageID),"result":\#(result)}"#
    ))
}

func targetDispatchMessage(
    targetID: ProtocolTarget.ID,
    message: String
) -> String {
    let escapedTargetID = jsonEscapedString(targetID.rawValue)
    let escapedMessage = jsonEscapedString(message)
    return #"{"method":"Target.dispatchMessageFromTarget","params":{"targetId":"\#(escapedTargetID)","message":"\#(escapedMessage)"}}"#
}

func jsonEscapedString(_ string: String) -> String {
    string
        .replacingOccurrences(of: #"\"#, with: #"\\"#)
        .replacingOccurrences(of: #"""#, with: #"\""#)
        .replacingOccurrences(of: "\n", with: #"\n"#)
        .replacingOccurrences(of: "\r", with: #"\r"#)
        .replacingOccurrences(of: "\t", with: #"\t"#)
}

func messageID(_ message: String) throws -> UInt64 {
    let object = try messageObject(message)
    if let number = object["id"] as? NSNumber {
        return number.uint64Value
    }
    if let string = object["id"] as? String,
       let id = UInt64(string) {
        return id
    }
    throw TransportSession.Error.malformedMessage
}

func messageMethod(_ message: String) throws -> String? {
    try messageObject(message)["method"] as? String
}

func messageParameters(_ message: String) throws -> [String: Any] {
    try messageObject(message)["params"] as? [String: Any] ?? [:]
}

func messageObject(_ message: String) throws -> [String: Any] {
    let data = try #require(message.data(using: .utf8))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

struct TimedOut: Error {}

enum TaskValueRace<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

func value<T: Sendable>(
    of task: Task<T, Never>,
    timeout: Duration = .seconds(5)
) async throws -> T {
    try await withThrowingTaskGroup(of: TaskValueRace<T>.self) { group in
        defer { group.cancelAll() }
        group.addTask {
            .value(await task.value)
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return .timedOut
        }
        guard let outcome = try await group.next() else {
            throw TimedOut()
        }
        switch outcome {
        case let .value(value):
            return value
        case .timedOut:
            task.cancel()
            throw TimedOut()
        }
    }
}

func throwingValue<T: Sendable>(
    of task: Task<T, any Error>,
    timeout: Duration = .seconds(5)
) async throws -> T {
    try await withThrowingTaskGroup(of: TaskValueRace<T>.self) { group in
        defer { group.cancelAll() }
        group.addTask {
            .value(try await task.value)
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return .timedOut
        }
        guard let outcome = try await group.next() else {
            throw TimedOut()
        }
        switch outcome {
        case let .value(value):
            return value
        case .timedOut:
            task.cancel()
            throw TimedOut()
        }
    }
}
