import Foundation
import OSLog
import WebInspectorEngine
import WebKit

@MainActor
final class ConsoleTransportDriver: WIConsoleBackend, InspectorTransportCapabilityProviding {
    weak var webView: WKWebView?
    let store = ConsoleStore()

    private let logger = Logger(subsystem: "WebInspectorKit", category: "ConsoleTransportDriver")
    private let codec = WITransportCodec.shared
    private let transportSessionFactory: @MainActor () -> WITransportSession
    private let initialSupport: WIBackendSupport
    private let consoleObjectGroup = "console"

    private var transportSession: WITransportSession?
    private var attachTask: Task<Void, Never>?
    private var pageEventTask: Task<Void, Never>?
    private var enableTask: Task<Void, Never>?
    private var enabledTargetIdentifier: String?
    private var executionContextsByIdentifier: [Int: ConsoleWire.Transport.ExecutionContextDescription] = [:]
    private var currentGroupDepth = 0
    private weak var lastRepeatableEntry: WIConsoleEntry?

    init(
        transportSessionFactory: @escaping @MainActor () -> WITransportSession = { WITransportSession() },
        initialSupport: WIBackendSupport = WITransportSession().supportSnapshot.backendSupport
    ) {
        self.transportSessionFactory = transportSessionFactory
        self.initialSupport = initialSupport
    }

    isolated deinit {
        attachTask?.cancel()
        pageEventTask?.cancel()
        enableTask?.cancel()
    }

    package var inspectorTransportCapabilities: Set<InspectorTransportCapability> {
        guard let supportSnapshot = transportSession?.supportSnapshot else {
            return []
        }

        var mapped: Set<InspectorTransportCapability> = []
        if supportSnapshot.capabilities.contains(.consoleDomain) {
            mapped.insert(.consoleDomain)
        }
        if supportSnapshot.capabilities.contains(.pageTargetRouting) {
            mapped.insert(.pageTargetRouting)
        }
        return mapped
    }

    package var inspectorTransportSupportSnapshot: WITransportSupportSnapshot? {
        transportSession?.supportSnapshot
    }

    var support: WIBackendSupport {
        transportSession?.supportSnapshot.backendSupport ?? initialSupport
    }

    func attachPageWebView(_ newWebView: WKWebView?) async {
        guard webView !== newWebView || transportSession == nil else {
            return
        }

        detachTransportSession()
        webView = newWebView

        guard let newWebView else {
            return
        }

        startTransportSessionAttachment(for: newWebView)
    }

    func detachPageWebView() async {
        detachTransportSession()
        webView = nil
    }

