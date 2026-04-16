import Foundation
import OSLog
import WebInspectorEngine
import WebKit

@MainActor
final class ConsoleTransportDriver: WIConsoleBackend, InspectorTransportCapabilityProviding {
    weak var webView: WKWebView?
    let store = ConsoleStore()

    var isReadyToReceiveConsole: Bool {
        enabledTargetIdentifier != nil
    }

    private let logger = Logger(subsystem: "WebInspectorKit", category: "ConsoleTransportDriver")
    private let codec = WITransportCodec.shared
    private let transportSessionFactory: @MainActor () -> WITransportSession
    private let initialSupport: WIBackendSupport
    private let consoleObjectGroup = "console"

    private var transportSession: WITransportSession?
    private var attachTask: Task<Void, Never>?
    private var pageEventTask: Task<Void, Never>?
    private var enableTask: Task<Void, Never>?
    private var activeEnableTaskID: UUID?
    private var pendingDetachTask: Task<Void, Never>?
    private var enabledTargetIdentifier: String?
    private var executionContextsByIdentifier: [Int: ConsoleWire.Transport.ExecutionContextDescription] = [:]
    private var currentGroupDepth = 0
    private weak var lastRepeatableEntry: WIConsoleEntry?
    private var clearsStoreOnNextAttach = false
    private var pendingFrontendClearEchoCountsByTarget: [String: Int] = [:]
    private var attachFailureSupport: WIBackendSupport?
    private var pendingRemoteClearOnNextEnable = false
    private var pageReadinessObservations: [NSKeyValueObservation] = []

    init(
        transportSessionFactory: @escaping @MainActor () -> WITransportSession = { WITransportSession() },
        initialSupport: WIBackendSupport = WITransportSession().supportSnapshot.backendSupport
    ) {
        self.transportSessionFactory = transportSessionFactory
        self.initialSupport = initialSupport
    }

    isolated deinit {
        detachTransportSession()
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
        transportSession?.supportSnapshot.backendSupport
            ?? attachFailureSupport
            ?? initialSupport
    }

    func attachPageWebView(_ newWebView: WKWebView?) async {
        guard webView !== newWebView || transportSession == nil else {
            return
        }

        let shouldClearStoreOnReattach = newWebView != nil
            && store.entries.isEmpty == false
            && (clearsStoreOnNextAttach || (webView != nil && webView !== newWebView))

        detachTransportSession()
        await waitForPendingDetach()
        webView = newWebView
        updatePageReadinessObservation(for: newWebView)
        clearsStoreOnNextAttach = false

        if shouldClearStoreOnReattach {
            resetStoreState(reason: .mainFrameNavigation)
        }

        guard let newWebView else {
            return
        }

        startTransportSessionAttachment(for: newWebView)
    }

    func detachPageWebView(clearsStoreOnNextAttach: Bool) async {
        detachTransportSession(clearsStoreOnNextAttach: clearsStoreOnNextAttach)
        webView = nil
        updatePageReadinessObservation(for: nil)
    }

    func detachPageWebView() async {
        await detachPageWebView(clearsStoreOnNextAttach: true)
    }

