import Foundation
import OSLog
import WebKit
import WebInspectorNativeBridge

private let logger = Logger(subsystem: "WebInspectorKit", category: "WebInspectorProxy")

private struct ProtocolCommandTarget: Sendable {
    var targetID: WebInspectorTarget.ID
    var route: RoutingTargetID
    var resultTargetScopeRawValue: String?

    init(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        resultTargetScopeRawValue: String? = nil
    ) {
        self.targetID = targetID
        self.route = route
        self.resultTargetScopeRawValue = resultTargetScopeRawValue
    }
}

/// An attached Web Inspector protocol connection for a `WKWebView`.
///
/// `WebInspectorProxy` is a handle to the private WebKit inspector connection.
/// Its connection core owns the current physical page binding and routes typed
/// domain commands through
/// ``WebInspectorTarget`` values.
///
/// Example:
///
/// ```swift
/// let proxy = try await WebInspectorProxy(attachingTo: webView)
/// let page = try await proxy.waitForCurrentPage()
///
/// try await page.runtime.enable()
/// let evaluation = try await page.runtime.evaluate("document.title")
/// print(evaluation.object.description ?? "")
///
/// await proxy.close()
/// ```
public actor WebInspectorProxy {
    /// Timeout configuration for command replies and current-page bootstrap.
    public struct Configuration: Equatable, Sendable {
        /// The maximum time to wait for an individual protocol command reply.
        public var responseTimeout: Duration

        /// The maximum time to wait while discovering or refreshing the current
        /// page target.
        public var bootstrapTimeout: Duration

        /// Creates proxy timeout configuration.
        public init(
            responseTimeout: Duration = .seconds(5),
            bootstrapTimeout: Duration = .seconds(5)
        ) {
            self.responseTimeout = responseTimeout
            self.bootstrapTimeout = bootstrapTimeout
        }
    }

    private let configuration: Configuration
    private let backend: (any WebInspectorProxyBackend)?
    private let core: ConnectionCore

    package nonisolated var structuredEventBackend: (any WebInspectorProxyBackend)? {
        backend
    }

    /// The stable logical page inspected by this connection.
    public nonisolated var page: WebInspectorPage {
        WebInspectorPage(proxy: self)
    }

    /// Attaches a Web Inspector protocol connection to a web view.
    ///
    /// Attach from the main actor because `WKWebView` is a UI object. Use
    /// ``waitForCurrentPage()`` before dispatching page-scoped commands.
    @MainActor
    public init(
        attachingTo webView: WKWebView,
        configuration: Configuration = .init()
    ) async throws {
        let nativeCore: ConnectionCore
        do {
            nativeCore = try await NativeConnectionCoreFactory.attach(
                to: webView,
                responseTimeout: configuration.responseTimeout,
                fatalFailureHandler: { message in
                    logger.error("Native inspector fatal failure: \(message, privacy: .private)")
                }
            )
        } catch {
            throw Self.mapNativeAttachError(error)
        }

        self.configuration = configuration
        backend = LiveWebInspectorProxyBackend(transport: nativeCore)
        core = nativeCore

        do {
            try await bootstrapCurrentPage(from: nativeCore)
        } catch {
            await close()
            throw Self.mapNativeAttachError(error)
        }
    }

    package init(
        configuration: Configuration = .init(),
        backend: (any WebInspectorProxyBackend)? = nil,
        closeConnection: (@Sendable () async -> Void)? = nil
    ) {
        self.configuration = configuration
        self.backend = backend
        core = ConnectionCore(
            backend: UnavailableTransportBackend(),
            responseTimeout: configuration.responseTimeout,
            closeAction: closeConnection
        )
    }

    package init(
        transport: TransportSession,
        configuration: Configuration = .init(),
        closeConnection: (@Sendable () async -> Void)? = nil
    ) async throws {
        self.configuration = configuration
        core = transport
        backend = LiveWebInspectorProxyBackend(transport: transport)

        if let closeConnection {
            await transport.replaceCloseActionForTesting(closeConnection)
        }

        do {
            try await bootstrapCurrentPage(from: transport)
        } catch {
            await close()
            throw Self.mapBootstrapTargetError(error)
        }
    }

    /// The currently known page target, if bootstrap has completed.
    public var currentPage: WebInspectorTarget? {
        get async {
            guard let record = await core.currentMainPageRecord() else {
                return nil
            }
            return try? currentPageTarget(from: record)
        }
    }

    package var currentPageBindingID: String? {
        get async {
            await core.currentMainPageRecord()?.id.rawValue
        }
    }

    /// A Boolean value indicating whether the proxy has an open page target
    /// that can receive reload commands.
    public var canReload: Bool {
        get async {
            await core.currentMainPageRecord() != nil
        }
    }

    /// Waits for and returns the current page target.
    ///
    /// The proxy refreshes its current-page target from the transport when
    /// possible. The method throws if the proxy is closed, detached, or no page
    /// target can be discovered before the bootstrap timeout.
    public func waitForCurrentPage() async throws -> WebInspectorTarget {
        try await ensureOpenForCurrentPageAccess()
        do {
            return try await currentPageTarget(
                from: core,
                timeout: configuration.bootstrapTimeout
            )
        } catch {
            throw Self.mapBootstrapTargetError(error)
        }
    }

    /// Waits for a usable current page target after the previous one was
    /// destroyed. Returns nil when no successor target exists once
    /// `gracePeriod` elapses — page absence is a target-lifecycle fact owned
    /// by the transport registry, distinct from command timeouts. A nil
    /// `gracePeriod` waits indefinitely for the next page target. Throws only
    /// connection-terminal errors.
    package func waitForCurrentPageReplacement(gracePeriod: Duration?) async throws -> WebInspectorTarget? {
        try await ensureOpenForCurrentPageAccess()
        do {
            return try await currentPageTarget(from: core, timeout: gracePeriod)
        } catch TransportSession.Error.missingMainPageTarget {
            return nil
        } catch {
            throw Self.mapBootstrapTargetError(error)
        }
    }

    package var bootstrapGracePeriod: Duration {
        configuration.bootstrapTimeout
    }

    /// Reloads the currently inspected page without ignoring cache.
    public func reload() async throws {
        let pageTarget = try await waitForCurrentPage()
        let _: Void = try await dispatchCommand(
            targetID: pageTarget.id,
            route: pageTarget.route,
            domain: .page,
            method: "reload",
            payload: Page.ReloadPayload(ignoringCache: false)
        )
    }

    /// Closes the inspector connection.
    ///
    /// Calling `close()` more than once is allowed. Await
    /// ``waitUntilClosed()`` when another task needs to observe completion.
    public func close() async {
        await core.close()
    }

    /// Suspends until ``close()`` has finished.
    ///
    /// If the proxy is already closed, this method returns immediately. If the
    /// waiting task is cancelled, only that waiter is cancelled.
    public func waitUntilClosed() async throws {
        try await core.waitUntilClosed()
    }

    package func installTargetForTesting(
        kind: WebInspectorTarget.Kind = .page,
        frameID: FrameID? = nil,
        isProvisional: Bool = false
    ) async -> WebInspectorTarget {
        let record = await core.installTargetForTesting(
            kind: kind.protocolKind,
            frameID: frameID.map { ProtocolFrame.ID($0.rawValue) },
            isProvisional: isProvisional
        )
        let target = WebInspectorTarget(
            id: WebInspectorTarget.ID(record.id.rawValue),
            kind: kind,
            frameID: frameID,
            isProvisional: isProvisional,
            proxy: self,
            route: RoutingTargetID(record.id.rawValue)
        )
        return target
    }

    package func waitForCloseWaiterForTesting() async {
        await core.waitForCloseWaiterForTesting()
    }

    package func pageGeneration() async throws -> WebInspectorPage.Generation {
        try await core.pageGeneration()
    }

    package func dispatchCommand<Payload: Sendable, Result: Sendable>(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        domain: WebInspectorProxyDomain,
        method: String,
        payload: Payload
    ) async throws -> Result {
        do {
            try await core.requireOpen()
        } catch TransportSession.Error.transportClosed {
            throw WebInspectorProxyError.closed
        } catch let TransportSession.Error.transportFailure(message) {
            throw WebInspectorProxyError.disconnected(message)
        }
        guard let backend else {
            throw unimplementedCommand(domain: domain.rawValue, method: method)
        }
        let commandTarget = resolvedCommandTarget(
            targetID: targetID,
            route: route,
            domain: domain,
            payload: payload
        )
        let command = WebInspectorProxyCommand<Payload, Result>(
            targetID: commandTarget.targetID,
            route: commandTarget.route,
            resultTargetScopeRawValue: commandTarget.resultTargetScopeRawValue,
            domain: domain,
            method: method,
            payload: payload
        )
        return try await backend.dispatchCommand(command)
    }

    package nonisolated func domEvents(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<DOM.Event> {
        guard let backend else {
            preconditionFailure("WebInspectorProxy has no backend for DOM events.")
        }
        return AsyncStream<DOM.Event> { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await event in backend.events(route: route, targetID: targetID, domain: .dom) {
                            guard case let .dom(value) = event else {
                                preconditionFailure("Backend emitted a mismatched event for DOM.")
                            }
                            continuation.yield(value)
                        }
                    }
                    group.addTask {
                        for await event in backend.events(route: route, targetID: targetID, domain: .inspector) {
                            guard case let .inspector(value) = event else {
                                preconditionFailure("Backend emitted a mismatched event for Inspector.")
                            }
                            await self.emitDOMInspectEvent(
                                for: value,
                                targetID: targetID,
                                route: route,
                                continuation: continuation
                            )
                        }
                    }
                    await group.waitForAll()
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    package nonisolated func cssEvents(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<CSS.Event> {
        eventStream(targetID: targetID, route: route, domain: .css) { event in
            guard case let .css(value) = event else {
                return nil
            }
            return value
        }
    }

    package nonisolated func networkEvents(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<Network.Event> {
        eventStream(targetID: targetID, route: route, domain: .network) { event in
            guard case let .network(value) = event else {
                return nil
            }
            return value
        }
    }

    package nonisolated func consoleEvents(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<Console.Event> {
        eventStream(targetID: targetID, route: route, domain: .console) { event in
            guard case let .console(value) = event else {
                return nil
            }
            return value.event
        }
    }

    package nonisolated func targetedConsoleEvents(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<Console.TargetedEvent> {
        eventStream(targetID: targetID, route: route, domain: .console) { event in
            guard case let .console(value) = event else {
                return nil
            }
            return value
        }
    }

    package nonisolated func runtimeEvents(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<Runtime.Event> {
        eventStream(targetID: targetID, route: route, domain: .runtime) { event in
            guard case let .runtime(value) = event else {
                return nil
            }
            return value
        }
    }

    package nonisolated func targetLifecycleEvents(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID
    ) -> AsyncStream<WebInspectorTargetLifecycleEvent> {
        guard let backend else {
            preconditionFailure("WebInspectorProxy has no backend for lifecycle events.")
        }
        return AsyncStream<WebInspectorTargetLifecycleEvent> { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for domain in [WebInspectorProxyEventDomain.target, .page] {
                        group.addTask {
                            for await event in backend.events(route: route, targetID: targetID, domain: domain) {
                                guard case let .targetLifecycle(value) = event else {
                                    preconditionFailure("Backend emitted a mismatched event for lifecycle.")
                                }
                                continuation.yield(value)
                            }
                        }
                    }
                    await group.waitForAll()
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    package nonisolated func waitForEventSubscription(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        domain: WebInspectorProxyEventDomain
    ) async {
        guard let backend else {
            preconditionFailure("WebInspectorProxy has no backend for \(domain.rawValue) events.")
        }
        await backend.waitForEventSubscription(route: route, targetID: targetID, domain: domain)
    }

    private nonisolated func eventStream<Element: Sendable>(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        domain: WebInspectorProxyEventDomain,
        extract: @escaping @Sendable (WebInspectorProxyEvent) -> Element?
    ) -> AsyncStream<Element> {
        guard let backend else {
            preconditionFailure("WebInspectorProxy has no backend for \(domain.rawValue) events.")
        }
        return AsyncStream<Element> { continuation in
            let task = Task {
                for await event in backend.events(route: route, targetID: targetID, domain: domain) {
                    guard let value = extract(event) else {
                        preconditionFailure("Backend emitted a mismatched event for \(domain.rawValue).")
                    }
                    continuation.yield(value)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private nonisolated func emitDOMInspectEvent(
        for event: Inspector.Event,
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        continuation: AsyncStream<DOM.Event>.Continuation
    ) async {
        guard case let .inspect(object, _, origin) = event else {
            return
        }
        guard object.subtype?.rawValue == "node", let objectID = object.id else {
            logger.debug(
                "Inspector.inspect ignored reason=non-node route=\(Self.logDescription(route), privacy: .public) subtype=\(String(describing: object.subtype), privacy: .public)"
            )
            return
        }
        let targets = Self.inspectResolutionTargets(targetID: targetID, route: route, origin: origin)
        logger.debug(
            "Inspector.inspect resolving route=\(Self.logDescription(route), privacy: .public) objectID=\(objectID.rawValue, privacy: .public) commandTarget=\(targets.commandTargetID.rawValue, privacy: .public) commandRoute=\(Self.logDescription(targets.commandRoute), privacy: .public) projectionTarget=\(targets.projectionTargetID.rawValue, privacy: .public)"
        )
        // WebKit's FrameDOMAgent does not implement requestNode. Even when an
        // Inspector.inspect event is target-wrapped for a frame, the frontend
        // asks the page DOM agent to translate the RemoteObject into a node id.
        // The returned node still belongs to the inspect origin for current-page
        // projection, so keep that scope when emitting DOM.inspect.
        do {
            let nodeID: DOM.Node.ID = try await dispatchCommand(
                targetID: targets.commandTargetID,
                route: targets.commandRoute,
                domain: .dom,
                method: "requestNode",
                payload: DOM.RequestNodePayload(objectID: objectID)
            )
            let projectedNodeID = Self.projectedDOMNodeID(nodeID, targetID: targets.projectionTargetID, route: route)
            logger.debug(
                "Inspector.inspect resolved objectID=\(objectID.rawValue, privacy: .public) nodeID=\(nodeID.rawValue, privacy: .public) projectedNodeID=\(projectedNodeID.rawValue, privacy: .public)"
            )
            continuation.yield(.inspect(projectedNodeID))
        } catch {
            logger.debug(
                "Inspector.inspect requestNode failed objectID=\(objectID.rawValue, privacy: .public) commandTarget=\(targets.commandTargetID.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            continuation.yield(.unknown(RawEvent(domain: "Inspector", method: "inspect")))
        }
    }

    private nonisolated static func inspectResolutionTargets(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        origin: Inspector.EventOrigin?
    ) -> (
        commandTargetID: WebInspectorTarget.ID,
        commandRoute: RoutingTargetID,
        projectionTargetID: WebInspectorTarget.ID
    ) {
        guard route == .currentPage else {
            let commandTargetID = origin?.targetID ?? targetID
            return (
                commandTargetID: commandTargetID,
                commandRoute: origin?.route ?? route,
                projectionTargetID: commandTargetID
            )
        }
        return (
            commandTargetID: targetID,
            commandRoute: route,
            projectionTargetID: origin?.targetID ?? targetID
        )
    }

    private nonisolated static func logDescription(_ route: RoutingTargetID) -> String {
        switch route.storage {
        case .currentPage:
            return "current-page"
        case let .target(rawValue):
            return rawValue
        }
    }

    private func resolvedCommandTarget<Payload: Sendable>(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        domain: WebInspectorProxyDomain,
        payload: Payload
    ) -> ProtocolCommandTarget {
        if let nodeID = Self.nodeID(from: payload, domain: domain) {
            if let scopedTargetRawValue = nodeID.targetScopeRawValue {
                return ProtocolCommandTarget(
                    targetID: WebInspectorTarget.ID(scopedTargetRawValue),
                    route: RoutingTargetID(scopedTargetRawValue)
                )
            }
        }
        if let styleID = Self.styleID(from: payload, domain: domain),
           let scopedTargetRawValue = styleID.targetScopeRawValue {
            return ProtocolCommandTarget(
                targetID: WebInspectorTarget.ID(scopedTargetRawValue),
                route: RoutingTargetID(scopedTargetRawValue)
            )
        }
        if let ruleID = Self.ruleID(from: payload, domain: domain),
           let scopedTargetRawValue = ruleID.targetScopeRawValue {
            return ProtocolCommandTarget(
                targetID: WebInspectorTarget.ID(scopedTargetRawValue),
                route: RoutingTargetID(scopedTargetRawValue)
            )
        }
        if let styleSheetID = Self.styleSheetID(from: payload, domain: domain),
           let scopedTargetRawValue = styleSheetID.targetScopeRawValue {
            return ProtocolCommandTarget(
                targetID: WebInspectorTarget.ID(scopedTargetRawValue),
                route: RoutingTargetID(scopedTargetRawValue)
            )
        }
        if let requestID = Self.networkRequestID(from: payload, domain: domain),
           let scopedTargetRawValue = requestID.targetScopeRawValue {
            return ProtocolCommandTarget(
                targetID: WebInspectorTarget.ID(scopedTargetRawValue),
                route: RoutingTargetID(scopedTargetRawValue)
            )
        }
        if let executionContextID = Self.executionContextID(from: payload, domain: domain),
           let scopedTargetRawValue = executionContextID.targetScopeRawValue {
            return ProtocolCommandTarget(
                targetID: WebInspectorTarget.ID(scopedTargetRawValue),
                route: RoutingTargetID(scopedTargetRawValue)
            )
        }
        if let requestNodeObjectID = Self.requestNodeObjectID(from: payload, domain: domain) {
            return ProtocolCommandTarget(
                targetID: targetID,
                route: route,
                resultTargetScopeRawValue: requestNodeObjectID.targetScopeRawValue
            )
        }
        if let remoteObjectID = Self.remoteObjectID(from: payload, domain: domain),
           let scopedTargetRawValue = remoteObjectID.targetScopeRawValue {
            return ProtocolCommandTarget(
                targetID: WebInspectorTarget.ID(scopedTargetRawValue),
                route: RoutingTargetID(scopedTargetRawValue)
            )
        }
        return ProtocolCommandTarget(targetID: targetID, route: route)
    }

    private nonisolated static func projectedDOMNodeID(
        _ nodeID: DOM.Node.ID,
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID
    ) -> DOM.Node.ID {
        guard route == .currentPage,
              targetID != .currentPage,
              nodeID.targetScopeRawValue == nil else {
            return nodeID
        }
        return DOM.Node.ID(nodeID.rawValue, scopedToTargetRawValue: targetID.rawValue)
    }

    private nonisolated static func nodeID<Payload: Sendable>(
        from payload: Payload,
        domain: WebInspectorProxyDomain
    ) -> DOM.Node.ID? {
        switch domain {
        case .dom:
            switch payload {
            case let payload as DOM.RequestChildNodesPayload:
                return payload.id
            case let payload as DOM.GetOuterHTMLPayload:
                return payload.id
            case let payload as DOM.GetAttributesPayload:
                return payload.id
            case let payload as DOM.SetAttributeValuePayload:
                return payload.id
            case let payload as DOM.SetAttributesAsTextPayload:
                return payload.id
            case let payload as DOM.RemoveAttributePayload:
                return payload.id
            case let payload as DOM.SetOuterHTMLPayload:
                return payload.id
            case let payload as DOM.RemoveNodePayload:
                return payload.id
            default:
                return nil
            }
        case .css:
            switch payload {
            case let payload as CSS.GetMatchedStylesForNodePayload:
                return payload.node
            case let payload as CSS.GetComputedStyleForNodePayload:
                return payload.node
            case let payload as CSS.GetInlineStylesForNodePayload:
                return payload.node
            default:
                return nil
            }
        case .network, .console, .runtime, .page, .inspector:
            return nil
        }
    }

    private nonisolated static func styleID<Payload: Sendable>(
        from payload: Payload,
        domain: WebInspectorProxyDomain
    ) -> CSS.Style.ID? {
        guard domain == .css,
              let payload = payload as? CSS.SetStyleTextPayload else {
            return nil
        }
        return payload.id
    }

    private nonisolated static func ruleID<Payload: Sendable>(
        from payload: Payload,
        domain: WebInspectorProxyDomain
    ) -> CSS.Rule.ID? {
        guard domain == .css else {
            return nil
        }
        switch payload {
        case let payload as CSS.SetRuleSelectorPayload:
            return payload.id
        case let payload as CSS.SetGroupingHeaderTextPayload:
            return payload.id
        default:
            return nil
        }
    }

    private nonisolated static func styleSheetID<Payload: Sendable>(
        from payload: Payload,
        domain: WebInspectorProxyDomain
    ) -> CSS.StyleSheet.ID? {
        guard domain == .css,
              let payload = payload as? CSS.SetStyleSheetTextPayload else {
            return nil
        }
        return payload.id
    }

    private nonisolated static func networkRequestID<Payload: Sendable>(
        from payload: Payload,
        domain: WebInspectorProxyDomain
    ) -> Network.Request.ID? {
        guard domain == .network,
              let payload = payload as? Network.GetResponseBodyPayload else {
            return nil
        }
        return payload.id
    }

    private nonisolated static func executionContextID<Payload: Sendable>(
        from payload: Payload,
        domain: WebInspectorProxyDomain
    ) -> Runtime.ExecutionContext.ID? {
        guard domain == .runtime,
              let payload = payload as? Runtime.EvaluatePayload else {
            return nil
        }
        return payload.context
    }

    private nonisolated static func remoteObjectID<Payload: Sendable>(
        from payload: Payload,
        domain: WebInspectorProxyDomain
    ) -> Runtime.RemoteObject.ID? {
        switch domain {
        case .runtime:
            switch payload {
            case let payload as Runtime.GetPropertiesPayload:
                return payload.object
            case let payload as Runtime.GetPreviewPayload:
                return payload.object
            case let payload as Runtime.GetCollectionEntriesPayload:
                return payload.object
            case let payload as Runtime.ReleaseObjectPayload:
                return payload.id
            default:
                return nil
            }
        case .dom:
            return nil
        default:
            return nil
        }
    }

    private nonisolated static func requestNodeObjectID<Payload: Sendable>(
        from payload: Payload,
        domain: WebInspectorProxyDomain
    ) -> Runtime.RemoteObject.ID? {
        guard domain == .dom,
              let payload = payload as? DOM.RequestNodePayload else {
            return nil
        }
        return payload.objectID
    }

    private func bootstrapCurrentPage(from transport: TransportSession) async throws {
        _ = try await currentPageTarget(
            from: transport,
            timeout: configuration.bootstrapTimeout
        )
    }

    /// `timeout: nil` waits indefinitely for the next main page target. The
    /// returned handle is materialized from the core's current record; no
    /// proxy-owned current-target cache participates in routing.
    private func currentPageTarget(
        from transport: TransportSession,
        timeout: Duration?
    ) async throws -> WebInspectorTarget {
        _ = try await transport.waitForCurrentMainPageTarget(timeout: timeout)
        try await ensureOpenForCurrentPageAccess()
        guard let record = await transport.currentMainPageRecord() else {
            throw WebInspectorProxyError.disconnected("Current page target disappeared during bootstrap.")
        }
        return try currentPageTarget(from: record)
    }

    private func ensureOpenForCurrentPageAccess() async throws {
        do {
            try await core.requireOpen()
        } catch {
            throw Self.mapBootstrapTargetError(error)
        }
    }

    private func currentPageTarget(from record: ProtocolTarget.Record) throws -> WebInspectorTarget {
        guard let kind = WebInspectorTarget.Kind(protocolKind: record.kind) else {
            throw WebInspectorProxyError.disconnected("Current page target has unsupported kind.")
        }
        return WebInspectorTarget(
            id: .currentPage,
            kind: kind,
            frameID: record.frameID.map { FrameID($0.rawValue) },
            isProvisional: record.isProvisional,
            proxy: self,
            route: .currentPage,
            pageBindingID: record.id.rawValue
        )
    }

    private nonisolated static func mapBootstrapTargetError(_ error: any Error) -> any Error {
        guard let transportError = error as? TransportSession.Error else {
            return error
        }
        switch transportError {
        case .missingMainPageTarget:
            return WebInspectorProxyError.timeout(domain: "Target", method: "waitForCurrentPage")
        case .transportClosed:
            return WebInspectorProxyError.closed
        case let .transportFailure(message):
            return WebInspectorProxyError.disconnected(message)
        case let .replyTimeout(method, _):
            return WebInspectorProxyError.timeout(domain: "Target", method: method)
        case let .remoteError(method, _, message):
            return WebInspectorProxyError.commandFailed(domain: "Target", method: method, message: message)
        case let .missingTarget(targetID):
            return WebInspectorProxyError.disconnected("Target \(targetID.rawValue) disappeared during bootstrap.")
        case .malformedMessage:
            return WebInspectorProxyError.disconnected("Malformed target bootstrap message.")
        }
    }

    private nonisolated static func mapNativeAttachError(_ error: any Error) -> any Error {
        if let proxyError = error as? WebInspectorProxyError {
            return proxyError
        }
        if let transportError = error as? TransportSession.Error {
            return mapBootstrapTargetError(transportError)
        }
        if let symbolResolutionError = error as? NativeInspectorSymbolResolutionError {
            switch symbolResolutionError {
            case let .missingSymbols(functions):
                let missingFunctions = functions.sorted().joined(separator: ", ")
                if missingFunctions.isEmpty {
                    return WebInspectorProxyError.unsupported([
                        "Native Web Inspector symbols are unavailable."
                    ])
                }
                return WebInspectorProxyError.unsupported([
                    "Native Web Inspector symbols are unavailable: \(missingFunctions)"
                ])
            }
        }
        return WebInspectorProxyError.attachFailed(String(describing: error))
    }
}

private struct UnavailableTransportBackend: TransportBackend {
    func sendJSONString(_ message: String) async throws {
        _ = message
        throw TransportSession.Error.transportClosed
    }

    func detach() async {}
}

private extension WebInspectorTarget.Kind {
    var protocolKind: ProtocolTarget.Kind {
        switch self {
        case .page:
            .page
        case .frame:
            .frame
        case .worker:
            .worker
        case .serviceWorker:
            .serviceWorker
        }
    }
}
