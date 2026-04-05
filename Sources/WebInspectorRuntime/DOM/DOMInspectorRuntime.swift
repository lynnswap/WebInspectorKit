import OSLog
import WebInspectorBridge
import WebInspectorEngine
import WebKit

private let inspectorLogger = Logger(subsystem: "WebInspectorKit", category: "DOMInspectorRuntime")
private let bootstrapRetryDelayNanoseconds: UInt64 = 50_000_000

enum DOMDocumentReloadMode: String, Equatable {
    case fresh = "fresh"
    case preserveUIState = "preserve-ui-state"
}

@MainActor
package final class DOMInspectorRuntime: NSObject {
    private final class RequestScope {}
    private struct DocumentScope {
        let documentScopeID: UInt64
        let requestScope: RequestScope
    }
    private struct DeferredDOMBundle {
        let bundle: DOMBundle
    }

    struct MutationContext: Equatable {
        let pageEpoch: Int
        let documentScopeID: UInt64
    }

    private enum Phase: Equatable {
        case idle(epoch: Int)
        case transitioning(epoch: Int, generation: UInt64)
        case bootstrapping(epoch: Int, generation: UInt64)

        var epoch: Int {
            switch self {
            case let .idle(epoch),
                 let .transitioning(epoch, _),
                 let .bootstrapping(epoch, _):
                epoch
            }
        }

        var generation: UInt64 {
            switch self {
            case .idle:
                0
            case let .transitioning(_, generation),
                 let .bootstrapping(_, generation):
                generation
            }
        }

        var allowsFrontendTraffic: Bool {
            if case .idle = self {
                return true
            }
            return false
        }

        var isTransitioning: Bool {
            if case .transitioning = self {
                return true
            }
            return false
        }
    }

    private struct TransitionContext {
        let epoch: Int
        let generation: UInt64
        let suspendedDeferredDOMBundles: [DeferredDOMBundle]
    }

    private struct PendingDocumentRequest: Equatable {
        let depth: Int
        let mode: DOMDocumentReloadMode
    }

    let session: DOMSession
    let bridge: DOMInspectorBridge
    let currentDocumentModel: DOMDocumentModel

    private var isReady = false
    private var phase: Phase = .idle(epoch: 0)
    private let mutationPipeline: DOMMutationSender
    private var configuration: DOMConfiguration
    private var configurationNeedsBootstrap = true
    private var pendingPreferredDepth: Int?
    private var pendingDocumentRequest: PendingDocumentRequest?
    private var bootstrapTask: Task<Void, Never>?
    private var bootstrapTaskID = 0
    private var selectorPathTask: Task<Void, Never>?
    private var selectorPathRequestCount = 0
    private var enqueuedMutationGeneration = 0
    private var discardedMutationGeneration = 0
    private let payloadNormalizer = DOMPayloadNormalizer()
    private let bridgeRuntime = WISPIRuntime.shared
    private var nextTransitionGeneration: UInt64 = 0
    var onRecoverableError: (@MainActor (String?) -> Void)?
    private var nextDocumentScopeID: UInt64 = 0
    private var currentDocumentScope = DocumentScope(documentScopeID: 0, requestScope: RequestScope())
    private var deferredDOMBundlesDuringBootstrap: [DeferredDOMBundle] = []
    private var deferredFrontendDocumentRequestDrainScope: RequestScope?
    private var deferredFrontendChildNodeRetryDrainScope: RequestScope?
    private var replacementFenceContext: MutationContext?
    private var deferredReadyMessageContexts: [MutationContext] = []
    private var pendingSelectionOverrideLocalID: UInt64?
    private var lastSnapshotDocumentURL: String?
    private var pendingDocumentScopeSyncTask: Task<Bool, Never>?
    private var pendingDocumentScopeRecoveryTask: Task<Void, Never>?
    private var pendingDocumentScopeSyncGeneration: UInt64 = 0
    private var pendingDocumentScopeRecoveryGeneration: UInt64 = 0
    private let documentScopeResyncRetryAttempts = 12
    private let documentScopeResyncRetryDelayNanoseconds: UInt64 = 250_000_000
    private let pendingDocumentScopeSyncRetryAttempts = 3
    private let pendingDocumentScopeSyncRetryDelayNanoseconds: UInt64 = 500_000_000
    private var pendingDocumentScopeSyncPageEpoch: Int?
    private var pendingDocumentScopeSyncDocumentScopeID: UInt64?
    private var pendingDocumentScopeRecoveryPageEpoch: Int?
    private var pendingDocumentScopeRecoveryDocumentScopeID: UInt64?

#if DEBUG
    var testConfigurationApplyOverride: (@MainActor (DOMConfiguration) async -> Void)?
    var testPreferredDepthApplyOverride: (@MainActor (Int) async -> Void)?
    var testDocumentRequestApplyOverride: (@MainActor (_ depth: Int, _ mode: DOMDocumentReloadMode) async -> Void)?
    var testFrontendDispatchOverride: (@MainActor (Any) async -> Bool)?
    var testSkipFreshRequestDocumentScopeSyncStub = false
    var testDocumentScopeSyncOverride: (@MainActor (UInt64) async -> Void)?
    var testDocumentScopeSyncResultOverride: Bool?
    var testDocumentScopeResyncRetryAttemptsOverride: Int?
    var testDocumentScopeResyncRetryDelayNanosecondsOverride: UInt64?
    var testPendingDocumentScopeSyncRetryAttemptsOverride: Int?
    var testPendingDocumentScopeSyncRetryDelayNanosecondsOverride: UInt64?
#endif

    private var webView: InspectorWebView? {
        bridge.inspectorWebView
    }

    private var pageEpoch: Int {
        phase.epoch
    }

    private var currentRequestScope: RequestScope {
        currentDocumentScope.requestScope
    }

    init(session: DOMSession, documentModel: DOMDocumentModel) {
        self.session = session
        self.currentDocumentModel = documentModel
        bridge = DOMInspectorBridge()
        configuration = session.configuration
        mutationPipeline = DOMMutationSender(
            session: session,
            bridgeRuntime: bridgeRuntime,
            configuration: session.configuration
        )
        super.init()
        bridge.runtime = self
        session.bundleSink = bridge
    }

    convenience init(session: DOMSession) {
        self.init(session: session, documentModel: DOMDocumentModel())
    }

    func makeInspectorWebView() -> InspectorWebView {
        let inspectorWebView = bridge.makeInspectorWebView()
        mutationPipeline.attachWebView(inspectorWebView)
        return inspectorWebView
    }

    func detachInspectorWebView() {
        guard webView != nil else {
            return
        }
        resetInspectorState()
        mutationPipeline.attachWebView(nil)
        bridge.detachInspectorWebView()
    }

    func enqueueMutationBundle(_ bundle: Any, preservingInspectorState: Bool) {
        enqueuedMutationGeneration += 1
        mutationPipeline.enqueueMutationBundle(
            bundle,
            preservingInspectorState: preservingInspectorState,
            generation: enqueuedMutationGeneration,
            pageEpoch: pageEpoch,
            documentScopeID: currentDocumentScope.documentScopeID
        )
    }

    func clearPendingMutationBundles() {
        discardedMutationGeneration = max(
            discardedMutationGeneration,
            mutationPipeline.clearPendingMutationBundles()
        )
    }

    var pendingMutationBundleCount: Int {
        mutationPipeline.pendingMutationBundleCount
    }

    func resetDocumentStoreForDetachment() {
        deferredReadyMessageContexts.removeAll(keepingCapacity: true)
        replacementFenceContext = nil
        lastSnapshotDocumentURL = nil
        replaceCurrentDocumentModel()
        payloadNormalizer.resetForDocumentUpdate()
    }

    @discardableResult
    func adoptPageContextIfNeeded(
        _ pageContext: DOMPageContext,
        preserveCurrentDocumentState: Bool = false
    ) async -> Bool {
        let adoptedPageEpoch = pageContext.pageEpoch
        let incomingDocumentURL = normalizedDocumentURL(pageContext.documentURL)
        let didChangeDocument = incomingDocumentURL != nil
            && incomingDocumentURL != normalizedDocumentURL(lastSnapshotDocumentURL)
        let hasExistingDocumentContext = currentDocumentModel.rootNode != nil || lastSnapshotDocumentURL != nil
        guard adoptedPageEpoch != pageEpoch
            || pageContext.documentScopeID != currentDocumentScope.documentScopeID
            || (didChangeDocument && hasExistingDocumentContext)
        else {
            return false
        }

        let adoptedContext = MutationContext(
            pageEpoch: adoptedPageEpoch,
            documentScopeID: pageContext.documentScopeID
        )
        let hasDeferredFrontendDocumentRequestDrain = deferredFrontendDocumentRequestDrainScope != nil
        let hasDeferredFrontendChildNodeRetryDrain = deferredFrontendChildNodeRetryDrainScope != nil
        moveReadySignal(to: adoptedContext)
        nextDocumentScopeID = max(nextDocumentScopeID, pageContext.documentScopeID)
        currentDocumentScope = .init(
            documentScopeID: pageContext.documentScopeID,
            requestScope: RequestScope()
        )
        phase = .idle(epoch: adoptedPageEpoch)
        replacementFenceContext = adoptedContext
        cancelInFlightContextTasks()
        await drainTransitionFlushIfNeeded()
        deferredDOMBundlesDuringBootstrap.removeAll(keepingCapacity: true)
        cancelSelectorPathRequest()
        clearPendingMutationBundles()
        deferredFrontendDocumentRequestDrainScope = hasDeferredFrontendDocumentRequestDrain ? currentRequestScope : nil
        deferredFrontendChildNodeRetryDrainScope = hasDeferredFrontendChildNodeRetryDrain ? currentRequestScope : nil
        pendingDocumentRequest = nil
        enqueuedMutationGeneration = 0
        discardedMutationGeneration = 0
        if !preserveCurrentDocumentState {
            pendingSelectionOverrideLocalID = nil
            lastSnapshotDocumentURL = incomingDocumentURL
            currentDocumentModel.clearDocument(isFreshDocument: true)
            payloadNormalizer.resetForDocumentUpdate()
        }
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        return true
    }

    func performPageTransition<T>(
        resumeBootstrap: Bool = true,
        _ operation: (_ nextPageEpoch: Int) async -> T
    ) async -> T {
        let transition = beginTransition(advancePageEpoch: true)
        replaceCurrentDocumentModel()
        payloadNormalizer.resetForDocumentUpdate()
        await drainTransitionFlushIfNeeded()
        let result = await operation(transition.epoch)
        completeTransition(transition, resumeBootstrap: resumeBootstrap)
        return result
    }

    func setPreferredDepth(_ depth: Int, expectedPageEpoch: Int? = nil) async {
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return
        }
        await waitForCurrentBootstrapIfNeeded()
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return
        }
        pendingPreferredDepth = depth
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        scheduleBootstrapIfNeeded()
        await waitForCurrentBootstrapIfNeeded()
    }

    func requestDocument(
        depth: Int,
        mode: DOMDocumentReloadMode,
        expectedPageEpoch: Int? = nil,
        expectedDocumentScopeID: UInt64? = nil
    ) async -> Bool {
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return false
        }
        guard acceptsExpectedDocumentScopeID(expectedDocumentScopeID) else {
            return false
        }
        if mode == .fresh {
            let transition = beginTransition(advancePageEpoch: false)
            let currentProjectedDocumentScopeID = currentDocumentScope.documentScopeID
            guard acceptsExpectedPageEpoch(expectedPageEpoch),
                  acceptsExpectedDocumentScopeID(expectedDocumentScopeID),
                  pageEpoch == transition.epoch,
                  phase.generation == transition.generation
            else {
                restoreDeferredDOMBundles(from: transition)
                completeTransition(transition)
                restartSelectionDependentRequestsIfNeeded()
                return false
            }
            let didResetChildRequests = await dispatchResetChildNodeRequestsToFrontend(
                pageEpoch: transition.epoch,
                documentScopeID: currentProjectedDocumentScopeID
            )
            guard didResetChildRequests else {
                restoreDeferredDOMBundles(from: transition)
                completeTransition(transition)
                restartSelectionDependentRequestsIfNeeded()
                return false
            }
            await drainTransitionFlushIfNeeded()
            guard acceptsExpectedPageEpoch(expectedPageEpoch),
                  acceptsExpectedDocumentScopeID(expectedDocumentScopeID),
                  pageEpoch == transition.epoch,
                  phase.generation == transition.generation
            else {
                restoreDeferredDOMBundles(from: transition)
                completeTransition(transition)
                restartSelectionDependentRequestsIfNeeded()
                return false
            }
            guard acceptsExpectedPageEpoch(expectedPageEpoch),
                  acceptsExpectedDocumentScopeID(expectedDocumentScopeID),
                  pageEpoch == transition.epoch,
                  phase.generation == transition.generation
            else {
                restoreDeferredDOMBundles(from: transition)
                completeTransition(transition)
                return false
            }
            clearPendingMutationBundles()
            cancelSelectorPathRequest()
            moveReadySignal(
                to: .init(
                    pageEpoch: transition.epoch,
                    documentScopeID: currentProjectedDocumentScopeID
                )
            )
            currentDocumentScope = .init(
                documentScopeID: currentProjectedDocumentScopeID,
                requestScope: RequestScope()
            )
            pendingSelectionOverrideLocalID = nil
            payloadNormalizer.resetForDocumentUpdate()
            currentDocumentModel.clearDocument(isFreshDocument: true)
            pendingDocumentRequest = .init(depth: depth, mode: mode)
            bridge.refreshBootstrapPayloadIfPossible()
            completeTransition(transition)
            await waitForCurrentBootstrapIfNeeded()
            return true
        }
        await waitForCurrentBootstrapIfNeeded()
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return false
        }
        guard acceptsExpectedDocumentScopeID(expectedDocumentScopeID) else {
            return false
        }
        pendingDocumentRequest = .init(depth: depth, mode: mode)
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        scheduleBootstrapIfNeeded()
        await waitForCurrentBootstrapIfNeeded()
        return true
    }

    private func syncFreshRequestDocumentScopeID(
        _ documentScopeID: UInt64,
        allowsMissingPage: Bool = false,
        expectedPageEpoch: Int? = nil
    ) async -> Bool {
        if session.hasPageWebView == false {
            session.prepareDocumentScopeID(documentScopeID)
#if DEBUG
            if let testDocumentScopeSyncOverride {
                await testDocumentScopeSyncOverride(documentScopeID)
                return testDocumentScopeSyncResultOverride ?? allowsMissingPage
            }
#endif
            return allowsMissingPage
        }
#if DEBUG
        if testSkipFreshRequestDocumentScopeSyncStub == false,
           let testDocumentScopeSyncOverride {
            await testDocumentScopeSyncOverride(documentScopeID)
            return testDocumentScopeSyncResultOverride ?? true
        }
#endif
        var remainingAttempts = documentScopeResyncRetryAttemptsValue
        while remainingAttempts > 0, Task.isCancelled == false {
            let didSync = await performDocumentScopeSync(
                documentScopeID,
                expectedPageEpoch: expectedPageEpoch
            )
            if didSync {
                return true
            }
            if session.hasPageWebView == false {
                return false
            }
            if expectedPageEpoch != nil, acceptsExpectedPageEpoch(expectedPageEpoch) == false {
                return false
            }
            remainingAttempts -= 1
            if remainingAttempts > 0 {
                try? await Task.sleep(nanoseconds: documentScopeResyncRetryDelayNanosecondsValue)
                guard Task.isCancelled == false else {
                    return false
                }
            }
        }
        return false
    }

    func updateConfiguration(_ configuration: DOMConfiguration, expectedPageEpoch: Int? = nil) async {
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return
        }
        await waitForCurrentBootstrapIfNeeded()
        guard acceptsExpectedPageEpoch(expectedPageEpoch) else {
            return
        }
        self.configuration = configuration
        mutationPipeline.updateConfiguration(configuration)
        configurationNeedsBootstrap = true
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        scheduleBootstrapIfNeeded()
        await waitForCurrentBootstrapIfNeeded()
    }

    var currentPageEpoch: Int {
        pageEpoch
    }

    var currentDocumentScopeID: UInt64 {
        currentDocumentScope.documentScopeID
    }

    var currentMutationContext: MutationContext {
        .init(
            pageEpoch: pageEpoch,
            documentScopeID: currentDocumentScope.documentScopeID
        )
    }

    var currentBootstrapPayload: [String: Any] {
        var payload: [String: Any] = [
            "config": frontendConfigurationPayload(),
            "context": frontendContextPayload(),
        ]
        if let pendingPreferredDepth {
            payload["preferredDepth"] = pendingPreferredDepth
        }
        if let pendingDocumentRequest {
            payload["pendingDocumentRequest"] = [
                "depth": pendingDocumentRequest.depth,
                "mode": pendingDocumentRequest.mode.rawValue,
                "pageEpoch": pageEpoch,
            ]
        }
        return payload
    }

    isolated deinit {
        bootstrapTask?.cancel()
        pendingDocumentScopeSyncTask?.cancel()
        pendingDocumentScopeRecoveryTask?.cancel()
        pendingDocumentScopeSyncGeneration &+= 1
        pendingDocumentScopeRecoveryGeneration &+= 1
        pendingDocumentScopeSyncPageEpoch = nil
        pendingDocumentScopeSyncDocumentScopeID = nil
        pendingDocumentScopeRecoveryPageEpoch = nil
        pendingDocumentScopeRecoveryDocumentScopeID = nil
        cancelSelectorPathRequest()
        mutationPipeline.reset()
        bridge.detachInspectorWebView()
    }
}

