import WebKit
import WebInspectorNativeBridge

package struct NativeInspectorConnection: Sendable {
    package let transport: TransportSession
    package let receiver: TransportReceiver
    package let reloadPage: @MainActor @Sendable () async throws -> Void
    package let canReloadPage: @MainActor @Sendable () -> Bool
    private let cleanup: @MainActor @Sendable () -> Void

    package init(
        transport: TransportSession,
        receiver: TransportReceiver,
        reloadPage: @escaping @MainActor @Sendable () async throws -> Void,
        canReloadPage: @escaping @MainActor @Sendable () -> Bool,
        cleanup: @escaping @MainActor @Sendable () -> Void
    ) {
        self.transport = transport
        self.receiver = receiver
        self.reloadPage = reloadPage
        self.canReloadPage = canReloadPage
        self.cleanup = cleanup
    }

    package func close() async {
        receiver.close()
        await transport.detach()
        await restoreInspectabilityIfNeeded()
    }

    @MainActor
    package func restoreInspectabilityIfNeeded() {
        cleanup()
    }
}

package enum NativeInspectorConnectionFactory {
    @MainActor
    package static func attach(
        to webView: WKWebView,
        responseTimeout: Duration?,
        fatalFailureHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> NativeInspectorConnection {
        let resolvedSymbols = try await NativeInspectorBackendFactory.resolvedSymbolsDetached()
        return try await attach(
            to: webView,
            resolvedSymbols: resolvedSymbols,
            makeTransportSession: { backend in
                TransportSession(
                    backend: backend,
                    responseTimeout: responseTimeout
                )
            },
            fatalFailureHandler: fatalFailureHandler
        )
    }

    @MainActor
    package static func attach(
        to webView: WKWebView,
        resolvedSymbols: WebInspectorNativeResolvedSymbols,
        makeTransportSession: @MainActor (any TransportBackend) -> TransportSession,
        fatalFailureHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> NativeInspectorConnection {
        let receiver = TransportReceiver()
        let page = NativeInspectablePage(webView: webView)
        var transport: TransportSession?

        do {
            let backend = NativeInspectorBackendFactory.make(
                webView: webView,
                resolvedSymbols: resolvedSymbols,
                messageHandler: { message in
                    receiver.receive(message)
                },
                fatalFailureHandler: fatalFailureHandler
            )
            let createdTransport = makeTransportSession(backend)
            transport = createdTransport
            receiver.setTransport(createdTransport)

            try backend.attach()

            return NativeInspectorConnection(
                transport: createdTransport,
                receiver: receiver,
                reloadPage: { [page] in
                    try Task.checkCancellation()
                    try page.reload()
                },
                canReloadPage: { [page] in
                    page.canReload
                },
                cleanup: { [page] in
                    page.restoreInspectabilityIfNeeded()
                }
            )
        } catch {
            receiver.close()
            page.restoreInspectabilityIfNeeded()
            await transport?.detach()
            throw error
        }
    }
}

@MainActor
package final class NativeInspectablePage {
    private weak var webView: WKWebView?
    private let inspectabilityOwner = NativeInspectabilityOwner()

    package init(webView: WKWebView) {
        self.webView = webView
        NativeInspectabilityCoordinator.prepare(
            webView: webView,
            owner: inspectabilityOwner
        )
    }

    package var canReload: Bool {
        webView != nil
    }

    package func reload() throws {
        guard let webView else {
            throw NativeInspectablePageError.missingWebView
        }
        webView.reload()
    }

    package func restoreInspectabilityIfNeeded() {
        guard let webView else {
            return
        }
        NativeInspectabilityCoordinator.restoreIfOwned(
            webView: webView,
            owner: inspectabilityOwner
        )
    }

    #if DEBUG
    package init(missingWebViewForTesting: Void) {}
    #endif
}

package enum NativeInspectablePageError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingWebView

    package var description: String {
        switch self {
        case .missingWebView:
            "Inspected WKWebView is no longer available."
        }
    }
}

@MainActor
private enum NativeInspectabilityCoordinator {
    private static var records: [ObjectIdentifier: NativeInspectabilityRecord] = [:]

    static func prepare(webView: WKWebView, owner: NativeInspectabilityOwner) {
        let key = ObjectIdentifier(webView)
        let ownerID = ObjectIdentifier(owner)
        if let record = records[key],
           record.webView != nil {
            record.owners.insert(ownerID)
            webView.isInspectable = true
            return
        }

        records[key] = NativeInspectabilityRecord(
            webView: webView,
            ownerID: ownerID,
            originalInspectability: webView.isInspectable
        )
        webView.isInspectable = true
    }

    static func restoreIfOwned(webView: WKWebView, owner: NativeInspectabilityOwner) {
        let key = ObjectIdentifier(webView)
        guard let record = records[key] else {
            return
        }
        record.owners.remove(ObjectIdentifier(owner))
        guard record.owners.isEmpty else {
            return
        }
        records[key] = nil
        webView.isInspectable = record.originalInspectability
    }
}

@MainActor
private final class NativeInspectabilityOwner {}

@MainActor
private final class NativeInspectabilityRecord {
    weak var webView: WKWebView?
    var owners: Set<ObjectIdentifier>
    let originalInspectability: Bool

    init(
        webView: WKWebView,
        ownerID: ObjectIdentifier,
        originalInspectability: Bool
    ) {
        self.webView = webView
        self.owners = [ownerID]
        self.originalInspectability = originalInspectability
    }
}
