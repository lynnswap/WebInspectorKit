import OSLog
import WebInspectorKitCore
import WebKit

private let domMutationPipelineLogger = Logger(subsystem: "WebInspectorKit", category: "DOMMutationPipeline")

@MainActor
final class DOMMutationPipeline {
    private struct PendingBundle {
        let bundle: Any
        let preserveState: Bool
    }

    private let session: DOMSession
    private let bridgeRuntime: WISPIRuntime
    private weak var webView: InspectorWebView?
    private var isReady = false
    private var configuration: DOMConfiguration
    private var pendingBundles: [PendingBundle] = []
    private var pendingBundleFlushTask: Task<Void, Never>?
    private var jsBufferSequence = 0

    init(
        session: DOMSession,
        bridgeRuntime: WISPIRuntime,
        configuration: DOMConfiguration
    ) {
        self.session = session
        self.bridgeRuntime = bridgeRuntime
        self.configuration = configuration
    }

    func attachWebView(_ webView: InspectorWebView?) {
        self.webView = webView
    }

    func setReady(_ ready: Bool) {
        isReady = ready
        if ready {
            schedulePendingBundleFlush()
        } else {
            cancelPendingBundleFlush()
        }
    }

    func updateConfiguration(_ configuration: DOMConfiguration) {
        self.configuration = configuration
    }

    func enqueueMutationBundle(_ bundle: Any, preserveState: Bool) {
        pendingBundles.append(PendingBundle(bundle: bundle, preserveState: preserveState))
        if isReady {
            schedulePendingBundleFlush()
        }
    }

    func clearPendingMutationBundles() {
        pendingBundles.removeAll()
        cancelPendingBundleFlush()
    }

    func reset() {
        isReady = false
        clearPendingMutationBundles()
    }

    func flushPendingBundlesNow() async {
        pendingBundleFlushTask?.cancel()
        pendingBundleFlushTask = nil
        guard isReady else { return }
        let bundles = pendingBundles
        pendingBundles.removeAll()
        guard !bundles.isEmpty else {
            return
        }
        await applyBundlesNow(bundles)
    }

    var pendingMutationBundleCount: Int {
        pendingBundles.count
    }

    var hasPendingBundleFlushTask: Bool {
        pendingBundleFlushTask != nil
    }

    var currentBundleFlushInterval: TimeInterval {
        let baseInterval = configuration.autoUpdateDebounce / 4
        return max(0.05, min(0.2, baseInterval))
    }

    private func schedulePendingBundleFlush() {
        guard pendingBundleFlushTask == nil else {
            return
        }
        let interval = currentBundleFlushInterval
        pendingBundleFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delay = UInt64(interval * 1_000_000_000)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            await flushPendingBundlesNow()
        }
    }

    private func cancelPendingBundleFlush() {
        pendingBundleFlushTask?.cancel()
        pendingBundleFlushTask = nil
    }

    private func applyBundlesNow(_ bundles: [PendingBundle]) async {
        guard let webView, !bundles.isEmpty else {
            return
        }

        let payloads: [[String: Any]] = bundles.map {
            [
                "bundle": $0.bundle,
                "preserveState": $0.preserveState,
            ]
        }

        if await applyBundlesWithBufferIfNeeded(payloads, on: webView) {
            return
        }

        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.applyMutationBundles?.(bundles)",
                arguments: ["bundles": payloads],
                contentWorld: .page
            )
        } catch {
            domMutationPipelineLogger.error("send mutation bundles failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyBundlesWithBufferIfNeeded(
        _ payloads: [[String: Any]],
        on webView: InspectorWebView
    ) async -> Bool {
        guard session.bridgeMode == .privateFull else {
            return false
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: payloads),
            data.count > WIJSBufferTransport.bufferThresholdBytes
        else {
            return false
        }

        let controller = webView.configuration.userContentController
        guard WIJSBufferTransport.isAvailable(on: controller, runtime: bridgeRuntime) else {
            return false
        }

        let bufferName = nextBufferName()
        guard WIJSBufferTransport.addBuffer(
            data: data,
            name: bufferName,
            to: controller,
            contentWorld: .page,
            runtime: bridgeRuntime
        ) else {
            return false
        }

        defer {
            WIJSBufferTransport.removeBuffer(named: bufferName, from: controller, contentWorld: .page)
        }

        do {
            let rawResult = try await webView.callAsyncJavaScript(
                """
                if (!window.webInspectorDOMFrontend || typeof window.webInspectorDOMFrontend.applyMutationBuffer !== "function") {
                    return false;
                }
                return window.webInspectorDOMFrontend.applyMutationBuffer(bufferName);
                """,
                arguments: ["bufferName": bufferName],
                in: nil,
                contentWorld: .page
            )
            let didApply = (rawResult as? Bool) ?? (rawResult as? NSNumber)?.boolValue ?? false
            return didApply
        } catch {
            domMutationPipelineLogger.error("send mutation buffer failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func nextBufferName() -> String {
        jsBufferSequence += 1
        return "wi_dom_bundle_\(jsBufferSequence)"
    }
}