extension DOMInspectorRuntime {
    private var documentScopeResyncRetryAttemptsValue: Int {
#if DEBUG
        testDocumentScopeResyncRetryAttemptsOverride ?? documentScopeResyncRetryAttempts
#else
        documentScopeResyncRetryAttempts
#endif
    }

    private var documentScopeResyncRetryDelayNanosecondsValue: UInt64 {
#if DEBUG
        testDocumentScopeResyncRetryDelayNanosecondsOverride ?? documentScopeResyncRetryDelayNanoseconds
#else
        documentScopeResyncRetryDelayNanoseconds
#endif
    }

    private var pendingDocumentScopeSyncRetryAttemptsValue: Int {
#if DEBUG
        testPendingDocumentScopeSyncRetryAttemptsOverride ?? pendingDocumentScopeSyncRetryAttempts
#else
        pendingDocumentScopeSyncRetryAttempts
#endif
    }

    private var pendingDocumentScopeSyncRetryDelayNanosecondsValue: UInt64 {
#if DEBUG
        testPendingDocumentScopeSyncRetryDelayNanosecondsOverride ?? pendingDocumentScopeSyncRetryDelayNanoseconds
#else
        pendingDocumentScopeSyncRetryDelayNanoseconds
#endif
    }

    func matchesCurrentMutationContext(_ context: MutationContext?) -> Bool {
        guard let context else {
            return true
        }
        return pageEpoch == context.pageEpoch
            && currentDocumentScope.documentScopeID == context.documentScopeID
    }

    private func performDocumentScopeSync(
        _ documentScopeID: UInt64,
        expectedPageEpoch: Int? = nil
    ) async -> Bool {
#if DEBUG
        if let testDocumentScopeSyncOverride {
            await testDocumentScopeSyncOverride(documentScopeID)
            return testDocumentScopeSyncResultOverride ?? true
        }
#endif
        return await session.syncCurrentDocumentScopeIDIfNeeded(
            documentScopeID,
            expectedPageEpoch: expectedPageEpoch
        )
    }

    func syncMutationContextToPageIfNeeded(_ context: MutationContext) async -> Bool {
        guard session.hasPageWebView else {
            if matchesCurrentMutationContext(context) {
                session.prepareDocumentScopeID(context.documentScopeID)
            }
            return false
        }
        var remainingAttempts = documentScopeResyncRetryAttemptsValue
        while remainingAttempts > 0, Task.isCancelled == false {
            let didSync = await performDocumentScopeSync(
                context.documentScopeID,
                expectedPageEpoch: context.pageEpoch
            )
            if didSync {
                return true
            }
            if session.hasPageWebView == false {
                return false
            }
            if matchesCurrentMutationContext(context) == false {
                return false
            }
            remainingAttempts -= 1
            if remainingAttempts > 0 {
                try? await Task.sleep(nanoseconds: documentScopeResyncRetryDelayNanosecondsValue)
                guard Task.isCancelled == false else {
                    return false
                }
            }
        }
        guard matchesCurrentMutationContext(context) else {
            return false
        }
        syncCurrentDocumentScopeIDIfNeeded()
        return false
    }

    func setPendingSelectionOverride(localID: UInt64?) {
        pendingSelectionOverrideLocalID = localID.flatMap { $0 > 0 ? $0 : nil }
    }