    func clearConsole() async {
        store.clear(reason: .frontend)
        resetEntryAggregationState()

        guard let transportSession else {
            return
        }

        do {
            _ = try await transportSession.sendPageData(
                method: WITransportMethod.Console.clearMessages
            )
        } catch {
            logger.error("clear console failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func evaluate(_ expression: String) async {
        let trimmedExpression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedExpression.isEmpty == false else {
            return
        }

        appendCommandEntry(trimmedExpression)

        guard let transportSession else {
            appendSyntheticResultEntry(
                renderedText: support.failureReason ?? "Console is unavailable.",
                level: .error,
                wasThrown: true
            )
            return
        }

        do {
            let response = try await codec.decode(
                ConsoleWire.Transport.EvaluateResponse.self,
                from: try await transportSession.sendPageData(
                    method: WITransportMethod.Runtime.evaluate,
                    parametersData: try await codec.encode(
                        EvaluateParameters(
                            expression: trimmedExpression,
                            objectGroup: consoleObjectGroup,
                            includeCommandLineAPI: true,
                            doNotPauseOnExceptionsAndMuteConsole: false,
                            returnByValue: false,
                            generatePreview: false,
                            saveResult: true,
                            emulateUserGesture: false
                        )
                    )
                )
            )

            let renderedObject = render(remoteObject: response.result)
            let renderedText: String
            if let savedResultIndex = response.savedResultIndex {
                renderedText = "$\(savedResultIndex) = \(renderedObject)"
            } else {
                renderedText = renderedObject
            }
            appendSyntheticResultEntry(
                renderedText: renderedText,
                level: response.wasThrown == true ? .error : .log,
                wasThrown: response.wasThrown == true,
                savedResultIndex: response.savedResultIndex
            )
        } catch {
            appendSyntheticResultEntry(
                renderedText: error.localizedDescription,
                level: .error,
                wasThrown: true
            )
        }
    }

    func tearDownForDeinit() {
        detachTransportSession()
        webView = nil
        resetRuntimeState()
    }
}

extension ConsoleTransportDriver {
    package func waitForAttachForTesting() async {
        await attachTask?.value
    }
}

private extension ConsoleTransportDriver {
    struct EvaluateParameters: Encodable, Sendable {
        let expression: String
        let objectGroup: String
        let includeCommandLineAPI: Bool
        let doNotPauseOnExceptionsAndMuteConsole: Bool
        let returnByValue: Bool
        let generatePreview: Bool
        let saveResult: Bool
        let emulateUserGesture: Bool
    }

    struct SetConsoleClearAPIEnabledParameters: Encodable, Sendable {
        let enable: Bool
    }

    struct ReleaseObjectGroupParameters: Encodable, Sendable {
        let objectGroup: String
    }

    func startTransportSessionAttachment(for webView: WKWebView) {
        let transportSession = transportSessionFactory()
        self.transportSession = transportSession

        attachTask = Task { @MainActor [weak self, weak transportSession] in
            guard let self, let transportSession else {
                return
            }
            defer {
                self.attachTask = nil
            }

            do {
                try await transportSession.attach(to: webView)
            } catch {
                self.logger.error("console transport attach failed: \(error.localizedDescription, privacy: .public)")
                if self.transportSession === transportSession {
                    self.transportSession = nil
                }
                return
            }

            self.startPageEventLoop(using: transportSession)
            self.scheduleDomainEnable(using: transportSession)
        }
    }

    func detachTransportSession() {
        attachTask?.cancel()
        attachTask = nil
        pageEventTask?.cancel()
        pageEventTask = nil
        enableTask?.cancel()
        enableTask = nil

        if let transportSession {
            Task { @MainActor [weak self, weak transportSession] in
                guard let self, let transportSession, self.transportSession === transportSession else {
                    return
                }
                try? await self.releaseObjectGroupIfPossible(using: transportSession)
            }
            transportSession.detach()
        }

        transportSession = nil
        resetRuntimeState()
    }

    func startPageEventLoop(using transportSession: WITransportSession) {
        pageEventTask?.cancel()
        let stream = transportSession.pageEvents()
        pageEventTask = Task { @MainActor [weak self, weak transportSession] in
            guard let self, let transportSession else {
                return
            }

            for await envelope in stream {
                guard self.transportSession === transportSession else {
                    break
                }
                await self.handlePageEvent(envelope, session: transportSession)
            }

            if self.transportSession === transportSession {
                self.pageEventTask = nil
            }
        }
    }

    func scheduleDomainEnable(using transportSession: WITransportSession) {
        enableTask?.cancel()
        enableTask = Task { @MainActor [weak self, weak transportSession] in
            guard let self, let transportSession else {
                return
            }

            while self.transportSession === transportSession {
                do {
                    let targetIdentifier: String
                    if let currentPageTargetIdentifier = transportSession.currentPageTargetIdentifier() {
                        targetIdentifier = currentPageTargetIdentifier
                    } else {
                        targetIdentifier = try await transportSession.waitForPageTarget()
                    }

                    guard self.enabledTargetIdentifier != targetIdentifier else {
                        return
                    }

                    try await self.enableDomains(on: targetIdentifier, session: transportSession)
                    self.enabledTargetIdentifier = targetIdentifier
                    return
                } catch is CancellationError {
                    return
                } catch let error as WITransportError {
                    guard self.shouldRetry(after: error) else {
                        self.logger.error("console domain enable failed: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    await self.yieldToMainQueue()
                } catch {
                    self.logger.error("console domain enable failed: \(error.localizedDescription, privacy: .public)")
                    return
                }
            }
        }
    }

    func shouldRetry(after error: WITransportError) -> Bool {
        switch error {
        case .pageTargetUnavailable:
            return true
        case .requestTimedOut(let scope, let method):
            return scope == .root && method == "Target.targetCreated"
        case .remoteError(let scope, let method, _):
            return scope == .root && method == "Target.sendMessageToTarget"
        default:
            return false
        }
    }

    func enableDomains(
        on targetIdentifier: String,
        session: WITransportSession
    ) async throws {
        _ = try await session.sendPageData(
            method: WITransportMethod.Runtime.enable,
            targetIdentifier: targetIdentifier
        )
        _ = try await session.sendPageData(
            method: WITransportMethod.Console.enable,
            targetIdentifier: targetIdentifier
        )
        _ = try await session.sendPageData(
            method: WITransportMethod.Console.setConsoleClearAPIEnabled,
            targetIdentifier: targetIdentifier,
            parametersData: try await codec.encode(
                SetConsoleClearAPIEnabledParameters(enable: true)
            )
        )
    }

    func releaseObjectGroupIfPossible(using session: WITransportSession) async throws {
        _ = try await session.sendPageData(
            method: WITransportMethod.Runtime.releaseObjectGroup,
            parametersData: try await codec.encode(
                ReleaseObjectGroupParameters(objectGroup: consoleObjectGroup)
            )
        )
    }

    func handlePageEvent(
        _ envelope: WITransportEventEnvelope,
        session: WITransportSession
    ) async {
        switch envelope.method {
        case "Target.targetCreated", "Target.didCommitProvisionalTarget", "Target.targetDestroyed":
            resetRuntimeState()
            scheduleDomainEnable(using: session)

        case "Runtime.executionContextCreated":
            guard let event = decodeParams(ConsoleWire.Transport.ExecutionContextCreatedEvent.self, from: envelope) else {
                return
            }
            executionContextsByIdentifier[event.context.id] = event.context

        case "Console.messageAdded":
            guard let event = decodeParams(ConsoleWire.Transport.MessageAddedEvent.self, from: envelope) else {
                return
            }
            appendRemoteMessage(event.message)

        case "Console.messageRepeatCountUpdated":
            guard let event = decodeParams(ConsoleWire.Transport.MessageRepeatCountUpdatedEvent.self, from: envelope) else {
                return
            }
            lastRepeatableEntry?.updateRepeatCount(
                event.count,
                timestamp: event.timestamp.map(Date.init(timeIntervalSince1970:))
            )
            store.updateRepeatCount(
                forLastEntry: event.count,
                timestamp: event.timestamp.map(Date.init(timeIntervalSince1970:))
            )

        case "Console.messagesCleared":
            let event = decodeParams(ConsoleWire.Transport.MessagesClearedEvent.self, from: envelope)
            store.clear(reason: event?.reason)
            resetEntryAggregationState()

        default:
            break
        }
    }

    func appendRemoteMessage(_ message: ConsoleWire.Transport.ConsoleMessage) {
        let messageType = message.type ?? .log
        let entryDepth: Int
        if messageType == .endGroup {
            currentGroupDepth = max(0, currentGroupDepth - 1)
            lastRepeatableEntry = nil
            return
        }

        entryDepth = currentGroupDepth
        let renderedText = render(message: message)
        let location = makeLocation(from: message)
        let stackFrames = flatten(stackTrace: message.stackTrace)
        let timestamp = message.timestamp.map(Date.init(timeIntervalSince1970:)) ?? .now

        let entry = WIConsoleEntry(
            kind: .message,
            source: message.source,
            level: message.level,
            type: messageType,
            text: message.text,
            renderedText: renderedText,
            timestamp: timestamp,
            repeatCount: message.repeatCount ?? 1,
            nestingLevel: entryDepth,
            networkRequestID: message.networkRequestId,
            location: location,
            stackFrames: stackFrames
        )
        store.append(entry)
        lastRepeatableEntry = entry

        if messageType == .startGroup || messageType == .startGroupCollapsed {
            currentGroupDepth += 1
        }
    }

    func appendCommandEntry(_ expression: String) {
        let entry = WIConsoleEntry(
            kind: .command,
            source: .other,
            level: .log,
            type: .command,
            text: expression,
            renderedText: expression,
            nestingLevel: 0
        )
        store.append(entry)
        lastRepeatableEntry = nil
    }

    func appendSyntheticResultEntry(
        renderedText: String,
        level: WIConsoleMessageLevel,
        wasThrown: Bool,
        savedResultIndex: Int? = nil
    ) {
        let entry = WIConsoleEntry(
            kind: .result,
            source: .javascript,
            level: level,
            type: .result,
            text: renderedText,
            renderedText: renderedText,
            savedResultIndex: savedResultIndex,
            wasThrown: wasThrown,
            nestingLevel: 0
        )
        store.append(entry)
        lastRepeatableEntry = nil
    }

    func render(message: ConsoleWire.Transport.ConsoleMessage) -> String {
        let renderedParameters = (message.parameters ?? []).map(render(remoteObject:))
        if message.text.isEmpty {
            return renderedParameters.joined(separator: " ")
        }
        guard renderedParameters.isEmpty == false else {
            return message.text
        }
        return ([message.text] + renderedParameters).joined(separator: " ")
    }

    func render(remoteObject: ConsoleWire.Transport.RemoteObject) -> String {
        if let value = remoteObject.value {
            return value.summary
        }
        if let description = remoteObject.description, description.isEmpty == false {
            return description
        }
        if let className = remoteObject.className, className.isEmpty == false {
            return className
        }
        if let subtype = remoteObject.subtype, subtype.isEmpty == false {
            return subtype
        }
        return remoteObject.type
    }

    func makeLocation(from message: ConsoleWire.Transport.ConsoleMessage) -> WIConsoleEntry.Location? {
        if let url = message.url, url.isEmpty == false {
            return .init(url: url, line: message.line, column: message.column)
        }
        guard let firstFrame = message.stackTrace?.callFrames.first else {
            return nil
        }
        return .init(
            url: firstFrame.url,
            line: firstFrame.lineNumber,
            column: firstFrame.columnNumber
        )
    }

    func flatten(stackTrace: ConsoleWire.Transport.StackTrace?) -> [WIConsoleEntry.StackFrame] {
        guard let stackTrace else {
            return []
        }

        var result: [WIConsoleEntry.StackFrame] = stackTrace.callFrames.map { frame in
            WIConsoleEntry.StackFrame(
                functionName: frame.functionName,
                url: frame.url,
                line: frame.lineNumber,
                column: frame.columnNumber
            )
        }
        if let parentStackTrace = stackTrace.parentStackTrace {
            result.append(contentsOf: flatten(stackTrace: parentStackTrace))
        }
        return result
    }

    func resetEntryAggregationState() {
        currentGroupDepth = 0
        lastRepeatableEntry = nil
    }

    func resetRuntimeState() {
        enabledTargetIdentifier = nil
        executionContextsByIdentifier.removeAll()
        resetEntryAggregationState()
    }

    func yieldToMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    func decodeParams<T: Decodable>(
        _ type: T.Type,
        from envelope: WITransportEventEnvelope
    ) -> T? {
        do {
            return try JSONDecoder().decode(type, from: envelope.paramsData)
        } catch {
            logger.error("console event decode failed method=\(envelope.method, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
