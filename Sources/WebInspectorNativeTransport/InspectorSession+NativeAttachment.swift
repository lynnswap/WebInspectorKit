import WebKit
import WebInspectorCore
import WebInspectorTransport

package extension InspectorSession {
    @MainActor
    func attach(to webView: WKWebView) async throws {
        let attachRequestGeneration = beginAttachmentRequest()
        let resolvedSymbols = try await NativeInspectorBackendFactory.resolvedSymbolsDetached()
        try ensureCurrentAttachmentRequest(attachRequestGeneration)
        try await detachForAttachmentRequest(attachRequestGeneration)

        let receiver = TransportReceiver()
        let page = NativeInspectablePage(
            webView: webView
        )
        var transport: TransportSession?

        do {
            let backend = NativeInspectorBackendFactory.make(
                webView: webView,
                resolvedSymbols: resolvedSymbols,
                messageHandler: { message in
                    receiver.receive(message)
                },
                fatalFailureHandler: { [weak self] message in
                    Task { @MainActor in
                        self?.recordAttachmentError(InspectorSession.Error(message))
                    }
                }
            )
            let createdTransport = makeTransportSession(backend: backend)
            transport = createdTransport
            receiver.setTransport(createdTransport)

            try backend.attach()
            try await connectAttachment(
                transport: createdTransport,
                receiver: receiver,
                pageReloadAction: { [page] in
                    try Task.checkCancellation()
                    try page.reload()
                },
                connectionCleanup: { [page] in
                    page.restoreInspectabilityIfNeeded()
                },
                attachRequestGeneration: attachRequestGeneration
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

    package func reload() throws {
        guard let webView else {
            throw InspectorSession.Error("Inspected WKWebView is no longer available.")
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