    func clearConsole() async {
        store.clear(reason: .frontend)
        resetEntryAggregationState()

        guard let transportSession else {
            pendingRemoteClearOnNextEnable = true
            return
        }

        let targetIdentifier = await resolveEnabledTargetIdentifierForUserInteraction(
            using: transportSession
        )
        guard let targetIdentifier else {
            pendingRemoteClearOnNextEnable = true
            return
        }

        incrementPendingFrontendClearEcho(for: targetIdentifier)
        do {
            try await Self.releaseObjectGroupIfPossible(
                using: transportSession,
                codec: codec,
                objectGroup: consoleObjectGroup,
                targetIdentifier: targetIdentifier
            )
            _ = try await transportSession.sendPageData(
                method: WITransportMethod.Console.clearMessages,
                targetIdentifier: targetIdentifier
            )
        } catch {
            decrementPendingFrontendClearEcho(for: targetIdentifier)
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

        guard let targetIdentifier = await resolveEnabledTargetIdentifierForUserInteraction(
            using: transportSession
        ) else {
            appendSyntheticResultEntry(
                renderedText: "Console is unavailable.",
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
                    targetIdentifier: targetIdentifier,
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
        detachTransportSession(clearsStoreOnNextAttach: true)
        webView = nil
        clearsStoreOnNextAttach = false
        resetStoreState()
        resetRuntimeState()
    }
}

extension ConsoleTransportDriver {
    package func waitForAttachForTesting() async {
        await attachTask?.value
    }

    package func waitForEnableForTesting() async {
        await attachTask?.value
        await enableTask?.value
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
        attachFailureSupport = nil

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
                self.attachFailureSupport = WIBackendSupport(
                    availability: .unsupported,
                    backendKind: self.initialSupport.backendKind,
                    capabilities: self.initialSupport.capabilities,
                    failureReason: error.localizedDescription
                )
                self.store.markUpdated()
                if self.transportSession === transportSession {
                    self.transportSession = nil
                }
                return
            }

            guard self.transportSession === transportSession, Task.isCancelled == false else {
                transportSession.detach()
                return
            }

            self.attachFailureSupport = nil
            self.startPageEventLoop(using: transportSession)
            self.scheduleDomainEnable(using: transportSession)
        }
    }

    func detachTransportSession(clearsStoreOnNextAttach: Bool = true) {
        attachTask?.cancel()
        attachTask = nil
        pageEventTask?.cancel()
        pageEventTask = nil
        enableTask?.cancel()
        enableTask = nil
        activeEnableTaskID = nil

        if let transportSession {
            let codec = self.codec
            let logger = self.logger
            let objectGroup = consoleObjectGroup
            let targetIdentifier = transportSession.currentPageTargetIdentifier() ?? enabledTargetIdentifier
            pendingDetachTask = Task { @MainActor in
                defer {
                    transportSession.detach()
                }
                do {
                    try await Self.releaseObjectGroupIfPossible(
                        using: transportSession,
                        codec: codec,
                        objectGroup: objectGroup,
                        targetIdentifier: targetIdentifier
                    )
                } catch {
                    logger.debug("release object group failed during detach: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        transportSession = nil
        attachFailureSupport = nil
        self.clearsStoreOnNextAttach = clearsStoreOnNextAttach
        pendingFrontendClearEchoCountsByTarget.removeAll()
        pendingRemoteClearOnNextEnable = false
        resetRuntimeState()
    }

    func updatePageReadinessObservation(for webView: WKWebView?) {
        pageReadinessObservations.removeAll()
        guard let webView else {
            return
        }

        pageReadinessObservations = [
            webView.observe(\.isLoading, options: [.initial, .new]) { _, _ in
                let _ = Task { @MainActor [weak self, weak webView] in
                    self?.handleObservedPageReadinessChange(for: webView)
                }
            },
            webView.observe(\.url, options: [.initial, .new]) { _, _ in
                let _ = Task { @MainActor [weak self, weak webView] in
                    self?.handleObservedPageReadinessChange(for: webView)
                }
            },
        ]
    }

    func handleObservedPageReadinessChange(for observedWebView: WKWebView?) {
        guard let observedWebView,
              webView === observedWebView,
              let transportSession,
              enabledTargetIdentifier == nil,
              shouldWaitForPageReadinessBeforeEnable() == false,
              activeEnableTaskID == nil
        else {
            return
        }
        scheduleDomainEnable(using: transportSession)
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
        let taskIdentifier = UUID()
        activeEnableTaskID = taskIdentifier
        enableTask = Task { @MainActor [weak self, weak transportSession] in
            guard let self, let transportSession else {
                return
            }
            defer {
                if self.activeEnableTaskID == taskIdentifier {
                    self.activeEnableTaskID = nil
                }
            }

            guard self.shouldWaitForPageReadinessBeforeEnable() == false else {
                return
            }

            do {
                let targetIdentifier = try await self.prepareEnabledPageTarget(using: transportSession)
                guard self.transportSession === transportSession else {
                    return
                }
                self.enabledTargetIdentifier = targetIdentifier
            } catch is CancellationError {
                return
            } catch {
                self.failCurrentTransportSession(
                    using: transportSession,
                    failureReason: error.localizedDescription
                )
            }
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

    static func releaseObjectGroupIfPossible(
        using session: WITransportSession,
        codec: WITransportCodec,
        objectGroup: String,
        targetIdentifier: String?
    ) async throws {
        guard let targetIdentifier else {
            return
        }
        _ = try await session.sendPageData(
            method: WITransportMethod.Runtime.releaseObjectGroup,
            targetIdentifier: targetIdentifier,
            parametersData: try await codec.encode(
                ReleaseObjectGroupParameters(objectGroup: objectGroup)
            )
        )
    }

    func handlePageEvent(
        _ envelope: WITransportEventEnvelope,
        session: WITransportSession
    ) async {
        switch envelope.method {
        case "Target.targetCreated":
            break

        case "Target.targetDestroyed":
            guard envelope.targetIdentifier == enabledTargetIdentifier else {
                return
            }
            resetRuntimeState()
            scheduleDomainEnable(using: session)

        case "Target.didCommitProvisionalTarget":
            resetStoreState(reason: .mainFrameNavigation)
            resetRuntimeState()
            scheduleDomainEnable(using: session)

        case "Runtime.executionContextCreated":
            guard shouldProcess(envelope, session: session) else {
                return
            }
            guard let event = decodeParams(ConsoleWire.Transport.ExecutionContextCreatedEvent.self, from: envelope) else {
                return
            }
            executionContextsByIdentifier[event.context.id] = event.context

        case "Console.messageAdded":
            guard shouldProcess(envelope, session: session) else {
                return
            }
            guard let event = decodeParams(ConsoleWire.Transport.MessageAddedEvent.self, from: envelope) else {
                return
            }
            appendRemoteMessage(event.message)

        case "Console.messageRepeatCountUpdated":
            guard shouldProcess(envelope, session: session) else {
                return
            }
            guard let event = decodeParams(ConsoleWire.Transport.MessageRepeatCountUpdatedEvent.self, from: envelope) else {
                return
            }
            if let lastRepeatableEntry {
                store.updateRepeatCount(
                    for: lastRepeatableEntry,
                    count: event.count,
                    timestamp: event.timestamp.map(Date.init(timeIntervalSince1970:))
                )
            }

        case "Console.messagesCleared":
            guard shouldProcess(envelope, session: session) else {
                return
            }
            let event = decodeParams(ConsoleWire.Transport.MessagesClearedEvent.self, from: envelope)
            if event?.reason == .frontend,
               consumePendingFrontendClearEcho(
                for: envelope.targetIdentifier ?? enabledTargetIdentifier
               ) {
                return
            }
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
        if let formattedParameters = renderConsoleParameters(message.parameters ?? []) {
            let leadingParameterString: String?
            if case let .string(stringValue)? = message.parameters?.first?.value {
                leadingParameterString = stringValue
            } else {
                leadingParameterString = nil
            }

            if message.text.isEmpty
                || message.text == formattedParameters
                || message.text == leadingParameterString {
                return formattedParameters
            }
            return [message.text, formattedParameters]
                .filter { $0.isEmpty == false }
                .joined(separator: " ")
        }

        let renderedParameters = (message.parameters ?? []).map(renderConsoleParameter(remoteObject:))
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

    func renderConsoleParameter(remoteObject: ConsoleWire.Transport.RemoteObject) -> String {
        if case let .string(stringValue)? = remoteObject.value {
            return stringValue
        }
        return render(remoteObject: remoteObject)
    }

    func renderConsoleParameters(_ parameters: [ConsoleWire.Transport.RemoteObject]) -> String? {
        guard parameters.isEmpty == false else {
            return nil
        }
        guard case let .string(formatString)? = parameters.first?.value else {
            return parameters.map(renderConsoleParameter(remoteObject:)).joined(separator: " ")
        }

        let renderedArguments = Array(parameters.dropFirst()).map(renderConsoleParameter(remoteObject:))
        guard formatString.contains("%") else {
            return ([formatString] + renderedArguments).joined(separator: " ")
        }

        var formatted = ""
        var argumentIndex = 0
        var cursor = formatString.startIndex
        var replacedAnyPlaceholder = false

        while cursor < formatString.endIndex {
            let character = formatString[cursor]
            guard character == "%" else {
                formatted.append(character)
                cursor = formatString.index(after: cursor)
                continue
            }

            let nextIndex = formatString.index(after: cursor)
            guard nextIndex < formatString.endIndex else {
                formatted.append(character)
                break
            }

            let specifier = formatString[nextIndex]
            if specifier == "%" {
                formatted.append("%")
                cursor = formatString.index(after: nextIndex)
                continue
            }

            guard ["s", "d", "i", "f", "o", "O", "c", "@"].contains(specifier),
                  argumentIndex < renderedArguments.count else {
                formatted.append(character)
                cursor = nextIndex
                continue
            }

            if specifier != "c" {
                formatted.append(renderedArguments[argumentIndex])
            }
            argumentIndex += 1
            replacedAnyPlaceholder = true
            cursor = formatString.index(after: nextIndex)
        }

        guard replacedAnyPlaceholder else {
            return ([formatString] + renderedArguments).joined(separator: " ")
        }

        if argumentIndex < renderedArguments.count {
            formatted += " " + renderedArguments[argumentIndex...].joined(separator: " ")
        }
        return formatted
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

    func resetStoreState(reason: WIConsoleClearReason? = nil) {
        store.clear(reason: reason)
    }

    func waitForPendingDetach() async {
        let pendingDetachTask = self.pendingDetachTask
        self.pendingDetachTask = nil
        await pendingDetachTask?.value
    }

    func resolveEnabledTargetIdentifierForUserInteraction(
        using session: WITransportSession
    ) async -> String? {
        if let attachTask {
            await attachTask.value
        }

        if let currentPageTargetIdentifier = session.currentPageTargetIdentifier(),
           currentPageTargetIdentifier == enabledTargetIdentifier {
            return currentPageTargetIdentifier
        }

        if let enableTask {
            await enableTask.value
        }

        guard let currentPageTargetIdentifier = session.currentPageTargetIdentifier(),
              currentPageTargetIdentifier == enabledTargetIdentifier else {
            return nil
        }
        return currentPageTargetIdentifier
    }

    func prepareEnabledPageTarget(using session: WITransportSession) async throws -> String {
        var targetIdentifier = try await currentOrInitialPageTarget(using: session)

        while true {
            guard enabledTargetIdentifier != targetIdentifier else {
                return targetIdentifier
            }

            do {
                try await enableDomains(on: targetIdentifier, session: session)
                await yieldToMainQueue()

                if session.currentPageTargetIdentifier() == targetIdentifier {
                    try await replayDeferredClearIfNeeded(
                        on: targetIdentifier,
                        session: session
                    )
                    await yieldToMainQueue()

                    if session.currentPageTargetIdentifier() == targetIdentifier {
                        pendingRemoteClearOnNextEnable = false
                        return targetIdentifier
                    }
                }

                targetIdentifier = try await session.waitForReplacementPageTarget(after: targetIdentifier)
            } catch let error as WITransportError {
                guard let replacementTargetIdentifier = try await replacementTargetAfterEnableFailure(
                    after: error,
                    targetIdentifier: targetIdentifier,
                    session: session
                ) else {
                    throw error
                }
                targetIdentifier = replacementTargetIdentifier
            }
        }
    }

    func currentOrInitialPageTarget(using session: WITransportSession) async throws -> String {
        if let currentPageTargetIdentifier = session.currentPageTargetIdentifier() {
            return currentPageTargetIdentifier
        }
        return try await session.waitForPageTarget()
    }

    func replayDeferredClearIfNeeded(
        on targetIdentifier: String,
        session: WITransportSession
    ) async throws {
        guard pendingRemoteClearOnNextEnable else {
            return
        }

        incrementPendingFrontendClearEcho(for: targetIdentifier)
        do {
            try await Self.releaseObjectGroupIfPossible(
                using: session,
                codec: codec,
                objectGroup: consoleObjectGroup,
                targetIdentifier: targetIdentifier
            )
            _ = try await session.sendPageData(
                method: WITransportMethod.Console.clearMessages,
                targetIdentifier: targetIdentifier
            )
        } catch {
            decrementPendingFrontendClearEcho(for: targetIdentifier)
            logger.error("deferred console clear failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func replacementTargetAfterEnableFailure(
        after error: WITransportError,
        targetIdentifier: String,
        session: WITransportSession
    ) async throws -> String? {
        switch error {
        case .pageTargetUnavailable:
            if let currentPageTargetIdentifier = session.currentPageTargetIdentifier(),
               currentPageTargetIdentifier != targetIdentifier {
                return currentPageTargetIdentifier
            }
            return try? await session.waitForReplacementPageTarget(after: targetIdentifier)

        case .remoteError(let scope, _, let message):
            guard scope == .root, Self.isTargetChurnMessage(message.lowercased()) else {
                return nil
            }
            await yieldToMainQueue()
            if let currentPageTargetIdentifier = session.currentPageTargetIdentifier(),
               currentPageTargetIdentifier != targetIdentifier {
                return currentPageTargetIdentifier
            }
            return try? await session.waitForReplacementPageTarget(after: targetIdentifier)

        default:
            return nil
        }
    }

    func shouldWaitForPageReadinessBeforeEnable() -> Bool {
        guard transportSession?.supportSnapshot.backendKind == .iOSNativeInspector,
              enabledTargetIdentifier == nil,
              let webView else {
            return false
        }

        guard let url = webView.url else {
            return true
        }
        if webView.isLoading {
            return true
        }
        return url.absoluteString == "about:blank"
    }

    func failCurrentTransportSession(
        using session: WITransportSession,
        failureReason: String
    ) {
        guard transportSession === session else {
            return
        }
        logger.error("console domain enable failed: \(failureReason, privacy: .public)")
        attachFailureSupport = WIBackendSupport(
            availability: .unsupported,
            backendKind: initialSupport.backendKind,
            capabilities: initialSupport.capabilities,
            failureReason: failureReason
        )
        store.markUpdated()
        session.detach()
        transportSession = nil
        resetRuntimeState()
    }

    func shouldProcess(
        _ envelope: WITransportEventEnvelope,
        session: WITransportSession
    ) -> Bool {
        guard let targetIdentifier = envelope.targetIdentifier else {
            return true
        }
        if let currentPageTargetIdentifier = session.currentPageTargetIdentifier() {
            return currentPageTargetIdentifier == targetIdentifier
        }
        if let enabledTargetIdentifier {
            return enabledTargetIdentifier == targetIdentifier
        }
        return false
    }

    func incrementPendingFrontendClearEcho(for targetIdentifier: String) {
        pendingFrontendClearEchoCountsByTarget[targetIdentifier, default: 0] += 1
    }

    func decrementPendingFrontendClearEcho(for targetIdentifier: String) {
        let nextCount = max(0, pendingFrontendClearEchoCountsByTarget[targetIdentifier, default: 0] - 1)
        if nextCount == 0 {
            pendingFrontendClearEchoCountsByTarget.removeValue(forKey: targetIdentifier)
        } else {
            pendingFrontendClearEchoCountsByTarget[targetIdentifier] = nextCount
        }
    }

    func consumePendingFrontendClearEcho(for targetIdentifier: String?) -> Bool {
        guard let targetIdentifier,
              pendingFrontendClearEchoCountsByTarget[targetIdentifier, default: 0] > 0 else {
            return false
        }
        decrementPendingFrontendClearEcho(for: targetIdentifier)
        return true
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

private extension ConsoleTransportDriver {
    static func isTargetChurnMessage(_ message: String) -> Bool {
        message.contains("not found")
            || message.contains("no target")
            || message.contains("closed")
            || message.contains("destroyed")
    }
}
