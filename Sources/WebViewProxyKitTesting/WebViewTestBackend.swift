import Foundation
import WebViewProxyKit

public struct RecordedCommand: Equatable, Sendable {
    public let domain: String
    public let method: String

    public init(domain: String, method: String) {
        self.domain = domain
        self.method = method
    }
}

private struct HeldCommand: Sendable {
    var domain: String
    var method: String
    var gate: WebViewTestGate
}

public actor WebViewTestBackend {
    private var enqueuedReplies: [RecordedCommand]
    private var commands: [RecordedCommand]
    private var heldCommands: [HeldCommand]

    public init() {
        enqueuedReplies = []
        commands = []
        heldCommands = []
    }

    public func enqueue(
        _ result: some Encodable & Sendable,
        for domain: String,
        method: String
    ) async {
        _ = result
        enqueuedReplies.append(RecordedCommand(domain: domain, method: method))
    }

    public func emit(_ event: Network.Event, target: WebViewTarget.ID) async {
        _ = (event, target)
    }

    public func emit(_ event: DOM.Event, target: WebViewTarget.ID) async {
        _ = (event, target)
    }

    public func emit(_ event: CSS.Event, target: WebViewTarget.ID) async {
        _ = (event, target)
    }

    public func emit(_ event: Console.Event, target: WebViewTarget.ID) async {
        _ = (event, target)
    }

    public func emit(_ event: Runtime.Event, target: WebViewTarget.ID) async {
        _ = (event, target)
    }

    public func recordedCommands() async -> [RecordedCommand] {
        commands
    }

    public func hold(domain: String, method: String, gate: WebViewTestGate) async {
        heldCommands.append(HeldCommand(domain: domain, method: method, gate: gate))
    }
}

extension WebViewTestBackend: WebViewProxyBackend {}
