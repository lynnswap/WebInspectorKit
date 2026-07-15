import Foundation
import OSLog
import WebKit
import WebInspectorNativeBridge

private let logger = Logger(subsystem: "WebInspectorKit", category: "WebInspectorProxy")

private struct ProtocolCommandTarget: Sendable {
    var targetID: WebInspectorTarget.ID
    var route: RoutingTargetID

    init(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID
    ) {
        self.targetID = targetID
        self.route = route
    }
}

/// An attached Web Inspector protocol connection for a `WKWebView`.
///
/// `WebInspectorProxy` owns the private WebKit inspector attachment, tracks the
/// current page target, and routes typed domain commands through
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
    /// Optional timeout configuration for command replies and current-page bootstrap.
    public struct Configuration: Equatable, Sendable {
        /// The maximum time to wait for an individual protocol command reply.
        ///
        /// `nil` waits until WebKit replies, the connection closes, or the
        /// calling task is cancelled. The default is `nil`.
        public var responseTimeout: Duration?

        /// The maximum time to wait while discovering or refreshing the current
        /// page target.
        ///
        /// `nil` waits until WebKit publishes a target, the connection closes,
        /// or the calling task is cancelled. The default is `nil`.
        public var bootstrapTimeout: Duration?

        /// Creates proxy timeout configuration. Pass a duration only when the
        /// consumer explicitly owns a finite deadline.
        public init(
            responseTimeout: Duration? = nil,
            bootstrapTimeout: Duration? = nil
        ) {
            self.responseTimeout = responseTimeout
            self.bootstrapTimeout = bootstrapTimeout
        }
    }

    private let configuration: Configuration
    private let backend: (any WebInspectorProxyBackend)?
    private let transport: TransportSession?
    private let closeConnection: (@Sendable () async -> Void)?
    private var pageTarget: WebInspectorTarget?
    private var nextTargetOrdinal: UInt64
    private var nextCloseWaiterID: UInt64
    private var closeWaiters: [UInt64: CheckedContinuation<Void, any Error>]
    private var closeWaiterRegistrationWaiters: [CheckedContinuation<Void, Never>]
    private var cancelledCloseWaiterIDs: Set<UInt64>
    private var closeState: CloseState

    private enum CloseState {
        case open
        case closing
        case closed
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
        let nativeConnection: NativeInspectorConnection
        do {
            nativeConnection = try await NativeInspectorConnectionFactory.attach(
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
        backend = LiveWebInspectorProxyBackend(transport: nativeConnection.transport)
        transport = nativeConnection.transport
        closeConnection = {
            await nativeConnection.close()
        }
        pageTarget = nil
        nextTargetOrdinal = 0
        nextCloseWaiterID = 0
        closeWaiters = [:]
        closeWaiterRegistrationWaiters = []
        cancelledCloseWaiterIDs = []
        closeState = .open

        do {
            try await bootstrapCurrentPage(from: nativeConnection.transport)
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
        transport = nil
        self.closeConnection = closeConnection
        pageTarget = nil
        nextTargetOrdinal = 0
        nextCloseWaiterID = 0
        closeWaiters = [:]
        closeWaiterRegistrationWaiters = []
        cancelledCloseWaiterIDs = []
        closeState = .open
    }

    package init(
        transport: TransportSession,
        configuration: Configuration = .init(),
        closeConnection: (@Sendable () async -> Void)? = nil
    ) async throws {
        self.configuration = configuration
        self.transport = transport
        backend = LiveWebInspectorProxyBackend(transport: transport)
        self.closeConnection = closeConnection ?? {
            await transport.detach()
        }
        pageTarget = nil
        nextTargetOrdinal = 0
        nextCloseWaiterID = 0
        closeWaiters = [:]
        closeWaiterRegistrationWaiters = []
        cancelledCloseWaiterIDs = []
        closeState = .open

        do {
            try await bootstrapCurrentPage(from: transport)
        } catch {
            await close()
            throw Self.mapBootstrapTargetError(error)
        }
    }

    /// The currently known page target, if bootstrap has completed.
    public var currentPage: WebInspectorTarget? {
        pageTarget
    }

    package var currentPageBindingID: String? {
        pageTarget?.pageBindingID
    }

    /// A Boolean value indicating whether the proxy has an open page target
    /// that can receive reload commands.
    public var canReload: Bool {
        pageTarget != nil && closeState == .open
    }

    /// Waits for and returns the current page target.
    ///
    /// The proxy refreshes its current-page target from the transport when
    /// possible. The method throws if the proxy is closed, detached, or no page
    /// target can be discovered before the bootstrap timeout.
    public func waitForCurrentPage() async throws -> WebInspectorTarget {
        try ensureOpenForCurrentPageAccess()
        if let transport {
            do {
                try await refreshCurrentPage(from: transport, timeout: configuration.bootstrapTimeout)
            } catch {
                throw Self.mapBootstrapTargetError(error)
            }
            if let pageTarget {
                return pageTarget
            }
        }
        if let pageTarget {
            return pageTarget
        }
        throw WebInspectorProxyError.disconnected("WebInspectorProxyKit shell has no current page target.")
    }

    /// Waits for a usable current page target after the previous one was
    /// destroyed. Returns nil when no successor target exists once
    /// `gracePeriod` elapses — page absence is a target-lifecycle fact owned
    /// by the transport registry, distinct from command timeouts. A nil
    /// `gracePeriod` waits indefinitely for the next page target. Throws only
    /// connection-terminal errors.
    package func waitForCurrentPageReplacement(gracePeriod: Duration?) async throws -> WebInspectorTarget? {
        try ensureOpenForCurrentPageAccess()
        guard let transport else {
            return pageTarget
        }
        do {
            try await refreshCurrentPage(from: transport, timeout: gracePeriod)
        } catch TransportSession.Error.missingMainPageTarget {
            return nil
        } catch {
            throw Self.mapBootstrapTargetError(error)
        }
        try ensureOpenForCurrentPageAccess()
        return pageTarget
    }

    package var bootstrapGracePeriod: Duration? {
        configuration.bootstrapTimeout
    }

    /// Reloads the currently inspected page without ignoring cache.
    public func reload() async throws {
        guard let pageTarget else {
            throw WebInspectorProxyError.disconnected("WebInspectorProxyKit shell has no current page target.")
        }
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
        switch closeState {
        case .open:
            break
        case .closing:
            try? await waitUntilClosed()
            return
        case .closed:
            return
        }
        closeState = .closing
        pageTarget = nil
        await closeConnection?()
        closeState = .closed
        resumeCloseWaiters()
    }

    /// Suspends until ``close()`` has finished.
    ///
    /// If the proxy is already closed, this method returns immediately. If the
    /// waiting task is cancelled, only that waiter is cancelled.
    public func waitUntilClosed() async throws {
        guard closeState != .closed else {
            return
        }
        nextCloseWaiterID &+= 1
        let waiterID = nextCloseWaiterID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerCloseWaiter(id: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task {
                await self.cancelCloseWaiter(waiterID)
            }
        }
    }

    package func installTargetForTesting(
        kind: WebInspectorTarget.Kind = .page,
        frameID: FrameID? = nil,
        isProvisional: Bool = false
    ) -> WebInspectorTarget {
        let ordinal = nextTargetOrdinal
        nextTargetOrdinal += 1
        let target = WebInspectorTarget(
            id: WebInspectorTarget.ID("test-target-\(ordinal)"),
            kind: kind,
            frameID: frameID,
            isProvisional: isProvisional,
            proxy: self,
            route: RoutingTargetID("test-route-\(ordinal)")
        )
        if kind == .page && isProvisional == false {
            pageTarget = target
        }
        return target
    }

    package func waitForCloseWaiterForTesting() async {
        guard closeState != .closed else {
            preconditionFailure("Cannot wait for a close waiter after WebInspectorProxy closed.")
        }
        guard closeWaiters.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            closeWaiterRegistrationWaiters.append(continuation)
        }
    }

    package func dispatchCommand<Payload: Sendable, Result: Sendable>(
        targetID: WebInspectorTarget.ID,
        route: RoutingTargetID,
        domain: WebInspectorProxyDomain,
        method: String,
        payload: Payload
    ) async throws -> Result {
        guard closeState == .open else {
            throw WebInspectorProxyError.closed
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
                                await self.applyTargetLifecycleEventToProxyState(value)
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
        route: RoutingTargetID,
        continuation: AsyncStream<DOM.Event>.Continuation
    ) async {
        guard case let .inspect(object, _) = event else {
            return
        }
        guard object.subtype?.rawValue == "node", let objectID = object.id else {
            logger.debug(
                "Inspector.inspect ignored reason=non-node route=\(Self.logDescription(route), privacy: .public) subtype=\(String(describing: object.subtype), privacy: .public)"
            )
            return
        }
        logger.debug(
            "Inspector.inspect resolving route=\(Self.logDescription(route), privacy: .public) objectID=\(objectID.rawValue, privacy: .public)"
        )
        // Inspector.inspect is a page-target event. WebInspectorUI resolves it
        // through the main page DOM agent, whose node namespace is unscoped.
        do {
            let nodeID: DOM.Node.ID = try await dispatchCommand(
                targetID: .currentPage,
                route: .currentPage,
                domain: .dom,
                method: "requestNode",
                payload: DOM.RequestNodePayload(objectID: objectID)
            )
            logger.debug(
                "Inspector.inspect resolved objectID=\(objectID.rawValue, privacy: .public) nodeID=\(nodeID.rawValue, privacy: .public)"
            )
            continuation.yield(.inspect(nodeID))
        } catch {
            logger.debug(
                "Inspector.inspect requestNode failed objectID=\(objectID.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
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
        if let requestNodeObjectID = Self.requestNodeObjectID(from: payload, domain: domain),
           let scopedTargetRawValue = requestNodeObjectID.targetScopeRawValue {
            return ProtocolCommandTarget(
                targetID: WebInspectorTarget.ID(scopedTargetRawValue),
                route: RoutingTargetID(scopedTargetRawValue)
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
        try await refreshCurrentPage(from: transport, timeout: configuration.bootstrapTimeout)
    }

    /// `timeout: nil` waits indefinitely for the next main page target.
    private func refreshCurrentPage(
        from transport: TransportSession,
        timeout: Duration?
    ) async throws {
        let transportTarget: TransportSession.MainPageTarget
        do {
            transportTarget = try await transport.waitForCurrentMainPageTarget(
                timeout: timeout
            )
        } catch {
            pageTarget = nil
            try ensureOpenForCurrentPageAccess()
            throw error
        }
        let snapshot = await transport.snapshot()
        try ensureOpenForCurrentPageAccess()
        guard let record = snapshot.targetsByID[transportTarget.targetID] else {
            throw WebInspectorProxyError.disconnected("Current page target disappeared during bootstrap.")
        }
        pageTarget = try currentPageTarget(from: record)
    }

    private func ensureOpenForCurrentPageAccess() throws {
        guard closeState == .open else {
            pageTarget = nil
            throw WebInspectorProxyError.closed
        }
    }

    private func applyTargetLifecycleEventToProxyState(_ event: WebInspectorTargetLifecycleEvent) {
        guard closeState == .open else {
            return
        }
        switch event {
        case let .didCommitProvisionalTarget(commit) where commit.newTarget.id == .currentPage:
            pageTarget = currentPageTarget(from: commit.newTarget)
        case let .targetDestroyed(targetID) where targetID == .currentPage:
            pageTarget = nil
        default:
            break
        }
    }

    private func registerCloseWaiter(id: UInt64, continuation: CheckedContinuation<Void, any Error>) {
        guard closeState != .closed else {
            continuation.resume()
            return
        }
        guard cancelledCloseWaiterIDs.remove(id) == nil else {
            continuation.resume(throwing: CancellationError())
            return
        }
        closeWaiters[id] = continuation
        resumeCloseWaiterRegistrationWaiters()
    }

    private func cancelCloseWaiter(_ id: UInt64) {
        guard let continuation = closeWaiters.removeValue(forKey: id) else {
            if closeState != .closed {
                cancelledCloseWaiterIDs.insert(id)
            }
            return
        }
        continuation.resume(throwing: CancellationError())
    }

    private func resumeCloseWaiters() {
        let waiters = closeWaiters.values
        closeWaiters.removeAll()
        cancelledCloseWaiterIDs.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeCloseWaiterRegistrationWaiters() {
        let waiters = closeWaiterRegistrationWaiters
        closeWaiterRegistrationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
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

    private func currentPageTarget(from target: WebInspectorLifecycleTarget) -> WebInspectorTarget {
        WebInspectorTarget(
            id: target.id,
            kind: target.kind,
            frameID: target.frameID,
            isProvisional: target.isProvisional,
            proxy: self,
            route: .currentPage,
            pageBindingID: target.pageBindingID
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
        case let .replyTimeout(method, _):
            return WebInspectorProxyError.timeout(domain: "Target", method: method)
        case let .remoteError(method, _, message):
            return WebInspectorProxyError.commandFailed(domain: "Target", method: method, message: message)
        case let .missingTarget(targetID):
            return WebInspectorProxyError.disconnected("Target \(targetID.rawValue) disappeared during bootstrap.")
        case let .unsupportedDomain(domain, targetID):
            return WebInspectorProxyError.disconnected(
                "Target \(targetID.rawValue) does not support \(domain.description) during bootstrap."
            )
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