    private func syncCurrentDocumentScopeIDIfNeeded() {
        let documentScopeID = currentDocumentScope.documentScopeID
        let pageEpoch = self.pageEpoch
        session.prepareDocumentScopeID(documentScopeID)
        if let pendingDocumentScopeRecoveryTask,
           pendingDocumentScopeRecoveryPageEpoch == pageEpoch,
           pendingDocumentScopeRecoveryDocumentScopeID == documentScopeID {
            _ = pendingDocumentScopeRecoveryTask
            return
        }

        if pendingDocumentScopeSyncPageEpoch != pageEpoch
            || pendingDocumentScopeSyncDocumentScopeID != documentScopeID {
            pendingDocumentScopeSyncTask?.cancel()
            pendingDocumentScopeSyncTask = nil
            pendingDocumentScopeSyncGeneration &+= 1
            pendingDocumentScopeSyncPageEpoch = nil
            pendingDocumentScopeSyncDocumentScopeID = nil
        }
        pendingDocumentScopeRecoveryTask?.cancel()
        pendingDocumentScopeRecoveryPageEpoch = pageEpoch
        pendingDocumentScopeRecoveryDocumentScopeID = documentScopeID
        pendingDocumentScopeRecoveryGeneration &+= 1
        let generation = pendingDocumentScopeRecoveryGeneration
        let recoveryTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.finishPendingDocumentScopeRecoveryTask(
                    generation: generation,
                    pageEpoch: pageEpoch,
                    documentScopeID: documentScopeID
                )
            }
            var remainingRecoveryRetries = self.documentScopeResyncRetryAttemptsValue
            while Task.isCancelled == false,
                  remainingRecoveryRetries > 0,
                  self.session.hasPageWebView,
                  self.pageEpoch == pageEpoch,
                  self.currentDocumentScope.documentScopeID == documentScopeID {
                let didSync = await self.syncCurrentDocumentScopeIDIfNeeded(
                    documentScopeID: documentScopeID,
                    pageEpoch: pageEpoch
                )
                if didSync {
                    return
                }
                remainingRecoveryRetries -= 1
                guard self.session.hasPageWebView,
                      self.pageEpoch == pageEpoch,
                      self.currentDocumentScope.documentScopeID == documentScopeID,
                      remainingRecoveryRetries > 0,
                      Task.isCancelled == false
                else {
                    return
                }
                try? await Task.sleep(
                    nanoseconds: self.documentScopeResyncRetryDelayNanosecondsValue
                )
                guard Task.isCancelled == false else {
                    return
                }
            }
        }
        pendingDocumentScopeRecoveryTask = recoveryTask
    }

    private func syncCurrentDocumentScopeIDIfNeeded(
        documentScopeID: UInt64,
        pageEpoch: Int
    ) async -> Bool {
        if let pendingDocumentScopeSyncTask,
           pendingDocumentScopeSyncPageEpoch == pageEpoch,
           pendingDocumentScopeSyncDocumentScopeID == documentScopeID {
            return await pendingDocumentScopeSyncTask.value
        }

        pendingDocumentScopeSyncTask?.cancel()
        pendingDocumentScopeSyncGeneration &+= 1
        let generation = pendingDocumentScopeSyncGeneration
        pendingDocumentScopeSyncPageEpoch = pageEpoch
        pendingDocumentScopeSyncDocumentScopeID = documentScopeID
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return false
            }
            let maxAttempts = self.pendingDocumentScopeSyncRetryAttemptsValue
            for attempt in 0..<maxAttempts {
                guard Task.isCancelled == false else {
                    self.finishPendingDocumentScopeSync(generation: generation)
                    return false
                }
                let didSync = await self.performDocumentScopeSync(
                    documentScopeID,
                    expectedPageEpoch: pageEpoch
                )
                guard self.pendingDocumentScopeSyncGeneration == generation else {
                    return false
                }
                if didSync {
                    self.finishPendingDocumentScopeSync(generation: generation)
                    return true
                }
                guard self.session.hasPageWebView,
                      self.pageEpoch == pageEpoch,
                      self.currentDocumentScope.documentScopeID == documentScopeID,
                      Task.isCancelled == false
                else {
                    self.finishPendingDocumentScopeSync(generation: generation)
                    return false
                }
                if attempt + 1 < maxAttempts {
                    try? await Task.sleep(
                        nanoseconds: self.pendingDocumentScopeSyncRetryDelayNanosecondsValue
                    )
                    guard Task.isCancelled == false else {
                        self.finishPendingDocumentScopeSync(generation: generation)
                        return false
                    }
                }
            }
            self.finishPendingDocumentScopeSync(generation: generation)
            return false
        }
        pendingDocumentScopeSyncTask = task
        return await task.value
    }

    private func finishPendingDocumentScopeSync(generation: UInt64) {
        guard pendingDocumentScopeSyncGeneration == generation else {
            return
        }
        pendingDocumentScopeSyncTask = nil
        pendingDocumentScopeSyncPageEpoch = nil
        pendingDocumentScopeSyncDocumentScopeID = nil
    }

    private func finishPendingDocumentScopeRecoveryTask(
        generation: UInt64,
        pageEpoch: Int,
        documentScopeID: UInt64
    ) {
        guard pendingDocumentScopeRecoveryGeneration == generation,
              pendingDocumentScopeRecoveryPageEpoch == pageEpoch,
              pendingDocumentScopeRecoveryDocumentScopeID == documentScopeID
        else {
            return
        }
        pendingDocumentScopeRecoveryTask = nil
        pendingDocumentScopeRecoveryPageEpoch = nil
        pendingDocumentScopeRecoveryDocumentScopeID = nil
    }

    private func makeNextDocumentScope() -> DocumentScope {
        nextDocumentScopeID &+= 1
        return .init(documentScopeID: nextDocumentScopeID, requestScope: RequestScope())
    }

    private func replaceCurrentDocumentModel() {
        let nextScope = makeNextDocumentScope()
        cancelSelectorPathRequest()
        moveReadySignal(
            to: .init(
                pageEpoch: pageEpoch,
                documentScopeID: nextScope.documentScopeID
            )
        )
        currentDocumentScope = nextScope
        pendingSelectionOverrideLocalID = nil
        currentDocumentModel.clearDocument(isFreshDocument: true)
        syncCurrentDocumentScopeIDIfNeeded()
    }

    private func commitCurrentDocumentScope(
        _ nextScope: DocumentScope,
        clearCurrentContents: Bool
    ) {
        clearPendingMutationBundles()
        moveReadySignal(
            to: .init(
                pageEpoch: pageEpoch,
                documentScopeID: nextScope.documentScopeID
            )
        )
        currentDocumentScope = nextScope
        pendingSelectionOverrideLocalID = nil
        if clearCurrentContents {
            currentDocumentModel.clearDocument(isFreshDocument: true)
        }
        cancelSelectorPathRequest()
        bridge.refreshBootstrapPayloadIfPossible()
        syncCurrentDocumentScopeIDIfNeeded()
        if phase.allowsFrontendTraffic, hasPendingBootstrapWork == false {
            activateDeferredReadyMessageIfMatchingCurrentContext()
        }
        updateMutationPipelineReadyState()
        scheduleBootstrapIfNeeded()
    }

    private func advanceCurrentDocumentScope(clearCurrentContents: Bool) {
        commitCurrentDocumentScope(
            makeNextDocumentScope(),
            clearCurrentContents: clearCurrentContents
        )
    }

    private func adoptSyncedDocumentScopeAfterAbortedFreshRequest(
        _ nextScope: DocumentScope,
        transition: TransitionContext
    ) {
        guard pageEpoch == transition.epoch else {
            return
        }
        guard currentDocumentScope.documentScopeID < nextScope.documentScopeID else {
            return
        }
        restoreDeferredDOMBundles(
            from: transition,
            rebasedToDocumentScopeID: nextScope.documentScopeID
        )
        commitCurrentDocumentScope(nextScope, clearCurrentContents: true)
    }

    private func applyMutationEventsToCurrentDocumentModel(_ events: [DOMGraphMutationEvent]) {
        guard !events.isEmpty else {
            return
        }
        currentDocumentModel.applyMutationBundle(.init(events: events))
    }

    private func applyMutationBundleAcrossDocumentUpdates(_ bundle: DOMGraphMutationBundle) {
        guard !bundle.events.isEmpty else {
            return
        }

        var bufferedEvents: [DOMGraphMutationEvent] = []
        for event in bundle.events {
            switch event {
            case .documentUpdated:
                applyMutationEventsToCurrentDocumentModel(bufferedEvents)
                payloadNormalizer.resetForDocumentUpdate()
                advanceCurrentDocumentScope(clearCurrentContents: true)
                return
            default:
                bufferedEvents.append(event)
            }
        }

        applyMutationEventsToCurrentDocumentModel(bufferedEvents)
    }

    func updateMutationPipelineReadyState() {
        mutationPipeline.setReady(isReady && phase.allowsFrontendTraffic && bootstrapTask == nil && !hasPendingBootstrapWork)
    }

    func clearDocumentReplacementAfterContextAdoptionRequirement() {
        clearDocumentReplacementAfterContextAdoptionRequirement(
            pageEpoch: pageEpoch,
            documentScopeID: currentDocumentScope.documentScopeID
        )
    }

    private func clearDocumentReplacementAfterContextAdoptionRequirement(
        pageEpoch: Int,
        documentScopeID: UInt64
    ) {
        guard replacementFenceContext == .init(pageEpoch: pageEpoch, documentScopeID: documentScopeID) else {
            return
        }
        replacementFenceContext = nil
        activateDeferredReadyMessageIfMatchingCurrentContext()
        if bootstrapTask == nil {
            applyDeferredDOMBundlesIfNeeded(expectedPageEpoch: pageEpoch)
        }
        drainDeferredFrontendDocumentRequestIfNeeded()
        drainDeferredFrontendChildNodeRetryIfNeeded()
    }

    func retryDocumentReplacementAfterContextAdoption(depth: Int, mode: DOMDocumentReloadMode) {
        pendingDocumentRequest = .init(depth: depth, mode: mode)
        replacementFenceContext = currentMutationContext
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        scheduleBootstrapIfNeeded()
    }

    private func activateDeferredReadyMessageIfMatchingCurrentContext() {
        let currentContext = currentMutationContext
        pruneDeferredReadyMessages(except: currentContext)
        guard hasReplacementFenceForCurrentContext == false,
              consumeDeferredReadyMessage(for: currentContext)
        else {
            return
        }
        applyReadyState()
    }

    private func applyReadyState() {
        isReady = true
        updateMutationPipelineReadyState()
        scheduleBootstrapIfNeeded()
    }

    func waitForCurrentBootstrapIfNeeded() async {
        guard let bootstrapTask else {
            return
        }
        let currentTaskID = bootstrapTaskID
        await bootstrapTask.value
        if bootstrapTaskID == currentTaskID {
            self.bootstrapTask = nil
        }
    }

    var hasConfigurationBootstrapEndpoint: Bool {
#if DEBUG
        webView != nil || testConfigurationApplyOverride != nil
#else
        webView != nil
#endif
    }

    var hasPreferredDepthBootstrapEndpoint: Bool {
#if DEBUG
        webView != nil || testPreferredDepthApplyOverride != nil
#else
        webView != nil
#endif
    }

    var hasDocumentRequestBootstrapEndpoint: Bool {
#if DEBUG
        webView != nil || testDocumentRequestApplyOverride != nil
#else
        webView != nil
#endif
    }

    var hasBootstrapExecutionEndpoint: Bool {
        if configurationNeedsBootstrap {
            return hasConfigurationBootstrapEndpoint
        }
        if pendingPreferredDepth != nil {
            return hasPreferredDepthBootstrapEndpoint
        }
        if pendingDocumentRequest != nil {
            return hasDocumentRequestBootstrapEndpoint
        }
        return false
    }

    var hasPendingBootstrapWork: Bool {
        configurationNeedsBootstrap || pendingPreferredDepth != nil || pendingDocumentRequest != nil
    }

    private func enqueueDeferredReadyMessage(_ context: MutationContext) {
        guard deferredReadyMessageContexts.contains(context) == false else {
            return
        }
        deferredReadyMessageContexts.append(context)
    }

    private func pruneDeferredReadyMessages(except context: MutationContext? = nil) {
        deferredReadyMessageContexts.removeAll { queuedContext in
            guard let context else {
                return true
            }
            return queuedContext != context
        }
    }

    private func hasDeferredReadyMessage(for context: MutationContext) -> Bool {
        deferredReadyMessageContexts.contains(context)
    }

    @discardableResult
    private func consumeDeferredReadyMessage(for context: MutationContext) -> Bool {
        guard let index = deferredReadyMessageContexts.firstIndex(of: context) else {
            return false
        }
        deferredReadyMessageContexts.remove(at: index)
        return true
    }

    private func moveReadySignal(to context: MutationContext) {
        let hasCurrentReadySignal = isReady || hasDeferredReadyMessage(for: currentMutationContext)
        pruneDeferredReadyMessages()
        isReady = false
        if hasCurrentReadySignal {
            enqueueDeferredReadyMessage(context)
        }
    }

    private func isReadyContextCurrentOrNewer(_ context: MutationContext) -> Bool {
        context == currentMutationContext
    }

    private var hasReplacementFenceForCurrentContext: Bool {
        replacementFenceContext == currentMutationContext
    }

    private var hasBootstrapReadySignalForCurrentContext: Bool {
        if hasReplacementFenceForCurrentContext {
            return hasDeferredReadyMessage(for: currentMutationContext)
        }
        return isReady || hasDeferredReadyMessage(for: currentMutationContext)
    }

    func acceptsExpectedPageEpoch(_ expectedPageEpoch: Int?) -> Bool {
        guard let expectedPageEpoch else {
            return true
        }
        return expectedPageEpoch == pageEpoch
    }

    func acceptsExpectedDocumentScopeID(_ expectedDocumentScopeID: UInt64?) -> Bool {
        guard let expectedDocumentScopeID else {
            return true
        }
        return expectedDocumentScopeID == currentDocumentScope.documentScopeID
    }

    func frontendConfigurationPayload() -> [String: Any] {
        [
            "snapshotDepth": configuration.snapshotDepth,
            "subtreeDepth": configuration.subtreeDepth,
            "autoUpdateDebounce": configuration.autoUpdateDebounce,
        ]
    }

    func frontendContextPayload() -> [String: Any] {
        [
            "pageEpoch": pageEpoch,
            "documentScopeID": currentDocumentScope.documentScopeID,
        ]
    }

    func publishRecoverableError(_ message: String?) {
        onRecoverableError?(message)
    }

    func scheduleBootstrapIfNeeded() {
        guard bootstrapTask == nil,
              hasBootstrapReadySignalForCurrentContext,
              phase.isTransitioning == false,
              hasBootstrapExecutionEndpoint,
              hasPendingBootstrapWork
        else {
            return
        }

        let expectedPageEpoch = pageEpoch
        let expectedGeneration = phase.generation
        phase = .bootstrapping(epoch: expectedPageEpoch, generation: expectedGeneration)
        bootstrapTaskID += 1
        let taskID = bootstrapTaskID
        bootstrapTask = Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.bootstrapTaskID == taskID {
                    self.bootstrapTask = nil
                }
                if self.pageEpoch == expectedPageEpoch, self.phase.generation == expectedGeneration {
                    if self.hasPendingBootstrapWork {
                        self.phase = .bootstrapping(epoch: expectedPageEpoch, generation: expectedGeneration)
                    } else {
                        self.phase = .idle(epoch: expectedPageEpoch)
                        self.activateDeferredReadyMessageIfMatchingCurrentContext()
                    }
                }
                self.updateMutationPipelineReadyState()
                self.drainDeferredFrontendDocumentRequestIfNeeded()
                self.drainDeferredFrontendChildNodeRetryIfNeeded()
                if self.hasBootstrapReadySignalForCurrentContext,
                   self.pageEpoch == expectedPageEpoch,
                   self.hasPendingBootstrapWork
                {
                    self.scheduleBootstrapIfNeeded()
                }
            }

            while Task.isCancelled == false,
                  self.hasBootstrapReadySignalForCurrentContext,
                  self.hasBootstrapExecutionEndpoint,
                  self.pageEpoch == expectedPageEpoch,
                  self.hasPendingBootstrapWork {
                let didApply = await self.performBootstrapPass(expectedPageEpoch: expectedPageEpoch)
                if didApply {
                    continue
                }
                try? await Task.sleep(nanoseconds: bootstrapRetryDelayNanoseconds)
            }
        }
    }

    func performBootstrapPass(expectedPageEpoch: Int) async -> Bool {
        guard pageEpoch == expectedPageEpoch else {
            return true
        }

        if configurationNeedsBootstrap {
            guard await applyConfigurationToInspector(expectedPageEpoch: expectedPageEpoch) else {
                return false
            }
            guard pageEpoch == expectedPageEpoch else {
                return true
            }
            guard Task.isCancelled == false else {
                return true
            }
            configurationNeedsBootstrap = false
        }

        if let depth = pendingPreferredDepth {
            guard await applyPreferredDepthNow(depth, expectedPageEpoch: expectedPageEpoch) else {
                return false
            }
            guard pageEpoch == expectedPageEpoch else {
                return true
            }
            guard Task.isCancelled == false else {
                return true
            }
            if pendingPreferredDepth == depth {
                pendingPreferredDepth = nil
            }
        }

        if let request = pendingDocumentRequest {
            guard await requestDocumentNow(
                depth: request.depth,
                mode: request.mode,
                expectedPageEpoch: expectedPageEpoch
            ) else {
                return false
            }
            guard pageEpoch == expectedPageEpoch else {
                return true
            }
            guard Task.isCancelled == false else {
                return true
            }
            if pendingDocumentRequest == request {
                pendingDocumentRequest = nil
            }
        }

        guard Task.isCancelled == false else {
            return true
        }
        applyDeferredDOMBundlesIfNeeded(expectedPageEpoch: expectedPageEpoch)

        publishRecoverableError(nil)
        return true
    }

    func applyConfigurationToInspector(expectedPageEpoch: Int) async -> Bool {
        guard pageEpoch == expectedPageEpoch else {
            return true
        }
        let config = frontendConfigurationPayload()
#if DEBUG
        if let testConfigurationApplyOverride {
            await testConfigurationApplyOverride(configuration)
            return true
        }
#endif
        guard let webView else {
            publishRecoverableError("Inspector web view unavailable")
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                """
                (function(config) {
                    if (window.webInspectorDOMFrontend?.updateConfig) {
                        window.webInspectorDOMFrontend.updateConfig(config);
                        return;
                    }
                    const bootstrap = window.__wiDOMFrontendBootstrap || (window.__wiDOMFrontendBootstrap = {});
                    bootstrap.config = { ...(bootstrap.config || {}), ...config };
                })(config);
                """,
                arguments: [
                    "config": config,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            publishRecoverableError(error.localizedDescription)
            inspectorLogger.error("apply config failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func beginTransition(advancePageEpoch: Bool) -> TransitionContext {
        cancelInFlightContextTasks()
        let suspendedDeferredDOMBundles = deferredDOMBundlesDuringBootstrap
        deferredDOMBundlesDuringBootstrap.removeAll(keepingCapacity: true)
        cancelSelectorPathRequest()
        nextTransitionGeneration &+= 1
        let generation = nextTransitionGeneration
        let nextEpoch = pageEpoch + (advancePageEpoch ? 1 : 0)
        phase = .transitioning(epoch: nextEpoch, generation: generation)
        if advancePageEpoch {
            configurationNeedsBootstrap = true
        }
        mutationPipeline.setReady(false)
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        return .init(
            epoch: nextEpoch,
            generation: generation,
            suspendedDeferredDOMBundles: suspendedDeferredDOMBundles
        )
    }

    private func restoreDeferredDOMBundles(
        from transition: TransitionContext,
        rebasedToDocumentScopeID documentScopeID: UInt64? = nil
    ) {
        guard !transition.suspendedDeferredDOMBundles.isEmpty else {
            return
        }
        let restoredBundles = transition.suspendedDeferredDOMBundles.map { entry in
            DeferredDOMBundle(
                bundle: rebasedDOMBundle(
                    entry.bundle,
                    documentScopeID: documentScopeID ?? entry.bundle.documentScopeID
                )
            )
        }
        deferredDOMBundlesDuringBootstrap = restoredBundles + deferredDOMBundlesDuringBootstrap
    }

    private func rebasedDOMBundle(_ bundle: DOMBundle, documentScopeID: UInt64?) -> DOMBundle {
        bundleByUpdatingTransportContext(
            bundle,
            pageEpoch: bundle.pageEpoch,
            documentScopeID: documentScopeID
        )
    }

    private func bundleByUpdatingTransportContext(
        _ bundle: DOMBundle,
        pageEpoch: Int?,
        documentScopeID: UInt64?
    ) -> DOMBundle {
        switch bundle.payload {
        case let .jsonString(rawJSON):
            let rebasedPayload = payloadByUpdatingTransportContext(
                rawJSON,
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID
            )
            if let rebasedJSON = rebasedPayload as? String {
                return .init(
                    rawJSON: rebasedJSON,
                    pageEpoch: pageEpoch,
                    documentScopeID: documentScopeID
                )
            }
            return .init(
                objectEnvelope: rebasedPayload,
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID
            )
        case let .objectEnvelope(objectEnvelope):
            let rebasedPayload = payloadByUpdatingTransportContext(
                objectEnvelope,
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID
            )
            return .init(
                objectEnvelope: rebasedPayload,
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID
            )
        }
    }

    private func drainTransitionFlushIfNeeded(resetCompletedGeneration: Bool = true) async {
        discardedMutationGeneration = max(
            discardedMutationGeneration,
            await mutationPipeline.cancelAndDrainFlushIfNeeded(
                resetCompletedGeneration: resetCompletedGeneration
            )
        )
    }

    private func completeTransition(
        _ transition: TransitionContext,
        resumeBootstrap: Bool = true
    ) {
        guard pageEpoch == transition.epoch, phase.generation == transition.generation else {
            return
        }
        enqueuedMutationGeneration = 0
        discardedMutationGeneration = 0
        if resumeBootstrap, hasPendingBootstrapWork {
            phase = .bootstrapping(epoch: transition.epoch, generation: transition.generation)
        } else {
            phase = .idle(epoch: transition.epoch)
        }
        bridge.refreshBootstrapPayloadIfPossible()
        updateMutationPipelineReadyState()
        drainDeferredFrontendDocumentRequestIfNeeded()
        drainDeferredFrontendChildNodeRetryIfNeeded()
        if resumeBootstrap {
            scheduleBootstrapIfNeeded()
        }
    }

    private func cancelInFlightContextTasks() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        pendingDocumentScopeSyncTask?.cancel()
        pendingDocumentScopeRecoveryTask?.cancel()
        pendingDocumentScopeSyncTask = nil
        pendingDocumentScopeRecoveryTask = nil
        pendingDocumentScopeSyncGeneration &+= 1
        pendingDocumentScopeRecoveryGeneration &+= 1
        pendingDocumentScopeSyncPageEpoch = nil
        pendingDocumentScopeSyncDocumentScopeID = nil
        pendingDocumentScopeRecoveryPageEpoch = nil
        pendingDocumentScopeRecoveryDocumentScopeID = nil
    }

    func resetInspectorState() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        pendingDocumentScopeSyncTask?.cancel()
        pendingDocumentScopeRecoveryTask?.cancel()
        pendingDocumentScopeSyncTask = nil
        pendingDocumentScopeRecoveryTask = nil
        pendingDocumentScopeSyncGeneration &+= 1
        pendingDocumentScopeRecoveryGeneration &+= 1
        pendingDocumentScopeSyncPageEpoch = nil
        pendingDocumentScopeSyncDocumentScopeID = nil
        pendingDocumentScopeRecoveryPageEpoch = nil
        pendingDocumentScopeRecoveryDocumentScopeID = nil
        cancelSelectorPathRequest()
        isReady = false
        configurationNeedsBootstrap = true
        pendingPreferredDepth = nil
        pendingDocumentRequest = nil
        enqueuedMutationGeneration = 0
        discardedMutationGeneration = 0
        deferredDOMBundlesDuringBootstrap.removeAll(keepingCapacity: true)
        deferredFrontendDocumentRequestDrainScope = nil
        deferredFrontendChildNodeRetryDrainScope = nil
        deferredReadyMessageContexts.removeAll(keepingCapacity: true)
        replacementFenceContext = nil
        pendingSelectionOverrideLocalID = nil
        phase = .idle(epoch: pageEpoch)
        updateMutationPipelineReadyState()
        mutationPipeline.reset()
    }

    func applyPreferredDepthNow(_ depth: Int, expectedPageEpoch: Int) async -> Bool {
        guard pageEpoch == expectedPageEpoch else {
            return true
        }
#if DEBUG
        if let testPreferredDepthApplyOverride {
            await testPreferredDepthApplyOverride(depth)
            return true
        }
#endif
        guard let webView else {
            publishRecoverableError("Inspector web view unavailable")
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                """
                (function(depth, pageEpoch) {
                    if (window.webInspectorDOMFrontend?.setPreferredDepth) {
                        window.webInspectorDOMFrontend.setPreferredDepth(depth, pageEpoch);
                        return;
                    }
                    const bootstrap = window.__wiDOMFrontendBootstrap || (window.__wiDOMFrontendBootstrap = {});
                    bootstrap.preferredDepth = depth;
                })(depth, pageEpoch);
                """,
                arguments: [
                    "depth": depth,
                    "pageEpoch": pageEpoch,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            publishRecoverableError(error.localizedDescription)
            inspectorLogger.error("send preferred depth failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func requestDocumentNow(depth: Int, mode: DOMDocumentReloadMode, expectedPageEpoch: Int) async -> Bool {
        guard pageEpoch == expectedPageEpoch else {
            return true
        }
        let requestScope = currentRequestScope
        let requestDocumentScopeID = currentDocumentScope.documentScopeID
#if DEBUG
        if let testDocumentRequestApplyOverride {
            await testDocumentRequestApplyOverride(depth, mode)
            guard pageEpoch == expectedPageEpoch, currentRequestScope === requestScope else {
                return true
            }
            clearDocumentReplacementAfterContextAdoptionRequirement()
            return true
        }
#endif
        do {
            let payload = try await session.captureSnapshotPayload(
                maxDepth: depth,
                initialModeOwnership: .preservePendingInitialMode
            )
            let (payloadForDispatch, appliedSelectionOverride) = payloadByApplyingPendingSelectionOverride(payload)
            guard pageEpoch == expectedPageEpoch, currentRequestScope === requestScope else {
                setDeferredFrontendDocumentRequestDrainScope(requestScope)
                _ = await dispatchRejectDocumentRequestToFrontend(
                    pageEpoch: expectedPageEpoch,
                    documentScopeID: requestDocumentScopeID
                )
                return true
            }
            guard await dispatchFullSnapshotToFrontend(
                payloadForDispatch,
                mode: mode.rawValue,
                pageEpoch: expectedPageEpoch,
                documentScopeID: requestDocumentScopeID,
                requestScope: requestScope
            ) else {
                return false
            }
            guard pageEpoch == expectedPageEpoch, currentRequestScope === requestScope else {
                clearDocumentReplacementAfterContextAdoptionRequirement(
                    pageEpoch: expectedPageEpoch,
                    documentScopeID: requestDocumentScopeID
                )
                return true
            }
            let clearsReplacementFence = hasReplacementFenceForCurrentContext
            guard let snapshot = payloadNormalizer.normalizeSnapshot(payloadForDispatch) else {
                publishRecoverableError("Snapshot normalization failed")
                inspectorLogger.error("normalize snapshot failed after frontend dispatch")
                clearDocumentReplacementAfterContextAdoptionRequirement()
                if clearsReplacementFence {
                    restartSelectionDependentRequestsAfterResync()
                }
                return true
            }
            await session.consumePendingInitialSnapshotMode(
                expectedPageEpoch: expectedPageEpoch,
                expectedDocumentScopeID: requestDocumentScopeID
            )
            currentDocumentModel.replaceDocument(
                with: snapshot,
                isFreshDocument: clearsReplacementFence
            )
            if appliedSelectionOverride {
                pendingSelectionOverrideLocalID = nil
            }
            clearDocumentReplacementAfterContextAdoptionRequirement()
            if clearsReplacementFence {
                restartSelectionDependentRequestsAfterResync()
            }
            return true
        } catch {
            publishRecoverableError(error.localizedDescription)
            inspectorLogger.error("request document failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func payloadByApplyingPendingSelectionOverride(_ payload: Any) -> (payload: Any, applied: Bool) {
        guard let pendingSelectionOverrideLocalID else {
            return (payload, false)
        }
        if var dictionary = payload as? [String: Any] {
            dictionary["selectedNodeId"] = pendingSelectionOverrideLocalID
            dictionary["selectedLocalId"] = pendingSelectionOverrideLocalID
            return (dictionary, true)
        }
        if let dictionary = payload as? NSDictionary {
            var copied = dictionary as? [String: Any] ?? [:]
            copied["selectedNodeId"] = pendingSelectionOverrideLocalID
            copied["selectedLocalId"] = pendingSelectionOverrideLocalID
            return (copied, true)
        }
        if let json = payload as? String,
           let data = json.data(using: .utf8),
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object["selectedNodeId"] = pendingSelectionOverrideLocalID
            object["selectedLocalId"] = pendingSelectionOverrideLocalID
            return (object, true)
        }
        return (payload, false)
    }

    private func payloadByUpdatingTransportContext(
        _ payload: Any,
        pageEpoch: Int?,
        documentScopeID: UInt64?
    ) -> Any {
        func applyContext(to object: inout [String: Any]) {
            if let pageEpoch {
                object["pageEpoch"] = pageEpoch
            }
            if let documentScopeID {
                object["documentScopeID"] = documentScopeID
            }
            guard object["kind"] as? String == "mutation",
                  let events = object["events"] as? [Any]
            else {
                return
            }
            object["events"] = truncatedMutationEvents(events)
        }

        func truncatedMutationEvents(_ events: [Any]) -> [Any] {
            var truncated: [Any] = []
            truncated.reserveCapacity(events.count)

            for event in events {
                truncated.append(event)
                if let dictionary = event as? [String: Any],
                   dictionary["method"] as? String == "DOM.documentUpdated" {
                    break
                }
                if let dictionary = event as? NSDictionary,
                   dictionary["method"] as? String == "DOM.documentUpdated" {
                    break
                }
            }

            return truncated
        }

        if var dictionary = payload as? [String: Any] {
            applyContext(to: &dictionary)
            return dictionary
        }
        if let dictionary = payload as? NSDictionary {
            var copied = dictionary as? [String: Any] ?? [:]
            applyContext(to: &copied)
            return copied
        }
        if let json = payload as? String,
           let data = json.data(using: .utf8),
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            applyContext(to: &object)
            return object
        }
        return payload
    }

    func startSelectorPathRequest(target: DOMRequestNodeTarget, selectionEntry: DOMNodeModel) {
        cancelSelectorPathRequest()
        selectorPathRequestCount += 1
        let requestGeneration = selectorPathRequestCount
        let requestScope = currentRequestScope
        let selectionDocumentScopeID = currentDocumentScope.documentScopeID

        selectorPathTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let selectorPath = try await self.session.selectorPath(target: target)
                guard Task.isCancelled == false else {
                    return
                }
                guard self.selectorPathRequestCount == requestGeneration,
                      self.currentRequestScope === requestScope,
                      self.currentSelectedEntry(target: target, documentScopeID: selectionDocumentScopeID) != nil
                else {
                    return
                }
                guard let currentSelection = self.currentSelectedEntry(
                    target: target,
                    documentScopeID: selectionDocumentScopeID
                ) else {
                    return
                }
                self.currentDocumentModel.applySelectorPath(selectorPath, for: currentSelection)
            } catch {
                guard self.selectorPathRequestCount == requestGeneration,
                      self.currentRequestScope === requestScope,
                      self.currentSelectedEntry(target: target, documentScopeID: selectionDocumentScopeID) != nil
                else {
                    return
                }
                guard let currentSelection = self.currentSelectedEntry(
                    target: target,
                    documentScopeID: selectionDocumentScopeID
                ) else {
                    return
                }
                self.currentDocumentModel.applySelectorPath("", for: currentSelection)
                return
            }
        }
    }

    func cancelSelectorPathRequest() {
        selectorPathTask?.cancel()
        selectorPathTask = nil
    }

    private func restartSelectionDependentRequestsIfNeeded() {
        guard let selected = currentDocumentModel.selectedNode,
              let target = selectionRequestTarget(for: selected) else {
            return
        }
        if selected.selectorPath.isEmpty {
            startSelectorPathRequest(target: target, selectionEntry: selected)
        }
    }

    func restartSelectionDependentRequestsAfterResync() {
        drainDeferredFrontendDocumentRequestIfNeeded()
        drainDeferredFrontendChildNodeRetryIfNeeded()
        restartSelectionDependentRequestsIfNeeded()
    }

    func applySelectionDelta(_ delta: DOMGraphDelta) {
        switch delta {
        case let .selection(selectionPayload):
            currentDocumentModel.applySelectionSnapshot(selectionPayload)
        case let .selectorPath(selectorPayload):
            currentDocumentModel.applySelectorPath(selectorPayload)
        case .snapshot, .mutations, .replaceSubtree:
            return
        }
    }

    func parseIntegerValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String, let parsed = Int(value) {
            return parsed
        }
        return nil
    }

    func parseBooleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func currentSelectedEntry(target: DOMRequestNodeTarget, documentScopeID: UInt64) -> DOMNodeModel? {
        guard currentDocumentScope.documentScopeID == documentScopeID,
              let selectedEntry = currentDocumentModel.selectedNode,
              selectionRequestTarget(for: selectedEntry) == target
        else {
            return nil
        }
        return selectedEntry
    }

    func selectionRequestTarget(for node: DOMNodeModel) -> DOMRequestNodeTarget? {
        if let backendNodeID = node.backendNodeID,
           backendNodeID > 0 {
            return .backend(backendNodeID)
        }
        guard node.localID <= UInt64(Int.max) else {
            return nil
        }
        return .local(node.localID)
    }
}

