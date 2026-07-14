import Dispatch
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
        let receiver = ConnectionReceiver()
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
            try await awaitInitialTargetDiscovery(
                receiver: receiver,
                core: createdCore
            )

            return createdCore
        } catch {
            if let core {
                await core.close()
            } else if let attachment {
                await attachment.close()
            } else {
                await receiver.close()
                page.restoreInspectabilityIfNeeded()
            }
            throw error
        }
    }

    /// Waits for the initial target messages queued by WebKit while attaching.
    ///
    /// `connectFrontend` synchronously enumerates targets but delivers its
    /// frontend callbacks through the main queue. The queue barrier observes
    /// the complete initial callback prefix. The receiver ordinal then waits
    /// for exactly that prefix to finish mutating `ConnectionCore`; later live
    /// messages do not extend this attachment barrier.
    @MainActor
    package static func awaitInitialTargetDiscovery(
        receiver: ConnectionReceiver,
        core: ConnectionCore
    ) async throws {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        let initialTailOrdinal = receiver.tailOrdinal()
        await receiver.waitUntilDrained(through: initialTailOrdinal)
        try await core.requireOpen()
    }
}

@MainActor
package final class NativeAttachment {
    private let receiver: ConnectionReceiver
    private let backend: any NativeAttachmentBackend
    private let page: NativeInspectablePage
    private var isClosed = false

    package init(
        receiver: ConnectionReceiver,
        backend: any NativeAttachmentBackend,
        page: NativeInspectablePage
    ) {
        self.receiver = receiver
        self.backend = backend
        self.page = page
    }

    package func close() async {
        guard !isClosed else {
            return
        }
        isClosed = true
        await receiver.close()
        await backend.detach()
        page.restoreInspectabilityIfNeeded()
    }

    isolated deinit {
        guard !isClosed else {
            return
        }
        receiver.closeSynchronously()
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
