import WebKit
import WebInspectorNativeBridge

package enum NativeConnectionCoreFactory {
    @MainActor
    package static func attach(
        to webView: WKWebView,
        responseTimeout: Duration?,
        fatalFailureHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ConnectionCore {
        let resolvedSymbols = try await NativeInspectorBackendFactory.resolvedSymbolsDetached()
        return try await attach(
            to: webView,
            resolvedSymbols: resolvedSymbols,
            responseTimeout: responseTimeout,
            fatalFailureHandler: fatalFailureHandler
        )
    }

    @MainActor
    package static func attach(
        to webView: WKWebView,
        resolvedSymbols: NativeInspectorResolvedSymbols,
        responseTimeout: Duration?,
        fatalFailureHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> ConnectionCore {
        let receiver = TransportReceiver()
        let page = NativeInspectablePage(webView: webView)
        var core: ConnectionCore?
        var attachment: NativeAttachment?

        do {
            let backend = NativeInspectorBackendFactory.make(
                webView: webView,
                resolvedSymbols: resolvedSymbols,
                messageHandler: { message in
                    receiver.receive(message)
                },
                fatalFailureHandler: { message in
                    fatalFailureHandler(message)
                    receiver.fail(message)
                }
            )
            let createdAttachment = NativeAttachment(
                receiver: receiver,
                backend: backend,
                page: page
            )
            attachment = createdAttachment
            let createdCore = ConnectionCore(
                backend: backend,
                responseTimeout: responseTimeout,
                closeAction: {
                    await createdAttachment.close()
                }
            )
            core = createdCore
            receiver.setCore(createdCore)

            try backend.attach()

            return createdCore
        } catch {
            if let core {
                await core.close()
            } else if let attachment {
                await attachment.close()
            } else {
                receiver.close()
                page.restoreInspectabilityIfNeeded()
            }
            throw error
        }
    }
}

@MainActor
private final class NativeAttachment {
    private let receiver: TransportReceiver
    private let backend: NativeInspectorBackend
    private let page: NativeInspectablePage
    private var isClosed = false

    init(
        receiver: TransportReceiver,
        backend: NativeInspectorBackend,
        page: NativeInspectablePage
    ) {
        self.receiver = receiver
        self.backend = backend
        self.page = page
    }

    func close() async {
        guard !isClosed else {
            return
        }
        isClosed = true
        receiver.close()
        await backend.detach()
        page.restoreInspectabilityIfNeeded()
    }

    isolated deinit {
        guard !isClosed else {
            return
        }
        receiver.close()
        backend.detachSynchronously()
        page.restoreInspectabilityIfNeeded()
    }
}

@MainActor
package final class NativeInspectablePage {
    private weak var webView: WKWebView?
    private let webViewIdentifier: ObjectIdentifier?
    private let inspectabilityOwner = NativeInspectabilityOwner()

    package init(webView: WKWebView) {
        self.webView = webView
        webViewIdentifier = ObjectIdentifier(webView)
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
        guard let webViewIdentifier else {
            return
        }
        NativeInspectabilityCoordinator.restoreIfOwned(
            webViewIdentifier: webViewIdentifier,
            owner: inspectabilityOwner
        )
    }

    isolated deinit {
        restoreInspectabilityIfNeeded()
    }

    #if DEBUG
    package init(missingWebViewForTesting: Void) {
        webViewIdentifier = nil
    }
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

    static func restoreIfOwned(
        webViewIdentifier: ObjectIdentifier,
        owner: NativeInspectabilityOwner
    ) {
        guard let record = records[webViewIdentifier] else {
            return
        }
        record.owners.remove(ObjectIdentifier(owner))
        guard record.owners.isEmpty else {
            return
        }
        records[webViewIdentifier] = nil
        record.webView?.isInspectable = record.originalInspectability
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
