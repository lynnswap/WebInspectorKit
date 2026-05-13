import Foundation
import Observation
import Synchronization
import WebKit
import V2_WebInspectorCore
import V2_WebInspectorTransport

package enum V2_InspectorAttachmentState: Equatable, Sendable {
    case detached
    case connecting
    case attached(targetID: ProtocolTargetIdentifier)
    case detaching
    case failed(String)
}

package struct V2_InspectorSessionError: Error, Equatable, Sendable, CustomStringConvertible {
    package var message: String

    package init(_ message: String) {
        self.message = message
    }

    package var description: String {
        message
    }
}

package struct V2_InspectorSessionConfiguration: Equatable, Sendable {
    package var responseTimeout: Duration
    package var bootstrapTimeout: Duration
    package var eventApplicationTimeout: Duration

    package init(
        responseTimeout: Duration = .seconds(5),
        bootstrapTimeout: Duration = .seconds(5),
        eventApplicationTimeout: Duration = .milliseconds(250)
    ) {
        self.responseTimeout = responseTimeout
        self.bootstrapTimeout = bootstrapTimeout
        self.eventApplicationTimeout = eventApplicationTimeout
    }
}

@MainActor
@Observable
package final class V2_InspectorSession {
    package let dom: DOMSession
    package let network: NetworkSession
    package private(set) var attachmentState: V2_InspectorAttachmentState
    package private(set) var lastError: V2_InspectorSessionError?

    @ObservationIgnored private let configuration: V2_InspectorSessionConfiguration
    @ObservationIgnored private var transport: TransportSession?
    @ObservationIgnored private var pumps: [ProtocolDomain: V2_DomainEventPump]
    @ObservationIgnored private weak var inspectableWebView: WKWebView?
    @ObservationIgnored private var originalInspectability: Bool?

    package init(
        configuration: V2_InspectorSessionConfiguration = .init(),
        dom: DOMSession = DOMSession(),
        network: NetworkSession = NetworkSession()
    ) {
        self.configuration = configuration
        self.dom = dom
        self.network = network
        attachmentState = .detached
        lastError = nil
        transport = nil
        pumps = [:]
        inspectableWebView = nil
        originalInspectability = nil
    }

    package func attach(to webView: WKWebView) async throws {
        await detach()
        let receiver = TransportReceiver()
        let originalInspectability = Self.prepareInspectability(for: webView)
        var transport: TransportSession?

        do {
            let backend = try NativeInspectorBackendFactory.make(
                webView: webView,
                messageHandler: { message in
                    receiver.receive(message)
                },
                fatalFailureHandler: { [weak self] message in
                    Task { @MainActor in
                        self?.lastError = V2_InspectorSessionError(message)
                    }
                }
            )
            let createdTransport = TransportSession(
                backend: backend,
                responseTimeout: configuration.responseTimeout
            )
            transport = createdTransport
            receiver.setTransport(createdTransport)

            try backend.attach()
            try await connect(transport: createdTransport)
            inspectableWebView = webView
            self.originalInspectability = originalInspectability
        } catch {
            Self.restoreInspectabilityIfNeeded(on: webView, originalValue: originalInspectability)
            await transport?.detach()
            throw error
        }
    }

    package func connect(transport: TransportSession) async throws {
        await detach()
        self.transport = transport
        attachmentState = .connecting
        lastError = nil
        await startPumps(transport: transport)
        seedDOMSession(from: await transport.snapshot())

        do {
            let mainTarget = try await transport.waitForCurrentMainPageTarget(
                timeout: configuration.bootstrapTimeout
            )
            seedDOMSession(from: await transport.snapshot())
            try await bootstrap(mainTargetID: mainTarget.targetID, transport: transport)
            try ensureCurrentTransport(transport)
            attachmentState = .attached(targetID: mainTarget.targetID)
            lastError = nil
        } catch {
            guard self.transport === transport else {
                throw error
            }
            stopPumps()
            self.transport = nil
            await transport.detach()
            dom.reset()
            network.reset()
            let sessionError = V2_InspectorSessionError(String(describing: error))
            lastError = sessionError
            attachmentState = .failed(sessionError.message)
            throw error
        }
    }

    package func detach() async {
        guard attachmentState != .detached || transport != nil else {
            return
        }

        attachmentState = .detaching
        stopPumps()
        let previousTransport = transport
        transport = nil
        await previousTransport?.detach()
        restoreInspectabilityIfNeeded()
        dom.reset()
        network.reset()
        lastError = nil
        attachmentState = .detached
    }

    package func perform(_ intent: DOMCommandIntent) async throws {
        let transport = try activeTransport()
        let command = try DOMTransportAdapter.command(for: intent)
        let result = try await transport.send(command)
        try ensureCurrentTransport(transport)

        switch intent {
        case .getDocument:
            try DOMTransportAdapter.applyGetDocumentResult(result, to: dom)
        case let .requestNode(selectionRequestID, targetID, _):
            let domSequence = result.receivedSequence(for: .dom)
            if requestNodeResultMayNeedDOMPathPush(result, targetID: targetID, domSequence: domSequence) {
                await waitForAppliedSequence(domSequence, domain: .dom)
                try ensureCurrentTransport(transport)
            }
            let selectionResult = try DOMTransportAdapter.applyRequestNodeResult(
                result,
                selectionRequestID: selectionRequestID,
                to: dom
            )
            if case let .failure(failure) = selectionResult {
                lastError = V2_InspectorSessionError(String(describing: failure))
            }
        case .requestChildNodes, .highlightNode:
            break
        }
    }

    @discardableResult
    package func perform(_ intent: NetworkCommandIntent) async throws -> ProtocolCommandResult {
        let transport = try activeTransport()
        let result = try await transport.send(NetworkTransportAdapter.command(for: intent))
        try ensureCurrentTransport(transport)
        return result
    }

    private func bootstrap(mainTargetID: ProtocolTargetIdentifier, transport: TransportSession) async throws {
        _ = try await sendTargetCommand(domain: .inspector, method: "Inspector.enable", targetID: mainTargetID, transport: transport)
        try ensureCurrentTransport(transport)
        _ = try await sendTargetCommand(domain: .inspector, method: "Inspector.initialized", targetID: mainTargetID, transport: transport)
        try ensureCurrentTransport(transport)
        _ = try await sendTargetCommand(domain: .dom, method: "DOM.enable", targetID: mainTargetID, transport: transport)
        try ensureCurrentTransport(transport)
        _ = try await sendTargetCommand(domain: .runtime, method: "Runtime.enable", targetID: mainTargetID, transport: transport)
        try ensureCurrentTransport(transport)

        let documentResult = try await sendTargetCommand(domain: .dom, method: "DOM.getDocument", targetID: mainTargetID, transport: transport)
        try ensureCurrentTransport(transport)
        try DOMTransportAdapter.applyGetDocumentResult(documentResult, to: dom)

        _ = try await transport.send(
            ProtocolCommand(
                domain: .network,
                method: "Network.enable",
                routing: .octopus(pageTarget: mainTargetID)
            )
        )
        try ensureCurrentTransport(transport)
    }

    private func sendTargetCommand(
        domain: ProtocolDomain,
        method: String,
        targetID: ProtocolTargetIdentifier,
        transport: TransportSession
    ) async throws -> ProtocolCommandResult {
        try await transport.send(
            ProtocolCommand(
                domain: domain,
                method: method,
                routing: .target(targetID)
            )
        )
    }

    private func startPumps(transport: TransportSession) async {
        stopPumps()
        let targetPump = V2_DomainEventPump()
        targetPump.start(stream: await transport.events(for: .target)) { [weak self] event in
            self?.applyEvent(event) {
                try DOMTransportAdapter.applyTargetEvent(event, to: $0.dom)
            }
        }

        let runtimePump = V2_DomainEventPump()
        runtimePump.start(stream: await transport.events(for: .runtime)) { [weak self] event in
            self?.applyEvent(event) {
                try DOMTransportAdapter.applyRuntimeEvent(event, to: $0.dom)
            }
        }

        let domPump = V2_DomainEventPump()
        domPump.start(stream: await transport.events(for: .dom)) { [weak self] event in
            self?.applyEvent(event) {
                try DOMTransportAdapter.applyDOMEvent(event, to: $0.dom)
            }
        }

        let networkPump = V2_DomainEventPump()
        networkPump.start(stream: await transport.events(for: .network)) { [weak self] event in
            self?.applyEvent(event) {
                try NetworkTransportAdapter.applyNetworkEvent(event, to: $0.network)
            }
        }

        pumps = [
            .target: targetPump,
            .runtime: runtimePump,
            .dom: domPump,
            .network: networkPump,
        ]
    }

    private func stopPumps() {
        for pump in pumps.values {
            pump.stop()
        }
        pumps.removeAll()
    }

    private func applyEvent(
        _ event: ProtocolEventEnvelope,
        apply: @MainActor (V2_InspectorSession) throws -> Void
    ) {
        do {
            try apply(self)
        } catch {
            lastError = V2_InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func seedDOMSession(from snapshot: TransportSnapshot) {
        for record in snapshot.targetsByID.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            dom.applyTargetCreated(
                record,
                makeCurrentMainPage: record.id == snapshot.currentMainPageTargetID
                    && record.kind == .page
                    && record.parentFrameID == nil
            )
        }
        for record in snapshot.executionContextsByID.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            dom.applyExecutionContextCreated(record)
        }
    }

    private func waitForAppliedSequence(_ sequence: UInt64, domain: ProtocolDomain) async {
        await pumps[domain]?.waitUntilApplied(
            sequence,
            timeout: configuration.eventApplicationTimeout
        )
    }

    private func activeTransport() throws -> TransportSession {
        guard case .attached = attachmentState,
              let transport else {
            throw V2_InspectorSessionError("Inspector session is not attached.")
        }
        return transport
    }

    private func ensureCurrentTransport(_ candidate: TransportSession) throws {
        guard transport === candidate else {
            throw TransportError.transportClosed
        }
    }

    private func requestNodeResultMayNeedDOMPathPush(
        _ result: ProtocolCommandResult,
        targetID: ProtocolTargetIdentifier,
        domSequence: UInt64
    ) -> Bool {
        guard domSequence > 0,
              let payload = try? TransportMessageParser.decode(RequestNodeResultPayload.self, from: result.resultData) else {
            return false
        }
        let key = DOMNodeCurrentKey(targetID: targetID, nodeID: payload.nodeId)
        return dom.snapshot().currentNodeIDByKey[key] == nil
    }

    package static func prepareInspectability(for webView: WKWebView) -> Bool? {
        guard #available(iOS 16.4, macOS 13.3, *) else {
            return nil
        }

        let originalValue = webView.isInspectable
        webView.isInspectable = true
        return originalValue
    }

    package static func restoreInspectabilityIfNeeded(on webView: WKWebView, originalValue: Bool?) {
        guard #available(iOS 16.4, macOS 13.3, *),
              let originalValue else {
            return
        }
        webView.isInspectable = originalValue
    }

    private func restoreInspectabilityIfNeeded() {
        guard let inspectableWebView else {
            originalInspectability = nil
            return
        }
        Self.restoreInspectabilityIfNeeded(on: inspectableWebView, originalValue: originalInspectability)
        self.inspectableWebView = nil
        originalInspectability = nil
    }
}

private final class TransportReceiver: @unchecked Sendable {
    private struct State: Sendable {
        var transport: TransportSession?
        var messages: [String] = []
        var isDraining = false
    }

    private let state = Mutex(State())

    func setTransport(_ transport: TransportSession) {
        state.withLock {
            $0.transport = transport
        }
    }

    func receive(_ message: String) {
        let shouldStartDraining = state.withLock {
            $0.messages.append(message)
            guard !$0.isDraining else {
                return false
            }
            $0.isDraining = true
            return true
        }

        guard shouldStartDraining else {
            return
        }
        Task {
            await drain()
        }
    }

    private func drain() async {
        while let next = nextMessage() {
            await next.transport?.receiveRootMessage(next.message)
        }
    }

    private func nextMessage() -> (transport: TransportSession?, message: String)? {
        state.withLock {
            guard !$0.messages.isEmpty else {
                $0.isDraining = false
                return nil
            }
            return ($0.transport, $0.messages.removeFirst())
        }
    }
}

private struct RequestNodeResultPayload: Decodable {
    var nodeId: DOMProtocolNodeID
}