extension DOMInspectorRuntime {
    private func canDispatchFrontendPayload(
        pageEpoch: Int,
        documentScopeID: UInt64,
        requestScope: RequestScope
    ) -> Bool {
        self.pageEpoch == pageEpoch
            && currentDocumentScope.documentScopeID == documentScopeID
            && currentRequestScope === requestScope
    }

    @discardableResult
    private func dispatchFullSnapshotToFrontend(
        _ payload: Any,
        mode: String,
        pageEpoch: Int,
        documentScopeID: UInt64,
        requestScope: RequestScope
    ) async -> Bool {
        guard canDispatchFrontendPayload(
            pageEpoch: pageEpoch,
            documentScopeID: documentScopeID,
            requestScope: requestScope
        ) else {
            return true
        }
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "fullSnapshot",
                "payload": payload,
                "mode": mode,
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return true
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.applyFullSnapshot?.(payload, mode, pageEpoch, documentScopeID)",
                arguments: [
                    "payload": payload,
                    "mode": mode,
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch full snapshot failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchSubtreePayloadToFrontend(
        _ payload: Any,
        pageEpoch: Int,
        documentScopeID: UInt64,
        requestScope: RequestScope
    ) async -> Bool {
        guard canDispatchFrontendPayload(
            pageEpoch: pageEpoch,
            documentScopeID: documentScopeID,
            requestScope: requestScope
        ) else {
            return true
        }
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "subtree",
                "payload": payload,
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.applySubtreePayload?.(payload, pageEpoch, documentScopeID)",
                arguments: [
                    "payload": payload,
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch subtree failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func materializeSubtree(
        nodeID: Int,
        depth: Int,
        expectedContext: MutationContext
    ) async -> Bool {
        guard matchesCurrentMutationContext(expectedContext) else {
            return false
        }

        let requestScope = currentRequestScope
        let requestDocumentScopeID = currentDocumentScope.documentScopeID

        do {
            let payload = try await session.captureSubtreePayload(
                target: .local(UInt64(nodeID)),
                maxDepth: depth
            )
            guard matchesCurrentMutationContext(expectedContext),
                  currentRequestScope === requestScope
            else {
                return false
            }

            if webView != nil {
                let didDispatch = await dispatchSubtreePayloadToFrontend(
                    payload,
                    pageEpoch: expectedContext.pageEpoch,
                    documentScopeID: requestDocumentScopeID,
                    requestScope: requestScope
                )
                guard didDispatch else {
                    return false
                }
            }

            guard matchesCurrentMutationContext(expectedContext),
                  currentRequestScope === requestScope
            else {
                return false
            }

            guard let delta = payloadNormalizer.normalizeBackendResponse(
                method: "DOM.requestChildNodes",
                responseObject: ["result": payload],
                resetDocument: false
            ),
            case let .replaceSubtree(root) = delta
            else {
                return false
            }

            currentDocumentModel.applyMutationBundle(
                .init(events: [.replaceSubtree(root: root)])
            )
            return true
        } catch {
            inspectorLogger.debug("materialize subtree failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func dispatchSelectionToFrontend(
        localID: UInt64,
        expectedContext: MutationContext
    ) async -> Bool {
        guard matchesCurrentMutationContext(expectedContext) else {
            return false
        }
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "selection",
                "localID": localID,
                "pageEpoch": expectedContext.pageEpoch,
                "documentScopeID": expectedContext.documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return false
        }
        do {
            let rawResult = try await webView.callAsyncJavaScript(
                "return window.webInspectorDOMFrontend?.applySelectionPayload?.(nodeId, pageEpoch, documentScopeID) ?? false",
                arguments: [
                    "nodeId": localID,
                    "pageEpoch": expectedContext.pageEpoch,
                    "documentScopeID": expectedContext.documentScopeID,
                ],
                in: nil,
                contentWorld: .page
            )
            return parseBooleanValue(rawResult) ?? false
        } catch {
            inspectorLogger.error("dispatch selection failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchCompleteChildNodeRequestToFrontend(
        nodeID: Int,
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "completeChildNodeRequest",
                "nodeId": nodeID,
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.completeChildNodeRequest?.(nodeId, pageEpoch, documentScopeID)",
                arguments: [
                    "nodeId": nodeID,
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch child request completion failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchRejectChildNodeRequestToFrontend(
        nodeID: Int,
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "rejectChildNodeRequest",
                "nodeId": nodeID,
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.rejectChildNodeRequest?.(nodeId, pageEpoch, documentScopeID)",
                arguments: [
                    "nodeId": nodeID,
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch child request rejection failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchRetryQueuedChildNodeRequestsToFrontend(
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "retryQueuedChildNodeRequests",
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return true
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.retryQueuedChildNodeRequests?.(pageEpoch, documentScopeID)",
                arguments: [
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch child request retry failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchResetChildNodeRequestsToFrontend(
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "resetChildNodeRequests",
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return true
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.resetChildNodeRequests?.(pageEpoch, documentScopeID)",
                arguments: [
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch child request reset failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchCompleteDocumentRequestToFrontend(
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "completeDocumentRequest",
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.completeDocumentRequest?.(pageEpoch, documentScopeID)",
                arguments: [
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch document request completion failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func dispatchRejectDocumentRequestToFrontend(
        pageEpoch: Int,
        documentScopeID: UInt64
    ) async -> Bool {
#if DEBUG
        if let testFrontendDispatchOverride {
            return await testFrontendDispatchOverride([
                "kind": "rejectDocumentRequest",
                "pageEpoch": pageEpoch,
                "documentScopeID": documentScopeID,
            ])
        }
#endif
        guard let webView else {
            return false
        }
        do {
            try await webView.callAsyncVoidJavaScript(
                "window.webInspectorDOMFrontend?.rejectDocumentRequest?.(pageEpoch, documentScopeID)",
                arguments: [
                    "pageEpoch": pageEpoch,
                    "documentScopeID": documentScopeID,
                ],
                contentWorld: .page
            )
            return true
        } catch {
            inspectorLogger.error("dispatch document request rejection failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func handleDocumentRequestMessage(_ payload: Any) {
        guard let body = payload as? [String: Any] ?? (payload as? NSDictionary as? [String: Any]) else {
            return
        }
        let requestedDepth = parseIntegerValue(body["depth"]) ?? configuration.snapshotDepth
        let mode = DOMDocumentReloadMode(rawValue: body["mode"] as? String ?? "") ?? .fresh
        let expectedPageEpoch = pageEpoch
        let expectedDocumentScopeID = if let requestedDocumentScopeID = parseIntegerValue(body["documentScopeID"]),
                                         requestedDocumentScopeID >= 0 {
            UInt64(requestedDocumentScopeID)
        } else {
            currentDocumentScope.documentScopeID
        }
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            let didRequestDocument = await self.requestDocument(
                depth: requestedDepth,
                mode: mode,
                expectedPageEpoch: expectedPageEpoch,
                expectedDocumentScopeID: expectedDocumentScopeID
            )
            guard didRequestDocument == false else {
                return
            }
            _ = await self.dispatchRejectDocumentRequestToFrontend(
                pageEpoch: expectedPageEpoch,
                documentScopeID: expectedDocumentScopeID
            )
        }
    }

    func handleChildNodeRequestMessage(_ payload: Any) {
        guard let body = payload as? [String: Any] ?? (payload as? NSDictionary as? [String: Any]) else {
            return
        }
        let nodeID = parseIntegerValue(body["nodeId"]) ?? 0
        let depth = parseIntegerValue(body["depth"]) ?? configuration.subtreeDepth
        guard nodeID > 0 else {
            return
        }
        let expectedPageEpoch = pageEpoch
        let requestScope = currentRequestScope
        let requestDocumentScopeID = currentDocumentScope.documentScopeID
        Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            do {
                let payload = try await self.session.captureSubtreePayload(
                    target: .local(UInt64(nodeID)),
                    maxDepth: depth
                )
                guard self.pageEpoch == expectedPageEpoch, self.currentRequestScope === requestScope else {
                    self.setDeferredFrontendChildNodeRetryDrainScope(requestScope)
                    _ = await self.dispatchRejectChildNodeRequestToFrontend(
                        nodeID: nodeID,
                        pageEpoch: expectedPageEpoch,
                        documentScopeID: requestDocumentScopeID
                    )
                    return
                }
                let didDispatch = await self.dispatchSubtreePayloadToFrontend(
                    payload,
                    pageEpoch: expectedPageEpoch,
                    documentScopeID: requestDocumentScopeID,
                    requestScope: requestScope
                )
                if !didDispatch {
                    _ = await self.dispatchCompleteChildNodeRequestToFrontend(
                        nodeID: nodeID,
                        pageEpoch: expectedPageEpoch,
                        documentScopeID: requestDocumentScopeID
                    )
                    return
                }
                guard self.pageEpoch == expectedPageEpoch, self.currentRequestScope === requestScope else {
                    return
                }
                if let delta = self.payloadNormalizer.normalizeBackendResponse(
                    method: "DOM.requestChildNodes",
                    responseObject: ["result": payload],
                    resetDocument: false
                ),
                   case let .replaceSubtree(root) = delta {
                    self.currentDocumentModel.applyMutationBundle(
                        .init(events: [.replaceSubtree(root: root)])
                    )
                }
            } catch {
                inspectorLogger.debug("capture subtree failed: \(error.localizedDescription, privacy: .public)")
                _ = await self.dispatchCompleteChildNodeRequestToFrontend(
                    nodeID: nodeID,
                    pageEpoch: expectedPageEpoch,
                    documentScopeID: requestDocumentScopeID
                )
            }
        }
    }

    func handleHighlightRequestMessage(_ payload: Any) {
        guard let body = payload as? [String: Any] ?? (payload as? NSDictionary as? [String: Any]) else {
            return
        }
        let nodeID = parseIntegerValue(body["nodeId"]) ?? 0
        let reveal = parseBooleanValue(body["reveal"]) ?? true
        guard nodeID > 0 else {
            return
        }
        Task.immediateIfAvailable { [weak self] in
            await self?.session.highlight(nodeId: nodeID, reveal: reveal)
        }
    }

    func handleHideHighlightRequestMessage(_ payload: Any) {
        _ = payload
        Task.immediateIfAvailable { [weak self] in
            await self?.session.hideHighlight()
        }
    }

    func handleRejectedDocumentRequestMessage(pageEpoch: Int?, documentScopeID: UInt64?) {
        guard let pageEpoch, pageEpoch == self.pageEpoch else {
            return
        }
        setDeferredFrontendDocumentRequestDrainScope(currentRequestScope)
        let responseDocumentScopeID = documentScopeID ?? currentDocumentScope.documentScopeID
        Task.immediateIfAvailable { [weak self] in
            _ = await self?.dispatchRejectDocumentRequestToFrontend(
                pageEpoch: pageEpoch,
                documentScopeID: responseDocumentScopeID
            )
        }
    }

    func handleRejectedChildNodeRequestMessage(nodeID: Int?, pageEpoch: Int?, documentScopeID: UInt64?) {
        guard let nodeID, nodeID > 0, let pageEpoch, pageEpoch == self.pageEpoch else {
            return
        }
        setDeferredFrontendChildNodeRetryDrainScope(currentRequestScope)
        let responseDocumentScopeID = documentScopeID ?? currentDocumentScope.documentScopeID
        Task.immediateIfAvailable { [weak self] in
            _ = await self?.dispatchRejectChildNodeRequestToFrontend(
                nodeID: nodeID,
                pageEpoch: pageEpoch,
                documentScopeID: responseDocumentScopeID
            )
        }
    }

    private func applyBundleToCurrentDocumentStore(
        _ payload: Any,
        bundleDocumentScopeID: DOMDocumentScopeID?
    ) -> Bool {
        let incomingDocumentURL = documentURL(from: payload)
        guard let delta = payloadNormalizer.normalizeBundlePayload(payload) else {
            inspectorLogger.notice("[TEMP DOM TRACE][Runtime] applyBundleToCurrentDocumentStore normalizeBundlePayload=nil")
            return true
        }
        switch delta {
        case let .snapshot(snapshot, shouldResetDocument):
            let shouldReplaceCurrentDocument = shouldResetDocument || currentDocumentModel.rootNode == nil
            inspectorLogger.notice("[TEMP DOM TRACE][Runtime] apply delta=snapshot resetDocument=\(shouldResetDocument, privacy: .public) replaceCurrentDocument=\(shouldReplaceCurrentDocument, privacy: .public) advanceScope=false rootLocalID=\(snapshot.root.localID, privacy: .public)")
            if shouldReplaceCurrentDocument {
                payloadNormalizer.resetForDocumentUpdate()
            }
            currentDocumentModel.replaceDocument(
                with: snapshot,
                isFreshDocument: shouldReplaceCurrentDocument
            )
            if let incomingDocumentURL {
                lastSnapshotDocumentURL = incomingDocumentURL
            }
            return !shouldReplaceCurrentDocument
        case let .mutations(bundle):
            inspectorLogger.notice("[TEMP DOM TRACE][Runtime] apply delta=mutations events=\(bundle.events.count, privacy: .public)")
            applyMutationBundleAcrossDocumentUpdates(bundle)
            if bundle.events.contains(where: Self.isStructuralMutationEvent),
               let selectedEntry = currentDocumentModel.selectedNode,
               let target = selectionRequestTarget(for: selectedEntry) {
                startSelectorPathRequest(target: target, selectionEntry: selectedEntry)
            }
            return !bundle.events.contains {
                if case .documentUpdated = $0 {
                    return true
                }
                return false
            }
        case let .replaceSubtree(root):
            inspectorLogger.notice("[TEMP DOM TRACE][Runtime] apply delta=replaceSubtree rootLocalID=\(root.localID, privacy: .public)")
            currentDocumentModel.applyMutationBundle(.init(events: [.replaceSubtree(root: root)]))
            if let selectedEntry = currentDocumentModel.selectedNode,
               let target = selectionRequestTarget(for: selectedEntry) {
                startSelectorPathRequest(target: target, selectionEntry: selectedEntry)
            }
            return true
        case let .selection(selection):
            inspectorLogger.notice("[TEMP DOM TRACE][Runtime] apply delta=selection hasSelection=\(selection != nil, privacy: .public)")
            currentDocumentModel.applySelectionSnapshot(selection)
            return true
        case let .selectorPath(selector):
            inspectorLogger.notice("[TEMP DOM TRACE][Runtime] apply delta=selectorPath localID=\(String(describing: selector.localID), privacy: .public)")
            currentDocumentModel.applySelectorPath(selector)
            return true
        }
    }

    private func documentURLChanged(_ incomingDocumentURL: String?) -> Bool {
        guard let incomingDocumentURL = normalizedDocumentURL(incomingDocumentURL) else {
            return false
        }
        guard let lastSnapshotDocumentURL = normalizedDocumentURL(lastSnapshotDocumentURL) else {
            return true
        }
        return incomingDocumentURL != lastSnapshotDocumentURL
    }

    private func documentURL(from payload: Any) -> String? {
        payloadDictionary(from: payload)?["documentURL"] as? String
    }

    func domDidEmit(bundle: DOMBundle) {
        handleDOMBundle(bundle)
    }

    func handleDOMBundle(_ bundle: DOMBundle) {
        let payloadKind = switch bundle.payload {
        case let .jsonString(rawJSON):
            if let data = rawJSON.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                object["kind"] as? String ?? "raw"
            } else {
                "raw"
            }
        case let .objectEnvelope(object):
            if let dictionary = object as? [String: Any] {
                dictionary["kind"] as? String ?? "object"
            } else if let dictionary = object as? NSDictionary,
                      let swiftDictionary = dictionary as? [String: Any] {
                swiftDictionary["kind"] as? String ?? "object"
            } else {
                "object"
            }
        }
        inspectorLogger.notice(
            "[TEMP DOM TRACE][Runtime] handleDOMBundle kind=\(payloadKind, privacy: .public) bundlePageEpoch=\(String(describing: bundle.pageEpoch), privacy: .public) bundleDocumentScopeID=\(String(describing: bundle.documentScopeID), privacy: .public) currentPageEpoch=\(self.pageEpoch, privacy: .public) currentDocumentScopeID=\(self.currentDocumentScope.documentScopeID, privacy: .public) bootstrapTaskActive=\(self.bootstrapTask != nil, privacy: .public) replacementFence=\(self.hasReplacementFenceForCurrentContext, privacy: .public)"
        )
        if hasReplacementFenceForCurrentContext,
           bundle.pageEpoch == pageEpoch,
           bundle.documentScopeID == currentDocumentScope.documentScopeID
        {
            inspectorLogger.notice("[TEMP DOM TRACE][Runtime] handleDOMBundle deferred: replacement fence")
            deferredDOMBundlesDuringBootstrap.append(.init(bundle: bundle))
            return
        }
        if acceptsDOMBundle(documentScopeID: bundle.documentScopeID) == false,
           adoptAuthoritativeInitialSnapshotContextIfNeeded(from: bundle) {
            inspectorLogger.notice("[TEMP DOM TRACE][Runtime] handleDOMBundle adopted authoritative initial snapshot context")
        }
        guard acceptsDOMBundle(documentScopeID: bundle.documentScopeID) else {
            inspectorLogger.notice("[TEMP DOM TRACE][Runtime] handleDOMBundle ignored: acceptsDOMBundle=false")
            return
        }
        if bootstrapTask != nil {
            inspectorLogger.notice("[TEMP DOM TRACE][Runtime] handleDOMBundle deferred: bootstrap in progress")
            deferredDOMBundlesDuringBootstrap.append(.init(bundle: bundle))
            return
        }
        inspectorLogger.notice("[TEMP DOM TRACE][Runtime] handleDOMBundle applying and enqueueing")
        let preservesInspectorState = applyDOMBundleToCurrentDocumentStore(bundle)
        enqueueMutationPayload(bundle, preservingInspectorState: preservesInspectorState)
    }

    private func applyDeferredDOMBundlesIfNeeded(expectedPageEpoch: Int) {
        guard pageEpoch == expectedPageEpoch else {
            deferredDOMBundlesDuringBootstrap.removeAll(keepingCapacity: true)
            return
        }
        guard !deferredDOMBundlesDuringBootstrap.isEmpty else {
            return
        }
        let bundles = deferredDOMBundlesDuringBootstrap
        deferredDOMBundlesDuringBootstrap.removeAll(keepingCapacity: true)
        // Transition/reset clears this queue, so the remaining entries all belong to the
        // current bootstrap session and must replay in-order even if one bundle replaces the document.
        for entry in bundles {
            guard acceptsDOMBundle(documentScopeID: entry.bundle.documentScopeID) else {
                continue
            }
            let preservesInspectorState = applyDOMBundleToCurrentDocumentStore(entry.bundle)
            enqueueMutationPayload(entry.bundle, preservingInspectorState: preservesInspectorState)
        }
    }

    private func applyDOMBundleToCurrentDocumentStore(_ bundle: DOMBundle) -> Bool {
        switch bundle.payload {
        case let .jsonString(rawJSON):
            return applyBundleToCurrentDocumentStore(
                rawJSON,
                bundleDocumentScopeID: bundle.documentScopeID
            )
        case let .objectEnvelope(object):
            return applyBundleToCurrentDocumentStore(
                object,
                bundleDocumentScopeID: bundle.documentScopeID
            )
        }
    }

    private func adoptAuthoritativeInitialSnapshotContextIfNeeded(from bundle: DOMBundle) -> Bool {
        guard let bundleDocumentScopeID = bundle.documentScopeID,
              let initialSnapshotMetadata = initialSnapshotMetadata(for: bundle),
              initialSnapshotMetadata.shouldAdopt,
              (bundle.pageEpoch ?? pageEpoch) == pageEpoch
        else {
            return false
        }

        nextDocumentScopeID = max(nextDocumentScopeID, bundleDocumentScopeID)
        commitCurrentDocumentScope(
            .init(documentScopeID: bundleDocumentScopeID, requestScope: RequestScope()),
            clearCurrentContents: true
        )
        payloadNormalizer.resetForDocumentUpdate()
        lastSnapshotDocumentURL = initialSnapshotMetadata.documentURL
        return true
    }

    private func initialSnapshotMetadata(
        for bundle: DOMBundle
    ) -> (documentURL: String?, shouldAdopt: Bool)? {
        let payload: Any = switch bundle.payload {
        case let .jsonString(rawJSON):
            rawJSON
        case let .objectEnvelope(object):
            object
        }
        guard let object = payloadDictionary(from: payload),
              (object["kind"] as? String) == "snapshot"
        else {
            return nil
        }
        let snapshotMode = object["snapshotMode"] as? String
        let documentURL = normalizedDocumentURL(object["documentURL"] as? String)
        let shouldAdopt = switch snapshotMode {
        case "fresh":
            true
        case "preserve-ui-state":
            false
        default:
            documentURLChanged(documentURL)
        }
        return (
            documentURL: documentURL,
            shouldAdopt: shouldAdopt
        )
    }

    private func payloadDictionary(from payload: Any) -> [String: Any]? {
        if let object = payload as? [String: Any] {
            return object
        }
        if let object = payload as? NSDictionary {
            return object as? [String: Any]
        }
        if let rawJSON = payload as? String,
           let data = rawJSON.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object
        }
        return nil
    }

    private func normalizedDocumentURL(_ documentURL: String?) -> String? {
        guard let documentURL, !documentURL.isEmpty else {
            return nil
        }
        return documentURL
    }

    func applyReplacementDOMBundleAfterContextAdoption(_ bundle: DOMBundle) -> Bool {
        guard bundle.pageEpoch == pageEpoch,
              bundle.documentScopeID == currentDocumentScope.documentScopeID
        else {
            return false
        }
        let adjustedBundle: DOMBundle
        let appliedSelectionOverride: Bool
        switch bundle.payload {
        case let .jsonString(rawJSON):
            let (adjustedPayload, didApplySelectionOverride) = payloadByApplyingPendingSelectionOverride(rawJSON)
            appliedSelectionOverride = didApplySelectionOverride
            if let adjustedRawJSON = adjustedPayload as? String {
                adjustedBundle = .init(
                    rawJSON: adjustedRawJSON,
                    pageEpoch: bundle.pageEpoch,
                    documentScopeID: bundle.documentScopeID
                )
            } else {
                adjustedBundle = .init(
                    objectEnvelope: adjustedPayload,
                    pageEpoch: bundle.pageEpoch,
                    documentScopeID: bundle.documentScopeID
                )
            }
        case let .objectEnvelope(objectEnvelope):
            let (adjustedPayload, didApplySelectionOverride) = payloadByApplyingPendingSelectionOverride(objectEnvelope)
            appliedSelectionOverride = didApplySelectionOverride
            adjustedBundle = .init(
                objectEnvelope: adjustedPayload,
                pageEpoch: bundle.pageEpoch,
                documentScopeID: bundle.documentScopeID
            )
        }
        let replacementSnapshot: DOMGraphSnapshot?
        switch adjustedBundle.payload {
        case let .jsonString(rawJSON):
            if case let .snapshot(snapshot, _) = payloadNormalizer.normalizeBundlePayload(rawJSON) {
                replacementSnapshot = snapshot
            } else {
                replacementSnapshot = nil
            }
        case let .objectEnvelope(objectEnvelope):
            if case let .snapshot(snapshot, _) = payloadNormalizer.normalizeBundlePayload(objectEnvelope) {
                replacementSnapshot = snapshot
            } else {
                replacementSnapshot = nil
            }
        }
        guard let replacementSnapshot else {
            return false
        }
        let clearsReplacementFence = hasReplacementFenceForCurrentContext
        payloadNormalizer.resetForDocumentUpdate()
        currentDocumentModel.replaceDocument(
            with: replacementSnapshot,
            isFreshDocument: clearsReplacementFence
        )
        if appliedSelectionOverride {
            pendingSelectionOverrideLocalID = nil
        }
        enqueueMutationPayload(adjustedBundle, preservingInspectorState: !clearsReplacementFence)
        clearDocumentReplacementAfterContextAdoptionRequirement()
        if clearsReplacementFence {
            restartSelectionDependentRequestsAfterResync()
        }
        return true
    }

    private func enqueueMutationPayload(_ bundle: DOMBundle, preservingInspectorState: Bool) {
        let adjustedBundle = bundleByUpdatingTransportContext(
            bundle,
            pageEpoch: pageEpoch,
            documentScopeID: currentDocumentScope.documentScopeID
        )
        switch adjustedBundle.payload {
        case let .jsonString(rawJSON):
            enqueueMutationBundle(rawJSON, preservingInspectorState: preservingInspectorState)
        case let .objectEnvelope(object):
            enqueueMutationBundle(object, preservingInspectorState: preservingInspectorState)
        }
    }

    func acceptsFrontendMessage(pageEpoch: Int?, documentScopeID: UInt64?) -> Bool {
        phase.allowsFrontendTraffic
            && !hasReplacementFenceForCurrentContext
            && (pageEpoch ?? 0) == self.pageEpoch
            && (documentScopeID == nil || documentScopeID == currentDocumentScope.documentScopeID)
    }

    func acceptsFrontendInteractionMessage(pageEpoch: Int?, documentScopeID: UInt64?) -> Bool {
        phase.allowsFrontendTraffic
            && (pageEpoch ?? 0) == self.pageEpoch
            && (documentScopeID == nil || documentScopeID == currentDocumentScope.documentScopeID)
    }

    private static func isStructuralMutationEvent(_ event: DOMGraphMutationEvent) -> Bool {
        switch event {
        case .childNodeInserted,
             .childNodeRemoved,
             .childNodeCountUpdated,
             .setChildNodes,
             .replaceSubtree,
             .documentUpdated:
            return true
        case .attributeModified,
             .attributeRemoved,
             .characterDataModified:
            return false
        }
    }

    private func drainDeferredFrontendDocumentRequestIfNeeded() {
        guard let deferredScope = deferredFrontendDocumentRequestDrainScope,
              isReady,
              phase.allowsFrontendTraffic
        else {
            return
        }
        guard deferredScope === currentRequestScope else {
            deferredFrontendDocumentRequestDrainScope = nil
            return
        }
        deferredFrontendDocumentRequestDrainScope = nil
        let pageEpoch = self.pageEpoch
        let documentScopeID = currentDocumentScope.documentScopeID
        Task.immediateIfAvailable { [weak self] in
            _ = await self?.dispatchCompleteDocumentRequestToFrontend(
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID
            )
        }
    }

    private func drainDeferredFrontendChildNodeRetryIfNeeded() {
        guard let deferredScope = deferredFrontendChildNodeRetryDrainScope,
              isReady,
              phase.allowsFrontendTraffic
        else {
            return
        }
        guard deferredScope === currentRequestScope else {
            deferredFrontendChildNodeRetryDrainScope = nil
            return
        }
        deferredFrontendChildNodeRetryDrainScope = nil
        let pageEpoch = self.pageEpoch
        let documentScopeID = currentDocumentScope.documentScopeID
        Task.immediateIfAvailable { [weak self] in
            _ = await self?.dispatchRetryQueuedChildNodeRequestsToFrontend(
                pageEpoch: pageEpoch,
                documentScopeID: documentScopeID
            )
        }
    }

    private func setDeferredFrontendDocumentRequestDrainScope(_ scope: RequestScope) {
        if scope === currentRequestScope {
            deferredFrontendDocumentRequestDrainScope = currentRequestScope
            return
        }
        if deferredFrontendDocumentRequestDrainScope == nil {
            deferredFrontendDocumentRequestDrainScope = scope
        }
    }

    private func setDeferredFrontendChildNodeRetryDrainScope(_ scope: RequestScope) {
        if scope === currentRequestScope {
            deferredFrontendChildNodeRetryDrainScope = currentRequestScope
            return
        }
        if deferredFrontendChildNodeRetryDrainScope == nil {
            deferredFrontendChildNodeRetryDrainScope = scope
        }
    }

    func acceptsDOMBundle(documentScopeID: DOMDocumentScopeID?) -> Bool {
        !phase.isTransitioning
            && !hasReplacementFenceForCurrentContext
            && (documentScopeID == nil || documentScopeID == currentDocumentScope.documentScopeID)
    }

    func acceptsReadyMessage(pageEpoch: Int?, documentScopeID: UInt64?) -> Bool {
        isReadyContextCurrentOrNewer(
            .init(
                pageEpoch: pageEpoch ?? self.pageEpoch,
                documentScopeID: documentScopeID ?? currentDocumentScope.documentScopeID
            )
        )
    }

    func handleReadyMessage(pageEpoch: Int?, documentScopeID: UInt64?) {
        let readyContext = MutationContext(
            pageEpoch: pageEpoch ?? self.pageEpoch,
            documentScopeID: documentScopeID ?? currentDocumentScope.documentScopeID
        )
        guard isReadyContextCurrentOrNewer(readyContext) else {
            return
        }
        guard hasReplacementFenceForCurrentContext == false else {
            if readyContext == currentMutationContext {
                enqueueDeferredReadyMessage(readyContext)
                scheduleBootstrapIfNeeded()
            } else {
                enqueueDeferredReadyMessage(readyContext)
            }
            return
        }
        if readyContext != currentMutationContext {
            enqueueDeferredReadyMessage(readyContext)
            return
        }
        applyReadyState()
    }

    func handleLogMessage(_ payload: Any) {
        if let dictionary = payload as? NSDictionary,
           let logMessage = dictionary["message"] as? String {
            if logMessage.contains("[TEMP DOM TRACE]") {
                inspectorLogger.notice("\(logMessage, privacy: .public)")
            } else {
                inspectorLogger.debug("inspector log: \(logMessage, privacy: .public)")
            }
        } else if let logMessage = payload as? String {
            if logMessage.contains("[TEMP DOM TRACE]") {
                inspectorLogger.notice("\(logMessage, privacy: .public)")
            } else {
                inspectorLogger.debug("inspector log: \(logMessage, privacy: .public)")
            }
        }
    }

    func handleDOMSelectionMessage(_ payload: Any) {
        let previousSelectedSnapshot: (
            entry: DOMNodeModel,
            preview: String,
            path: [String],
            attributes: [DOMAttribute]
        )? = currentDocumentModel.selectedNode.map {
            (
                entry: $0,
                preview: $0.preview,
                path: $0.path,
                attributes: $0.attributes
            )
        }
        applySelectionDelta(payloadNormalizer.normalizeSelectionPayload(payload))
        guard let selected = currentDocumentModel.selectedNode else {
            cancelSelectorPathRequest()
            return
        }

        guard let target = selectionRequestTarget(for: selected) else {
            return
        }

        let didSelectNewNode = previousSelectedSnapshot.map { $0.entry !== selected } ?? true
        let didStyleRelevantSnapshotChange = !didSelectNewNode && (
            previousSelectedSnapshot?.preview != selected.preview
                || previousSelectedSnapshot?.path != selected.path
                || previousSelectedSnapshot?.attributes != selected.attributes
        )
        let shouldRefetchSelectorPath = selected.selectorPath.isEmpty
        if didSelectNewNode || didStyleRelevantSnapshotChange || shouldRefetchSelectorPath {
            startSelectorPathRequest(target: target, selectionEntry: selected)
        }
    }

}

#if DEBUG
extension DOMInspectorRuntime {
    func testAdvanceCurrentDocumentScopeWithoutClearingModel() {
        currentDocumentScope = makeNextDocumentScope()
    }

    func testSetPhaseIdleForCurrentPage() {
        phase = .idle(epoch: pageEpoch)
    }

    var testBundleFlushInterval: TimeInterval {
        mutationPipeline.currentBundleFlushInterval
    }

    var testHasPendingBundleFlushTask: Bool {
        mutationPipeline.hasPendingBundleFlushTask
    }

    var testHasActiveBundleFlushTask: Bool {
        mutationPipeline.hasActiveBundleFlushTask
    }

    func testSetReady(_ ready: Bool) {
        isReady = ready
        updateMutationPipelineReadyState()
        if ready {
            scheduleBootstrapIfNeeded()
        }
    }

    var testMutationFlushOverride: (@MainActor ([[String: Any]]) async -> Void)? {
        get { mutationPipeline.testApplyBundlesOverride }
        set { mutationPipeline.testApplyBundlesOverride = newValue }
    }

    var testBeforeMutationDispatchOverride: (@MainActor () async -> Void)? {
        get { mutationPipeline.testBeforeBundleDispatchOverride }
        set { mutationPipeline.testBeforeBundleDispatchOverride = newValue }
    }

    var testSelectorPathRequestToken: Int {
        selectorPathRequestCount
    }

    var testCompletedMutationGeneration: Int {
        mutationPipeline.completedMutationGeneration
    }

    var testDiscardedMutationGeneration: Int {
        discardedMutationGeneration
    }

    var testPendingSelectionOverrideLocalID: UInt64? {
        pendingSelectionOverrideLocalID
    }

    func testHandleDOMSelectionMessage(_ payload: Any) {
        handleDOMSelectionMessage(payload)
    }

    func testWaitForReconcileForTesting() async {
        await bootstrapTask?.value
        _ = await mutationPipeline.flushPendingBundlesNow()
        await selectorPathTask?.value
        _ = await mutationPipeline.flushPendingBundlesNow()
    }

    func testResetInspectorStateForTesting() {
        resetInspectorState()
    }

    func testSyncCurrentDocumentScopeIDIfNeeded() async -> Bool {
        await syncCurrentDocumentScopeIDIfNeeded(
            documentScopeID: currentDocumentScope.documentScopeID,
            pageEpoch: pageEpoch
        )
    }

    func testWaitForBootstrapForTesting() async {
        await bootstrapTask?.value
    }

    @discardableResult
    func testFlushPendingMutationBundlesNowForTesting() async -> DOMMutationSender.FlushSettlement? {
        await mutationPipeline.flushPendingBundlesNow()
    }

    func testBundleForFrontend(_ bundle: DOMBundle) -> DOMBundle {
        bundleByUpdatingTransportContext(
            bundle,
            pageEpoch: pageEpoch,
            documentScopeID: currentDocumentScope.documentScopeID
        )
    }
}
#endif
