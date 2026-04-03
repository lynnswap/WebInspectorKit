import OSLog
import WebInspectorEngine
import WebInspectorBridge
import WebKit

private let domMutationPipelineLogger = Logger(subsystem: "WebInspectorKit", category: "DOMMutationSender")

@MainActor
final class DOMMutationSender {
    private struct PendingBundle {
        let bundle: Any
        let preservesInspectorState: Bool
        let generation: Int
        let pageEpoch: Int
        let documentScopeID: UInt64
    }

    struct FlushSettlement {
        let completedGeneration: Int?
        let discardedGeneration: Int?

        var hasValue: Bool {
            completedGeneration != nil || discardedGeneration != nil
        }

        static func completed(_ generation: Int) -> Self {
            .init(completedGeneration: generation, discardedGeneration: nil)
        }

        static func discarded(_ generation: Int) -> Self {
            .init(completedGeneration: nil, discardedGeneration: generation)
        }
    }

    private let session: DOMSession
    private let bridgeRuntime: WISPIRuntime
    private weak var webView: InspectorWebView?
    private var isReady = false
    private var configuration: DOMConfiguration
    private var pendingBundles: [PendingBundle] = []
    private var pendingBundleFlushTask: Task<Void, Never>?
    private var activeFlushTask: Task<FlushSettlement, Never>?
    private var activeFlushTaskToken = 0
    private var activeFlushBundles: [PendingBundle] = []
    private var activeFlushGeneration = 0
    private var activeDispatchGeneration = 0
    private var completedFlushGeneration = 0
    private var jsBufferSequence = 0
#if DEBUG
    var testBeforeBundleDispatchOverride: (@MainActor () async -> Void)?
    var testApplyBundlesOverride: (@MainActor ([Any]) async -> Void)?
#endif

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

    func enqueueMutationBundle(
        _ bundle: Any,
        preservingInspectorState: Bool,
        generation: Int,
        pageEpoch: Int,
        documentScopeID: UInt64
    ) {
        pendingBundles.append(
            PendingBundle(
                bundle: bundle,
                preservesInspectorState: preservingInspectorState,
                generation: generation,
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID
            )
        )
        if isReady {
            schedulePendingBundleFlush()
        }
    }

    @discardableResult
    func clearPendingMutationBundles(resetCompletedGeneration: Bool = false) -> Int {
        let discardedPendingGeneration = pendingBundles.reduce(into: 0) { partialResult, bundle in
            partialResult = max(partialResult, bundle.generation)
        }
        let discardedActiveGeneration = activeFlushGeneration
        let discardedGeneration = max(discardedPendingGeneration, discardedActiveGeneration)
        pendingBundles.removeAll()
        cancelPendingBundleFlush()
        activeFlushTaskToken += 1
        activeFlushTask?.cancel()
        activeFlushTask = nil
        activeFlushBundles.removeAll()
        activeFlushGeneration = 0
        activeDispatchGeneration = 0
        if resetCompletedGeneration {
            completedFlushGeneration = 0
        }
        return discardedGeneration
    }

    func reset() {
        isReady = false
        _ = clearPendingMutationBundles(resetCompletedGeneration: true)
        completedFlushGeneration = 0
    }

    func waitForActiveFlushIfNeeded() async {
        guard let activeFlushTask else {
            return
        }
        let activeFlushTaskToken = self.activeFlushTaskToken
        _ = await activeFlushTask.value
        if self.activeFlushTaskToken == activeFlushTaskToken {
            self.activeFlushTask = nil
            activeFlushGeneration = 0
            activeDispatchGeneration = 0
        }
    }

    func cancelAndDrainFlushIfNeeded(resetCompletedGeneration: Bool = false) async -> Int {
        let activeFlushTask = self.activeFlushTask
        let discardedGeneration = clearPendingMutationBundles(
            resetCompletedGeneration: resetCompletedGeneration
        )
        if let activeFlushTask {
            _ = await activeFlushTask.value
        }
        return discardedGeneration
    }

