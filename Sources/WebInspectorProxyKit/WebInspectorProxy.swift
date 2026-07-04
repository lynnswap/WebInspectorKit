import Foundation
import OSLog
import WebKit
import WebInspectorNativeTransport
import WebInspectorTransport

private let logger = Logger(subsystem: "WebInspectorKit", category: "WebInspectorProxy")

public actor WebInspectorProxy {
    public struct Configuration: Equatable, Sendable {
        public var responseTimeout: Duration
        public var bootstrapTimeout: Duration

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
    private let closeConnection: (@Sendable () async -> Void)?
    private var pageTarget: WebInspectorTarget?
    private var nextTargetOrdinal: UInt64
    private var nextCloseWaiterID: UInt64
    private var closeWaiters: [UInt64: CheckedContinuation<Void, any Error>]
    private var closeWaiterRegistrationWaiters: [CheckedContinuation<Void, Never>]
    private var cancelledCloseWaiterIDs: Set<UInt64>
    private var closed: Bool

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
        backend = WebInspectorTransportBackend(transport: nativeConnection.transport)
        closeConnection = {
            await nativeConnection.close()
        }
        pageTarget = nil
        nextTargetOrdinal = 0
        nextCloseWaiterID = 0
        closeWaiters = [:]
        closeWaiterRegistrationWaiters = []
        cancelledCloseWaiterIDs = []
        closed = false

        do {
            try await bootstrapCurrentPage(from: nativeConnection.transport)
        } catch {
            await close()
            throw Self.mapNativeAttachError(error)
        }
    }

    package init(
        configuration: Configuration = .init(),
        backend: (any WebInspectorProxyBackend)? = nil
    ) {
        self.configuration = configuration
        self.backend = backend
        closeConnection = nil
        pageTarget = nil
        nextTargetOrdinal = 0
        nextCloseWaiterID = 0
        closeWaiters = [:]
        closeWaiterRegistrationWaiters = []
        cancelledCloseWaiterIDs = []
        closed = false
    }

    package init(
        transport: TransportSession,
        configuration: Configuration = .init()
    ) async throws {
        self.configuration = configuration
        backend = WebInspectorTransportBackend(transport: transport)
        closeConnection = {
            await transport.detach()
        }
        pageTarget = nil
        nextTargetOrdinal = 0
        nextCloseWaiterID = 0
        closeWaiters = [:]
        closeWaiterRegistrationWaiters = []
        cancelledCloseWaiterIDs = []
        closed = false

        do {
            try await bootstrapCurrentPage(from: transport)
        } catch {
            await close()
            throw Self.mapBootstrapTargetError(error)
        }
    }

    public var currentPage: WebInspectorTarget? {
        pageTarget
    }

    public var canReload: Bool {
        pageTarget != nil && closed == false
    }

    public func waitForCurrentPage() async throws -> WebInspectorTarget {
        if let pageTarget {
            return pageTarget
        }
        throw WebInspectorProxyError.disconnected("WebInspectorProxyKit shell has no current page target.")
    }

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

    public func close() async {
        guard closed == false else {
            return
        }
        closed = true
        pageTarget = nil
        await closeConnection?()
        resumeCloseWaiters()
    }

    public func waitUntilClosed() async throws {
        guard closed == false else {
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
        guard closed == false else {
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
        guard closed == false else {
            throw WebInspectorProxyError.closed
        }
        guard let backend else {
            throw unimplementedCommand(domain: domain.rawValue, method: method)
        }
        let command = WebInspectorProxyCommand<Payload, Result>(
            targetID: targetID,
            route: route,
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
        guard case let .inspect(object, _) = event else {
            return
        }
        guard object.subtype?.rawValue == "node", let objectID = object.id else {
            return
        }
        do {
            let nodeID: DOM.Node.ID = try await dispatchCommand(
                targetID: targetID,
                route: route,
                domain: .dom,
                method: "requestNode",
                payload: DOM.RequestNodePayload(objectID: objectID)
            )
            continuation.yield(.inspect(nodeID))
        } catch {
            continuation.yield(.unknown(RawEvent(domain: "Inspector", method: "inspect")))
        }
    }

    private func bootstrapCurrentPage(from transport: TransportSession) async throws {
        let transportTarget = try await transport.waitForCurrentMainPageTarget(
            timeout: configuration.bootstrapTimeout
        )
        let snapshot = await transport.snapshot()
        guard let record = snapshot.targetsByID[transportTarget.targetID] else {
            throw WebInspectorProxyError.disconnected("Current page target disappeared during bootstrap.")
        }
        pageTarget = try currentPageTarget(from: record)
    }

    private func registerCloseWaiter(id: UInt64, continuation: CheckedContinuation<Void, any Error>) {
        guard closed == false else {
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
            if closed == false {
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
            route: .currentPage
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
        if let factoryError = error as? NativeInspectorBackendFactoryError {
            switch factoryError {
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
