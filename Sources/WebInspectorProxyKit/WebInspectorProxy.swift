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
/// `WebInspectorProxy` is a handle to the private WebKit inspector connection.
/// Its connection core owns the current physical page binding and routes typed
/// domain commands through its stable ``page`` handle.
///
/// Example:
///
/// ```swift
/// let proxy = try await WebInspectorProxy(attachingTo: webView)
/// let page = proxy.page
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
    /// Attach from the main actor because `WKWebView` is a UI object.
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
        localStateOnly: Void,
        closeConnection: (@Sendable () async -> Void)? = nil
    ) {
        configuration = .init()
        backend = nil
        core = ConnectionCore(
            backend: UnavailableTransportBackend(),
            responseTimeout: nil,
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

    package var currentPage: WebInspectorTarget? {
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

    package func waitForCurrentPage() async throws -> WebInspectorTarget {
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

    /// Closes the inspector connection.
    ///
    /// Calling `close()` more than once is allowed. Await
    /// ``waitUntilClosed()`` when another task needs to observe completion.
    public func close() async {
        await core.close()
    }

    package func openModelFeed(
        configuredDomains: Set<ModelDomain>,
        capacity: Int = 256
    ) async throws -> ConnectionModelFeed {
        try await core.openModelFeed(
            configuredDomains: configuredDomains,
            capacity: capacity
        )
    }

    /// Suspends until ``close()`` has finished.
    ///
    /// If the proxy is already closed, this method returns immediately. If the
    /// waiting task is cancelled, only that waiter is cancelled.
    public func waitUntilClosed() async throws {
        try await core.waitUntilClosed()
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
        payload: Payload,
        authority: WebInspectorCommandAuthority = .direct
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
            domain: domain,
            method: method,
            payload: payload,
            authority: authority
        )
        return try await backend.dispatchCommand(command)
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
        if Self.isRequestNodePayload(from: payload, domain: domain) {
            return ProtocolCommandTarget(
                targetID: .currentPage,
                route: .currentPage
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

    private nonisolated static func isRequestNodePayload<Payload: Sendable>(
        from payload: Payload,
        domain: WebInspectorProxyDomain
    ) -> Bool {
        domain == .dom && payload is DOM.RequestNodePayload
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