    func flushPendingBundlesNow() async -> FlushSettlement? {
        pendingBundleFlushTask?.cancel()
        pendingBundleFlushTask = nil
        guard isReady else { return nil }

        var latestCompletedGeneration: Int?
        var latestDiscardedGeneration: Int?
        while isReady {
            if let activeFlushTask {
                let activeFlushTaskToken = self.activeFlushTaskToken
                let settlement = await activeFlushTask.value
                let isCurrentActiveFlush = self.activeFlushTaskToken == activeFlushTaskToken
                if isCurrentActiveFlush {
                    if let completedGeneration = settlement.completedGeneration {
                        completedFlushGeneration = max(completedFlushGeneration, completedGeneration)
                        latestCompletedGeneration = max(latestCompletedGeneration ?? 0, completedGeneration)
                    }
                    if let discardedGeneration = settlement.discardedGeneration {
                        latestDiscardedGeneration = max(latestDiscardedGeneration ?? 0, discardedGeneration)
                    }
                }
                if isCurrentActiveFlush {
                    self.activeFlushTask = nil
                    activeFlushGeneration = 0
                    activeDispatchGeneration = 0
                }
                if pendingBundles.isEmpty {
                    let latestSettlement = FlushSettlement(
                        completedGeneration: latestCompletedGeneration,
                        discardedGeneration: latestDiscardedGeneration
                    )
                    return latestSettlement.hasValue ? latestSettlement : nil
                }
                continue
            }

            let bundles = pendingBundles
            pendingBundles.removeAll()
            guard !bundles.isEmpty else {
                let latestSettlement = FlushSettlement(
                    completedGeneration: latestCompletedGeneration,
                    discardedGeneration: latestDiscardedGeneration
                )
                return latestSettlement.hasValue ? latestSettlement : nil
            }

            let flushGeneration = bundles.reduce(into: 0) { partialResult, bundle in
                partialResult = max(partialResult, bundle.generation)
            }
            activeFlushGeneration = flushGeneration
            activeFlushBundles = bundles
            activeDispatchGeneration = 0
            activeFlushTaskToken += 1
            let flushPageEpoch = bundles.last?.pageEpoch ?? 0
            activeFlushTask = Task<FlushSettlement, Never> { @MainActor [weak self] in
                guard let self else {
                    return .discarded(flushGeneration)
                }
                return await self.runActiveFlush(generation: flushGeneration, pageEpoch: flushPageEpoch)
            }
        }
        let latestSettlement = FlushSettlement(
            completedGeneration: latestCompletedGeneration,
            discardedGeneration: latestDiscardedGeneration
        )
        return latestSettlement.hasValue ? latestSettlement : nil
    }

    var pendingMutationBundleCount: Int {
        pendingBundles.count
    }

    var hasPendingOrActiveBundleFlush: Bool {
        !pendingBundles.isEmpty || activeFlushTask != nil
    }

    var hasPendingBundleFlushTask: Bool {
        pendingBundleFlushTask != nil
    }

    var hasActiveBundleFlushTask: Bool {
        activeFlushTask != nil
    }

