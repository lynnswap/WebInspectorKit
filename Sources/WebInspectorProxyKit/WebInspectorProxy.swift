import Foundation
import OSLog
import Synchronization
import WebKit
import WebInspectorNativeBridge

private let proxyLogger = Logger(subsystem: "WebInspectorKit", category: "WebInspectorProxy")

/// An attached Web Inspector protocol connection for a `WKWebView`.
public final class WebInspectorProxy: Sendable {
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
    package let core: ConnectionCore

    /// The stable logical page inspected by this connection.
    public var page: WebInspectorPage { WebInspectorPage(proxy: self) }

    @MainActor
    public init(
        attachingTo webView: WKWebView,
        configuration: Configuration = .init()
    ) async throws {
        self.configuration = configuration
        let connection: ConnectionCore
        do {
            connection = try await NativeConnectionCoreFactory.attach(
                to: webView,
                responseTimeout: configuration.responseTimeout,
                fatalFailureHandler: { message in
                    proxyLogger.error("Native inspector failure: \(message, privacy: .private)")
                }
            )
        } catch {
            throw Self.mapAttachError(error)
        }
        do {
            _ = try await connection.waitForCurrentMainPageTarget(
                timeout: configuration.bootstrapTimeout
            )
            core = connection
        } catch {
            await connection.close()
            throw Self.mapAttachError(error)
        }
    }

    package init(
        connection: ConnectionCore,
        configuration: Configuration = .init()
    ) async throws {
        self.configuration = configuration
        core = connection
        do {
            _ = try await connection.waitForCurrentMainPageTarget(timeout: configuration.bootstrapTimeout)
        } catch {
            await connection.close()
            throw Self.mapConnectionError(error)
        }
    }

    public func close() async { await core.close() }

    public func waitUntilClosed() async throws { try await core.waitUntilClosed() }

    package func generation() async throws -> WebInspectorPage.Generation {
        do { return try await core.pageGeneration() }
        catch { throw Self.mapConnectionError(error) }
    }

    package func send<Result: Sendable>(
        _ command: WebInspectorWireCommand<Result>,
        route: WebInspectorRoute
    ) async throws -> Result {
        do { return try await core.send(command, route: route) }
        catch { throw Self.mapConnectionError(error) }
    }

    package func send<Result: Sendable>(
        _ command: WebInspectorWireCommand<Result>,
        in scopeID: WebInspectorOrderedScopeID
    ) async throws -> WebInspectorScopedReply<Result> {
        do { return try await core.sendScoped(command, route: .currentPage, scopeID: scopeID) }
        catch { throw Self.mapConnectionError(error) }
    }

    package func openScope<Element: Sendable>(
        descriptor: WebInspectorOrderedScopeDescriptor<Element>,
        buffering: WebInspectorEventBufferingPolicy
    ) async throws -> WebInspectorOrderedEventScope<Element> {
        do {
            return try await core.openScope(
                descriptor: descriptor,
                buffering: buffering,
                proxyReference: WebInspectorProxyReference(self)
            )
        } catch {
            throw Self.mapConnectionError(error)
        }
    }

    package func completeBoundary(
        _ boundary: WebInspectorReplyBoundary,
        in scopeID: WebInspectorOrderedScopeID
    ) async throws {
        do { try await core.completeBoundary(boundary, in: scopeID) }
        catch { throw Self.mapConnectionError(error) }
    }

    package func closeScope(_ id: WebInspectorOrderedScopeID) async {
        await core.closeScope(id)
    }

    private static func mapConnectionError(_ error: any Error) -> any Error {
        guard let connection = error as? ConnectionError else { return error }
        switch connection {
        case .closed: return WebInspectorProxyError.closed
        case let .failed(message): return WebInspectorProxyError.disconnected(message)
        case .unreadableEnvelope: return WebInspectorProxyError.disconnected("Unreadable Web Inspector envelope.")
        case let .malformedTargetControlPlane(method):
            return WebInspectorProxyError.disconnected("Malformed \(method) control-plane message.")
        case .missingTarget: return WebInspectorProxyError.pageUnavailable
        case let .replyTimeout(method):
            let method = WebInspectorProtocolMethod(rawValue: method)
            return WebInspectorProxyError.timeout(domain: method.domain.rawValue, method: method.name)
        case let .remoteError(method, message):
            return WebInspectorProxyError.commandRejected(method: method, message: message)
        }
    }

    private static func mapAttachError(_ error: any Error) -> any Error {
        if let symbolError = error as? NativeInspectorSymbolResolutionError {
            if case let .missingSymbols(symbols) = symbolError {
                return WebInspectorProxyError.unsupported(symbols.sorted())
            }
        }
        let mapped = mapConnectionError(error)
        if mapped is WebInspectorProxyError { return mapped }
        return WebInspectorProxyError.attachFailed(String(describing: error))
    }
}

package final class WebInspectorProxyReference: Sendable {
    private struct State: Sendable { weak var value: WebInspectorProxy? }
    private let state: Mutex<State>

    package init(_ proxy: WebInspectorProxy) {
        state = Mutex(State(value: proxy))
    }

    package func resolve() -> WebInspectorProxy? {
        state.withLock { $0.value }
    }
}