    var completedMutationGeneration: Int {
        completedFlushGeneration
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
            _ = await flushPendingBundlesNow()
        }
    }

    private func cancelPendingBundleFlush() {
        pendingBundleFlushTask?.cancel()
        pendingBundleFlushTask = nil
    }

    private func runActiveFlush(generation: Int, pageEpoch: Int) async -> FlushSettlement {
        let bundles = activeFlushBundles
        activeFlushBundles = []
        guard Task.isCancelled == false else {
            return .discarded(generation)
        }
        let didApply = await applyBundlesNow(bundles, generation: generation, pageEpoch: pageEpoch)
        return didApply ? .completed(generation) : .discarded(generation)
    }

    private func applyBundlesNow(_ bundles: [PendingBundle], generation: Int, pageEpoch: Int) async -> Bool {
        guard Task.isCancelled == false else {
            return false
        }
        guard !bundles.isEmpty else {
            return false
        }

        let payloads: [[String: Any]] = bundles.map {
            [
                "bundle": $0.bundle,
                "mode": $0.preservesInspectorState ? "preserve-ui-state" : "fresh",
                "documentScopeID": $0.documentScopeID,
            ]
        }

        guard Task.isCancelled == false else {
            return false
        }
#if DEBUG
        if let testBeforeBundleDispatchOverride {
            await testBeforeBundleDispatchOverride()
        }
        guard Task.isCancelled == false else {
            return false
        }
        if let testApplyBundlesOverride {
            activeDispatchGeneration = generation
            await testApplyBundlesOverride(bundles.map(\.bundle))
            return Task.isCancelled == false
        }
#endif
        guard let webView else {
            return false
        }
        guard Task.isCancelled == false else {
            return false
        }

        if await applyBundlesWithBufferIfNeeded(payloads, on: webView, generation: generation, pageEpoch: pageEpoch) {
            return Task.isCancelled == false
        }
        guard Task.isCancelled == false else {
            return false
        }

        do {
            activeDispatchGeneration = generation
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.applyMutationBundles?.(bundles, pageEpoch)",
                arguments: [
                    "bundles": payloads,
                    "pageEpoch": pageEpoch,
                ],
                contentWorld: .page
            )
            return Task.isCancelled == false
        } catch {
            domMutationPipelineLogger.error("send mutation bundles failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func applyBundlesWithBufferIfNeeded(
        _ payloads: [[String: Any]],
        on webView: InspectorWebView,
        generation: Int,
        pageEpoch: Int
    ) async -> Bool {
        guard session.bridgeMode == .privateFull else {
            return false
        }

        guard
            let jsonSafePayloads = Self.makeBufferTransportPayload(payloads),
            JSONSerialization.isValidJSONObject(jsonSafePayloads),
            let data = try? JSONSerialization.data(withJSONObject: jsonSafePayloads),
            data.count > WIJSBufferTransport.bufferThresholdBytes
        else {
            return false
        }

        let controller = webView.configuration.userContentController
        guard WIJSBufferTransport.isAvailable(on: controller, runtime: bridgeRuntime) else {
            return false
        }
        guard Task.isCancelled == false else {
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
        guard Task.isCancelled == false else {
            return false
        }

        do {
            activeDispatchGeneration = generation
            let rawResult = try await webView.callAsyncJavaScript(
                """
                if (!window.webInspectorDOMFrontend || typeof window.webInspectorDOMFrontend.applyMutationBuffer !== "function") {
                    return false;
                }
                return window.webInspectorDOMFrontend.applyMutationBuffer(bufferName, pageEpoch);
                """,
                arguments: [
                    "bufferName": bufferName,
                    "pageEpoch": pageEpoch,
                ],
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

extension DOMMutationSender {
    static func makeBufferTransportPayload(_ payloads: [[String: Any]]) -> [Any]? {
        makeBufferTransportValue(payloads) as? [Any]
    }

    static func makeBufferTransportValue(_ value: Any) -> Any? {
        if value is NSNull {
            return NSNull()
        }

        if let string = value as? String {
            return string
        }

        if let number = value as? NSNumber {
            return number
        }

        if let array = value as? [Any] {
            var resolved: [Any] = []
            resolved.reserveCapacity(array.count)
            for item in array {
                guard let safeItem = makeBufferTransportValue(item) else {
                    return nil
                }
                resolved.append(safeItem)
            }
            return resolved
        }

        if let array = value as? NSArray {
            return makeBufferTransportValue(array.map { $0 })
        }

        if let dictionary = value as? [String: Any] {
            if dictionary["type"] as? String == "serialized-node-envelope" {
                guard let fallback = dictionary["fallback"] else {
                    return nil
                }
                return makeBufferTransportValue(fallback)
            }

            var resolved: [String: Any] = [:]
            resolved.reserveCapacity(dictionary.count)
            for (key, nestedValue) in dictionary {
                guard let safeValue = makeBufferTransportValue(nestedValue) else {
                    return nil
                }
                resolved[key] = safeValue
            }
            return resolved
        }

        if let dictionary = value as? NSDictionary {
            var swiftDictionary: [String: Any] = [:]
            swiftDictionary.reserveCapacity(dictionary.count)
            for (rawKey, rawValue) in dictionary {
                guard let key = rawKey as? String else {
                    return nil
                }
                swiftDictionary[key] = rawValue
            }
            return makeBufferTransportValue(swiftDictionary)
        }

        return nil
    }
}

typealias DOMMutationPipeline = DOMMutationSender
