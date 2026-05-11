import Foundation
import OSLog
import Observation
import ObjectiveC
import WebKit
import WebInspectorEngine
import WebInspectorTransport

#if canImport(UIKit)
import UIKit
#endif

private let domViewLogger = Logger(subsystem: "WebInspectorKit", category: "WIDOMInspector")
private let domDeleteUndoHistoryLimit = 128
nonisolated(unsafe) private let pageWebViewLifetimeObserverAssociationKey = unsafe malloc(1)!

private enum WIDOMConsoleDiagnostics {
    private static let milestoneMessages: Set<String> = [
        "beginFreshContext requested",
        "beginSelectionMode using native inspector backend",
        "beginSelectionMode enabled protocol inspect mode for native inspector backend",
        "requestSelectionModeToggle enabled inspect mode",
        "beginSelectionMode armed inspect selection",
        "applyPendingInspectSelectionIfPossible resolved transport node",
        "applySelection updated document",
    ]

    static let verboseConsoleDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["WEBSPECTOR_VERBOSE_CONSOLE_LOGS"] == "1"

    static func shouldEmitSelectionDiagnostic(
        message: String,
        level: OSLogType,
        verboseConsoleDiagnostics: Bool = verboseConsoleDiagnosticsEnabled
    ) -> Bool {
        if verboseConsoleDiagnostics {
            return true
        }

        switch level {
        case .error, .fault:
            return true
        case .debug:
            return false
        default:
            return milestoneMessages.contains(message)
        }
    }
}

@MainActor
private final class WIPageWebViewLifetimeObserver {
    private let onDeinit: @MainActor () -> Void

    init(onDeinit: @escaping @MainActor () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        let onDeinit = self.onDeinit
        Task { @MainActor in
            onDeinit()
        }
    }
}

@MainActor
@Observable
public final class WIDOMInspector {
    private enum Phase: Equatable {
        case idle
        case loadingDocument(DOMContext, targetIdentifier: String?)
        case ready(DOMContext, targetIdentifier: String)

        var context: DOMContext? {
            switch self {
            case .idle:
                nil
            case let .loadingDocument(context, _),
                 let .ready(context, _):
                context
            }
        }

        func matches(_ contextID: DOMContextID?) -> Bool {
            guard let contextID else {
                return false
            }
            return context?.contextID == contextID
        }

        var targetIdentifier: String? {
            switch self {
            case .idle:
                return nil
            case let .loadingDocument(_, targetIdentifier):
                return targetIdentifier
            case let .ready(_, targetIdentifier):
                return targetIdentifier
            }
        }
    }

#if DEBUG
    package enum FreshContextDiagnosticEvent: Equatable, Sendable {
        case clearContextState(reason: String)
        case beginFreshContext(reason: String, isFreshDocument: Bool)
    }

    package enum InspectSelectionDiagnosticEvent: Equatable, Sendable {
        case armed(contextID: DOMContextID, targetIdentifier: String, generation: UInt64)
        case ignoredStaleEvent(
            reason: String,
            eventContextID: DOMContextID?,
            eventTargetIdentifier: String?,
            armContextID: DOMContextID?,
            armTargetIdentifier: String?,
            generation: UInt64?
        )
        case resolutionFailed(contextID: DOMContextID?, generation: UInt64?)
        case nativeNodeSearch(enabled: Bool, contextID: DOMContextID?, succeeded: Bool, summary: String?)
    }
#endif

    fileprivate struct DeleteUndoState {
        let nodeID: Int
        let nodeLocalID: UInt64?
        let contextID: DOMContextID
        let targetIdentifier: String
    }

    private struct DeferredLoadingMutationState {
        let contextID: DOMContextID
        let targetIdentifier: String
        var sawMutation = false
        var performedFollowUpRefresh = false
    }

    private struct SelectionTransaction: Equatable {
        let contextID: DOMContextID
        let generation: UInt64
    }

    package enum InspectModeControlBackend: String {
        case nativeInspector = "native-inspector"
        case transportProtocol = "transport-protocol"
    }

    private enum SelectionMaterializationStrategy: String {
        case frameRelated = "frame-related"
        case genericIncomplete = "generic-incomplete"
        case nestedDocumentRoots = "nested-document-roots"
        case body = "body"
        case html = "html"
        case structuredChild = "structured-child"
        case root = "root"
        case none = "none"
    }

    @MainActor
    private struct SelectionMaterializationPlan {
        // WebKit materializes iframe contentDocument when serializing the frame owner payload,
        // not when requestChildNodes is sent to the owner element itself. Keep request candidates
        // limited to document/canonical nodes and reserve frame owners for fallback selection only.
        let strategy: SelectionMaterializationStrategy
        let candidates: [DOMNodeModel]
        let frameOwnerCandidates: [DOMNodeModel]
        let frameDocumentCandidates: [DOMNodeModel]
        let canonicalEmbeddedCandidates: [DOMNodeModel]
        let genericIncompleteCandidates: [DOMNodeModel]

        var candidateNodeIDs: Set<DOMNodeModel.ID> {
            Set(candidates.map(\.id))
        }
    }

    private enum PendingInspectMaterializationOutcome {
        case requested
        case waitingForMutation
        case exhausted
    }

    private struct InspectSelectionArm: Equatable {
        let contextID: DOMContextID
        let targetIdentifier: String
        let generation: UInt64
    }

    private struct PendingInspectSelection: Equatable {
        let nodeID: Int
        let contextID: DOMContextID
        let selectorPath: String?
        let resolutionTargetIdentifier: String
        let transaction: SelectionTransaction?
        var scopedMaterializationRootNodeIDs: [DOMNodeModel.ID] = []
        var materializedAncestorNodeIDs: Set<DOMNodeModel.ID> = []
        var outstandingMaterializationNodeIDs: Set<DOMNodeModel.ID> = []
        var activeMaterializationStrategy: SelectionMaterializationStrategy = .none
        var activeRequestGeneration: UInt64 = 0
        var genericDispatchDeferralCount: UInt64 = 0
        var observedMaterializationStrategy: SelectionMaterializationStrategy = .none
        var observedMaterializationCandidateNodeIDs: Set<DOMNodeModel.ID> = []
        var observedDocumentBackedFrameIDs: Set<String> = []
        var lastExhaustedScopedCandidateNodeIDs: Set<DOMNodeModel.ID> = []
        var lastExhaustedScopedStrategy: SelectionMaterializationStrategy?
        var progressRevision: UInt64 = 0
    }

    private struct InspectorInspectNodeResolution {
        let nodeID: Int
        let targetIdentifier: String
        let attemptedTargetIdentifiers: [String]
    }

    private struct PendingChildRequestKey: Hashable {
        let nodeID: Int
        let contextID: DOMContextID
    }

    @MainActor
    private final class PendingChildRequestRecord {
        let key: PendingChildRequestKey
        private(set) var reportsToFrontend: Bool

        private var result: Bool?
        private var waiters: [CheckedContinuation<Bool, Never>] = []
        private var timeoutTask: Task<Void, Never>?

        init(key: PendingChildRequestKey, reportsToFrontend: Bool) {
            self.key = key
            self.reportsToFrontend = reportsToFrontend
        }

        func upgradeToFrontendRequest() -> Bool {
            guard reportsToFrontend == false, result == nil else {
                return false
            }
            reportsToFrontend = true
            return true
        }

        func wait(
            timeout: Duration,
            onTimeout: @escaping @MainActor () async -> Void
        ) async -> Bool {
            if let result {
                return result
            }

            if timeoutTask == nil {
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await ContinuousClock().sleep(for: timeout)
                    } catch {
                        return
                    }

                    guard let self, self.result == nil else {
                        return
                    }
                    await onTimeout()
                }
            }

            return await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    waiters.append(continuation)
                }
            }
        }

        func finish(_ result: Bool) {
            guard self.result == nil else {
                return
            }

            self.result = result
            timeoutTask?.cancel()
            timeoutTask = nil

            let waiters = self.waiters
            self.waiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume(returning: result)
            }
        }
    }

    @ObservationIgnored package let dependencies: WIInspectorDependencies
    @ObservationIgnored private let sharedTransport: WISharedInspectorTransport
    @ObservationIgnored private let payloadNormalizer = DOMPayloadNormalizer()

    public let document: DOMDocumentModel
    public private(set) var isSelectingElement = false
    public private(set) var hasPageWebView = false
    package private(set) var isPageReadyForSelection = false

    @ObservationIgnored private var configuration: DOMConfiguration
    @ObservationIgnored package weak var pageWebView: WKWebView?
    @ObservationIgnored private var phase: Phase = .idle
    @ObservationIgnored private var currentContext: DOMContext?
    @ObservationIgnored private var nextContextID: DOMContextID = 1
    @ObservationIgnored private var documentURL: String?
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapGeneration: UInt64 = 0
    @ObservationIgnored private var externalRecoverableErrorHandler: (@MainActor (String?) -> Void)?
    @ObservationIgnored private var inspectModeTargetIdentifier: String?
    @ObservationIgnored package var inspectModeControlBackend: InspectModeControlBackend?
    @ObservationIgnored private var inspectSelectionArm: InspectSelectionArm?
    @ObservationIgnored private weak var deleteUndoManager: UndoManager?
    @ObservationIgnored private var pendingChildRequests: [PendingChildRequestKey: PendingChildRequestRecord] = [:]
    @ObservationIgnored private var lastSelectionDiagnosticMessage: String?
    @ObservationIgnored private var lastEmittedSelectionDiagnosticMessage: String?
    @ObservationIgnored private var selectionGeneration: UInt64 = 0
    @ObservationIgnored private var selectionActivationGeneration: UInt64 = 0
    @ObservationIgnored private var acceptsInspectEvents = false
    @ObservationIgnored private var pendingInspectSelection: PendingInspectSelection?
    @ObservationIgnored private var pendingInspectMaterializationTimeoutTask: Task<Void, Never>?
    @ObservationIgnored var pointerDisconnectObserver: NSObjectProtocol?
    @ObservationIgnored private var pageWebViewAttachmentGeneration: UInt64 = 0
    @ObservationIgnored private var isDOMTransportAttached = false
    @ObservationIgnored private var deferredLoadingMutationState: DeferredLoadingMutationState?
#if DEBUG
    @ObservationIgnored package private(set) var freshContextDiagnosticsForTesting: [FreshContextDiagnosticEvent] = []
    @ObservationIgnored package private(set) var inspectSelectionDiagnosticsForTesting: [InspectSelectionDiagnosticEvent] = []
#endif

#if canImport(UIKit)
    @ObservationIgnored package weak var sceneActivationRequestingScene: UIScene?
    @ObservationIgnored package var nativeInspectorSelectionToggleNeedsDeactivation = false
    @ObservationIgnored package var nativeInspectorNodeSearchNeedsDirectDeactivation = false
    @ObservationIgnored package var nativeInspectorProtocolInspectModeNeedsDeactivation = false
#endif

    public convenience init(
        configuration: DOMConfiguration = .init(),
        dependencies: WIInspectorDependencies = .liveValue,
        onRecoverableError: (@MainActor (String?) -> Void)? = nil
    ) {
        self.init(
            configuration: configuration,
            dependencies: dependencies,
            sharedTransport: dependencies.makeSharedTransport(),
            onRecoverableError: onRecoverableError
        )
    }

    package init(
        configuration: DOMConfiguration = .init(),
        dependencies: WIInspectorDependencies = .liveValue,
        sharedTransport: WISharedInspectorTransport,
        onRecoverableError: (@MainActor (String?) -> Void)? = nil
    ) {
        self.dependencies = dependencies
        self.configuration = configuration
        self.sharedTransport = sharedTransport
        self.document = DOMDocumentModel()
        self.externalRecoverableErrorHandler = onRecoverableError

        self.sharedTransport.setEventHandler({ [weak self] envelope in
            await self?.handleTransportEvent(envelope)
        }, for: .dom)
    }

    isolated deinit {
        bootstrapTask?.cancel()
    }
    package func setRecoverableErrorHandler(_ handler: (@MainActor (String?) -> Void)?) {
        externalRecoverableErrorHandler = handler
    }

    package func attach(to webView: WKWebView) async {
#if canImport(UIKit)
        installPointerDisconnectObserverIfNeeded()
#endif
        let previousPageWebView = pageWebView
        logSelectionDiagnostics(
            "attach requested",
            extra: "incomingWebView=\(webViewSummary(webView)) currentWebView=\(webViewSummary(previousPageWebView)) sameWebView=\(previousPageWebView === webView) currentContext=\(currentContext.map { String($0.contextID) } ?? "nil")"
        )
        if pageWebView === webView, currentContext != nil {
            installPageWebViewLifetimeObserver(on: webView)
            setDOMTransportAttached(false)
            await sharedTransport.attach(client: .dom, to: webView)
            setDOMTransportAttached(await sharedTransport.attachedSession() != nil)
            logSelectionDiagnostics(
                "attach sameWebView transport result",
                extra: "transportAttached=\(isDOMTransportAttached) observedTarget=\(sharedTransport.currentObservedPageTargetIdentifier() ?? "nil") pageTarget=\(sharedTransport.currentPageTargetIdentifier() ?? "nil")"
            )
            guard isDOMTransportAttached else {
                cancelBootstrap()
                clearContextState(reason: "attach.transportUnavailable.sameWebView")
                return
            }
            ensureDocumentLoadIsActive(reason: "attach.sameWebView")
            return
        }

        await resetInteractionState()
        let isSwitchingAttachedPage = pageWebView !== webView
        if isSwitchingAttachedPage {
            logSelectionDiagnostics(
                "attach switching pageWebView",
                extra: "from=\(webViewSummary(previousPageWebView)) to=\(webViewSummary(webView))"
            )
        }
        setPageWebView(webView)
        installPageWebViewLifetimeObserver(on: webView)
        setDOMTransportAttached(false)
        await sharedTransport.attach(client: .dom, to: webView)
        setDOMTransportAttached(await sharedTransport.attachedSession() != nil)
        logSelectionDiagnostics(
            "attach newWebView transport result",
            extra: "transportAttached=\(isDOMTransportAttached) observedTarget=\(sharedTransport.currentObservedPageTargetIdentifier() ?? "nil") pageTarget=\(sharedTransport.currentPageTargetIdentifier() ?? "nil")"
        )
        guard isDOMTransportAttached else {
            if isSwitchingAttachedPage {
                cancelBootstrap()
                clearContextState(reason: "attach.transportUnavailable.newWebView")
            }
            return
        }
        let targetIdentifier = sharedTransport.currentObservedPageTargetIdentifier()
            ?? sharedTransport.currentPageTargetIdentifier()
        await beginFreshContext(
            documentURL: normalizedDocumentURL(webView.url?.absoluteString),
            targetIdentifier: targetIdentifier,
            loadImmediately: targetIdentifier != nil,
            isFreshDocument: true,
            reason: "attach.newWebView"
        )
    }

    package func suspend() async {
        logSelectionDiagnostics(
            "suspend requested",
            extra: "pageWebView=\(webViewSummary(pageWebView)) transportAttached=\(isDOMTransportAttached)"
        )
        await resetInteractionState()
        try? await hideHighlight()
        await sharedTransport.suspend(client: .dom)
        setDOMTransportAttached(false)
#if canImport(UIKit)
        removePointerDisconnectObserver()
#endif
        setPageWebView(nil)
        cancelBootstrap()
        clearContextState(reason: "suspend")
    }

    package func detach() async {
        logSelectionDiagnostics(
            "detach requested",
            extra: "pageWebView=\(webViewSummary(pageWebView)) transportAttached=\(isDOMTransportAttached)"
        )
        await resetInteractionState()
        try? await hideHighlight()
        await sharedTransport.detach(client: .dom)
        setDOMTransportAttached(false)
#if canImport(UIKit)
        removePointerDisconnectObserver()
#endif
        setPageWebView(nil)
        cancelBootstrap()
        clearContextState(reason: "detach")
    }

    public func reloadPage() async throws {
        let webView = try requirePageWebView()
        await resetInteractionState()
        await beginFreshContext(
            documentURL: normalizedDocumentURL(webView.url?.absoluteString),
            targetIdentifier: nil,
            loadImmediately: false,
            isFreshDocument: true,
            reason: "reloadPage"
        )
        webView.reload()
    }

    public func reloadDocument() async throws {
        try await reloadDocument(isFreshDocument: true)
    }

    private func reloadDocument(isFreshDocument: Bool) async throws {
        _ = try requirePageWebView()
        await resetInteractionState()
        let targetIdentifier = try requireCurrentTargetIdentifier()
        await beginFreshContext(
            documentURL: normalizedDocumentURL(pageWebView?.url?.absoluteString),
            targetIdentifier: targetIdentifier,
            loadImmediately: true,
            isFreshDocument: isFreshDocument,
            reason: "reloadDocument"
        )
    }

    public func cancelSelectionMode() async {
        guard isSelectingElement else {
            return
        }
        await cancelInspectMode(
            targetIdentifier: inspectModeTargetIdentifier ?? phase.targetIdentifier,
            invalidatePendingSelection: true,
            restoreSelectedHighlight: true
        )
    }

    package func selectionLifecycleStateMatches(
        contextID: DOMContextID,
        targetIdentifier: String
    ) -> Bool {
        guard case let .ready(context, currentTargetIdentifier) = phase else {
            return false
        }
        return context.contextID == contextID
            && currentTargetIdentifier == targetIdentifier
            && currentContext?.contextID == contextID
    }

    public func beginSelectionMode() async throws {
        let _ = try requirePageWebView()
        await awaitTransportMessagesToDrain()
        try await refreshReadyContextIfTransportTargetAdvanced(reason: "beginSelectionMode")
        await cancelStaleInspectModeBeforeBeginningSelectionIfNeeded()
        applyRecoverableError(nil)
        let selectedContextID = currentContext?.contextID
        let hadSelectedNode = document.selectedNode != nil
        var selectionActivation: (
            generation: UInt64,
            contextID: DOMContextID,
            targetIdentifier: String
        )?

        do {
            let initialState = try requireReadySelectionState()
            let activationGeneration = beginSelectionActivation(
                contextID: initialState.context.contextID,
                targetIdentifier: initialState.targetIdentifier
            )
            selectionActivation = (
                generation: activationGeneration,
                contextID: initialState.context.contextID,
                targetIdentifier: initialState.targetIdentifier
            )
            activatePageWindowForSelectionIfPossible()
#if canImport(UIKit)
            try await requestPageWindowActivationIfNeeded()
            await awaitInspectModeInactive()
#endif

            guard selectionActivationIsCurrent(
                generation: activationGeneration,
                contextID: initialState.context.contextID,
                targetIdentifier: initialState.targetIdentifier
            ) else {
                throw DOMOperationError.contextInvalidated
            }
            let readyState = try requireReadySelectionState()
            guard readyState.context.contextID == initialState.context.contextID,
                  readyState.targetIdentifier == initialState.targetIdentifier else {
                throw DOMOperationError.contextInvalidated
            }
            let context = readyState.context
            let targetIdentifier = readyState.targetIdentifier
#if canImport(UIKit)
            let inspectModeControlBackend = try await enableInspectorSelectionMode(
                hadSelectedNode: hadSelectedNode,
                contextID: context.contextID,
                targetIdentifier: targetIdentifier
            )
#else
            if hadSelectedNode {
                try? await hideHighlight()
            }
            try await setInspectModeEnabled(true, targetIdentifier: targetIdentifier)
            let inspectModeControlBackend = InspectModeControlBackend.transportProtocol
#endif
            guard selectionActivationIsCurrent(
                generation: activationGeneration,
                contextID: context.contextID,
                targetIdentifier: targetIdentifier
            ) else {
#if canImport(UIKit)
                await disableInspectorSelectionModeIfNeeded(
                    targetIdentifier: targetIdentifier,
                    backend: inspectModeControlBackend
                )
#else
                try? await setInspectModeEnabled(false, targetIdentifier: targetIdentifier)
#endif
                clearInspectModeState(
                    invalidatePendingSelection: true,
                    clearSelectionArm: true
                )
                throw DOMOperationError.contextInvalidated
            }
            beginInspectMode(
                contextID: context.contextID,
                targetIdentifier: targetIdentifier,
                backend: inspectModeControlBackend
            )
        } catch {
            if let selectionActivation,
               selectionActivationGeneration == selectionActivation.generation {
                clearInspectModeState(
                    invalidatePendingSelection: true,
                    clearSelectionArm: true
                )
            }
            if hadSelectedNode, let selectedContextID {
                await syncSelectedNodeHighlight(contextID: selectedContextID)
            }
            throw error
        }
    }

    package func hideHighlightForInspectorLifecycle() async throws {
        try await hideHighlight()
    }

    package func setProtocolInspectModeEnabledForInspectorLifecycle(
        _ enabled: Bool,
        targetIdentifier: String
    ) async throws {
        try await setInspectModeEnabled(enabled, targetIdentifier: targetIdentifier)
    }

    package func logInspectorLifecycleDiagnostics(
        _ message: String,
        extra: String? = nil,
        level: OSLogType = .default
    ) {
        logSelectionDiagnostics(message, extra: extra, level: level)
    }

    private func setPageWebView(_ webView: WKWebView?) {
        pageWebView = webView
        hasPageWebView = webView != nil
        updateSelectionAvailability()
    }

    private func setDOMTransportAttached(_ isAttached: Bool) {
        isDOMTransportAttached = isAttached
        updateSelectionAvailability()
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        updateSelectionAvailability()
    }

    private func updateSelectionAvailability() {
        let isReadyPhase: Bool
        if case .ready = phase {
            isReadyPhase = true
        } else {
            isReadyPhase = false
        }
        isPageReadyForSelection =
            hasPageWebView
            && isDOMTransportAttached
            && currentContext != nil
            && phase.targetIdentifier != nil
            && isReadyPhase
    }

    package func requestSelectionModeToggle() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if self.isSelectingElement {
                self.logSelectionDiagnostics("requestSelectionModeToggle cancelling inspect mode")
                await self.cancelSelectionMode()
            } else {
                self.logSelectionDiagnostics("requestSelectionModeToggle enabling inspect mode")
                do {
                    try await self.beginSelectionMode()
                    self.logSelectionDiagnostics("requestSelectionModeToggle enabled inspect mode")
                } catch {
                    let nativeState: String
#if canImport(UIKit)
                    nativeState = self.nativeInspectorInteractionStateSummaryForDiagnostics() ?? "nil"
#else
                    nativeState = "n/a"
#endif
                    self.logSelectionDiagnostics(
                        "requestSelectionModeToggle failed to enable inspect mode",
                        extra: "\(error.localizedDescription) nativeState=\(nativeState)",
                        level: .error
                    )
                }
            }
        }
    }

    package func tearDownForDeinit() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
#if canImport(UIKit)
        removePointerDisconnectObserver()
#endif
        pageWebView = nil
        hasPageWebView = false
        isPageReadyForSelection = false
        isDOMTransportAttached = false
        currentContext = nil
        setPhase(.idle)
        inspectSelectionArm = nil
        cancelPendingChildRequestRecords()
        document.clearDocument(isFreshDocument: true)
        clearDeleteUndoHistory()
        Task { @MainActor [sharedTransport] in
            await sharedTransport.detach(client: .dom)
        }
    }

    @_spi(Monocly) public func currentDocumentURLForDiagnostics() -> String? {
        currentContext?.documentURL
    }

    @_spi(Monocly) public func currentContextIDForDiagnostics() -> DOMContextID? {
        currentContext?.contextID
    }

    @_spi(Monocly) public func currentSelectedNodePreviewForDiagnostics() -> String? {
        guard let selectedNode = document.selectedNode else {
            return nil
        }
        return selectionPreview(for: selectedNode)
    }

    @_spi(Monocly) public func currentSelectedNodeSelectorForDiagnostics() -> String? {
        document.selectedNode?.selectorPath.nilIfEmpty
    }

    @_spi(Monocly) public func currentSelectedNodeLineageForDiagnostics() -> String? {
        guard let selectedNode = document.selectedNode else {
            return nil
        }
        return selectionPathLabels(for: selectedNode).joined(separator: " > ")
    }

    @_spi(Monocly) public func visibleNodeSummariesForDiagnostics(limit: Int = 12) -> [String] {
        selectionVisibleNodeSummaries(limit: limit)
    }

    @_spi(Monocly) public func lastSelectionDiagnosticForDiagnostics() -> String? {
        lastSelectionDiagnosticMessage
    }

#if DEBUG
    package func resetFreshContextDiagnosticsForTesting() {
        freshContextDiagnosticsForTesting.removeAll(keepingCapacity: false)
    }

    package func resetInspectSelectionDiagnosticsForTesting() {
        inspectSelectionDiagnosticsForTesting.removeAll(keepingCapacity: false)
    }

    package static func shouldEmitSelectionDiagnosticToConsoleForTesting(
        _ message: String,
        level: OSLogType,
        verboseConsoleDiagnostics: Bool
    ) -> Bool {
        WIDOMConsoleDiagnostics.shouldEmitSelectionDiagnostic(
            message: message,
            level: level,
            verboseConsoleDiagnostics: verboseConsoleDiagnostics
        )
    }
#endif

#if canImport(UIKit)
    @_spi(Monocly) public func nativeInspectorInteractionStateForDiagnostics() -> String? {
        nativeInspectorInteractionStateSummaryForDiagnostics()
    }
#endif

#if DEBUG
    func setSelectionModeActiveForTesting(_ active: Bool) {
        if active {
            beginInspectMode(
                contextID: currentContext?.contextID ?? 0,
                targetIdentifier: "testing",
                backend: .transportProtocol
            )
        } else {
            clearInspectModeState()
        }
    }
#endif

    @_spi(Monocly) public func selectNodeForTesting(cssSelector: String) async throws {
        guard !cssSelector.isEmpty else {
            logSelectionDiagnostics(
                "selectNodeForTesting rejected empty selector",
                level: .error
            )
            await clearSelectionForFailedResolution(
                contextID: currentContext?.contextID,
                showError: true,
                errorMessage: "Failed to resolve selected element."
            )
            throw DOMOperationError.invalidSelection
        }
        guard case let .ready(context, targetIdentifier) = phase,
              let rootNode = document.rootNode else {
            logSelectionDiagnostics(
                "selectNodeForTesting rejected because inspector is not ready",
                selector: cssSelector,
                level: .error
            )
            throw DOMOperationError.contextInvalidated
        }

        logSelectionDiagnostics(
            "selectNodeForTesting started",
            selector: cssSelector,
            extra: "target=\(targetIdentifier) rootTransportNode=\((try? transportNodeID(for: rootNode)) ?? -1)"
        )

        if let nodeID = try await resolveTransportNodeIDForTestingSelector(
            cssSelector,
            contextID: context.contextID,
            targetIdentifier: targetIdentifier,
            rootNode: rootNode
        ) {
            try await applyInspectedNode(
                nodeID: nodeID,
                contextID: context.contextID,
                selectorPath: cssSelector,
                targetIdentifier: targetIdentifier,
                transaction: nil,
                showErrorOnFailure: true,
                allowMaterialization: true
            )
            return
        }

        logSelectionDiagnostics(
            "selectNodeForTesting failed to resolve selector",
            selector: cssSelector,
            extra: "visibleNodes=\(selectionVisibleNodeSummaries(limit: 12).joined(separator: " | "))",
            level: .error
        )
        await clearSelectionForFailedResolution(
            contextID: context.contextID,
            showError: true,
            errorMessage: "Failed to resolve selected element."
        )
        throw DOMOperationError.invalidSelection
    }

    @_spi(Monocly) public func selectNodeForTesting(
        preview: String,
        selectorPath: String? = nil
    ) async throws {
        guard case let .ready(context, targetIdentifier) = phase,
              let rootNode = document.rootNode else {
            throw DOMOperationError.contextInvalidated
        }

        if let node = resolveTestingPreviewNode(preview) {
            await applySelection(
                to: node,
                selectorPath: selectorPath,
                contextID: context.contextID
            )
            applyRecoverableError(nil)
            return
        }

        _ = try? await refreshCurrentDocumentFromTransport(
            contextID: context.contextID,
            targetIdentifier: targetIdentifier,
            depth: max(configuration.snapshotDepth, 128),
            isFreshDocument: false
        )

        _ = await requestTestingChildNodesAndWaitForCompletion(
            transportNodeID: (try? transportNodeID(for: rootNode)) ?? Int(rootNode.id.localID),
            frontendNodeID: Int(rootNode.id.localID),
            targetIdentifier: targetIdentifier,
            contextID: context.contextID,
            depth: max(configuration.snapshotDepth, 128)
        )

        if let node = resolveTestingPreviewNode(preview) {
            await applySelection(
                to: node,
                selectorPath: selectorPath,
                contextID: context.contextID
            )
            applyRecoverableError(nil)
            return
        }

        await clearSelectionForFailedResolution(
            contextID: context.contextID,
            showError: true,
            errorMessage: "Failed to resolve selected element."
        )
        throw DOMOperationError.invalidSelection
    }

    public func copySelectedHTML() async throws -> String {
        try await copySelectionImpl(.html)
    }

    public func copySelectedSelectorPath() async throws -> String {
        try await copySelectionImpl(.selectorPath)
    }

    public func copySelectedXPath() async throws -> String {
        try await copySelectionImpl(.xpath)
    }

    package func copyNode(nodeID: DOMNodeModel.ID, kind: DOMSelectionCopyKind) async throws -> String {
        guard let node = document.node(id: nodeID) else {
            throw DOMOperationError.invalidSelection
        }
        return try await copyText(for: node, kind: kind)
    }

    package func copyNode(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        if let node = nodeForBackendAction(backendNodeID: nodeId) {
            return try await copyText(for: node, kind: kind)
        }
        if kind == .html {
            let response = try await sendDOMCommand(
                WITransportMethod.DOM.getOuterHTML,
                targetIdentifier: try requireCurrentTargetIdentifier(),
                parameters: DOMNodeIdentifierParameters(nodeId: nodeId)
            )
            return stringValue(response["outerHTML"]) ?? ""
        }
        let context = try requireCurrentContext()
        let targetIdentifier = try requireCurrentTargetIdentifier()
        try await refreshCurrentDocumentFromTransport(
            contextID: context.contextID,
            targetIdentifier: targetIdentifier,
            depth: configuration.snapshotDepth,
            isFreshDocument: false
        )
        if let node = nodeForBackendAction(backendNodeID: nodeId) {
            return try await copyText(for: node, kind: kind)
        }
        return ""
    }

    public func deleteSelection() async throws {
        try await performDeleteSelection(undoManager: nil)
    }

    public func deleteSelection(undoManager: UndoManager?) async throws {
        try await performDeleteSelection(undoManager: undoManager)
    }
    
    private func performDeleteSelection(undoManager: UndoManager?) async throws {
        guard let nodeID = document.selectedNode?.id else {
            throw DOMOperationError.invalidSelection
        }
        try await deleteNode(nodeID: nodeID, undoManager: undoManager)
    }

    public func deleteNode(nodeID: DOMNodeModel.ID?, undoManager: UndoManager?) async throws {
        try await performDeleteNode(nodeID: nodeID, undoManager: undoManager)
    }

    private func performDeleteNode(nodeID: DOMNodeModel.ID?, undoManager: UndoManager?) async throws {
        guard let nodeID,
              let node = document.node(id: nodeID) else {
            throw DOMOperationError.invalidSelection
        }
        try await deleteNode(
            nodeID: try transportNodeID(for: node),
            nodeLocalID: node.localID,
            undoManager: undoManager
        )
    }

    public func deleteNode(nodeId: Int?, undoManager: UndoManager?) async throws {
        try await performDeleteNode(nodeId: nodeId, undoManager: undoManager)
    }

    private func performDeleteNode(nodeId: Int?, undoManager: UndoManager?) async throws {
        guard let nodeId else {
            throw DOMOperationError.invalidSelection
        }
        if let node = nodeForBackendAction(backendNodeID: nodeId) {
            try await deleteNode(nodeID: node.id, undoManager: undoManager)
            return
        }
        try await deleteNode(nodeID: nodeId, nodeLocalID: nil, undoManager: undoManager)
    }

    package func selectNode(_ node: DOMNodeModel) async {
        guard document.contains(node) else {
            return
        }

        if let contextID = currentContext?.contextID {
            await applySelection(
                to: node,
                selectorPath: node.selectorPath.nilIfEmpty,
                contextID: contextID
            )
        } else {
            document.applySelectionSnapshot(selectionPayload(for: node))
        }
    }

    package func requestChildNodes(for node: DOMNodeModel, depth: Int) async {
        guard document.contains(node),
              node.hasUnloadedRegularChildren,
              node.localID <= UInt64(Int.max),
              let context = currentContext,
              let targetIdentifier = phase.targetIdentifier ?? sharedTransport.currentPageTargetIdentifier()
        else {
            return
        }

        _ = await requestChildNodesAndWaitForCompletion(
            transportNodeID: (try? transportNodeID(for: node)) ?? Int(node.localID),
            frontendNodeID: Int(node.localID),
            targetIdentifier: targetIdentifier,
            contextID: context.contextID,
            depth: depth
        )
    }

    package func highlightNode(_ node: DOMNodeModel, reveal: Bool) async {
        guard document.contains(node),
              node.localID <= UInt64(Int.max)
        else {
            return
        }

        try? await highlightNode(Int(node.localID), reveal: reveal)
    }

    package func hideNodeHighlight() async {
        try? await hideHighlight()
    }

    public func setAttribute(
        nodeID: DOMNodeModel.ID,
        name: String,
        value: String
    ) async throws {
        guard let node = document.node(id: nodeID) else {
            throw DOMOperationError.invalidSelection
        }
        let context = try requireCurrentContext()
        let targetIdentifier = try requireCurrentTargetIdentifier()
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.setAttributeValue,
            targetIdentifier: targetIdentifier,
            parameters: DOMSetAttributeValueParameters(
                nodeId: try transportNodeID(for: node),
                name: name,
                value: value
            )
        )
        _ = document.updateAttribute(
            name: name,
            value: value,
            localID: node.localID,
            backendNodeID: node.backendNodeID
        )
        applyRecoverableError(nil)
        if currentContext?.contextID != context.contextID {
            throw DOMOperationError.contextInvalidated
        }
    }

    public func removeAttribute(
        nodeID: DOMNodeModel.ID,
        name: String
    ) async throws {
        guard let node = document.node(id: nodeID) else {
            throw DOMOperationError.invalidSelection
        }
        let context = try requireCurrentContext()
        let targetIdentifier = try requireCurrentTargetIdentifier()
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.removeAttribute,
            targetIdentifier: targetIdentifier,
            parameters: DOMRemoveAttributeParameters(
                nodeId: try transportNodeID(for: node),
                name: name
            )
        )
        _ = document.removeAttribute(
            name: name,
            localID: node.localID,
            backendNodeID: node.backendNodeID
        )
        applyRecoverableError(nil)
        if currentContext?.contextID != context.contextID {
            throw DOMOperationError.contextInvalidated
        }
    }

    public func updateSelectedAttribute(name: String, value: String) async throws {
        guard let nodeID = document.selectedNode?.id else {
            throw DOMOperationError.invalidSelection
        }
        try await setAttribute(nodeID: nodeID, name: name, value: value)
    }

    public func removeSelectedAttribute(name: String) async throws {
        guard let nodeID = document.selectedNode?.id else {
            throw DOMOperationError.invalidSelection
        }
        try await removeAttribute(nodeID: nodeID, name: name)
    }
}

private extension WIDOMInspector {
    func armInspectSelection(
        contextID: DOMContextID,
        targetIdentifier: String
    ) {
        let arm = InspectSelectionArm(
            contextID: contextID,
            targetIdentifier: targetIdentifier,
            generation: selectionGeneration
        )
        inspectSelectionArm = arm
#if DEBUG
        inspectSelectionDiagnosticsForTesting.append(
            .armed(
                contextID: contextID,
                targetIdentifier: targetIdentifier,
                generation: selectionGeneration
            )
        )
#endif
        logSelectionDiagnostics(
            "beginSelectionMode armed inspect selection",
            extra: "contextID=\(contextID) target=\(targetIdentifier) generation=\(selectionGeneration)"
        )
    }

    func inspectSelectionArmMatches(
        contextID: DOMContextID,
        targetIdentifier: String?,
        reason: String
    ) -> Bool {
        guard let inspectSelectionArm else {
#if DEBUG
            inspectSelectionDiagnosticsForTesting.append(
                .ignoredStaleEvent(
                    reason: reason,
                    eventContextID: contextID,
                    eventTargetIdentifier: targetIdentifier,
                    armContextID: nil,
                    armTargetIdentifier: nil,
                    generation: nil
                )
            )
#endif
            logSelectionDiagnostics(
                "selection arm ignored stale context",
                extra: "reason=\(reason) eventContextID=\(contextID) eventTarget=\(targetIdentifier ?? "nil") armContext=nil armTarget=nil generation=nil",
                level: .debug
            )
            return false
        }

        let targetMatches: Bool
        if let targetIdentifier {
            targetMatches = inspectSelectionArm.targetIdentifier == targetIdentifier
                || sharedTransport.targetKind(for: targetIdentifier) == .frame
        } else {
            targetMatches = true
        }

        guard inspectSelectionArm.contextID == contextID,
              targetMatches else {
#if DEBUG
            inspectSelectionDiagnosticsForTesting.append(
                .ignoredStaleEvent(
                    reason: reason,
                    eventContextID: contextID,
                    eventTargetIdentifier: targetIdentifier,
                    armContextID: inspectSelectionArm.contextID,
                    armTargetIdentifier: inspectSelectionArm.targetIdentifier,
                    generation: inspectSelectionArm.generation
                )
            )
#endif
            logSelectionDiagnostics(
                "selection arm ignored stale context",
                extra: "reason=\(reason) eventContextID=\(contextID) eventTarget=\(targetIdentifier ?? "nil") armContext=\(inspectSelectionArm.contextID) armTarget=\(inspectSelectionArm.targetIdentifier) generation=\(inspectSelectionArm.generation)",
                level: .debug
            )
            return false
        }

        return true
    }

    func requirePageWebView() throws -> WKWebView {
        guard let pageWebView else {
            applyRecoverableError("Web view unavailable.")
            throw DOMOperationError.pageUnavailable
        }
        return pageWebView
    }

    func requireCurrentContext() throws -> DOMContext {
        guard let currentContext else {
            throw DOMOperationError.contextInvalidated
        }
        return currentContext
    }

    func requireReadySelectionState() throws -> (context: DOMContext, targetIdentifier: String) {
        guard case let .ready(context, targetIdentifier) = phase,
              currentContext?.contextID == context.contextID else {
            throw DOMOperationError.contextInvalidated
        }
        return (context, targetIdentifier)
    }

    func requireCurrentTargetIdentifier() throws -> String {
        guard let targetIdentifier = phase.targetIdentifier ?? sharedTransport.currentPageTargetIdentifier() else {
            throw DOMOperationError.contextInvalidated
        }
        return targetIdentifier
    }

    func refreshReadyContextIfTransportTargetAdvanced(reason: String) async throws {
        guard case let .ready(_, activeTargetIdentifier) = phase,
              let committedTargetIdentifier = sharedTransport.currentCommittedPageTargetIdentifier(),
              committedTargetIdentifier != activeTargetIdentifier else {
            return
        }

        logSelectionDiagnostics(
            "selection requested with stale target; refreshing current document",
            extra: "reason=\(reason) activeTarget=\(activeTargetIdentifier) committedTarget=\(committedTargetIdentifier)",
            level: .error
        )
        await beginFreshContext(
            documentURL: normalizedDocumentURL(pageWebView?.url?.absoluteString),
            targetIdentifier: committedTargetIdentifier,
            loadImmediately: true,
            isFreshDocument: true,
            reason: "\(reason).targetAdvanced"
        )
        throw DOMOperationError.contextInvalidated
    }

    func ensureDocumentLoadIsActive(reason: String) {
        guard case let .loadingDocument(context, activeTargetIdentifier) = phase,
              currentContext?.contextID == context.contextID,
              bootstrapTask == nil else {
            return
        }
        guard let targetIdentifier = activeTargetIdentifier
            ?? sharedTransport.currentObservedPageTargetIdentifier()
            ?? sharedTransport.currentPageTargetIdentifier()
            ?? sharedTransport.currentCommittedPageTargetIdentifier()
        else {
            logBootstrapDiagnostics("ensureDocumentLoadIsActive awaiting target reason=\(reason) context=\(context.contextID)")
            return
        }
        logBootstrapDiagnostics("ensureDocumentLoadIsActive starting load reason=\(reason) context=\(context.contextID) target=\(targetIdentifier)")
        startLoadingDocumentEnsuringLoadingState(
            for: context,
            targetIdentifier: targetIdentifier,
            depth: configuration.snapshotDepth,
            isFreshDocument: false
        )
    }

    func documentLoadTargetIdentifier(
        activeTargetIdentifier: String?,
        eventTargetIdentifier: String?
    ) -> String? {
        if let activeTargetIdentifier {
            return activeTargetIdentifier
        }
        if let eventTargetIdentifier,
           sharedTransport.targetKind(for: eventTargetIdentifier) != .frame {
            return eventTargetIdentifier
        }
        return sharedTransport.currentObservedPageTargetIdentifier()
            ?? sharedTransport.currentPageTargetIdentifier()
            ?? sharedTransport.currentCommittedPageTargetIdentifier()
    }

    func cancelStaleInspectModeBeforeBeginningSelectionIfNeeded() async {
        var shouldCancelStaleInspectMode =
            isSelectingElement
                || acceptsInspectEvents
                || inspectModeControlBackend != nil
                || inspectModeTargetIdentifier != nil
#if canImport(UIKit)
        shouldCancelStaleInspectMode =
            shouldCancelStaleInspectMode
                || nativeInspectorSelectionToggleNeedsDeactivation
                || nativeInspectorNodeSearchNeedsDirectDeactivation
                || nativeInspectorProtocolInspectModeNeedsDeactivation
#endif
        guard shouldCancelStaleInspectMode else {
            return
        }

        let targetIdentifier = inspectModeTargetIdentifier ?? phase.targetIdentifier
        logSelectionDiagnostics(
            "beginSelectionMode cancelling stale inspect mode before rearming",
            extra: "target=\(targetIdentifier ?? "nil") selecting=\(isSelectingElement) acceptsInspectEvents=\(acceptsInspectEvents) backend=\(inspectModeControlBackend?.rawValue ?? "nil")"
        )
        await cancelInspectMode(
            targetIdentifier: targetIdentifier,
            invalidatePendingSelection: true
        )
    }

    func nodeForBackendAction(backendNodeID: Int) -> DOMNodeModel? {
        document.node(stableBackendNodeID: backendNodeID)
            ?? document.node(backendNodeID: backendNodeID)
    }

    func transportNodeID(for node: DOMNodeModel) throws -> Int {
        guard node.localID <= UInt64(Int.max) else {
            throw DOMOperationError.invalidSelection
        }
        return Int(node.localID)
    }

    func transportNodeID(forFrontendNodeID nodeID: Int) throws -> Int {
        if let node = document.node(localID: UInt64(nodeID)) {
            return try transportNodeID(for: node)
        }
        if let node = document.node(backendNodeID: nodeID) {
            return try transportNodeID(for: node)
        }
        return nodeID
    }

    func cancelBootstrap() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        bootstrapGeneration &+= 1
    }

    func clearContextState(reason: String = "unspecified") {
#if DEBUG
        freshContextDiagnosticsForTesting.append(.clearContextState(reason: reason))
#endif
        logSelectionDiagnostics(
            "clearContextState",
            extra: "reason=\(reason) pageWebView=\(webViewSummary(pageWebView)) transportAttached=\(isDOMTransportAttached) inspectTarget=\(inspectModeTargetIdentifier ?? "nil")"
        )
        currentContext = nil
        setPhase(.idle)
        documentURL = nil
        deferredLoadingMutationState = nil
        inspectModeTargetIdentifier = nil
        acceptsInspectEvents = false
        cancelPendingInspectMaterializationTimeout()
        pendingInspectSelection = nil
        isSelectingElement = false
        selectionGeneration &+= 1
        selectionActivationGeneration &+= 1
        cancelPendingChildRequestRecords()
        payloadNormalizer.resetForDocumentUpdate()
        document.clearDocument(isFreshDocument: true)
    }

    func beginFreshContext(
        documentURL: String?,
        targetIdentifier: String?,
        loadImmediately: Bool,
        isFreshDocument: Bool,
        reason: String = "unspecified"
    ) async {
#if DEBUG
        freshContextDiagnosticsForTesting.append(
            .beginFreshContext(reason: reason, isFreshDocument: isFreshDocument)
        )
#endif
        logSelectionDiagnostics(
            "beginFreshContext requested",
            extra: "reason=\(reason) target=\(targetIdentifier ?? "nil") loadImmediately=\(loadImmediately) isFreshDocument=\(isFreshDocument) pageWebView=\(webViewSummary(pageWebView))"
        )
        if isSelectingElement,
           let activeTargetIdentifier = inspectModeTargetIdentifier ?? phase.targetIdentifier {
            await cancelInspectMode(
                targetIdentifier: activeTargetIdentifier,
                invalidatePendingSelection: true
            )
        }
        if document.selectedNode != nil {
            try? await hideHighlight()
        }
        await failPendingChildRequests()
        cancelBootstrap()
        payloadNormalizer.resetForDocumentUpdate()
        deferredLoadingMutationState = nil
        cancelPendingInspectMaterializationTimeout()

        let context = DOMContext(
            contextID: nextContextID,
            documentURL: documentURL
        )
        nextContextID &+= 1
        currentContext = context
        self.documentURL = documentURL
        document.beginLoadingDocument(isFreshDocument: isFreshDocument)
        applyRecoverableError(nil)
        inspectSelectionArm = nil

        setPhase(.loadingDocument(context, targetIdentifier: targetIdentifier))

#if canImport(UIKit)
        await resetNativeInspectorSelectionStateForFreshContext(
            reason: reason,
            contextID: context.contextID
        )
#endif
        logBootstrapDiagnostics(
            "beginFreshContext context=\(context.contextID) target=\(targetIdentifier ?? "nil") loadImmediately=\(loadImmediately) url=\(documentURL ?? "nil")"
        )

        guard loadImmediately, let targetIdentifier else {
            logBootstrapDiagnostics("phase loadingDocument awaiting target context=\(context.contextID)")
            return
        }

        startLoadingDocument(
            for: context,
            targetIdentifier: targetIdentifier,
            depth: configuration.snapshotDepth,
            isFreshDocument: isFreshDocument
        )
    }

    func startLoadingDocumentEnsuringLoadingState(
        for context: DOMContext,
        targetIdentifier: String,
        depth: Int,
        isFreshDocument: Bool
    ) {
        if document.documentState != .loading {
            document.beginLoadingDocument(isFreshDocument: isFreshDocument)
            applyRecoverableError(nil)
        }
        startLoadingDocument(
            for: context,
            targetIdentifier: targetIdentifier,
            depth: depth,
            isFreshDocument: isFreshDocument
        )
    }

    func startLoadingDocument(
        for context: DOMContext,
        targetIdentifier: String,
        depth: Int,
        isFreshDocument: Bool
    ) {
        cancelBootstrap()
        setPhase(.loadingDocument(context, targetIdentifier: targetIdentifier))
        logBootstrapDiagnostics(
            "startLoadingDocument context=\(context.contextID) target=\(targetIdentifier) depth=\(depth)"
        )
        let generation = bootstrapGeneration
        bootstrapTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.bootstrapGeneration == generation {
                    self.bootstrapTask = nil
                }
            }
            do {
                try await self?.refreshCurrentDocumentFromTransport(
                    contextID: context.contextID,
                    targetIdentifier: targetIdentifier,
                    depth: depth,
                    isFreshDocument: isFreshDocument
                )
            } catch {
                guard let self, self.currentContext?.contextID == context.contextID else {
                    return
                }
                self.setPhase(.loadingDocument(context, targetIdentifier: targetIdentifier))
                self.failCurrentDocumentLoad(self.errorMessage(from: error))
            }
        }
    }

    func refreshCurrentDocumentFromTransport(
        contextID: DOMContextID,
        targetIdentifier: String,
        depth: Int,
        isFreshDocument: Bool
    ) async throws {
        guard let activeContext = currentContext,
              activeContext.contextID == contextID else {
            throw DOMOperationError.contextInvalidated
        }
        setPhase(.loadingDocument(activeContext, targetIdentifier: targetIdentifier))
        logBootstrapDiagnostics(
            "refreshCurrentDocumentFromTransport begin context=\(contextID) target=\(targetIdentifier)"
        )
        let responseData = try await loadDocumentResponseData(
            targetIdentifier: targetIdentifier
        )

        guard let currentContext,
              currentContext.contextID == contextID else {
            throw DOMOperationError.contextInvalidated
        }

        guard let delta = await payloadNormalizer.normalizeDocumentResponseData(
            responseData,
            resetDocument: isFreshDocument
        ),
        case let .snapshot(snapshot, _) = delta else {
            throw DOMOperationError.scriptFailure("document normalization failed")
        }

        document.replaceDocument(with: snapshot, isFreshDocument: isFreshDocument)
        let responseDocumentURL = await payloadNormalizer.documentURL(fromDocumentResponseData: responseData)
        let resolvedURL = normalizedDocumentURL(pageWebView?.url?.absoluteString)
            ?? normalizedDocumentURL(responseDocumentURL)
            ?? currentContext.documentURL
        let resolvedContext = DOMContext(contextID: contextID, documentURL: resolvedURL)
        self.currentContext = resolvedContext
        self.documentURL = resolvedURL
        setPhase(.ready(resolvedContext, targetIdentifier: targetIdentifier))
        applyRecoverableError(nil)
        logBootstrapDiagnostics(
            "refreshCurrentDocumentFromTransport ready context=\(contextID) target=\(targetIdentifier) root=\(snapshot.root.nodeName)"
        )

        if consumeDeferredLoadingMutationRefreshIfNeeded(
            contextID: contextID,
            targetIdentifier: targetIdentifier
        ) {
            logSelectionDiagnostics(
                "refreshCurrentDocumentFromTransport scheduling follow-up refresh after loading-time mutations",
                extra: "contextID=\(contextID) target=\(targetIdentifier)",
                level: .debug
            )
            try await refreshCurrentDocumentFromTransport(
                contextID: contextID,
                targetIdentifier: targetIdentifier,
                depth: depth,
                isFreshDocument: false
            )
            return
        }

        await hydrateInitiallyExpandedNodes(
            contextID: contextID,
            targetIdentifier: targetIdentifier,
            depth: depth
        )

        clearDeferredLoadingMutationStateIfSettled(
            contextID: contextID,
            targetIdentifier: targetIdentifier
        )
    }

    func loadDocumentResponseData(
        targetIdentifier: String
    ) async throws -> Data {
        logBootstrapDiagnostics("loadDocumentResponseData target=\(targetIdentifier) inspector.enable")
        _ = try await sendDOMCommand(
            WITransportMethod.Inspector.enable,
            targetIdentifier: targetIdentifier
        )
        logBootstrapDiagnostics("loadDocumentResponseData target=\(targetIdentifier) inspector.initialized")
        _ = try await sendDOMCommand(
            WITransportMethod.Inspector.initialized,
            targetIdentifier: targetIdentifier
        )
        logBootstrapDiagnostics("loadDocumentResponseData target=\(targetIdentifier) dom.enable")
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.enable,
            targetIdentifier: targetIdentifier
        )
        logBootstrapDiagnostics("loadDocumentResponseData target=\(targetIdentifier) dom.getDocument")
        return try await sendDOMCommandData(
            WITransportMethod.DOM.getDocument,
            targetIdentifier: targetIdentifier
        )
    }

    func hydrateInitiallyExpandedNodes(
        contextID: DOMContextID,
        targetIdentifier: String,
        depth: Int
    ) async {
        guard currentContext?.contextID == contextID else {
            return
        }

        var requestedNodeIDs = Set<DOMNodeModel.ID>()

        while currentContext?.contextID == contextID {
            let candidates = initiallyExpandedIncompleteNodes().filter {
                requestedNodeIDs.insert($0.id).inserted
            }
            guard !candidates.isEmpty else {
                return
            }

            var requestedAnyChildren = false
            for node in candidates {
                guard let transportNodeID = try? transportNodeID(for: node) else {
                    continue
                }
                do {
                    _ = try await sendDOMCommand(
                        WITransportMethod.DOM.requestChildNodes,
                        targetIdentifier: targetIdentifier,
                        parameters: DOMRequestChildNodesParameters(
                            nodeId: transportNodeID,
                            depth: max(1, depth)
                        )
                    )
                    requestedAnyChildren = true
                } catch {
                    continue
                }
            }

            if requestedAnyChildren {
                await awaitTransportMessagesToDrain()
                for _ in 0..<8 {
                    guard currentContext?.contextID == contextID else {
                        return
                    }
                    let hasUnrequestedCandidates = initiallyExpandedIncompleteNodes().contains {
                        requestedNodeIDs.contains($0.id) == false
                    }
                    if hasUnrequestedCandidates {
                        break
                    }
                    await Task.yield()
                }
            }
        }
    }

    func initiallyExpandedIncompleteNodes() -> [DOMNodeModel] {
        var nodes: [DOMNodeModel] = []

        func visit(_ node: DOMNodeModel?, depth: Int) {
            guard let node else {
                return
            }
            guard shouldHydrateInitiallyExpandedNode(node, depth: depth) else {
                return
            }
            if node.hasUnloadedRegularChildren {
                nodes.append(node)
            }
            for child in node.visibleDOMTreeChildren {
                visit(child, depth: depth + 1)
            }
        }

        visit(document.rootNode, depth: 0)
        return nodes
    }

    func shouldHydrateInitiallyExpandedNode(_ node: DOMNodeModel, depth: Int) -> Bool {
        guard node.nodeType != .documentType else {
            return false
        }
        let name = (node.localName.isEmpty ? node.nodeName : node.localName).lowercased()
        if name == "head" {
            return false
        }
        return depth <= 2
    }

    func handleTransportEvent(_ envelope: WITransportEventEnvelope) async {
        switch envelope.method {
        case "Target.targetCreated":
            guard transportLifecycleEventIsForPage(envelope) else {
                return
            }
            let observedTargetIdentifier = sharedTransport.currentObservedPageTargetIdentifier()
            switch phase {
            case let .loadingDocument(context, activeTargetIdentifier):
                guard let targetIdentifier = observedTargetIdentifier
                    ?? sharedTransport.currentPageTargetIdentifier()
                    ?? envelope.targetIdentifier
                else {
                    return
                }
                guard activeTargetIdentifier != targetIdentifier || bootstrapTask == nil else {
                    return
                }
                startLoadingDocumentEnsuringLoadingState(
                    for: context,
                    targetIdentifier: targetIdentifier,
                    depth: configuration.snapshotDepth,
                    isFreshDocument: activeTargetIdentifier != nil && activeTargetIdentifier != targetIdentifier
                )
            default:
                return
            }
        case "Target.didCommitProvisionalTarget":
            guard transportLifecycleEventIsForPage(envelope) else {
                return
            }
            let targetIdentifier = sharedTransport.currentPageTargetIdentifier()
                ?? envelope.targetIdentifier
            await beginFreshContext(
                documentURL: normalizedDocumentURL(pageWebView?.url?.absoluteString),
                targetIdentifier: targetIdentifier,
                loadImmediately: targetIdentifier != nil,
                isFreshDocument: true,
                reason: "transport.targetDidCommitProvisionalTarget"
            )
        case "Target.targetDestroyed":
            guard transportLifecycleEventIsForPage(envelope) else {
                return
            }
            guard let activeTargetIdentifier = phase.targetIdentifier,
                  envelope.targetIdentifier == activeTargetIdentifier else {
                return
            }
            let replacementTargetIdentifier = sharedTransport.currentObservedPageTargetIdentifier()
                ?? sharedTransport.currentPageTargetIdentifier()
            await beginFreshContext(
                documentURL: normalizedDocumentURL(pageWebView?.url?.absoluteString),
                targetIdentifier: replacementTargetIdentifier,
                loadImmediately: replacementTargetIdentifier != nil,
                isFreshDocument: true,
                reason: "transport.targetDestroyed"
            )
        default:
            await handleDOMEventEnvelope(envelope)
        }
    }

    func handleDOMEventEnvelope(_ envelope: WITransportEventEnvelope) async {
        let isDOMEvent = envelope.method.hasPrefix("DOM.")
        let isInspectEvent = envelope.method == "DOM.inspect" || envelope.method == "Inspector.inspect"
        guard isDOMEvent || envelope.method == "Inspector.inspect" else {
            return
        }
        if isInspectEvent == false,
           case let .loadingDocument(context, activeTargetIdentifier) = phase {
            let matchesLoadingTarget =
                activeTargetIdentifier == nil
                || envelope.targetIdentifier == nil
                || envelope.targetIdentifier == activeTargetIdentifier
                || sharedTransport.targetKind(for: envelope.targetIdentifier) == .frame

            guard matchesLoadingTarget else {
                return
            }

            if envelope.method == "DOM.documentUpdated" {
                guard let targetIdentifier = documentLoadTargetIdentifier(
                    activeTargetIdentifier: activeTargetIdentifier,
                    eventTargetIdentifier: envelope.targetIdentifier
                ) else {
                    return
                }
                if activeTargetIdentifier == targetIdentifier, bootstrapTask != nil {
                    noteDeferredLoadingMutation(
                        contextID: context.contextID,
                        targetIdentifier: targetIdentifier,
                        method: envelope.method
                    )
                    return
                }
                startLoadingDocumentEnsuringLoadingState(
                    for: context,
                    targetIdentifier: targetIdentifier,
                    depth: configuration.snapshotDepth,
                    isFreshDocument: true
                )
                return
            }

            if let targetIdentifier = documentLoadTargetIdentifier(
                activeTargetIdentifier: activeTargetIdentifier,
                eventTargetIdentifier: envelope.targetIdentifier
            ) {
                if activeTargetIdentifier != nil {
                    noteDeferredLoadingMutation(
                        contextID: context.contextID,
                        targetIdentifier: targetIdentifier,
                        method: envelope.method
                    )
                }
                return
            }
            return
        }
        guard case let .ready(context, targetIdentifier) = phase,
              isInspectEvent
                || envelope.targetIdentifier == nil
                || envelope.targetIdentifier == targetIdentifier
                || sharedTransport.targetKind(for: envelope.targetIdentifier) == .frame
        else {
            return
        }

        if envelope.method == "DOM.inspect" {
            guard acceptsInspectEvents,
                  inspectSelectionArmMatches(
                    contextID: context.contextID,
                    targetIdentifier: envelope.targetIdentifier,
                    reason: "DOM.inspect"
                  ),
                  let object = try? JSONSerialization.jsonObject(with: envelope.paramsData) as? [String: Any],
                  let nodeID = intValue(object["nodeId"]) else {
                return
            }
            await handleInspectEvent(
                nodeID: nodeID,
                contextID: context.contextID,
                eventTargetIdentifier: envelope.targetIdentifier
            )
            return
        }

        if envelope.method == "Inspector.inspect" {
            guard acceptsInspectEvents,
                  inspectSelectionArmMatches(
                    contextID: context.contextID,
                    targetIdentifier: envelope.targetIdentifier,
                    reason: "Inspector.inspect"
                  ),
                  let object = try? JSONSerialization.jsonObject(with: envelope.paramsData) as? [String: Any],
                  let remoteObject = object["object"] as? [String: Any],
                  let objectID = stringValue(remoteObject["objectId"]) else {
                return
            }
            await handleInspectorInspectEvent(
                objectID: objectID,
                contextID: context.contextID,
                eventTargetIdentifier: envelope.targetIdentifier
            )
            return
        }

        guard let delta = await payloadNormalizer.normalizeDOMEvent(
            method: envelope.method,
            paramsData: envelope.paramsData
        ) else {
            return
        }

        switch delta {
        case let .mutations(bundle):
            if bundle.events.contains(where: { if case .documentUpdated = $0 { true } else { false } }) {
                await beginFreshContext(
                    documentURL: normalizedDocumentURL(pageWebView?.url?.absoluteString),
                    targetIdentifier: targetIdentifier,
                    loadImmediately: true,
                    isFreshDocument: true,
                    reason: "transport.documentUpdated"
                )
                return
            }
            document.applyMutationBundle(bundle)
            let mirrorInvariantViolationReason = document.consumeMirrorInvariantViolationReason()
            let rejectedStructuralMutationParentLocalIDs = document.consumeRejectedStructuralMutationParentLocalIDs()
            if let mirrorInvariantViolationReason {
                logSelectionDiagnostics(
                    "handleDOMEventEnvelope detected canonical mirror invariant violation",
                    extra: "contextID=\(context.contextID) target=\(targetIdentifier) reason=\(mirrorInvariantViolationReason)",
                    level: .error
                )
                await beginFreshContext(
                    documentURL: normalizedDocumentURL(pageWebView?.url?.absoluteString),
                    targetIdentifier: targetIdentifier,
                    loadImmediately: true,
                    isFreshDocument: true,
                    reason: "transport.mirrorInvariantViolation"
                )
                return
            }
            recordPendingInspectProgressIfNeeded(
                from: bundle,
                contextID: context.contextID,
                reason: "mutation.bundle",
                rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
            )
            await applyPendingInspectSelectionIfPossible()
            await finishPendingInspectMaterialization(
                from: bundle,
                contextID: context.contextID,
                rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
            )
            await applyPendingInspectSelectionIfPossible()
            await finishPendingChildRequests(
                from: bundle,
                contextID: context.contextID,
                rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
            )
            await advancePendingInspectMaterializationIfIdle(
                contextID: context.contextID
            )
        case let .selection(selection):
            let previousSelection = selectionNodeSummary(document.selectedNode)
            document.applySelectionSnapshot(selection)
            logSelectionDiagnostics(
                "handleDOMEventEnvelope applied transport selection",
                selector: selection?.selectorPath,
                extra: "payload=\(selectionPayloadSummary(selection)) previous=\(previousSelection)"
            )
        case let .selectorPath(selectorPath):
            document.applySelectorPath(selectorPath)
        case let .snapshot(snapshot, resetDocument):
            document.replaceDocument(with: snapshot, isFreshDocument: resetDocument)
            await applyPendingInspectSelectionIfPossible()
        }
    }

    func finishPendingChildRequests(
        from bundle: DOMGraphMutationBundle,
        contextID: DOMContextID,
        rejectedStructuralMutationParentLocalIDs: Set<UInt64>
    ) async {
        let completedNodeIDs = completedChildRequestNodeIDs(
            from: bundle,
            rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
        )
        let shouldLogCompletion = !completedNodeIDs.isEmpty && (
            !pendingChildRequests.isEmpty
                || pendingInspectSelection != nil
        )
        if shouldLogCompletion {
            logSelectionDiagnostics(
                "finishPendingChildRequests completed child nodes",
                extra: "contextID=\(contextID) completedNodeIDs=\(completedNodeIDs) mutation=\(mutationBundleSummary(bundle)) pendingInspectOutstanding=\(pendingInspectSelection?.outstandingMaterializationNodeIDs.map { $0.localID }.sorted() ?? []) pendingChildRequests=\(pendingChildRequestDiagnosticsSummary())",
                level: .debug
            )
        }

        for nodeID in completedNodeIDs {
            await completePendingChildRequest(
                nodeID: nodeID,
                contextID: contextID,
                success: true
            )
        }
    }

    private func completedChildRequestNodeIDs(
        from bundle: DOMGraphMutationBundle,
        rejectedStructuralMutationParentLocalIDs: Set<UInt64> = []
    ) -> [Int] {
        bundle.events.compactMap { event in
            switch event {
            case let .setChildNodes(parentLocalID, _):
                guard !rejectedStructuralMutationParentLocalIDs.contains(parentLocalID) else {
                    return nil
                }
                return Int(parentLocalID)
            case let .replaceSubtree(root):
                return Int(root.localID)
            default:
                return nil
            }
        }
    }

    func performChildRequest(nodeID: Int, depth: Int, contextID: DOMContextID) async {
        guard let registration = registerPendingChildRequest(
            nodeID: nodeID,
            contextID: contextID,
            reportsToFrontend: true
        ) else {
            return
        }

        do {
            if await completePendingChildRequestIfAlreadySatisfied(
                nodeID: nodeID,
                contextID: contextID
            ) {
                return
            }

            if registration.shouldSendRequest {
                let targetIdentifier = try requireCurrentTargetIdentifier()
                let transportNodeID = try transportNodeID(forFrontendNodeID: nodeID)
                _ = try await sendDOMCommand(
                    WITransportMethod.DOM.requestChildNodes,
                    targetIdentifier: targetIdentifier,
                    parameters: DOMRequestChildNodesParameters(
                        nodeId: transportNodeID,
                        depth: max(1, depth)
                    )
                )
            }

            if await completePendingChildRequestIfAlreadySatisfied(
                nodeID: nodeID,
                contextID: contextID
            ) {
                return
            }

            _ = await waitForPendingChildRequestCompletion(
                registration.record,
                nodeID: nodeID,
                contextID: contextID
            )
        } catch {
            await completePendingChildRequest(
                nodeID: nodeID,
                contextID: contextID,
                success: false
            )
        }
    }

    private func registerPendingChildRequest(
        nodeID: Int,
        contextID: DOMContextID,
        reportsToFrontend: Bool
    ) -> (record: PendingChildRequestRecord, shouldSendRequest: Bool)? {
        let key = PendingChildRequestKey(nodeID: nodeID, contextID: contextID)
        if let existing = pendingChildRequests[key] {
            if reportsToFrontend, existing.upgradeToFrontendRequest() == false {
                return nil
            }
            return (existing, false)
        }

        let record = PendingChildRequestRecord(key: key, reportsToFrontend: reportsToFrontend)
        pendingChildRequests[key] = record
        return (record, true)
    }

    private func completePendingChildRequestIfAlreadySatisfied(
        nodeID: Int,
        contextID: DOMContextID
    ) async -> Bool {
        guard childRequestIsAlreadySatisfied(nodeID: nodeID) else {
            return false
        }

        await completePendingChildRequest(
            nodeID: nodeID,
            contextID: contextID,
            success: true
        )
        return true
    }

    private func childRequestIsAlreadySatisfied(nodeID: Int) -> Bool {
        guard let node = document.node(localID: UInt64(nodeID)) else {
            return false
        }
        return !node.hasUnloadedRegularChildren
    }

    private func waitForPendingChildRequestCompletion(
        _ record: PendingChildRequestRecord,
        nodeID: Int,
        contextID: DOMContextID,
        timeout overrideTimeout: Duration? = nil
    ) async -> Bool {
        let timeout: Duration
        if let overrideTimeout {
            timeout = overrideTimeout
        } else if let responseTimeout = await sharedTransport.attachedSession()?.responseTimeout {
            timeout = responseTimeout
        } else {
            timeout = .seconds(15)
        }
        return await record.wait(timeout: timeout) { [weak self] in
            guard let self else {
                return
            }
            await self.completePendingChildRequest(
                nodeID: nodeID,
                contextID: contextID,
                success: false
            )
        }
    }

    private func requestChildNodesAndWaitForCompletion(
        transportNodeID: Int,
        frontendNodeID: Int,
        targetIdentifier: String,
        contextID: DOMContextID,
        depth: Int,
        timeout: Duration? = nil
    ) async -> Bool {
        guard let registration = registerPendingChildRequest(
            nodeID: frontendNodeID,
            contextID: contextID,
            reportsToFrontend: false
        ) else {
            return false
        }

        if registration.shouldSendRequest {
            do {
                _ = try await sendDOMCommand(
                    WITransportMethod.DOM.requestChildNodes,
                    targetIdentifier: targetIdentifier,
                    parameters: DOMRequestChildNodesParameters(
                        nodeId: transportNodeID,
                        depth: max(1, depth)
                    )
                )
            } catch {
                await completePendingChildRequest(
                    nodeID: frontendNodeID,
                    contextID: contextID,
                    success: false
                )
                return false
            }
        }

        return await waitForPendingChildRequestCompletion(
            registration.record,
            nodeID: frontendNodeID,
            contextID: contextID,
            timeout: timeout
        )
    }

    private func completePendingChildRequest(
        nodeID: Int,
        contextID: DOMContextID,
        success: Bool
    ) async {
        let key = PendingChildRequestKey(nodeID: nodeID, contextID: contextID)
        guard let record = pendingChildRequests.removeValue(forKey: key) else {
            return
        }

        let shouldNotifyFrontend = record.reportsToFrontend
        record.finish(success)
        logSelectionDiagnostics(
            "completePendingChildRequest",
            extra: "nodeID=\(nodeID) contextID=\(contextID) success=\(success) reportsToFrontend=\(shouldNotifyFrontend) node=\(selectionNodeSummary(document.node(localID: UInt64(nodeID))))",
            level: .debug
        )

    }

    private func failPendingChildRequests(contextID: DOMContextID? = nil) async {
        let keysToFail = pendingChildRequests.keys.filter {
            contextID == nil || $0.contextID == contextID
        }
        guard !keysToFail.isEmpty else {
            return
        }

        let failedRecords = keysToFail.compactMap { key in
            pendingChildRequests.removeValue(forKey: key).map { (key, $0) }
        }

        for (key, record) in failedRecords {
            let shouldNotifyFrontend = record.reportsToFrontend
            record.finish(false)
            logSelectionDiagnostics(
                "failPendingChildRequests",
                extra: "nodeID=\(key.nodeID) contextID=\(key.contextID) reportsToFrontend=\(shouldNotifyFrontend)",
                level: .debug
            )
        }
    }

    private func cancelPendingChildRequestRecords() {
        let records = Array(pendingChildRequests.values)
        pendingChildRequests.removeAll(keepingCapacity: true)
        for record in records {
            record.finish(false)
        }
    }

    private func cancelPendingInspectMaterializationTimeout() {
        pendingInspectMaterializationTimeoutTask?.cancel()
        pendingInspectMaterializationTimeoutTask = nil
    }

    private func schedulePendingInspectMaterializationTimeout(
        for pendingSelection: PendingInspectSelection
    ) {
        cancelPendingInspectMaterializationTimeout()
        pendingInspectMaterializationTimeoutTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let timeout = await self.inspectMaterializationTimeout()
            do {
                try await ContinuousClock().sleep(for: timeout)
            } catch {
                return
            }

            guard let currentPendingSelection = self.pendingInspectSelection,
                  currentPendingSelection == pendingSelection,
                  self.resolvedAttachedInspectedNodeFromCurrentDocument(nodeID: currentPendingSelection.nodeID) == nil,
                  self.selectionTransactionIsCurrent(currentPendingSelection.transaction) else {
                return
            }

            self.logSelectionDiagnostics(
                "pending inspect materialization timed out",
                selector: currentPendingSelection.selectorPath,
                extra: "timeout=\(String(describing: timeout)) \(self.inspectResolutionDiagnosticSummary(nodeID: currentPendingSelection.nodeID, targetIdentifier: currentPendingSelection.resolutionTargetIdentifier, contextID: currentPendingSelection.contextID))",
                level: .error
            )

            let didRefresh = await self.refreshSelectionSubtreeFromTransportIfNeeded(
                selectorPath: currentPendingSelection.selectorPath,
                contextID: currentPendingSelection.contextID,
                targetIdentifier: currentPendingSelection.resolutionTargetIdentifier
            )
            self.logSelectionDiagnostics(
                "pending inspect materialization timeout refresh finished",
                selector: currentPendingSelection.selectorPath,
                extra: "nodeID=\(currentPendingSelection.nodeID) didRefresh=\(didRefresh) currentSelection=\(self.selectionNodeSummary(self.document.selectedNode))",
                level: .debug
            )

            await self.applyPendingInspectSelectionIfPossible()

            if didRefresh {
                let materializationOutcome = await self.restartPendingInspectMaterializationAfterRefresh(
                    currentPendingSelection,
                    reason: "timeout.refresh"
                )
                if materializationOutcome != .exhausted {
                    return
                }
            }

            guard let unresolvedPendingSelection = self.pendingInspectSelection,
                  selectionTransactionIsCurrent(unresolvedPendingSelection.transaction) else {
                return
            }

            self.pendingInspectSelection = nil
            await self.clearSelectionForFailedResolution(
                contextID: unresolvedPendingSelection.contextID,
                transaction: unresolvedPendingSelection.transaction,
                showError: true,
                errorMessage: "Failed to resolve selected element."
            )
        }
    }

    private func inspectMaterializationTimeout() async -> Duration {
        if let responseTimeout = await sharedTransport.attachedSession()?.responseTimeout {
            return responseTimeout
        }
        return .seconds(15)
    }

    func highlightNode(_ nodeID: Int, reveal: Bool = true) async throws {
        let targetIdentifier = try requireCurrentTargetIdentifier()
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.highlightNode,
            targetIdentifier: targetIdentifier,
            parameters: DOMHighlightNodeParameters(
                nodeId: try transportNodeID(forFrontendNodeID: nodeID),
                reveal: reveal
            )
        )
    }

    func hideHighlight() async throws {
        let targetIdentifier = try requireCurrentTargetIdentifier()
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.hideHighlight,
            targetIdentifier: targetIdentifier
        )
    }

    func handleInspectorSelection(_ selection: DOMSelectionSnapshotPayload?) {
            let previousSelection = selectionNodeSummary(document.selectedNode)
            guard let selection else {
                logSelectionDiagnostics(
                    "handleInspectorSelection ignored nil frontend selection payload",
                    extra: "previous=\(previousSelection)"
                )
                return
            }
            guard selection.localID != nil else {
                if inspectSelectionArm != nil || pendingInspectSelection != nil {
                    logSelectionDiagnostics(
                        "handleInspectorSelection ignored frontend selection without localID",
                        selector: selection.selectorPath,
                        extra: "payload=\(selectionPayloadSummary(selection)) previous=\(previousSelection)"
                    )
                }
                return
            }
            guard let resolvedSelection = resolveFrontendSelectionPayloadForCurrentDocument(selection) else {
                logSelectionDiagnostics(
                    "handleInspectorSelection ignored stale frontend selection",
                    selector: selection.selectorPath,
                    extra: "payload=\(selectionPayloadSummary(selection)) previous=\(previousSelection)"
                )
                return
            }
            if inspectSelectionArm != nil || pendingInspectSelection != nil {
                if selectionPayloadMatchesCurrentSelection(resolvedSelection)
                    || selectionPayloadMatchesPendingInspectSelection(resolvedSelection)
                {
                    logSelectionDiagnostics(
                        "handleInspectorSelection ignored frontend selection echo during inspect resolution",
                        selector: resolvedSelection.selectorPath,
                        extra: "payload=\(selectionPayloadSummary(resolvedSelection)) previous=\(previousSelection)"
                    )
                    return
                }

                if document.selectedNode != nil {
                    logSelectionDiagnostics(
                        "handleInspectorSelection ignored frontend selection refinement while current selection is retained during inspect resolution",
                        selector: resolvedSelection.selectorPath,
                        extra: "payload=\(selectionPayloadSummary(resolvedSelection)) previous=\(previousSelection)"
                    )
                    return
                }

                document.applySelectionSnapshot(resolvedSelection)
                logSelectionDiagnostics(
                    "handleInspectorSelection applied frontend selection refinement during inspect resolution",
                    selector: resolvedSelection.selectorPath,
                    extra: "payload=\(selectionPayloadSummary(resolvedSelection)) previous=\(previousSelection)"
                )
                let transaction = pendingInspectSelection?.transaction
                    ?? {
                        guard let contextID = currentContext?.contextID else {
                            return nil
                        }
                        return selectionTransaction(for: contextID)
                    }()
                finishInspectSelectionResolution(transaction: transaction)
                applyRecoverableError(nil)
                Task { @MainActor [weak self] in
                    guard let self, let contextID = self.currentContext?.contextID else {
                        return
                    }
                    await self.syncSelectedNodeHighlight(contextID: contextID)
                }
                return
            }
            document.applySelectionSnapshot(resolvedSelection)
            logSelectionDiagnostics(
                "handleInspectorSelection applied frontend selection",
                selector: resolvedSelection.selectorPath,
                extra: "payload=\(selectionPayloadSummary(resolvedSelection)) previous=\(previousSelection)"
            )
            Task { @MainActor [weak self] in
                guard let self, let contextID = self.currentContext?.contextID else {
                    return
                }
                await self.syncSelectedNodeHighlight(contextID: contextID)
            }
        }

    func deleteNode(
        nodeID: Int,
        nodeLocalID: UInt64?,
        undoManager: UndoManager?
    ) async throws {
        let context = try requireCurrentContext()
        let targetIdentifier = try requireCurrentTargetIdentifier()
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.removeNode,
            targetIdentifier: targetIdentifier,
            parameters: DOMNodeIdentifierParameters(nodeId: nodeID)
        )
        applyDeletedNode(nodeID: nodeID, nodeLocalID: nodeLocalID)
        applyRecoverableError(nil)

        if let undoManager {
            rememberDeleteUndoManager(undoManager)
            registerUndoDelete(
                .init(
                    nodeID: nodeID,
                    nodeLocalID: nodeLocalID,
                    contextID: context.contextID,
                    targetIdentifier: targetIdentifier
                ),
                undoManager: undoManager
            )
        }
    }

    func applyDeletedNode(nodeID: Int, nodeLocalID: UInt64?) {
        if let nodeLocalID,
           let node = document.node(localID: nodeLocalID) {
            document.removeNode(id: node.id)
            return
        }
        if let node = document.node(localID: UInt64(nodeID)) {
            document.removeNode(id: node.id)
            return
        }
        if let node = document.node(backendNodeID: nodeID) {
            document.removeNode(id: node.id)
        }
    }

    func registerUndoDelete(_ state: DeleteUndoState, undoManager: UndoManager) {
        rememberDeleteUndoManager(undoManager)
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                try? await target.performUndoDelete(state, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Delete Node")
    }

    func performUndoDelete(_ state: DeleteUndoState, undoManager: UndoManager) async throws {
        guard currentContext?.contextID == state.contextID else {
            clearDeleteUndoHistory(using: undoManager)
            throw DOMOperationError.contextInvalidated
        }
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.undo,
            targetIdentifier: state.targetIdentifier
        )
        try await refreshCurrentDocumentFromTransport(
            contextID: state.contextID,
            targetIdentifier: state.targetIdentifier,
            depth: configuration.snapshotDepth,
            isFreshDocument: false
        )
        registerRedoDelete(state, undoManager: undoManager)
        applyRecoverableError(nil)
    }

    func registerRedoDelete(_ state: DeleteUndoState, undoManager: UndoManager) {
        rememberDeleteUndoManager(undoManager)
        undoManager.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                try? await target.performRedoDelete(state, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Delete Node")
    }

    func performRedoDelete(_ state: DeleteUndoState, undoManager: UndoManager) async throws {
        guard currentContext?.contextID == state.contextID else {
            clearDeleteUndoHistory(using: undoManager)
            throw DOMOperationError.contextInvalidated
        }
        _ = try await sendDOMCommand(
            WITransportMethod.DOM.redo,
            targetIdentifier: state.targetIdentifier
        )
        try await refreshCurrentDocumentFromTransport(
            contextID: state.contextID,
            targetIdentifier: state.targetIdentifier,
            depth: configuration.snapshotDepth,
            isFreshDocument: false
        )
        registerUndoDelete(state, undoManager: undoManager)
        applyRecoverableError(nil)
    }

    func rememberDeleteUndoManager(_ undoManager: UndoManager) {
        if undoManager.levelsOfUndo == 0 || undoManager.levelsOfUndo > domDeleteUndoHistoryLimit {
            undoManager.levelsOfUndo = domDeleteUndoHistoryLimit
        }
        deleteUndoManager = undoManager
    }

    func clearDeleteUndoHistory(using undoManager: UndoManager? = nil) {
        let manager = undoManager ?? deleteUndoManager
        manager?.removeAllActions(withTarget: self)
        if let manager, manager === deleteUndoManager {
            deleteUndoManager = nil
        }
    }

    func beginInspectMode(
        contextID: DOMContextID,
        targetIdentifier: String,
        backend: InspectModeControlBackend
    ) {
        selectionGeneration &+= 1
        pendingInspectSelection = nil
        inspectModeTargetIdentifier = targetIdentifier
        inspectModeControlBackend = backend
        armInspectSelection(
            contextID: contextID,
            targetIdentifier: targetIdentifier
        )
        acceptsInspectEvents = true
        isSelectingElement = true
    }

    func beginSelectionActivation(
        contextID: DOMContextID,
        targetIdentifier: String
    ) -> UInt64 {
        selectionActivationGeneration &+= 1
        pendingInspectSelection = nil
        inspectModeTargetIdentifier = targetIdentifier
        inspectModeControlBackend = nil
        acceptsInspectEvents = false
        inspectSelectionArm = nil
        isSelectingElement = true
        return selectionActivationGeneration
    }

    func selectionActivationIsCurrent(
        generation: UInt64,
        contextID: DOMContextID,
        targetIdentifier: String
    ) -> Bool {
        selectionActivationGeneration == generation
            && isSelectingElement
            && selectionLifecycleStateMatches(
                contextID: contextID,
                targetIdentifier: targetIdentifier
            )
    }

    func clearInspectModeState(
        invalidatePendingSelection: Bool = false,
        markSelectionInactive: Bool = true,
        deactivateInspectEvents: Bool = true,
        clearSelectionArm: Bool = true
    ) {
        inspectModeTargetIdentifier = nil
        inspectModeControlBackend = nil
        if deactivateInspectEvents {
            acceptsInspectEvents = false
        }
        if markSelectionInactive {
            isSelectingElement = false
        }
        if clearSelectionArm {
            inspectSelectionArm = nil
        }
        if invalidatePendingSelection {
            pendingInspectSelection = nil
            selectionGeneration &+= 1
            selectionActivationGeneration &+= 1
        }
    }

    private func cancelInspectMode(
        targetIdentifier: String?,
        invalidatePendingSelection: Bool = false,
        restoreSelectedHighlight: Bool = false
    ) async {
        let activeInspectModeControlBackend = inspectModeControlBackend
        clearInspectModeState(
            invalidatePendingSelection: invalidatePendingSelection,
            markSelectionInactive: false,
            deactivateInspectEvents: true,
            clearSelectionArm: true
        )
        let cancellationActivationGeneration = selectionActivationGeneration

#if canImport(UIKit)
        await disableInspectorSelectionModeIfNeeded(
            targetIdentifier: targetIdentifier,
            backend: activeInspectModeControlBackend
        )
#else
        if let targetIdentifier {
            do {
                _ = try await sendDOMCommand(
                    WITransportMethod.DOM.setInspectModeEnabled,
                    targetIdentifier: targetIdentifier,
                    parameters: DOMSetInspectModeEnabledParameters.disabled
                )
            } catch {
                logSelectionDiagnostics(
                    "finishInspectMode failed to disable inspect mode",
                    extra: error.localizedDescription,
                    level: .error
                )
            }
        }
#endif

#if canImport(UIKit)
        await awaitInspectModeInactive()
        if selectionActivationGeneration == cancellationActivationGeneration {
            isSelectingElement = false
        }
#else
        if selectionActivationGeneration == cancellationActivationGeneration {
            isSelectingElement = false
        }
#endif

        if selectionActivationGeneration == cancellationActivationGeneration,
           restoreSelectedHighlight,
           let contextID = currentContext?.contextID,
           document.selectedNode != nil {
            await syncSelectedNodeHighlight(contextID: contextID)
        }
    }

    private func completeInspectModeAfterBackendSelection(
        transaction: SelectionTransaction? = nil,
        invalidatePendingSelection: Bool = false
    ) async {
        guard selectionTransactionIsCurrent(transaction) else {
            logSelectionDiagnostics(
                "completeInspectModeAfterBackendSelection ignored stale transaction",
                extra: "generation=\(transaction.map { String($0.generation) } ?? "nil")"
            )
            return
        }
        let activeTargetIdentifier = inspectModeTargetIdentifier ?? phase.targetIdentifier
        let activeInspectModeControlBackend = inspectModeControlBackend
        clearInspectModeState(
            invalidatePendingSelection: invalidatePendingSelection,
            markSelectionInactive: false,
            deactivateInspectEvents: false,
            clearSelectionArm: false
        )

#if canImport(UIKit)
        await disableInspectorSelectionModeIfNeeded(
            targetIdentifier: activeTargetIdentifier,
            backend: activeInspectModeControlBackend
        )
#else
        if let activeTargetIdentifier {
            do {
                try await setInspectModeEnabled(false, targetIdentifier: activeTargetIdentifier)
            } catch {
                logSelectionDiagnostics(
                    "completeInspectModeAfterBackendSelection failed to disable inspect mode",
                    extra: error.localizedDescription,
                    level: .error
                )
            }
        }
#endif

        guard selectionTransactionIsCurrent(transaction) else {
            logSelectionDiagnostics(
                "completeInspectModeAfterBackendSelection skipped stale completion",
                extra: "generation=\(transaction.map { String($0.generation) } ?? "nil")"
            )
            return
        }
#if canImport(UIKit)
        await awaitInspectModeInactive()
        isSelectingElement = false
#else
        isSelectingElement = false
#endif

        if let contextID = currentContext?.contextID,
           document.selectedNode != nil {
            await syncSelectedNodeHighlight(contextID: contextID)
        }
    }

    func setInspectModeEnabled(
        _ enabled: Bool,
        targetIdentifier: String
    ) async throws {
        if enabled {
            _ = try await sendDOMCommand(
                WITransportMethod.DOM.setInspectModeEnabled,
                targetIdentifier: targetIdentifier,
                parameters: DOMSetInspectModeEnabledParameters.enabled
            )
        } else {
            _ = try await sendDOMCommand(
                WITransportMethod.DOM.setInspectModeEnabled,
                targetIdentifier: targetIdentifier,
                parameters: DOMSetInspectModeEnabledParameters.disabled
            )
        }
    }

    func handleInspectEvent(
        nodeID: Int,
        contextID: DOMContextID,
        eventTargetIdentifier: String?
    ) async {
        let resolutionTargetIdentifier = inspectEventResolutionTargetIdentifier(
            eventTargetIdentifier: eventTargetIdentifier
        )
        guard currentContext?.contextID == contextID,
              inspectSelectionArmMatches(
                contextID: contextID,
                targetIdentifier: eventTargetIdentifier,
                reason: "handleInspectEvent"
              ) else {
            return
        }
        acceptsInspectEvents = false
        logSelectionDiagnostics(
            "handleInspectEvent received transport inspect",
            extra: "nodeID=\(nodeID) contextID=\(contextID) sourceTarget=\(eventTargetIdentifier ?? "nil") resolutionTarget=\(resolutionTargetIdentifier ?? "nil") generation=\(selectionGeneration)"
        )
        guard let transaction = selectionTransaction(for: contextID) else {
            return
        }
        guard let resolutionTargetIdentifier else {
            await clearSelectionForFailedResolution(
                contextID: contextID,
                transaction: transaction,
                showError: false,
                errorMessage: "Failed to resolve selected element."
            )
            return
        }
        logSelectionDiagnostics(
            "handleInspectEvent armed inspect resolution",
            extra: inspectResolutionDiagnosticSummary(
                nodeID: nodeID,
                targetIdentifier: resolutionTargetIdentifier,
                contextID: contextID
            ),
            level: .debug
        )
        if resolvedAttachedInspectedNodeFromCurrentDocument(nodeID: nodeID) == nil {
            _ = upsertPendingInspectSelection(
                nodeID: nodeID,
                contextID: contextID,
                selectorPath: nil,
                resolutionTargetIdentifier: resolutionTargetIdentifier,
                transaction: transaction
            )
        }
        scheduleInspectSelectionResolutionAfterTransportDrain(
            objectID: nil,
            nodeID: nodeID,
            contextID: contextID,
            selectorPath: nil,
            targetIdentifier: resolutionTargetIdentifier,
            transaction: transaction,
            showErrorOnFailure: false,
            allowMaterialization: allowsInspectSelectionMaterialization(
                targetIdentifier: resolutionTargetIdentifier
            )
        )
    }

    private func handleInspectorInspectEvent(
        objectID: String,
        contextID: DOMContextID,
        eventTargetIdentifier: String?
    ) async {
        let resolutionTargetIdentifier = inspectEventResolutionTargetIdentifier(
            eventTargetIdentifier: eventTargetIdentifier
        )
        guard currentContext?.contextID == contextID,
              inspectSelectionArmMatches(
                contextID: contextID,
                targetIdentifier: eventTargetIdentifier,
                reason: "handleInspectorInspectEvent"
              ) else {
            return
        }

        acceptsInspectEvents = false
        guard let transaction = selectionTransaction(for: contextID) else {
            return
        }
        guard let resolutionTargetIdentifier else {
            await completeInspectModeAfterBackendSelection(transaction: transaction)
            await clearSelectionForFailedResolution(
                contextID: contextID,
                transaction: transaction,
                showError: true,
                errorMessage: "Failed to resolve selected element."
            )
            return
        }

        do {
            logSelectionDiagnostics(
                "handleInspectorInspectEvent received transport inspect",
                extra: "contextID=\(contextID) objectID=\(objectID) injectedScriptId=\(injectedScriptIdentifier(from: objectID) ?? "nil") sourceTarget=\(eventTargetIdentifier ?? "nil") requestNodeTarget=\(resolutionTargetIdentifier) generation=\(transaction.generation)"
            )
            let resolution = try await resolveInspectorInspectNodeID(
                forRemoteObjectID: objectID,
                initialTargetIdentifier: resolutionTargetIdentifier
            )
            logSelectionDiagnostics(
                "handleInspectorInspectEvent resolved requestNode",
                extra: inspectResolutionDiagnosticSummary(
                    nodeID: resolution.nodeID,
                    targetIdentifier: resolution.targetIdentifier,
                    contextID: contextID
                ) + " attempts=\(resolution.attemptedTargetIdentifiers.joined(separator: ","))",
                level: .debug
            )
            if resolvedAttachedInspectedNodeFromCurrentDocument(nodeID: resolution.nodeID) == nil {
                _ = upsertPendingInspectSelection(
                    nodeID: resolution.nodeID,
                    contextID: contextID,
                    selectorPath: nil,
                    resolutionTargetIdentifier: resolution.targetIdentifier,
                    transaction: transaction
                )
            }
            scheduleInspectSelectionResolutionAfterTransportDrain(
                objectID: objectID,
                nodeID: resolution.nodeID,
                contextID: contextID,
                selectorPath: nil,
                targetIdentifier: resolution.targetIdentifier,
                transaction: transaction,
                showErrorOnFailure: true,
                allowMaterialization: allowsInspectSelectionMaterialization(
                    targetIdentifier: resolution.targetIdentifier
                )
            )
        } catch {
            await completeInspectModeAfterBackendSelection(transaction: transaction)
            logSelectionDiagnostics(
                "Inspector.inspect failed to resolve node",
                extra: "sourceTarget=\(eventTargetIdentifier ?? "nil") requestNodeTarget=\(resolutionTargetIdentifier) error=\(error.localizedDescription)",
                level: .error
            )
            await clearSelectionForFailedResolution(
                contextID: contextID,
                transaction: transaction,
                showError: true,
                errorMessage: "Failed to resolve selected element."
            )
        }
    }

    private func scheduleInspectSelectionResolutionAfterTransportDrain(
        objectID: String?,
        nodeID: Int,
        contextID: DOMContextID,
        selectorPath: String?,
        targetIdentifier: String,
        transaction: SelectionTransaction?,
        showErrorOnFailure: Bool,
        allowMaterialization: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.resolveInspectSelectionAfterTransportDrain(
                objectID: objectID,
                nodeID: nodeID,
                contextID: contextID,
                selectorPath: selectorPath,
                targetIdentifier: targetIdentifier,
                transaction: transaction,
                showErrorOnFailure: showErrorOnFailure,
                allowMaterialization: allowMaterialization
            )
        }
    }

    private func resolveInspectSelectionAfterTransportDrain(
        objectID: String?,
        nodeID: Int,
        contextID: DOMContextID,
        selectorPath: String?,
        targetIdentifier: String,
        transaction: SelectionTransaction?,
        showErrorOnFailure: Bool,
        allowMaterialization: Bool
    ) async {
        guard currentContext?.contextID == contextID,
              selectionTransactionIsCurrent(transaction) else {
            return
        }

        if let node = resolvedAttachedInspectedNodeFromCurrentDocument(nodeID: nodeID) {
            logSelectionDiagnostics(
                "resolveInspectSelectionAfterTransportDrain resolved attached node before drain",
                selector: selectorPath,
                extra: selectionNodeSummary(node)
            )
            await commitInspectedNodeIfPossible(
                nodeID: nodeID,
                contextID: contextID,
                selectorPath: selectorPath,
                targetIdentifier: targetIdentifier,
                transaction: transaction,
                showErrorOnFailure: showErrorOnFailure,
                allowMaterialization: false
            )
            return
        }

        await awaitTransportMessagesToDrain()

        guard currentContext?.contextID == contextID,
              selectionTransactionIsCurrent(transaction) else {
            return
        }

        await applyPendingInspectSelectionIfPossible()

        if pendingInspectSelection == nil,
           resolvedAttachedInspectedNodeFromCurrentDocument(nodeID: nodeID) != nil {
            return
        }

        if shouldMergeTargetDocumentForInspectSelection(targetIdentifier: targetIdentifier) {
            _ = await mergeFrameTargetDocumentIfNeeded(
                targetIdentifier: targetIdentifier,
                contextID: contextID,
                transaction: transaction
            )
            await applyPendingInspectSelectionIfPossible()

            guard currentContext?.contextID == contextID,
                  selectionTransactionIsCurrent(transaction) else {
                return
            }

            if pendingInspectSelection == nil,
               resolvedAttachedInspectedNodeFromCurrentDocument(nodeID: nodeID) != nil {
                return
            }
        }

        guard currentContext?.contextID == contextID,
              selectionTransactionIsCurrent(transaction) else {
            return
        }

        await commitInspectedNodeIfPossible(
            nodeID: nodeID,
            contextID: contextID,
            selectorPath: selectorPath,
            targetIdentifier: targetIdentifier,
            transaction: transaction,
            showErrorOnFailure: showErrorOnFailure,
            allowMaterialization: allowMaterialization
        )
    }

    private func commitInspectedNodeIfPossible(
        nodeID: Int,
        contextID: DOMContextID,
        selectorPath: String?,
        targetIdentifier: String,
        transaction: SelectionTransaction?,
        showErrorOnFailure: Bool,
        allowMaterialization: Bool
    ) async {
        do {
            try await applyInspectedNode(
                nodeID: nodeID,
                contextID: contextID,
                selectorPath: selectorPath,
                targetIdentifier: targetIdentifier,
                transaction: transaction,
                showErrorOnFailure: showErrorOnFailure,
                allowMaterialization: allowMaterialization
            )
        } catch {
            return
        }
    }

    private func finishInspectSelectionResolution(transaction: SelectionTransaction?) {
        guard selectionTransactionIsCurrent(transaction) else {
            return
        }
        cancelPendingInspectMaterializationTimeout()
        pendingInspectSelection = nil
        acceptsInspectEvents = false
        inspectSelectionArm = nil
    }

    private func transportNodeID(
        forRemoteObjectID objectID: String,
        targetIdentifier: String
    ) async throws -> Int {
        let response = try await sendDOMCommand(
            WITransportMethod.DOM.requestNode,
            targetIdentifier: targetIdentifier,
            parameters: DOMRequestNodeParameters(objectId: objectID)
        )
        guard let nodeID = intValue(response["nodeId"]) else {
            throw DOMOperationError.invalidSelection
        }
        return nodeID
    }

    private func resolveInspectorInspectNodeID(
        forRemoteObjectID objectID: String,
        initialTargetIdentifier: String
    ) async throws -> InspectorInspectNodeResolution {
        let candidateTargetIdentifiers = inspectorInspectRequestNodeCandidateTargets(
            initialTargetIdentifier: initialTargetIdentifier
        )
        var attemptedTargetIdentifiers: [String] = []
        var lastError: (any Error)?

        for targetIdentifier in candidateTargetIdentifiers {
            attemptedTargetIdentifiers.append(targetIdentifier)
            do {
                let nodeID = try await transportNodeID(
                    forRemoteObjectID: objectID,
                    targetIdentifier: targetIdentifier
                )
                if targetIdentifier != initialTargetIdentifier {
                    logSelectionDiagnostics(
                        "Inspector.inspect resolved node on fallback target",
                        extra: "initialTarget=\(initialTargetIdentifier) resolvedTarget=\(targetIdentifier) attempts=\(attemptedTargetIdentifiers.joined(separator: ","))",
                        level: .debug
                    )
                }
                return InspectorInspectNodeResolution(
                    nodeID: nodeID,
                    targetIdentifier: targetIdentifier,
                    attemptedTargetIdentifiers: attemptedTargetIdentifiers
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? DOMOperationError.invalidSelection
    }

    private func inspectorInspectRequestNodeCandidateTargets(
        initialTargetIdentifier: String
    ) -> [String] {
        var targetIdentifiers: [String] = []
        func appendTarget(_ targetIdentifier: String?) {
            guard let targetIdentifier,
                  targetIdentifiers.contains(targetIdentifier) == false else {
                return
            }
            targetIdentifiers.append(targetIdentifier)
        }

        appendTarget(initialTargetIdentifier)

        guard sharedTransport.targetKind(for: initialTargetIdentifier) != .frame else {
            return targetIdentifiers
        }

        for targetIdentifier in sharedTransport.pageTargetIdentifiers() {
            appendTarget(targetIdentifier)
        }
        for targetIdentifier in sharedTransport.frameTargetIdentifiers() {
            appendTarget(targetIdentifier)
        }
        return targetIdentifiers
    }

    private func upsertPendingInspectSelection(
        nodeID: Int,
        contextID: DOMContextID,
        selectorPath: String?,
        resolutionTargetIdentifier: String,
        transaction: SelectionTransaction?
    ) -> PendingInspectSelection {
        let existing = pendingInspectSelection
        let shouldPreserveRequestState = existing?.contextID == contextID
            && existing?.transaction == transaction
            && existing?.resolutionTargetIdentifier == resolutionTargetIdentifier
        let pendingSelection = PendingInspectSelection(
            nodeID: nodeID,
            contextID: contextID,
            selectorPath: selectorPath,
            resolutionTargetIdentifier: resolutionTargetIdentifier,
            transaction: transaction,
            scopedMaterializationRootNodeIDs: shouldPreserveRequestState ? existing?.scopedMaterializationRootNodeIDs ?? [] : [],
            materializedAncestorNodeIDs: shouldPreserveRequestState ? existing?.materializedAncestorNodeIDs ?? [] : [],
            outstandingMaterializationNodeIDs: shouldPreserveRequestState ? existing?.outstandingMaterializationNodeIDs ?? [] : [],
            activeMaterializationStrategy: shouldPreserveRequestState ? existing?.activeMaterializationStrategy ?? .none : .none,
            activeRequestGeneration: shouldPreserveRequestState ? existing?.activeRequestGeneration ?? 0 : 0,
            genericDispatchDeferralCount: shouldPreserveRequestState ? existing?.genericDispatchDeferralCount ?? 0 : 0,
            observedMaterializationStrategy: shouldPreserveRequestState ? existing?.observedMaterializationStrategy ?? .none : .none,
            observedMaterializationCandidateNodeIDs: shouldPreserveRequestState ? existing?.observedMaterializationCandidateNodeIDs ?? [] : [],
            observedDocumentBackedFrameIDs: shouldPreserveRequestState ? existing?.observedDocumentBackedFrameIDs ?? [] : [],
            lastExhaustedScopedCandidateNodeIDs: shouldPreserveRequestState ? existing?.lastExhaustedScopedCandidateNodeIDs ?? [] : [],
            lastExhaustedScopedStrategy: shouldPreserveRequestState ? existing?.lastExhaustedScopedStrategy : nil,
            progressRevision: shouldPreserveRequestState ? existing?.progressRevision ?? 0 : 0
        )
        pendingInspectSelection = pendingSelection
        return pendingSelection
    }

    private func applyInspectedNode(
        nodeID: Int,
        contextID: DOMContextID,
        selectorPath: String?,
        targetIdentifier: String,
        transaction: SelectionTransaction?,
        showErrorOnFailure: Bool,
        allowMaterialization: Bool
    ) async throws {
        guard currentContext?.contextID == contextID,
              selectionTransactionIsCurrent(transaction) else {
            return
        }

        if let node = resolvedAttachedInspectedNodeFromCurrentDocument(nodeID: nodeID) {
            logSelectionDiagnostics(
                "applyInspectedNode resolved transport node",
                selector: selectorPath,
                extra: selectionNodeSummary(node)
            )
            await applySelection(
                to: node,
                selectorPath: selectorPath,
                contextID: contextID,
                targetIdentifierForMaterialization: targetIdentifier
            )
            await completeInspectModeAfterBackendSelection(transaction: transaction)
            finishInspectSelectionResolution(transaction: transaction)
            applyRecoverableError(nil)
            return
        }

        if shouldMergeTargetDocumentForInspectSelection(targetIdentifier: targetIdentifier),
           await mergeFrameTargetDocumentIfNeeded(
                targetIdentifier: targetIdentifier,
                contextID: contextID,
                transaction: transaction
           ),
           let node = resolvedAttachedInspectedNodeFromCurrentDocument(nodeID: nodeID) {
            logSelectionDiagnostics(
                "applyInspectedNode resolved node after frame document merge",
                selector: selectorPath,
                extra: selectionNodeSummary(node)
            )
            await applySelection(
                to: node,
                selectorPath: selectorPath,
                contextID: contextID,
                targetIdentifierForMaterialization: targetIdentifier
            )
            await completeInspectModeAfterBackendSelection(transaction: transaction)
            finishInspectSelectionResolution(transaction: transaction)
            applyRecoverableError(nil)
            return
        }

        guard selectionTransactionIsCurrent(transaction) else {
            return
        }

        let shouldMaterializeCurrentInspectSelection = shouldMaterializeInspectSelection(
            transaction: transaction,
            pendingSelection: pendingInspectSelection,
            showErrorOnFailure: showErrorOnFailure
        )

        if allowMaterialization, shouldMaterializeCurrentInspectSelection {
            let outcome = await materializePendingInspectSelection(
                nodeID: nodeID,
                selectorPath: selectorPath,
                contextID: contextID,
                targetIdentifier: targetIdentifier,
                transaction: transaction
            )
            switch outcome {
            case .requested, .waitingForMutation:
                return
            case .exhausted:
                break
            }
        }

        logSelectionDiagnostics(
            "applyInspectedNode could not resolve transport node",
            selector: selectorPath,
            extra: "currentSelection=\(selectionNodeSummary(document.selectedNode)) \(inspectResolutionDiagnosticSummary(nodeID: nodeID, targetIdentifier: targetIdentifier, contextID: contextID))",
            level: .error
        )
        if pendingInspectSelection?.nodeID == nodeID,
           pendingInspectSelection?.contextID == contextID {
            pendingInspectSelection = nil
        }
        await clearSelectionForFailedResolution(
            contextID: contextID,
            transaction: transaction,
            showError: showErrorOnFailure,
            errorMessage: "Failed to resolve selected element."
        )
        throw DOMOperationError.invalidSelection
    }

    private func shouldMaterializeInspectSelection(
        transaction: SelectionTransaction?,
        pendingSelection: PendingInspectSelection?,
        showErrorOnFailure: Bool
    ) -> Bool {
        guard transaction != nil else {
            return true
        }

        switch selectionMaterializationCandidates(for: pendingSelection).strategy {
        case .genericIncomplete:
            return true
        case .frameRelated, .nestedDocumentRoots:
            return showErrorOnFailure == false
        case .body, .html, .structuredChild, .root, .none:
            return false
        }
    }

    @discardableResult
    private func materializePendingInspectSelection(
        nodeID: Int,
        selectorPath: String?,
        contextID: DOMContextID,
        targetIdentifier: String,
        transaction: SelectionTransaction?
    ) async -> PendingInspectMaterializationOutcome {
        guard currentContext?.contextID == contextID,
              selectionTransactionIsCurrent(transaction) else {
            return .exhausted
        }

        switch phase {
        case let .ready(context, activeTargetIdentifier)
            where context.contextID == contextID && activeTargetIdentifier == targetIdentifier:
            break
        case let .loadingDocument(context, _)
            where context.contextID == contextID:
            logSelectionDiagnostics(
                "materializePendingInspectSelection deferred while document is not ready",
                selector: selectorPath,
                extra: "nodeID=\(nodeID) target=\(targetIdentifier) phase=\(String(describing: phase))"
            )
            return .waitingForMutation
        default:
            return .exhausted
        }

        var pendingInspectSelection = upsertPendingInspectSelection(
            nodeID: nodeID,
            contextID: contextID,
            selectorPath: selectorPath,
            resolutionTargetIdentifier: targetIdentifier,
            transaction: transaction
        )

        if pendingInspectSelection.scopedMaterializationRootNodeIDs.isEmpty == false {
            pendingInspectSelection.scopedMaterializationRootNodeIDs = normalizedScopedMaterializationRootNodeIDs(
                for: pendingInspectSelection
            )
        }

        let selectionMaterialization = selectionMaterializationCandidates(
            for: pendingInspectSelection
        )
        if pendingInspectSelection.scopedMaterializationRootNodeIDs.isEmpty,
           selectionMaterialization.strategy == .frameRelated || selectionMaterialization.strategy == .nestedDocumentRoots {
            pendingInspectSelection.scopedMaterializationRootNodeIDs = selectionMaterialization.candidates.map(\.id)
        }

        if shouldPreemptPendingInspectRequests(
            pendingInspectSelection,
            nextPlan: selectionMaterialization
        ) {
            let previousStrategy = pendingInspectSelection.activeMaterializationStrategy
            let staleOutstandingLocalIDs = pendingInspectSelection.outstandingMaterializationNodeIDs
                .map(\.localID)
                .sorted()
            resetPendingInspectMaterializationState(&pendingInspectSelection)
            pendingInspectSelection.scopedMaterializationRootNodeIDs = selectionMaterialization.candidates.map(\.id)
            pendingInspectSelection.activeMaterializationStrategy = selectionMaterialization.strategy
            pendingInspectSelection.activeRequestGeneration &+= 1
            pendingInspectSelection.observedMaterializationStrategy = selectionMaterialization.strategy
            pendingInspectSelection.observedMaterializationCandidateNodeIDs = selectionMaterialization.candidateNodeIDs
            self.pendingInspectSelection = pendingInspectSelection
            logSelectionDiagnostics(
                "pending inspect strategy transitioned",
                selector: selectorPath,
                extra: "nodeID=\(nodeID) target=\(targetIdentifier) from=\(previousStrategy.rawValue) to=\(selectionMaterialization.strategy.rawValue) staleOutstanding=\(staleOutstandingLocalIDs) scopedRoots=\(pendingInspectSelection.scopedMaterializationRootNodeIDs.map(\.localID))",
                level: .debug
            )
        }

        if shouldDeferGenericDispatch(
            pendingInspectSelection,
            plan: selectionMaterialization
        ) {
            pendingInspectSelection.activeMaterializationStrategy = .frameRelated
            pendingInspectSelection.activeRequestGeneration &+= 1
            pendingInspectSelection.genericDispatchDeferralCount &+= 1
            pendingInspectSelection.observedMaterializationStrategy = selectionMaterialization.strategy
            pendingInspectSelection.observedMaterializationCandidateNodeIDs = selectionMaterialization.candidateNodeIDs
            self.pendingInspectSelection = pendingInspectSelection
            logSelectionDiagnostics(
                "materializePendingInspectSelection deferred generic dispatch while awaiting frame-related candidates",
                selector: selectorPath,
                extra: "nodeID=\(nodeID) target=\(targetIdentifier) frameOwnerCount=\(selectionMaterialization.frameOwnerCandidates.count) genericCount=\(selectionMaterialization.genericIncompleteCandidates.count) deferralCount=\(pendingInspectSelection.genericDispatchDeferralCount)",
                level: .debug
            )
            schedulePendingInspectMaterializationTimeout(for: pendingInspectSelection)
            return .waitingForMutation
        }

        let candidates = selectionMaterialization.candidates
        if candidates.isEmpty {
            pendingInspectSelection.observedMaterializationStrategy = selectionMaterialization.strategy
            pendingInspectSelection.observedMaterializationCandidateNodeIDs = selectionMaterialization.candidateNodeIDs
            self.pendingInspectSelection = pendingInspectSelection
            return .exhausted
        }

        let unresolvedCandidates = candidates.filter {
            pendingInspectSelection.materializedAncestorNodeIDs.contains($0.id) == false
        }
        if unresolvedCandidates.isEmpty {
            pendingInspectSelection.observedMaterializationStrategy = selectionMaterialization.strategy
            pendingInspectSelection.observedMaterializationCandidateNodeIDs = selectionMaterialization.candidateNodeIDs
            self.pendingInspectSelection = pendingInspectSelection
            if selectionMaterialization.strategy == .genericIncomplete,
               pendingInspectSelection.outstandingMaterializationNodeIDs.isEmpty {
                logSelectionDiagnostics(
                    "materializePendingInspectSelection waiting after generic candidate completion",
                    selector: selectorPath,
                    extra: "nodeID=\(nodeID) target=\(targetIdentifier) plan=\(selectionMaterializationPlanSummary(selectionMaterialization)) pendingInspect=\(pendingInspectSelectionDiagnosticSummary(pendingInspectSelection))",
                    level: .debug
                )
                schedulePendingInspectMaterializationTimeout(for: pendingInspectSelection)
                return .waitingForMutation
            }
            return pendingInspectSelection.outstandingMaterializationNodeIDs.isEmpty ? .exhausted : .requested
        }

        let requestableCandidates = unresolvedCandidates.filter(\.hasUnloadedRegularChildren)
        let requestableCandidateIDs = Set(requestableCandidates.map(\.id))
        if pendingInspectSelection.activeMaterializationStrategy != selectionMaterialization.strategy
            || pendingInspectSelection.outstandingMaterializationNodeIDs.isEmpty {
            pendingInspectSelection.activeRequestGeneration &+= 1
        }
        pendingInspectSelection.activeMaterializationStrategy = selectionMaterialization.strategy
        pendingInspectSelection.materializedAncestorNodeIDs.formUnion(requestableCandidateIDs)
        pendingInspectSelection.outstandingMaterializationNodeIDs.formUnion(requestableCandidateIDs)
        pendingInspectSelection.observedMaterializationStrategy = selectionMaterialization.strategy
        pendingInspectSelection.observedMaterializationCandidateNodeIDs = selectionMaterialization.candidateNodeIDs
        self.pendingInspectSelection = pendingInspectSelection

        guard requestableCandidates.isEmpty == false else {
            let exhaustedCandidateNodeIDs = selectionMaterialization.candidateNodeIDs
            let repeatedScopedExhaustion = pendingInspectSelection.lastExhaustedScopedStrategy == selectionMaterialization.strategy
                && pendingInspectSelection.lastExhaustedScopedCandidateNodeIDs == exhaustedCandidateNodeIDs
            pendingInspectSelection.lastExhaustedScopedStrategy = selectionMaterialization.strategy
            pendingInspectSelection.lastExhaustedScopedCandidateNodeIDs = exhaustedCandidateNodeIDs
            self.pendingInspectSelection = pendingInspectSelection

            guard repeatedScopedExhaustion == false else {
                return .waitingForMutation
            }

            logSelectionDiagnostics(
                "materializePendingInspectSelection skipped fully loaded candidates",
                selector: selectorPath,
                extra: "nodeID=\(nodeID) target=\(targetIdentifier) plan=\(selectionMaterializationPlanSummary(selectionMaterialization)) skippedCandidates=\(nodeSummaryList(unresolvedCandidates)) pendingInspect=\(pendingInspectSelectionDiagnosticSummary(pendingInspectSelection))",
                level: .debug
            )
            schedulePendingInspectMaterializationTimeout(for: pendingInspectSelection)
            return .waitingForMutation
        }

        pendingInspectSelection.lastExhaustedScopedStrategy = nil
        pendingInspectSelection.lastExhaustedScopedCandidateNodeIDs.removeAll(keepingCapacity: true)
        var requestedNodes = 0
        for candidate in requestableCandidates {
            guard currentContext?.contextID == contextID,
                  selectionTransactionIsCurrent(transaction) else {
                return pendingInspectSelection.outstandingMaterializationNodeIDs.isEmpty ? .exhausted : .requested
            }
            guard let transportNodeID = try? transportNodeID(for: candidate) else {
                pendingInspectSelection.materializedAncestorNodeIDs.remove(candidate.id)
                pendingInspectSelection.outstandingMaterializationNodeIDs.remove(candidate.id)
                self.pendingInspectSelection = pendingInspectSelection
                continue
            }
            do {
                _ = try await sendDOMCommand(
                    WITransportMethod.DOM.requestChildNodes,
                    targetIdentifier: targetIdentifier,
                    parameters: DOMRequestChildNodesParameters(
                        nodeId: transportNodeID,
                        depth: max(configuration.snapshotDepth, 128)
                    )
                )
                requestedNodes += 1
            } catch {
                pendingInspectSelection.materializedAncestorNodeIDs.remove(candidate.id)
                pendingInspectSelection.outstandingMaterializationNodeIDs.remove(candidate.id)
                self.pendingInspectSelection = pendingInspectSelection
                logSelectionDiagnostics(
                    "materializePendingInspectSelection requestChildNodes failed",
                    extra: "nodeID=\(transportNodeID) error=\(error.localizedDescription)",
                    level: .error
                )
            }
        }
        self.pendingInspectSelection = pendingInspectSelection
        logSelectionDiagnostics(
            "materializePendingInspectSelection requested child nodes",
            selector: selectorPath,
            extra: "nodeID=\(nodeID) target=\(targetIdentifier) plan=\(selectionMaterializationPlanSummary(selectionMaterialization)) requestedCandidates=\(nodeSummaryList(requestableCandidates)) requestedNodes=\(requestedNodes) pendingInspect=\(pendingInspectSelectionDiagnosticSummary(pendingInspectSelection)) pendingChildRequests=\(pendingChildRequestDiagnosticsSummary())",
            level: .debug
        )
        if !pendingInspectSelection.outstandingMaterializationNodeIDs.isEmpty {
            schedulePendingInspectMaterializationTimeout(for: pendingInspectSelection)
            return .requested
        }
        return .exhausted
    }

    private func normalizedScopedMaterializationRootNodeIDs(
        for pendingSelection: PendingInspectSelection
    ) -> [DOMNodeModel.ID] {
        var seen = Set<DOMNodeModel.ID>()
        return pendingSelection.scopedMaterializationRootNodeIDs.filter { nodeID in
            guard document.node(localID: nodeID.localID) != nil else {
                return false
            }
            return seen.insert(nodeID).inserted
        }
    }

    private func materializationTraversalRoots(
        for pendingSelection: PendingInspectSelection?
    ) -> [DOMNodeModel] {
        if let pendingSelection {
            let scopedRootNodeIDs = normalizedScopedMaterializationRootNodeIDs(
                for: pendingSelection
            )
            let scopedRoots = scopedRootNodeIDs.compactMap { scopedRootNodeID in
                document.node(localID: scopedRootNodeID.localID)
            }
            if scopedRoots.isEmpty == false {
                return scopedRoots
            }
        }

        guard let root = document.rootNode else {
            return []
        }
        return [root]
    }

    private func selectionMaterializationCandidates(
        for pendingSelection: PendingInspectSelection? = nil
    ) -> SelectionMaterializationPlan {
        let traversalRoots = materializationTraversalRoots(for: pendingSelection)
        guard traversalRoots.isEmpty == false else {
            return SelectionMaterializationPlan(
                strategy: .none,
                candidates: [],
                frameOwnerCandidates: [],
                frameDocumentCandidates: [],
                canonicalEmbeddedCandidates: [],
                genericIncompleteCandidates: []
            )
        }

        let traversalRootIDs = Set(traversalRoots.map(\.id))
        var queue: [DOMNodeModel] = traversalRoots
        var traversal: [DOMNodeModel] = []
        var visited = Set<DOMNodeModel.ID>()

        while !queue.isEmpty {
            let node = queue.removeFirst()
            guard visited.insert(node.id).inserted else {
                continue
            }
            traversal.append(node)
            queue.append(contentsOf: node.visibleDOMTreeChildren)
        }

        let frameDocumentCandidates = traversal.filter { node in
            node.hasUnloadedRegularChildren
                && isFrameDocumentCandidate(node)
        }
        let frameOwnerCandidates = traversal.filter { node in
            traversalRootIDs.contains(node.id) == false
                && node.hasUnloadedRegularChildren
                && isFrameOwnerNode(node)
        }
        let canonicalEmbeddedCandidates = traversal.filter { node in
            traversalRootIDs.contains(node.id) == false
                && isFrameOwnerNode(node) == false
                && node.hasUnloadedRegularChildren
                && nodeIsInsideEmbeddedDocument(node)
                && isFrameDocumentCandidate(node) == false
        }
        let requestableFrameCandidates = uniqueNodes(
            preservingOrder: frameDocumentCandidates + canonicalEmbeddedCandidates
        )
        let frameAssociatedCandidates = uniqueNodes(
            preservingOrder: frameOwnerCandidates + frameDocumentCandidates + canonicalEmbeddedCandidates
        )
        let genericIncompleteCandidates = traversal.filter { node in
            traversalRootIDs.contains(node.id) == false
                && node.hasUnloadedRegularChildren
                && frameAssociatedCandidates.contains(where: { $0.id == node.id }) == false
        }

        if requestableFrameCandidates.isEmpty == false {
            return SelectionMaterializationPlan(
                strategy: .frameRelated,
                candidates: requestableFrameCandidates,
                frameOwnerCandidates: frameOwnerCandidates,
                frameDocumentCandidates: frameDocumentCandidates,
                canonicalEmbeddedCandidates: canonicalEmbeddedCandidates,
                genericIncompleteCandidates: genericIncompleteCandidates
            )
        }

        let nestedDocumentRootsSource: [DOMNodeModel]
        if let pendingSelection,
           pendingSelection.scopedMaterializationRootNodeIDs.isEmpty == false {
            nestedDocumentRootsSource = traversal
        } else {
            nestedDocumentRootsSource = knownDocumentRoots()
        }
        let nestedDocumentRoots = uniqueNodes(
            preservingOrder: nestedDocumentRootsSource.filter {
                isDocumentNode($0)
                    && traversalRootIDs.contains($0.id) == false
                    && ($0.hasUnloadedRegularChildren || !$0.children.isEmpty)
            }
        )
        if nestedDocumentRoots.isEmpty == false {
            return SelectionMaterializationPlan(
                strategy: .nestedDocumentRoots,
                candidates: nestedDocumentRoots,
                frameOwnerCandidates: frameOwnerCandidates,
                frameDocumentCandidates: frameDocumentCandidates,
                canonicalEmbeddedCandidates: canonicalEmbeddedCandidates,
                genericIncompleteCandidates: genericIncompleteCandidates
            )
        }

        if genericIncompleteCandidates.isEmpty == false {
            return SelectionMaterializationPlan(
                strategy: .genericIncomplete,
                candidates: genericIncompleteCandidates,
                frameOwnerCandidates: frameOwnerCandidates,
                frameDocumentCandidates: frameDocumentCandidates,
                canonicalEmbeddedCandidates: canonicalEmbeddedCandidates,
                genericIncompleteCandidates: genericIncompleteCandidates
            )
        }

        if let bodyNode = traversal.first(where: {
            ($0.localName.isEmpty ? $0.nodeName.lowercased() : $0.localName.lowercased()) == "body"
        }) {
            return SelectionMaterializationPlan(
                strategy: .body,
                candidates: [bodyNode],
                frameOwnerCandidates: frameOwnerCandidates,
                frameDocumentCandidates: frameDocumentCandidates,
                canonicalEmbeddedCandidates: canonicalEmbeddedCandidates,
                genericIncompleteCandidates: genericIncompleteCandidates
            )
        }

        if let htmlNode = traversal.first(where: {
            ($0.localName.isEmpty ? $0.nodeName.lowercased() : $0.localName.lowercased()) == "html"
        }) {
            return SelectionMaterializationPlan(
                strategy: .html,
                candidates: [htmlNode],
                frameOwnerCandidates: frameOwnerCandidates,
                frameDocumentCandidates: frameDocumentCandidates,
                canonicalEmbeddedCandidates: canonicalEmbeddedCandidates,
                genericIncompleteCandidates: genericIncompleteCandidates
            )
        }

        if let firstStructuredChild = traversal.first(where: {
            let name = ($0.localName.isEmpty ? $0.nodeName : $0.localName).lowercased()
            return !name.isEmpty && !name.hasPrefix("#")
        }) {
            return SelectionMaterializationPlan(
                strategy: .structuredChild,
                candidates: [firstStructuredChild],
                frameOwnerCandidates: frameOwnerCandidates,
                frameDocumentCandidates: frameDocumentCandidates,
                canonicalEmbeddedCandidates: canonicalEmbeddedCandidates,
                genericIncompleteCandidates: genericIncompleteCandidates
            )
        }

        return SelectionMaterializationPlan(
            strategy: .root,
            candidates: traversalRoots,
            frameOwnerCandidates: frameOwnerCandidates,
            frameDocumentCandidates: frameDocumentCandidates,
            canonicalEmbeddedCandidates: canonicalEmbeddedCandidates,
            genericIncompleteCandidates: genericIncompleteCandidates
        )
    }

    private func inferredNodeType(for node: DOMNodeModel) -> DOMNodeType {
        if node.nodeType != .unknown {
            return node.nodeType
        }

        switch nodeNameForMatching(node) {
        case "#document":
            return .document
        case "!doctype", "#doctype":
            return .documentType
        case "#text":
            return .text
        case "#comment":
            return .comment
        case "#cdata-section":
            return .cdataSection
        case "#document-fragment", "#shadow-root":
            return .documentFragment
        case let name where !name.isEmpty && !name.hasPrefix("#"):
            return .element
        default:
            return .unknown
        }
    }

    private func nodeNameForMatching(_ node: DOMNodeModel) -> String {
        (node.localName.isEmpty ? node.nodeName : node.localName).lowercased()
    }

    private func isDocumentNode(_ node: DOMNodeModel) -> Bool {
        inferredNodeType(for: node) == .document
    }

    private func isFrameDocumentCandidate(_ node: DOMNodeModel) -> Bool {
        guard isDocumentNode(node) else {
            return false
        }
        if node.frameID != nil {
            return true
        }
        if let parent = node.parent {
            return isFrameOwnerNode(parent)
        }
        return false
    }

    private func isFrameOwnerNode(_ node: DOMNodeModel) -> Bool {
        guard inferredNodeType(for: node) == .element else {
            return false
        }
        let nodeName = nodeNameForMatching(node)
        return nodeName == "iframe" || nodeName == "frame"
    }

    private func attributeValue(
        named name: String,
        for node: DOMNodeModel
    ) -> String? {
        node.attributes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private func isAuxiliaryFrameOwner(_ node: DOMNodeModel) -> Bool {
        guard isFrameOwnerNode(node) else {
            return false
        }

        let name = attributeValue(named: "name", for: node)?.lowercased() ?? ""
        let id = attributeValue(named: "id", for: node)?.lowercased() ?? ""
        let src = attributeValue(named: "src", for: node)?.lowercased() ?? ""

        let utilityIdentifiers = [
            "__uspapilocator",
            "__gpplocator",
            "googlefcpresent",
            "googlefcinactive",
            "googlefcloaded",
            "__pb_locator__",
        ]
        if utilityIdentifiers.contains(name) || utilityIdentifiers.contains(id) {
            return true
        }

        if (name.hasPrefix("__") || id.hasPrefix("__")),
           src == "about:blank" {
            return true
        }

        if src.contains("google.com/recaptcha")
            || src.contains("google.com/recap") {
            return true
        }

        return false
    }

    private func frameIDForSelectionFallback(_ node: DOMNodeModel) -> String? {
        if let frameID = node.frameID, !frameID.isEmpty {
            return frameID
        }
        if isDocumentNode(node),
           let parent = node.parent,
           isFrameOwnerNode(parent),
           let frameID = parent.frameID,
           !frameID.isEmpty {
            return frameID
        }
        if isFrameOwnerNode(node),
           let documentChild = node.contentDocument,
           let frameID = documentChild.frameID,
           !frameID.isEmpty {
            return frameID
        }
        return nil
    }

    private func documentBackedFrameIDs(
        from selectionMaterialization: SelectionMaterializationPlan
    ) -> Set<String> {
        var frameIDs = Set<String>()

        for node in selectionMaterialization.frameDocumentCandidates {
            if let frameID = frameIDForSelectionFallback(node) {
                frameIDs.insert(frameID)
            }
        }
        for node in selectionMaterialization.frameOwnerCandidates where node.contentDocument != nil {
            if let frameID = frameIDForSelectionFallback(node) {
                frameIDs.insert(frameID)
            }
        }

        return frameIDs
    }

    private func resolveFrameOwnerNode(for frameID: String) -> DOMNodeModel? {
        if let nestedDocument = canonicalNestedDocumentNode(for: frameID),
           let parent = nestedDocument.parent,
           isFrameOwnerNode(parent),
           isAuxiliaryFrameOwner(parent) == false {
            return parent
        }

        return firstNode(in: document.rootNode) { node in
            isFrameOwnerNode(node) && node.frameID == frameID && isAuxiliaryFrameOwner(node) == false
        }
    }

    private func documentBackedFrameOwnerFallbackCandidates(
        for pendingSelection: PendingInspectSelection
    ) -> [DOMNodeModel] {
        let completedMaterializedNodeIDs = pendingSelection.materializedAncestorNodeIDs
            .subtracting(pendingSelection.outstandingMaterializationNodeIDs)
        let candidateNodes = completedMaterializedNodeIDs.compactMap {
            document.node(localID: $0.localID)
        }

        let currentOwners = uniqueNodes(
            preservingOrder: candidateNodes.compactMap { candidate in
                if isFrameOwnerNode(candidate),
                   isAuxiliaryFrameOwner(candidate) == false,
                   candidate.contentDocument != nil {
                    return candidate
                }
                guard isDocumentNode(candidate) else {
                    return nil
                }
                if let parent = candidate.parent, isFrameOwnerNode(parent) {
                    guard isAuxiliaryFrameOwner(parent) == false else {
                        return nil
                    }
                    return parent
                }
                if let frameID = candidate.frameID,
                   let owner = resolveFrameOwnerNode(for: frameID) {
                    return owner
                }
                return nil
            }
        )

        let observedOwners: [DOMNodeModel]
        if pendingSelection.outstandingMaterializationNodeIDs.isEmpty {
            observedOwners = uniqueNodes(
                preservingOrder: pendingSelection.observedDocumentBackedFrameIDs
                    .sorted()
                    .compactMap(resolveFrameOwnerNode(for:))
            )
        } else {
            observedOwners = []
        }

        return uniqueNodes(
            preservingOrder: currentOwners + observedOwners
        )
    }

    private func frameOwnerFallbackCandidates(
        for pendingSelection: PendingInspectSelection
    ) -> [DOMNodeModel] {
        let candidateNodes = pendingSelection.materializedAncestorNodeIDs.compactMap {
            document.node(localID: $0.localID)
        }
        let documentDerivedOwners = documentBackedFrameOwnerFallbackCandidates(for: pendingSelection)
        if documentDerivedOwners.isEmpty == false {
            return documentDerivedOwners
        }

        return uniqueNodes(
            preservingOrder: candidateNodes.compactMap { candidate in
                isFrameOwnerNode(candidate) && isAuxiliaryFrameOwner(candidate) == false ? candidate : nil
            }
        )
    }

    @discardableResult
    private func applyFrameOwnerFallbackSelectionIfPossible(
        for pendingSelection: PendingInspectSelection,
        allowDirectOwnerFallback: Bool = true
    ) async -> Bool {
        let frameOwnerCandidates = allowDirectOwnerFallback
            ? frameOwnerFallbackCandidates(for: pendingSelection)
            : documentBackedFrameOwnerFallbackCandidates(for: pendingSelection)
        guard frameOwnerCandidates.count == 1,
              let frameOwner = frameOwnerCandidates.first else {
            if frameOwnerCandidates.isEmpty == false {
                logSelectionDiagnostics(
                    "applyFrameOwnerFallbackSelectionIfPossible skipped ambiguous frame owner fallback",
                    selector: pendingSelection.selectorPath,
                    extra: "nodeID=\(pendingSelection.nodeID) frameOwnerCandidates=\(frameOwnerCandidates.map { selectionNodeSummary($0) }.joined(separator: ",")) target=\(pendingSelection.resolutionTargetIdentifier)",
                    level: .debug
                )
            }
            return false
        }

        logSelectionDiagnostics(
            "applyFrameOwnerFallbackSelectionIfPossible selected frame owner fallback",
            selector: pendingSelection.selectorPath,
            extra: "nodeID=\(pendingSelection.nodeID) frameOwner=\(selectionNodeSummary(frameOwner)) target=\(pendingSelection.resolutionTargetIdentifier)",
            level: .debug
        )

        await applySelection(
            to: frameOwner,
            selectorPath: pendingSelection.selectorPath,
            contextID: pendingSelection.contextID,
            targetIdentifierForMaterialization: pendingSelection.resolutionTargetIdentifier
        )
        finishInspectSelectionResolution(transaction: pendingSelection.transaction)
        applyRecoverableError(nil)
        return true
    }

    private func uniqueNodes(preservingOrder nodes: [DOMNodeModel]) -> [DOMNodeModel] {
        var seen = Set<DOMNodeModel.ID>()
        var unique: [DOMNodeModel] = []

        for node in nodes where seen.insert(node.id).inserted {
            unique.append(node)
        }

        return unique
    }

    private func selectionMaterializationCountsSummary(_ plan: SelectionMaterializationPlan) -> String {
        "requestCount=\(plan.candidates.count) frameOwnerCount=\(plan.frameOwnerCandidates.count) frameDocumentCount=\(plan.frameDocumentCandidates.count) canonicalEmbeddedCount=\(plan.canonicalEmbeddedCandidates.count) genericCount=\(plan.genericIncompleteCandidates.count)"
    }

    private func resetPendingInspectMaterializationState(
        _ pendingSelection: inout PendingInspectSelection
    ) {
        pendingSelection.materializedAncestorNodeIDs.removeAll(keepingCapacity: true)
        pendingSelection.outstandingMaterializationNodeIDs.removeAll(keepingCapacity: true)
        pendingSelection.activeMaterializationStrategy = .none
        pendingSelection.lastExhaustedScopedCandidateNodeIDs.removeAll(keepingCapacity: true)
        pendingSelection.lastExhaustedScopedStrategy = nil
    }

    private func materializationStrategyPriority(
        _ strategy: SelectionMaterializationStrategy
    ) -> Int {
        switch strategy {
        case .frameRelated:
            7
        case .nestedDocumentRoots:
            6
        case .genericIncomplete:
            5
        case .body:
            4
        case .html:
            3
        case .structuredChild:
            2
        case .root:
            1
        case .none:
            0
        }
    }

    private func shouldPreemptPendingInspectRequests(
        _ pendingSelection: PendingInspectSelection,
        nextPlan: SelectionMaterializationPlan
    ) -> Bool {
        guard pendingSelection.outstandingMaterializationNodeIDs.isEmpty == false else {
            return false
        }
        guard nextPlan.strategy == .frameRelated else {
            return false
        }
        return materializationStrategyPriority(nextPlan.strategy)
            > materializationStrategyPriority(pendingSelection.activeMaterializationStrategy)
    }

    private func shouldDeferGenericDispatch(
        _ pendingSelection: PendingInspectSelection,
        plan: SelectionMaterializationPlan
    ) -> Bool {
        guard plan.strategy == .genericIncomplete else {
            return false
        }
        guard plan.frameOwnerCandidates.isEmpty == false else {
            return false
        }
        return pendingSelection.genericDispatchDeferralCount < 2
    }

    private func normalizeTrackedMaterializationNodeIDs(
        _ nodeIDs: Set<DOMNodeModel.ID>
    ) -> Set<DOMNodeModel.ID> {
        Set(
            nodeIDs.filter { nodeID in
                document.node(localID: nodeID.localID) != nil
            }
        )
    }

    private func normalizePendingInspectSelectionState(
        _ pendingSelection: inout PendingInspectSelection
    ) -> Bool {
        var didChange = false

        let normalizedScopedRoots = normalizedScopedMaterializationRootNodeIDs(
            for: pendingSelection
        )
        if normalizedScopedRoots != pendingSelection.scopedMaterializationRootNodeIDs {
            pendingSelection.scopedMaterializationRootNodeIDs = normalizedScopedRoots
            didChange = true
        }

        var normalizedMaterializedNodeIDs = normalizeTrackedMaterializationNodeIDs(
            pendingSelection.materializedAncestorNodeIDs
        )
        let normalizedOutstandingNodeIDs = normalizeTrackedMaterializationNodeIDs(
            pendingSelection.outstandingMaterializationNodeIDs
        )
        normalizedMaterializedNodeIDs.formUnion(normalizedOutstandingNodeIDs)

        if normalizedMaterializedNodeIDs != pendingSelection.materializedAncestorNodeIDs {
            pendingSelection.materializedAncestorNodeIDs = normalizedMaterializedNodeIDs
            didChange = true
        }

        if normalizedOutstandingNodeIDs != pendingSelection.outstandingMaterializationNodeIDs {
            pendingSelection.outstandingMaterializationNodeIDs = normalizedOutstandingNodeIDs
            didChange = true
        }

        if didChange {
            pendingSelection.lastExhaustedScopedCandidateNodeIDs.removeAll(keepingCapacity: true)
            pendingSelection.lastExhaustedScopedStrategy = nil
        }

        return didChange
    }

    private func markPendingInspectProgress(
        _ pendingSelection: inout PendingInspectSelection,
        reason: String,
        selectionMaterialization: SelectionMaterializationPlan? = nil,
        extra: String = ""
    ) {
        pendingSelection.progressRevision &+= 1
        if let selectionMaterialization {
            pendingSelection.observedMaterializationStrategy = selectionMaterialization.strategy
            pendingSelection.observedMaterializationCandidateNodeIDs = selectionMaterialization.candidateNodeIDs
            pendingSelection.observedDocumentBackedFrameIDs.formUnion(
                documentBackedFrameIDs(from: selectionMaterialization)
            )
        }
        pendingSelection.lastExhaustedScopedCandidateNodeIDs.removeAll(keepingCapacity: true)
        pendingSelection.lastExhaustedScopedStrategy = nil
        self.pendingInspectSelection = pendingSelection

        let countsSummary = selectionMaterialization.map(selectionMaterializationCountsSummary(_:)) ?? ""
        let extraParts = [countsSummary, extra]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        logSelectionDiagnostics(
            "pending inspect progress observed",
            selector: pendingSelection.selectorPath,
            extra: "reason=\(reason) nodeID=\(pendingSelection.nodeID) strategy=\(pendingSelection.observedMaterializationStrategy.rawValue) progressRevision=\(pendingSelection.progressRevision) outstanding=\(pendingSelection.outstandingMaterializationNodeIDs.map { $0.localID }.sorted()) \(extraParts)",
            level: .debug
        )

        if !pendingSelection.outstandingMaterializationNodeIDs.isEmpty {
            schedulePendingInspectMaterializationTimeout(for: pendingSelection)
        }
    }

    private func bundleTouchedNodeIDs(
        from bundle: DOMGraphMutationBundle
    ) -> Set<DOMNodeModel.ID> {
        var touchedNodeIDs = Set<DOMNodeModel.ID>()
        let documentIdentity = document.documentIdentity

        func insert(_ localID: UInt64) {
            touchedNodeIDs.insert(.init(documentIdentity: documentIdentity, localID: localID))
        }

        for event in bundle.events {
            switch event {
            case let .childNodeInserted(parentLocalID, _, node):
                insert(parentLocalID)
                insert(node.localID)
            case let .childNodeRemoved(parentLocalID, nodeLocalID):
                insert(parentLocalID)
                insert(nodeLocalID)
            case let .shadowRootPushed(hostLocalID, root):
                insert(hostLocalID)
                insert(root.localID)
            case let .shadowRootPopped(hostLocalID, rootLocalID):
                insert(hostLocalID)
                insert(rootLocalID)
            case let .pseudoElementAdded(parentLocalID, node):
                insert(parentLocalID)
                insert(node.localID)
            case let .pseudoElementRemoved(parentLocalID, nodeLocalID):
                insert(parentLocalID)
                insert(nodeLocalID)
            case let .setDetachedRoots(nodes):
                for node in nodes {
                    insert(node.localID)
                }
            case let .attributeModified(nodeLocalID, _, _, _, _),
                 let .attributeRemoved(nodeLocalID, _, _, _),
                 let .characterDataModified(nodeLocalID, _, _, _),
                 let .childNodeCountUpdated(nodeLocalID, _, _, _),
                 let .setChildNodes(nodeLocalID, _):
                insert(nodeLocalID)
            case let .replaceSubtree(root):
                insert(root.localID)
            case .documentUpdated:
                break
            }
        }

        return touchedNodeIDs
    }

    private func recordPendingInspectProgressIfNeeded(
        from bundle: DOMGraphMutationBundle,
        contextID: DOMContextID,
        reason: String,
        rejectedStructuralMutationParentLocalIDs: Set<UInt64>
    ) {
        guard var pendingInspectSelection,
              pendingInspectSelection.contextID == contextID,
              selectionTransactionIsCurrent(pendingInspectSelection.transaction) else {
            return
        }

        let didNormalizeState = normalizePendingInspectSelectionState(
            &pendingInspectSelection
        )
        if didNormalizeState {
            self.pendingInspectSelection = pendingInspectSelection
        }

        let completedOutstandingNodeIDs = Set(
            completedChildRequestNodeIDs(
                from: bundle,
                rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
            ).map {
                DOMNodeModel.ID(documentIdentity: document.documentIdentity, localID: UInt64($0))
            }
        ).intersection(pendingInspectSelection.outstandingMaterializationNodeIDs)
        guard completedOutstandingNodeIDs.isEmpty else {
            return
        }

        let selectionMaterialization = selectionMaterializationCandidates(
            for: pendingInspectSelection
        )
        if shouldPreemptPendingInspectRequests(
            pendingInspectSelection,
            nextPlan: selectionMaterialization
        ) {
            let previousStrategy = pendingInspectSelection.activeMaterializationStrategy
            let staleOutstandingLocalIDs = pendingInspectSelection.outstandingMaterializationNodeIDs
                .map(\.localID)
                .sorted()
            resetPendingInspectMaterializationState(&pendingInspectSelection)
            pendingInspectSelection.scopedMaterializationRootNodeIDs = selectionMaterialization.candidates.map(\.id)
            pendingInspectSelection.activeMaterializationStrategy = selectionMaterialization.strategy
            pendingInspectSelection.activeRequestGeneration &+= 1
            markPendingInspectProgress(
                &pendingInspectSelection,
                reason: "strategy.preempted",
                selectionMaterialization: selectionMaterialization,
                extra: "from=\(previousStrategy.rawValue) staleOutstanding=\(staleOutstandingLocalIDs) scopedRoots=\(pendingInspectSelection.scopedMaterializationRootNodeIDs.map(\.localID))"
            )
            return
        }

        let touchedNodeIDs = bundleTouchedNodeIDs(from: bundle)
        let didObserveCandidateChange =
            selectionMaterialization.strategy != pendingInspectSelection.observedMaterializationStrategy
            || selectionMaterialization.candidateNodeIDs != pendingInspectSelection.observedMaterializationCandidateNodeIDs

        guard didNormalizeState || didObserveCandidateChange else {
            return
        }

        markPendingInspectProgress(
            &pendingInspectSelection,
            reason: reason,
            selectionMaterialization: selectionMaterialization,
            extra: "normalized=\(didNormalizeState) touched=\(touchedNodeIDs.map { $0.localID }.sorted())"
        )
    }

    private func restartPendingInspectMaterializationAfterRefresh(
        _ pendingSelection: PendingInspectSelection,
        reason: String
    ) async -> PendingInspectMaterializationOutcome {
        guard var refreshedPendingSelection = self.pendingInspectSelection,
              refreshedPendingSelection == pendingSelection,
              selectionTransactionIsCurrent(refreshedPendingSelection.transaction) else {
            return .exhausted
        }

        resetPendingInspectMaterializationState(&refreshedPendingSelection)
        markPendingInspectProgress(
            &refreshedPendingSelection,
            reason: reason,
            selectionMaterialization: selectionMaterializationCandidates(
                for: refreshedPendingSelection
            )
        )

        return await materializePendingInspectSelection(
            nodeID: refreshedPendingSelection.nodeID,
            selectorPath: refreshedPendingSelection.selectorPath,
            contextID: refreshedPendingSelection.contextID,
            targetIdentifier: refreshedPendingSelection.resolutionTargetIdentifier,
            transaction: refreshedPendingSelection.transaction
        )
    }

    private func recoverPendingInspectSelectionAfterMirrorInvariantViolation(
        _ pendingSelection: PendingInspectSelection,
        targetIdentifier: String,
        reason: String
    ) async -> Bool {
        guard let currentPendingSelection = pendingInspectSelection,
              currentPendingSelection == pendingSelection,
              selectionTransactionIsCurrent(currentPendingSelection.transaction) else {
            return false
        }

        let didRefresh = await refreshSelectionSubtreeFromTransportIfNeeded(
            selectorPath: currentPendingSelection.selectorPath,
            contextID: currentPendingSelection.contextID,
            targetIdentifier: currentPendingSelection.resolutionTargetIdentifier
        )

        logSelectionDiagnostics(
            "pending inspect invariant refresh finished",
            selector: currentPendingSelection.selectorPath,
            extra: "reason=\(reason) target=\(targetIdentifier) didRefresh=\(didRefresh) currentSelection=\(selectionNodeSummary(document.selectedNode))",
            level: .debug
        )

        await applyPendingInspectSelectionIfPossible()

        if pendingInspectSelection == nil {
            return true
        }

        if didRefresh {
            let materializationOutcome = await restartPendingInspectMaterializationAfterRefresh(
                currentPendingSelection,
                reason: "invariant.refresh"
            )
            if materializationOutcome != .exhausted {
                return true
            }
        }

        return false
    }

    private func knownDocumentRoots() -> [DOMNodeModel] {
        guard let rootNode = document.rootNode else {
            return []
        }

        var roots: [DOMNodeModel] = []
        var seen = Set<DOMNodeModel.ID>()
        var queue: [DOMNodeModel] = [rootNode]

        while let node = queue.first {
            queue.removeFirst()
            if isDocumentNode(node), seen.insert(node.id).inserted {
                roots.append(node)
            }
            queue.append(contentsOf: node.visibleDOMTreeChildren)
        }

        return roots
    }

    private func shouldMergeTargetDocumentForInspectSelection(
        targetIdentifier: String
    ) -> Bool {
        sharedTransport.targetKind(for: targetIdentifier) == .frame
            || targetIdentifier != phase.targetIdentifier
    }

    private func allowsInspectSelectionMaterialization(
        targetIdentifier: String
    ) -> Bool {
        sharedTransport.targetKind(for: targetIdentifier) != .frame
            && targetIdentifier == phase.targetIdentifier
    }

    private func mergeFrameTargetDocumentIfNeeded(
        targetIdentifier: String,
        contextID: DOMContextID,
        transaction: SelectionTransaction?
    ) async -> Bool {
        guard currentContext?.contextID == contextID,
              selectionTransactionIsCurrent(transaction),
              shouldMergeTargetDocumentForInspectSelection(targetIdentifier: targetIdentifier) else {
            return false
        }

        let snapshot: DOMGraphSnapshot
        do {
            snapshot = try await loadDocumentSnapshot(targetIdentifier: targetIdentifier)
        } catch {
            logSelectionDiagnostics(
                "mergeFrameTargetDocumentIfNeeded failed to load frame document",
                extra: "target=\(targetIdentifier) error=\(error.localizedDescription)",
                level: .error
            )
            return false
        }

        guard let nestedDocument = canonicalNestedDocumentNode(for: snapshot.root.frameID) else {
            logSelectionDiagnostics(
                "mergeFrameTargetDocumentIfNeeded missing canonical frame owner",
                extra: "target=\(targetIdentifier) frameID=\(snapshot.root.frameID ?? "nil")",
                level: .error
            )
            return false
        }

        var replacementRoot = snapshot.root
        replacementRoot.localID = nestedDocument.localID
        if replacementRoot.backendNodeID == nil {
            replacementRoot.backendNodeID = nestedDocument.backendNodeID
            replacementRoot.backendNodeIDIsStable = nestedDocument.backendNodeIDIsStable
        }
        replacementRoot.frameID = nestedDocument.frameID ?? replacementRoot.frameID
        replacementRoot.childCount = max(replacementRoot.childCount, replacementRoot.regularChildren.count)
        document.applyMutationBundle(
            .init(events: [.replaceSubtree(root: replacementRoot)])
        )
        logSelectionDiagnostics(
            "mergeFrameTargetDocumentIfNeeded merged frame document",
            extra: "target=\(targetIdentifier) frameID=\(replacementRoot.frameID ?? "nil") canonicalRoot=\(selectionNodeSummary(document.node(localID: replacementRoot.localID)))"
        )
        return true
    }

    private func loadDocumentSnapshot(targetIdentifier: String) async throws -> DOMGraphSnapshot {
        let responseData = try await loadDocumentResponseData(targetIdentifier: targetIdentifier)
        guard let delta = await payloadNormalizer.normalizeDocumentResponseData(
            responseData,
            resetDocument: false
        ),
        case let .snapshot(snapshot, _) = delta else {
            throw DOMOperationError.scriptFailure("document normalization failed")
        }
        return snapshot
    }

    private func canonicalNestedDocumentNode(for frameID: String?) -> DOMNodeModel? {
        guard let frameID else {
            return nil
        }

        if let nestedDocument = knownDocumentRoots().first(where: {
            $0.parent != nil && $0.frameID == frameID
        }) {
            return nestedDocument
        }

        return firstNode(in: document.rootNode) { node in
            nodeNameForMatching(node) == "iframe" && node.frameID == frameID
        }?.contentDocument
    }

    private func materializeSelectionSubtreeIfNeeded(
        selectorPath: String?,
        contextID: DOMContextID,
        targetIdentifier: String
    ) async {
        var requestedCandidateIDs = Set<DOMNodeModel.ID>()
        var materializedCandidateIDs = Set<DOMNodeModel.ID>()
        var requiresSnapshotFallback = false

        for _ in 0..<3 {
            guard currentContext?.contextID == contextID,
                  let selectedNode = document.selectedNode else {
                return
            }

            let candidates = selectionProjectionMaterializationCandidates(for: selectedNode).filter {
                requestedCandidateIDs.insert($0.id).inserted
            }
            guard !candidates.isEmpty else {
                break
            }

            for candidate in candidates {
                guard let transportNodeID = try? transportNodeID(for: candidate) else {
                    continue
                }

                let didComplete = await requestChildNodesAndWaitForCompletion(
                    transportNodeID: transportNodeID,
                    frontendNodeID: Int(candidate.id.localID),
                    targetIdentifier: targetIdentifier,
                    contextID: contextID,
                    depth: max(configuration.snapshotDepth, 128)
                )
                guard didComplete else {
                    requiresSnapshotFallback = true
                    logSelectionDiagnostics(
                        "materializeSelectionSubtreeIfNeeded child request did not complete",
                        selector: selectorPath,
                        extra: "candidate=\(selectionNodeSummary(candidate)) target=\(targetIdentifier)",
                        level: .debug
                    )
                    continue
                }
                materializedCandidateIDs.insert(candidate.id)
            }
        }

        if requiresSnapshotFallback,
           await refreshSelectionSubtreeFromTransportIfNeeded(
                selectorPath: selectorPath,
                contextID: contextID,
                targetIdentifier: targetIdentifier
           ),
           let selectedNode = document.selectedNode {
            await applySelection(
                to: selectedNode,
                selectorPath: selectorPath,
                contextID: contextID,
                allowPostSelectionMaterialization: false
            )
            return
        }

        guard !materializedCandidateIDs.isEmpty,
              currentContext?.contextID == contextID,
              let selectedNode = document.selectedNode else {
            return
        }

        await applySelection(
            to: selectedNode,
            selectorPath: selectorPath,
            contextID: contextID,
            allowPostSelectionMaterialization: false
        )
    }

    private func refreshSelectionSubtreeFromTransportIfNeeded(
        selectorPath: String?,
        contextID: DOMContextID,
        targetIdentifier: String
    ) async -> Bool {
        guard currentContext?.contextID == contextID else {
            return false
        }

        if shouldMergeTargetDocumentForInspectSelection(targetIdentifier: targetIdentifier) {
            guard await mergeFrameTargetDocumentIfNeeded(
                targetIdentifier: targetIdentifier,
                contextID: contextID,
                transaction: nil
            ) else {
                logSelectionDiagnostics(
                    "refreshSelectionSubtreeFromTransportIfNeeded failed to merge frame document",
                    selector: selectorPath,
                    extra: "target=\(targetIdentifier)",
                    level: .error
                )
                return false
            }
        } else {
            do {
                try await refreshCurrentDocumentFromTransport(
                    contextID: contextID,
                    targetIdentifier: targetIdentifier,
                    depth: max(configuration.snapshotDepth, 128),
                    isFreshDocument: false
                )
            } catch {
                logSelectionDiagnostics(
                    "refreshSelectionSubtreeFromTransportIfNeeded failed",
                    selector: selectorPath,
                    extra: "target=\(targetIdentifier) error=\(error.localizedDescription)",
                    level: .error
                )
                return false
            }
        }

        guard let selectedNode = document.selectedNode else {
            logSelectionDiagnostics(
                "refreshSelectionSubtreeFromTransportIfNeeded did not preserve selection",
                selector: selectorPath,
                extra: "target=\(targetIdentifier)",
                level: .debug
            )
            return false
        }

        logSelectionDiagnostics(
            "refreshSelectionSubtreeFromTransportIfNeeded refreshed selection subtree",
            selector: selectorPath,
            extra: "target=\(targetIdentifier) selected=\(selectionNodeSummary(selectedNode))",
            level: .debug
        )
        return true
    }

    private func selectionProjectionMaterializationCandidates(for node: DOMNodeModel) -> [DOMNodeModel] {
        var queue: [DOMNodeModel] = [node]
        var seen = Set<DOMNodeModel.ID>()
        var candidates: [DOMNodeModel] = []

        while let current = queue.first {
            queue.removeFirst()
            if current.hasUnloadedRegularChildren,
               seen.insert(current.id).inserted {
                candidates.append(current)
            }
            queue.append(contentsOf: current.visibleDOMTreeChildren)
        }

        if let parent = node.parent,
           isDocumentNode(parent),
           parent.hasUnloadedRegularChildren,
           seen.insert(parent.id).inserted {
            candidates.append(parent)
        }

        return candidates
    }

    func applySelection(
        to node: DOMNodeModel,
        selectorPath: String?,
        contextID: DOMContextID,
        targetIdentifierForMaterialization: String? = nil,
        allowPostSelectionMaterialization: Bool = true
    ) async {
        var payload = selectionPayload(for: node)
        if let selectorPath, !selectorPath.isEmpty {
            payload.selectorPath = selectorPath
        }
        document.applySelectionSnapshot(payload)
        await syncSelectedNodeHighlight(contextID: contextID)
        logSelectionDiagnostics(
            "applySelection updated document",
            selector: selectorPath,
            extra: selectionNodeSummary(node)
        )

        guard allowPostSelectionMaterialization,
              let targetIdentifierForMaterialization,
              currentContext?.contextID == contextID,
              document.selectedNode != nil else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.materializeSelectionSubtreeIfNeeded(
                selectorPath: payload.selectorPath,
                contextID: contextID,
                targetIdentifier: targetIdentifierForMaterialization
            )
        }
    }

    func applyPendingInspectSelectionIfPossible() async {
        guard let pendingInspectSelection else {
            return
        }
        guard currentContext?.contextID == pendingInspectSelection.contextID,
              selectionTransactionIsCurrent(pendingInspectSelection.transaction) else {
            self.pendingInspectSelection = nil
            return
        }
        guard let node = resolvedAttachedInspectedNodeFromCurrentDocument(
            nodeID: pendingInspectSelection.nodeID
        ) else {
            return
        }

        self.pendingInspectSelection = nil
        logSelectionDiagnostics(
            "applyPendingInspectSelectionIfPossible resolved transport node",
            selector: pendingInspectSelection.selectorPath,
            extra: selectionNodeSummary(node)
        )
        await applySelection(
            to: node,
            selectorPath: pendingInspectSelection.selectorPath,
            contextID: pendingInspectSelection.contextID,
            targetIdentifierForMaterialization: pendingInspectSelection.resolutionTargetIdentifier
        )
        await completeInspectModeAfterBackendSelection(transaction: pendingInspectSelection.transaction)
        finishInspectSelectionResolution(transaction: pendingInspectSelection.transaction)
        applyRecoverableError(nil)
    }

    private func finishPendingInspectMaterialization(
        from bundle: DOMGraphMutationBundle,
        contextID: DOMContextID,
        rejectedStructuralMutationParentLocalIDs: Set<UInt64>
    ) async {
        guard var pendingInspectSelection else {
            return
        }
        guard pendingInspectSelection.contextID == contextID,
              selectionTransactionIsCurrent(pendingInspectSelection.transaction) else {
            self.pendingInspectSelection = nil
            return
        }

        let completedNodeIDs = Set(
            completedChildRequestNodeIDs(
                from: bundle,
                rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
            ).map {
                DOMNodeModel.ID(documentIdentity: document.documentIdentity, localID: UInt64($0))
            }
        )
        let relevantCompletedNodeIDs = completedNodeIDs.intersection(
            pendingInspectSelection.outstandingMaterializationNodeIDs
        )
        guard relevantCompletedNodeIDs.isEmpty == false else {
            return
        }

        pendingInspectSelection.outstandingMaterializationNodeIDs.subtract(relevantCompletedNodeIDs)
        self.pendingInspectSelection = pendingInspectSelection
        logSelectionDiagnostics(
            "finishPendingInspectMaterialization advanced",
            selector: pendingInspectSelection.selectorPath,
            extra: "contextID=\(contextID) completed=\(relevantCompletedNodeIDs.map { $0.localID }.sorted()) remaining=\(pendingInspectSelection.outstandingMaterializationNodeIDs.map { $0.localID }.sorted()) nodeID=\(pendingInspectSelection.nodeID)",
            level: .debug
        )
        markPendingInspectProgress(
            &pendingInspectSelection,
            reason: "materialization.completed",
            selectionMaterialization: selectionMaterializationCandidates(
                for: pendingInspectSelection
            ),
            extra: "completed=\(relevantCompletedNodeIDs.map { $0.localID }.sorted())"
        )
        guard pendingInspectSelection.outstandingMaterializationNodeIDs.isEmpty else {
            return
        }
        cancelPendingInspectMaterializationTimeout()
        guard resolvedAttachedInspectedNodeFromCurrentDocument(nodeID: pendingInspectSelection.nodeID) == nil else {
            return
        }

        let materializationOutcome = await materializePendingInspectSelection(
            nodeID: pendingInspectSelection.nodeID,
            selectorPath: pendingInspectSelection.selectorPath,
            contextID: pendingInspectSelection.contextID,
            targetIdentifier: pendingInspectSelection.resolutionTargetIdentifier,
            transaction: pendingInspectSelection.transaction
        )
        if materializationOutcome != .exhausted {
            return
        }

        logSelectionDiagnostics(
            "finishPendingInspectMaterialization exhausted candidates without resolving node",
            selector: pendingInspectSelection.selectorPath,
            extra: inspectResolutionDiagnosticSummary(
                nodeID: pendingInspectSelection.nodeID,
                targetIdentifier: pendingInspectSelection.resolutionTargetIdentifier,
                contextID: pendingInspectSelection.contextID
            ),
            level: .error
        )
        self.pendingInspectSelection = nil
        await clearSelectionForFailedResolution(
            contextID: contextID,
            transaction: pendingInspectSelection.transaction,
            showError: true,
            errorMessage: "Failed to resolve selected element."
        )
    }

    private func advancePendingInspectMaterializationIfIdle(
        contextID: DOMContextID
    ) async {
        guard let pendingInspectSelection,
              pendingInspectSelection.contextID == contextID,
              selectionTransactionIsCurrent(pendingInspectSelection.transaction),
              pendingInspectSelection.outstandingMaterializationNodeIDs.isEmpty,
              resolvedAttachedInspectedNodeFromCurrentDocument(nodeID: pendingInspectSelection.nodeID) == nil else {
            return
        }

        let materializationOutcome = await materializePendingInspectSelection(
            nodeID: pendingInspectSelection.nodeID,
            selectorPath: pendingInspectSelection.selectorPath,
            contextID: pendingInspectSelection.contextID,
            targetIdentifier: pendingInspectSelection.resolutionTargetIdentifier,
            transaction: pendingInspectSelection.transaction
        )
        if materializationOutcome != .exhausted {
            return
        }

        logSelectionDiagnostics(
            "advancePendingInspectMaterializationIfIdle kept pending selection unresolved",
            selector: pendingInspectSelection.selectorPath,
            extra: inspectResolutionDiagnosticSummary(
                nodeID: pendingInspectSelection.nodeID,
                targetIdentifier: pendingInspectSelection.resolutionTargetIdentifier,
                contextID: pendingInspectSelection.contextID
            ),
            level: .debug
        )
    }

    private func selectionSubtreeRoot(
        for node: DOMNodeModel,
        preferredNodeIDs: Set<DOMNodeModel.ID> = []
    ) -> DOMNodeModel? {
        guard isNodeAttachedToPrimaryTree(node) else {
            return document.rootNode
        }
        if !preferredNodeIDs.isEmpty {
            var preferredCurrent: DOMNodeModel? = node
            while let candidate = preferredCurrent {
                if preferredNodeIDs.contains(candidate.id) {
                    return candidate
                }
                if let documentParent = candidate.parent, isDocumentNode(documentParent) {
                    if let frameOwner = documentParent.parent,
                       preferredNodeIDs.contains(frameOwner.id) {
                        return frameOwner
                    }
                    preferredCurrent = documentParent.parent
                    continue
                }
                preferredCurrent = candidate.parent
            }
        }

        let topmostAncestor = topmostAncestor(of: node)

        if topmostAncestor !== document.rootNode {
            return topmostAncestor
        }

        return document.rootNode ?? node
    }

    private func topmostAncestor(of node: DOMNodeModel) -> DOMNodeModel {
        var topmostAncestor = node
        while let parent = topmostAncestor.parent {
            topmostAncestor = parent
        }
        return topmostAncestor
    }

    private func isNodeAttachedToPrimaryTree(_ node: DOMNodeModel) -> Bool {
        topmostAncestor(of: node) === document.rootNode
    }

    private func resolvedAttachedInspectedNodeFromCurrentDocument(nodeID: Int) -> DOMNodeModel? {
        guard let node = resolvedInspectedNodeFromCurrentDocument(nodeID: nodeID),
              isNodeAttachedToPrimaryTree(node) else {
            return nil
        }
        return node
    }

    private func nodeDescriptor(from node: DOMNodeModel) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            localID: node.localID,
            backendNodeID: node.backendNodeID,
            backendNodeIDIsStable: node.backendNodeIDIsStable,
            frameID: node.frameID,
            nodeType: inferredNodeType(for: node),
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            pseudoType: node.pseudoType,
            shadowRootType: node.shadowRootType,
            attributes: node.attributes,
            childCount: node.childCount,
            childCountIsKnown: node.childCountIsKnown,
            layoutFlags: node.layoutFlags,
            isRendered: node.isRendered,
            regularChildren: node.regularChildren.map(nodeDescriptor(from:)),
            contentDocument: node.contentDocument.map(nodeDescriptor(from:)),
            shadowRoots: node.shadowRoots.map(nodeDescriptor(from:)),
            templateContent: node.templateContent.map(nodeDescriptor(from:)),
            beforePseudoElement: node.beforePseudoElement.map(nodeDescriptor(from:)),
            afterPseudoElement: node.afterPseudoElement.map(nodeDescriptor(from:))
        )
    }

    private func clearSelectionForFailedResolution(
        contextID: DOMContextID?,
        transaction: SelectionTransaction? = nil,
        showError: Bool = false,
        errorMessage: String
    ) async {
        guard selectionTransactionIsCurrent(transaction) else {
            logSelectionDiagnostics(
                "clearSelectionForFailedResolution ignored stale transaction",
                extra: "contextID=\(contextID.map(String.init) ?? "nil") generation=\(transaction.map { String($0.generation) } ?? "nil")"
            )
            return
        }
        logSelectionDiagnostics(
            "clearSelectionForFailedResolution",
            extra: "contextID=\(contextID.map(String.init) ?? "nil") generation=\(transaction.map { String($0.generation) } ?? "nil") error=\(errorMessage)",
            level: .error
        )
        if transaction != nil,
           inspectModeControlBackend != nil || isSelectingElement {
            await completeInspectModeAfterBackendSelection(transaction: transaction)
        }
        if transaction != nil {
            cancelPendingInspectMaterializationTimeout()
            pendingInspectSelection = nil
            acceptsInspectEvents = false
            inspectSelectionArm = nil
#if DEBUG
            inspectSelectionDiagnosticsForTesting.append(
                .resolutionFailed(
                    contextID: contextID,
                    generation: transaction?.generation
                )
            )
#endif
        }
        let preservesExistingSelection = transaction != nil && document.selectedNode != nil
        if preservesExistingSelection {
            if let contextID {
                await syncSelectedNodeHighlight(contextID: contextID)
            }
            applyRecoverableError(showError ? errorMessage : nil)
            return
        }

        document.clearSelection()
        try? await hideHighlight()
        applyRecoverableError(showError ? errorMessage : nil)
    }

    func resolveTestingPreviewNode(_ preview: String) -> DOMNodeModel? {
        let normalizedPreview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPreview.isEmpty else {
            return nil
        }
        return firstNode(in: document.rootNode) { node in
            selectionPreview(for: node) == normalizedPreview
        }
    }

    private func requestTestingChildNodesAndWaitForCompletion(
        transportNodeID: Int,
        frontendNodeID: Int,
        targetIdentifier: String,
        contextID: DOMContextID,
        depth: Int
    ) async -> Bool {
        await requestChildNodesAndWaitForCompletion(
            transportNodeID: transportNodeID,
            frontendNodeID: frontendNodeID,
            targetIdentifier: targetIdentifier,
            contextID: contextID,
            depth: depth
        )
    }

    func resolveTransportNodeIDForTestingSelector(
        _ cssSelector: String,
        contextID: DOMContextID,
        targetIdentifier: String,
        rootNode: DOMNodeModel
    ) async throws -> Int? {
        if let nodeID = try await queryTransportSelectorAcrossKnownDocuments(
            cssSelector,
            targetIdentifier: targetIdentifier
        ) {
            return nodeID
        }

        do {
            _ = try await refreshCurrentDocumentFromTransport(
                contextID: contextID,
                targetIdentifier: targetIdentifier,
                depth: max(configuration.snapshotDepth, 128),
                isFreshDocument: false
            )
            logSelectionDiagnostics(
                "selectNodeForTesting refreshed current document",
                selector: cssSelector
            )
        } catch {
            logSelectionDiagnostics(
                "selectNodeForTesting refresh failed",
                selector: cssSelector,
                extra: error.localizedDescription,
                level: .error
            )
        }

        if let nodeID = try await queryTransportSelectorAcrossKnownDocuments(
            cssSelector,
            targetIdentifier: targetIdentifier
        ) {
            return nodeID
        }

        var requestedNodeIDs = Set<DOMNodeModel.ID>()
        for _ in 0..<12 {
            let candidates = selectorMaterializationCandidatesForTesting().filter {
                requestedNodeIDs.insert($0.id).inserted
            }
            guard !candidates.isEmpty else {
                break
            }

            for candidate in candidates {
                do {
                    let didComplete = await requestTestingChildNodesAndWaitForCompletion(
                        transportNodeID: try transportNodeID(for: candidate),
                        frontendNodeID: Int(candidate.id.localID),
                        targetIdentifier: targetIdentifier,
                        contextID: contextID,
                        depth: max(configuration.snapshotDepth, 128)
                    )
                    logSelectionDiagnostics(
                        "selectNodeForTesting requested child nodes",
                        selector: cssSelector,
                        extra: "candidate=\(selectionNodeSummary(candidate)) completed=\(didComplete)"
                    )
                } catch {
                    logSelectionDiagnostics(
                        "selectNodeForTesting requestChildNodes failed",
                        selector: cssSelector,
                        extra: "candidate=\(selectionNodeSummary(candidate)) error=\(error.localizedDescription)",
                        level: .error
                    )
                }
            }

            if let nodeID = try await queryTransportSelectorAcrossKnownDocuments(
                cssSelector,
                targetIdentifier: targetIdentifier
            ) {
                return nodeID
            }
        }

        do {
            let didComplete = await requestTestingChildNodesAndWaitForCompletion(
                transportNodeID: try transportNodeID(for: rootNode),
                frontendNodeID: Int(rootNode.id.localID),
                targetIdentifier: targetIdentifier,
                contextID: contextID,
                depth: max(configuration.snapshotDepth, 128)
            )
            logSelectionDiagnostics(
                "selectNodeForTesting requested root child nodes",
                selector: cssSelector,
                extra: "completed=\(didComplete)"
            )
        } catch {
            logSelectionDiagnostics(
                "selectNodeForTesting root requestChildNodes failed",
                selector: cssSelector,
                extra: error.localizedDescription,
                level: .error
            )
        }

        return try await queryTransportSelectorAcrossKnownDocuments(
            cssSelector,
            targetIdentifier: targetIdentifier
        )
    }

    func queryTransportSelectorAcrossKnownDocuments(
        _ cssSelector: String,
        targetIdentifier: String
    ) async throws -> Int? {
        for queryRoot in selectorQueryRootsForTesting() {
            let response = try await sendDOMCommand(
                WITransportMethod.DOM.querySelector,
                targetIdentifier: targetIdentifier,
                parameters: DOMQuerySelectorParameters(
                    nodeId: try transportNodeID(for: queryRoot),
                    selector: cssSelector
                )
            )
            logSelectionDiagnostics(
                "selectNodeForTesting DOM.querySelector returned",
                selector: cssSelector,
                extra: "queryRoot=\(selectionNodeSummary(queryRoot)) response=\(selectionLogValue(response))"
            )
            if let nodeID = intValue(response["nodeId"]),
               nodeID > 0 {
                return nodeID
            }
        }
        return nil
    }

    func selectorQueryRootsForTesting() -> [DOMNodeModel] {
        var roots: [DOMNodeModel] = []
        var seen = Set<DOMNodeModel.ID>()
        var queue: [DOMNodeModel] = []
        if let rootNode = document.rootNode {
            queue.append(rootNode)
        }

        while let node = queue.first {
            queue.removeFirst()
            if isDocumentNode(node), seen.insert(node.id).inserted {
                roots.append(node)
            }
            queue.append(contentsOf: node.visibleDOMTreeChildren)
        }
        return roots
    }

    func selectorMaterializationCandidatesForTesting() -> [DOMNodeModel] {
        var candidates = selectionMaterializationCandidates().candidates
        for nestedDocument in selectorQueryRootsForTesting() where nestedDocument.parent != nil {
            if candidates.contains(where: { $0.id == nestedDocument.id }) == false {
                candidates.append(nestedDocument)
            }
        }
        return candidates
    }

    func inspectEventResolutionTargetIdentifier(eventTargetIdentifier: String?) -> String? {
        if let eventTargetIdentifier,
           let targetKind = sharedTransport.targetKind(for: eventTargetIdentifier),
           targetKind == .page || targetKind == .frame {
            return eventTargetIdentifier
        }
        return inspectSelectionArm?.targetIdentifier
            ?? phase.targetIdentifier
            ?? sharedTransport.currentPageTargetIdentifier()
    }

    func transportLifecycleEventIsForPage(_ envelope: WITransportEventEnvelope) -> Bool {
        switch envelope.method {
        case "Target.targetCreated":
            guard let params = try? JSONSerialization.jsonObject(with: envelope.paramsData) as? [String: Any],
                  let targetInfo = params["targetInfo"] as? [String: Any],
                  let type = stringValue(targetInfo["type"]) else {
                return true
            }
            return type == "page"
        case "Target.didCommitProvisionalTarget", "Target.targetDestroyed":
            return sharedTransport.targetKind(for: envelope.targetIdentifier) != .frame
        default:
            return true
        }
    }

    func noteDeferredLoadingMutation(
        contextID: DOMContextID,
        targetIdentifier: String,
        method: String
    ) {
        if deferredLoadingMutationState?.contextID != contextID
            || deferredLoadingMutationState?.targetIdentifier != targetIdentifier {
            deferredLoadingMutationState = DeferredLoadingMutationState(
                contextID: contextID,
                targetIdentifier: targetIdentifier
            )
        }
        deferredLoadingMutationState?.sawMutation = true
        logSelectionDiagnostics(
            "handleDOMEventEnvelope deferred mutation while document is loading",
            extra: "contextID=\(contextID) target=\(targetIdentifier) method=\(method)",
            level: .debug
        )
    }

    func consumeDeferredLoadingMutationRefreshIfNeeded(
        contextID: DOMContextID,
        targetIdentifier: String
    ) -> Bool {
        guard var deferredLoadingMutationState,
              deferredLoadingMutationState.contextID == contextID,
              deferredLoadingMutationState.targetIdentifier == targetIdentifier,
              deferredLoadingMutationState.sawMutation else {
            return false
        }
        guard deferredLoadingMutationState.performedFollowUpRefresh == false else {
            self.deferredLoadingMutationState = nil
            logSelectionDiagnostics(
                "refreshCurrentDocumentFromTransport suppressed additional follow-up refresh",
                extra: "contextID=\(contextID) target=\(targetIdentifier)",
                level: .debug
            )
            return false
        }
        deferredLoadingMutationState.sawMutation = false
        deferredLoadingMutationState.performedFollowUpRefresh = true
        self.deferredLoadingMutationState = deferredLoadingMutationState
        return true
    }

    func clearDeferredLoadingMutationStateIfSettled(
        contextID: DOMContextID,
        targetIdentifier: String
    ) {
        guard let deferredLoadingMutationState,
              deferredLoadingMutationState.contextID == contextID,
              deferredLoadingMutationState.targetIdentifier == targetIdentifier,
              deferredLoadingMutationState.sawMutation == false else {
            return
        }
        self.deferredLoadingMutationState = nil
    }

    func injectedScriptIdentifier(from objectID: String) -> String? {
        guard let data = objectID.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let injectedScriptID = object["injectedScriptId"] as? Int {
            return String(injectedScriptID)
        }
        if let injectedScriptID = object["injectedScriptId"] as? NSNumber {
            return injectedScriptID.stringValue
        }
        return object["injectedScriptId"] as? String
    }

    func logSelectionDiagnostics(
        _ message: String,
        selector: String? = nil,
        extra: String? = nil,
        level: OSLogType = .default
    ) {
        let selectorPart = selector.map { " selector=\($0)" } ?? ""
        let extraPart = extra.map { " \($0)" } ?? ""
        let summary = selectionRuntimeSummary()
        let composed = "\(message)\(selectorPart)\(extraPart) \(summary)"
        lastSelectionDiagnosticMessage = composed
        guard WIDOMConsoleDiagnostics.shouldEmitSelectionDiagnostic(
            message: message,
            level: level
        ) else {
            return
        }
        if WIDOMConsoleDiagnostics.verboseConsoleDiagnosticsEnabled == false,
           level != .error,
           level != .fault,
           lastEmittedSelectionDiagnosticMessage == composed {
            return
        }
        lastEmittedSelectionDiagnosticMessage = composed
        switch level {
        case .error, .fault:
            domViewLogger.error("\(composed, privacy: .public)")
        case .debug:
            domViewLogger.debug("\(composed, privacy: .public)")
        default:
            domViewLogger.notice("\(composed, privacy: .public)")
        }
    }

    func selectionRuntimeSummary() -> String {
        let phaseDescription: String
        switch phase {
        case .idle:
            phaseDescription = "idle"
        case let .loadingDocument(context, targetIdentifier):
            phaseDescription = "loadingDocument(\(context.contextID),target=\(targetIdentifier ?? "nil"))"
        case let .ready(context, targetIdentifier):
            phaseDescription = "ready(\(context.contextID),target=\(targetIdentifier))"
        }

        return "phase=\(phaseDescription) documentURL=\(currentContext?.documentURL ?? "nil") pageWebView=\(webViewSummary(pageWebView)) root=\(selectionNodeSummary(document.rootNode)) selected=\(selectionNodeSummary(document.selectedNode))"
    }

    func logBootstrapDiagnostics(_ message: String) {
        guard WIDOMConsoleDiagnostics.verboseConsoleDiagnosticsEnabled else {
            return
        }
        domViewLogger.debug("[WebInspectorDOM] \(message, privacy: .public)")
    }

    func selectionNodeSummary(_ node: DOMNodeModel?) -> String {
        guard let node else {
            return "nil"
        }
        let nodeName = node.localName.isEmpty ? node.nodeName : node.localName
        return "\(nodeName)#local=\(node.localID)#backend=\(node.backendNodeID.map(String.init) ?? "nil")#children=\(node.children.count)/\(node.childCount)#selector=\(node.selectorPath.nilIfEmpty ?? "nil")"
    }

    func selectionPayloadSummary(_ payload: DOMSelectionSnapshotPayload?) -> String {
        guard let payload else {
            return "nil"
        }
        return "localID=\(payload.localID.map(String.init) ?? "nil") backend=\(payload.backendNodeID.map(String.init) ?? "nil") stable=\(payload.backendNodeIDIsStable) selector=\(payload.selectorPath ?? "nil") attributes=\(payload.attributes.count)"
    }

    func selectionPayloadMatchesCurrentSelection(_ payload: DOMSelectionSnapshotPayload) -> Bool {
        if let selectedNode = document.selectedNode {
            if payload.localID == selectedNode.localID {
                return true
            }
            if let backendNodeID = payload.backendNodeID,
               selectedNode.backendNodeID == backendNodeID {
                return true
            }
        }
        return false
    }

    func selectionPayloadMatchesPendingInspectSelection(_ payload: DOMSelectionSnapshotPayload) -> Bool {
        guard let pendingInspectSelection else {
            return false
        }

        if let localID = payload.localID,
           localID == UInt64(pendingInspectSelection.nodeID) {
            return true
        }

        if let backendNodeID = payload.backendNodeID,
           backendNodeID == pendingInspectSelection.nodeID {
            return true
        }

        return false
    }

    func resolveFrontendSelectionPayloadForCurrentDocument(
        _ selection: DOMSelectionSnapshotPayload
    ) -> DOMSelectionSnapshotPayload? {
        guard let localID = selection.localID else {
            return nil
        }

        if let node = document.node(localID: localID),
           isNodeAttachedToPrimaryTree(node) {
            var resolvedSelection = selection
            resolvedSelection.localID = node.localID
            if resolvedSelection.backendNodeID == nil {
                resolvedSelection.backendNodeID = node.backendNodeID
                resolvedSelection.backendNodeIDIsStable = node.backendNodeIDIsStable
            }
            return resolvedSelection
        }

        if let backendNodeID = selection.backendNodeID {
            if selection.backendNodeIDIsStable,
               let node = document.node(stableBackendNodeID: backendNodeID),
               isNodeAttachedToPrimaryTree(node) {
                var resolvedSelection = selection
                resolvedSelection.localID = node.localID
                resolvedSelection.backendNodeID = node.backendNodeID
                resolvedSelection.backendNodeIDIsStable = node.backendNodeIDIsStable
                return resolvedSelection
            }
            if let node = document.node(backendNodeID: backendNodeID),
               isNodeAttachedToPrimaryTree(node) {
                var resolvedSelection = selection
                resolvedSelection.localID = node.localID
                resolvedSelection.backendNodeID = node.backendNodeID
                resolvedSelection.backendNodeIDIsStable = node.backendNodeIDIsStable
                return resolvedSelection
            }
        }

        return nil
    }

    func webViewSummary(_ webView: WKWebView?) -> String {
        guard let webView else {
            return "nil"
        }
        return String(describing: ObjectIdentifier(webView))
    }

    func selectionVisibleNodeSummaries(limit: Int) -> [String] {
        var collected: [String] = []
        func visit(_ node: DOMNodeModel?) {
            guard let node, collected.count < limit else {
                return
            }
            collected.append(selectionNodeSummary(node))
            for child in node.visibleDOMTreeChildren {
                visit(child)
                if collected.count >= limit {
                    return
                }
            }
        }
        visit(document.rootNode)
        return collected
    }

    func selectionLogValue(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    private func nodeDescriptorSummary(_ node: DOMGraphNodeDescriptor) -> String {
        let nodeName = node.localName.isEmpty ? node.nodeName : node.localName
        return "\(nodeName)#local=\(node.localID)#backend=\(node.backendNodeID.map(String.init) ?? "nil")#children=\(node.children.count)/\(node.childCount)#frame=\(node.frameID ?? "nil")"
    }

    private func nodeSummaryList(_ nodes: [DOMNodeModel]) -> String {
        guard !nodes.isEmpty else {
            return "[]"
        }
        return "[" + nodes.map(selectionNodeSummary).joined(separator: ";") + "]"
    }

    private func nodeDescriptorSummaryList(_ nodes: [DOMGraphNodeDescriptor]) -> String {
        guard !nodes.isEmpty else {
            return "[]"
        }
        return "[" + nodes.map(nodeDescriptorSummary).joined(separator: ";") + "]"
    }

    private func pendingChildRequestDiagnosticsSummary() -> String {
        let records = pendingChildRequests.values.sorted { lhs, rhs in
            if lhs.key.contextID != rhs.key.contextID {
                return String(describing: lhs.key.contextID) < String(describing: rhs.key.contextID)
            }
            return lhs.key.nodeID < rhs.key.nodeID
        }
        guard !records.isEmpty else {
            return "[]"
        }
        return "[" + records.map {
            "nodeID=\($0.key.nodeID),contextID=\($0.key.contextID),reportsToFrontend=\($0.reportsToFrontend)"
        }.joined(separator: ";") + "]"
    }

    private func pendingInspectSelectionDiagnosticSummary(_ pendingSelection: PendingInspectSelection?) -> String {
        guard let pendingSelection else {
            return "nil"
        }
        let transactionSummary = pendingSelection.transaction.map {
            "contextID=\($0.contextID),generation=\($0.generation)"
        } ?? "nil"
        return "nodeID=\(pendingSelection.nodeID) contextID=\(pendingSelection.contextID) target=\(pendingSelection.resolutionTargetIdentifier) transaction=\(transactionSummary) scopedRoots=\(pendingSelection.scopedMaterializationRootNodeIDs.map(\.localID)) activeStrategy=\(pendingSelection.activeMaterializationStrategy.rawValue) activeGeneration=\(pendingSelection.activeRequestGeneration) genericDeferrals=\(pendingSelection.genericDispatchDeferralCount) observedStrategy=\(pendingSelection.observedMaterializationStrategy.rawValue) materializedCount=\(pendingSelection.materializedAncestorNodeIDs.count) outstandingCount=\(pendingSelection.outstandingMaterializationNodeIDs.count) observedCandidateCount=\(pendingSelection.observedMaterializationCandidateNodeIDs.count) observedFrameIDs=\(pendingSelection.observedDocumentBackedFrameIDs.sorted()) lastExhaustedStrategy=\(pendingSelection.lastExhaustedScopedStrategy?.rawValue ?? "nil") lastExhaustedCount=\(pendingSelection.lastExhaustedScopedCandidateNodeIDs.count) progressRevision=\(pendingSelection.progressRevision)"
    }

    private func selectionMaterializationPlanSummary(_ plan: SelectionMaterializationPlan) -> String {
        "strategy=\(plan.strategy.rawValue) candidateCount=\(plan.candidates.count) frameOwnerCount=\(plan.frameOwnerCandidates.count) frameDocumentCount=\(plan.frameDocumentCandidates.count) canonicalEmbeddedCount=\(plan.canonicalEmbeddedCandidates.count) genericIncompleteCount=\(plan.genericIncompleteCandidates.count)"
    }

    private func mutationBundleSummary(_ bundle: DOMGraphMutationBundle) -> String {
        guard !bundle.events.isEmpty else {
            return "[]"
        }
        let eventSummaries = bundle.events.map { event -> String in
            switch event {
            case let .childNodeInserted(parentLocalID, previousLocalID, node):
                return "childNodeInserted(parent=\(parentLocalID),previous=\(previousLocalID.map(String.init) ?? "nil"),node=\(nodeDescriptorSummary(node)))"
            case let .childNodeRemoved(parentLocalID, nodeLocalID):
                return "childNodeRemoved(parent=\(parentLocalID),node=\(nodeLocalID))"
            case let .shadowRootPushed(hostLocalID, root):
                return "shadowRootPushed(host=\(hostLocalID),root=\(nodeDescriptorSummary(root)))"
            case let .shadowRootPopped(hostLocalID, rootLocalID):
                return "shadowRootPopped(host=\(hostLocalID),root=\(rootLocalID))"
            case let .pseudoElementAdded(parentLocalID, node):
                return "pseudoElementAdded(parent=\(parentLocalID),node=\(nodeDescriptorSummary(node)))"
            case let .pseudoElementRemoved(parentLocalID, nodeLocalID):
                return "pseudoElementRemoved(parent=\(parentLocalID),node=\(nodeLocalID))"
            case let .attributeModified(nodeLocalID, name, value, _, _):
                return "attributeModified(node=\(nodeLocalID),name=\(name),value=\(value))"
            case let .attributeRemoved(nodeLocalID, name, _, _):
                return "attributeRemoved(node=\(nodeLocalID),name=\(name))"
            case let .characterDataModified(nodeLocalID, value, _, _):
                return "characterDataModified(node=\(nodeLocalID),value=\(value))"
            case let .childNodeCountUpdated(nodeLocalID, childCount, _, _):
                return "childNodeCountUpdated(node=\(nodeLocalID),childCount=\(childCount))"
            case let .setChildNodes(parentLocalID, nodes):
                return "setChildNodes(parent=\(parentLocalID),nodes=\(nodeDescriptorSummaryList(nodes)))"
            case let .setDetachedRoots(nodes):
                return "setDetachedRoots(nodes=\(nodeDescriptorSummaryList(nodes)))"
            case let .replaceSubtree(root):
                return "replaceSubtree(root=\(nodeDescriptorSummary(root)))"
            case .documentUpdated:
                return "documentUpdated"
            }
        }
        return "[" + eventSummaries.joined(separator: ";") + "]"
    }

    private func nodeResolutionLookupSummary(nodeID: Int) -> String {
        let localMatch = selectionNodeSummary(document.node(localID: UInt64(nodeID)))
        let backendMatch = selectionNodeSummary(document.node(backendNodeID: nodeID))
        let stableBackendMatch = selectionNodeSummary(document.node(stableBackendNodeID: nodeID))
        let resolvedMatch = selectionNodeSummary(resolvedInspectedNodeFromCurrentDocument(nodeID: nodeID))
        return "requestedNodeID=\(nodeID) localMatch=\(localMatch) backendMatch=\(backendMatch) stableBackendMatch=\(stableBackendMatch) resolvedMatch=\(resolvedMatch)"
    }

    private func inspectResolutionDiagnosticSummary(
        nodeID: Int,
        targetIdentifier: String,
        contextID: DOMContextID
    ) -> String {
        let relevantPendingSelection: PendingInspectSelection?
        if let pendingInspectSelection,
           pendingInspectSelection.nodeID == nodeID,
           pendingInspectSelection.contextID == contextID,
           pendingInspectSelection.resolutionTargetIdentifier == targetIdentifier {
            relevantPendingSelection = pendingInspectSelection
        } else {
            relevantPendingSelection = nil
        }
        let materializationPlan = selectionMaterializationCandidates(
            for: relevantPendingSelection
        )
        let frameOwnerFallbackCount = pendingInspectSelection.map {
            frameOwnerFallbackCandidates(for: $0).count
        } ?? 0
        return [
            nodeResolutionLookupSummary(nodeID: nodeID),
            "pendingInspect=\(pendingInspectSelectionDiagnosticSummary(pendingInspectSelection))",
            "pendingChildRequests=\(pendingChildRequestDiagnosticsSummary())",
            "materializationPlan=\(selectionMaterializationPlanSummary(materializationPlan))",
            "rootCounts=topLevel:\(document.topLevelRoots().count) knownDocuments:\(knownDocumentRoots().count)",
            "frameOwnerFallbackCount=\(frameOwnerFallbackCount)",
            "targets=requested=\(targetIdentifier) current=\(phase.targetIdentifier ?? "nil") observedPage=\(sharedTransport.currentObservedPageTargetIdentifier() ?? "nil") page=\(sharedTransport.currentPageTargetIdentifier() ?? "nil") contextID=\(contextID) projectionRevision=\(document.projectionRevision)"
        ].joined(separator: " ")
    }

    func firstNode(
        in root: DOMNodeModel?,
        where predicate: (DOMNodeModel) -> Bool
    ) -> DOMNodeModel? {
        guard let root else {
            return nil
        }
        if predicate(root) {
            return root
        }
        for child in root.visibleDOMTreeChildren {
            if let match = firstNode(in: child, where: predicate) {
                return match
            }
        }
        return nil
    }

    func resolvedInspectedNodeFromCurrentDocument(nodeID: Int) -> DOMNodeModel? {
        if let node = document.node(localID: UInt64(nodeID)) {
            return node
        }
        return document.node(backendNodeID: nodeID)
    }

    private func selectionTransaction(for contextID: DOMContextID) -> SelectionTransaction? {
        guard currentContext?.contextID == contextID else {
            return nil
        }
        return SelectionTransaction(contextID: contextID, generation: selectionGeneration)
    }

    private func selectionTransactionIsCurrent(_ transaction: SelectionTransaction?) -> Bool {
        guard let transaction else {
            return true
        }
        return currentContext?.contextID == transaction.contextID
            && selectionGeneration == transaction.generation
    }

    func selectionPayload(for node: DOMNodeModel) -> DOMSelectionSnapshotPayload {
        .init(
            localID: node.localID,
            backendNodeID: node.backendNodeID,
            backendNodeIDIsStable: node.backendNodeIDIsStable,
            attributes: node.attributes,
            path: selectionPathLabels(for: node),
            selectorPath: node.selectorPath.nilIfEmpty,
            styleRevision: node.styleRevision
        )
    }

    func selectionPathLabels(for node: DOMNodeModel) -> [String] {
        var labels: [String] = []
        var current: DOMNodeModel? = node
        var guardCount = 0
        while let currentNode = current, guardCount < 200 {
            labels.insert(selectionPreview(for: currentNode), at: 0)
            current = currentNode.parent
            guardCount += 1
        }
        return labels
    }

    func selectionPreview(for node: DOMNodeModel) -> String {
        if !node.preview.isEmpty {
            return node.preview
        }
        if node.nodeType == .text {
            return node.nodeValue
        }
        return "<\(node.localName.isEmpty ? node.nodeName.lowercased() : node.localName)>"
    }

    func node(at path: [Int], from root: DOMNodeModel?) -> DOMNodeModel? {
        var current = root
        for index in path {
            guard let node = current,
                  index >= 0,
                  index < node.visibleDOMTreeChildren.count else {
                return nil
            }
            current = node.visibleDOMTreeChildren[index]
        }
        return current
    }

    func copySelectionImpl(_ kind: DOMSelectionCopyKind) async throws -> String {
        guard let selectedNode = document.selectedNode else {
            throw DOMOperationError.invalidSelection
        }
        return try await copyText(for: selectedNode, kind: kind)
    }

    func copyText(
        for node: DOMNodeModel,
        kind: DOMSelectionCopyKind
    ) async throws -> String {
        switch kind {
        case .html:
            let response = try await sendDOMCommand(
                WITransportMethod.DOM.getOuterHTML,
                targetIdentifier: try requireCurrentTargetIdentifier(),
                parameters: DOMNodeIdentifierParameters(nodeId: try transportNodeID(for: node))
            )
            return stringValue(response["outerHTML"]) ?? ""
        case .selectorPath, .xpath:
            if kind == .selectorPath {
                return selectorPathText(for: node)
            }
            return xPathText(for: node)
        }
    }

    func selectorPathText(for node: DOMNodeModel) -> String {
        guard nodeIsElementLike(node) else {
            return ""
        }

        var components: [String] = []
        var current: DOMNodeModel? = node

        while let candidate = current {
            guard let component = selectorPathComponent(for: candidate) else {
                break
            }
            components.append(component.value)
            if component.done {
                break
            }
            current = selectorTraversalParent(for: candidate)
        }

        return components.reversed().joined(separator: " > ")
    }

    func xPathText(for node: DOMNodeModel) -> String {
        if node.nodeType == .document {
            return "/"
        }

        var components: [String] = []
        var current: DOMNodeModel? = node

        while let candidate = current {
            if candidate.nodeType == .document {
                current = candidate.parent
                continue
            }
            guard let component = xPathComponent(for: candidate) else {
                break
            }
            components.append(component)
            current = candidate.parent
        }

        guard !components.isEmpty else {
            return ""
        }
        return "/" + components.reversed().joined(separator: "/")
    }

    func selectorTraversalParent(for node: DOMNodeModel) -> DOMNodeModel? {
        guard let parent = node.parent else {
            return nil
        }
        if parent.nodeType == .document {
            return parent.parent
        }
        return parent
    }

    func selectorPathComponent(for node: DOMNodeModel) -> (value: String, done: Bool)? {
        guard nodeIsElementLike(node) else {
            return nil
        }

        let nodeName = selectorNodeName(for: node)
        guard !nodeName.isEmpty else {
            return nil
        }

        let parent = selectorTraversalParent(for: node)
        if parent == nil || (["html", "body", "head"].contains(nodeName) && !nodeIsInsideEmbeddedDocument(node)) {
            return (nodeName, true)
        }

        if let idValue = attributeValue(named: "id", on: node),
           !idValue.isEmpty {
            return ("#\(escapedCSSIdentifier(idValue))", !nodeIsInsideEmbeddedDocument(node))
        }

        let siblings = selectorSiblingElements(for: node)
        var uniqueClasses = Set(classNames(for: node))
        var hasUniqueTagName = true
        var nthChildIndex = 0
        var elementIndex = 0

        for sibling in siblings {
            elementIndex += 1
            if sibling === node {
                nthChildIndex = elementIndex
                continue
            }
            if selectorNodeName(for: sibling) == nodeName {
                hasUniqueTagName = false
            }
            for className in classNames(for: sibling) {
                uniqueClasses.remove(className)
            }
        }

        var selector = nodeName
        if nodeName == "input",
           let typeValue = attributeValue(named: "type", on: node),
           !typeValue.isEmpty,
           uniqueClasses.isEmpty {
            selector += "[type=\"\(escapedCSSAttributeValue(typeValue))\"]"
        }

        if !hasUniqueTagName {
            if !uniqueClasses.isEmpty {
                selector += "." + uniqueClasses.sorted().map(escapedCSSIdentifier).joined(separator: ".")
            } else if nthChildIndex > 0 {
                selector += ":nth-child(\(nthChildIndex))"
            }
        }

        return (selector, false)
    }

    func xPathComponent(for node: DOMNodeModel) -> String? {
        func elementComponent() -> String? {
            let nodeName = selectorNodeName(for: node)
            guard !nodeName.isEmpty else {
                return nil
            }
            let index = xPathIndex(for: node)
            return index > 0 ? "\(nodeName)[\(index)]" : nodeName
        }

        switch node.nodeType {
        case .element:
            return elementComponent()
        case .unknown where nodeIsElementLike(node):
            return elementComponent()
        case .attribute:
            return "@\(node.nodeName)"
        case .text, .cdataSection:
            let index = xPathIndex(for: node)
            return index > 0 ? "text()[\(index)]" : "text()"
        case .comment:
            let index = xPathIndex(for: node)
            return index > 0 ? "comment()[\(index)]" : "comment()"
        case .processingInstruction:
            let index = xPathIndex(for: node)
            return index > 0 ? "processing-instruction()[\(index)]" : "processing-instruction()"
        default:
            return nil
        }
    }

    func xPathIndex(for node: DOMNodeModel) -> Int {
        guard let parent = node.parent else {
            return 0
        }

        let siblings = parent.regularChildren
        if siblings.count <= 1 {
            return 0
        }

        var foundIndex = -1
        var counter = 1
        var unique = true

        for sibling in siblings where xPathNodesAreSimilar(node, sibling) {
            if sibling === node {
                foundIndex = counter
                if !unique {
                    return foundIndex
                }
            } else {
                unique = false
                if foundIndex != -1 {
                    return foundIndex
                }
            }
            counter += 1
        }

        if unique {
            return 0
        }
        return foundIndex > 0 ? foundIndex : 0
    }

    func xPathNodesAreSimilar(_ lhs: DOMNodeModel, _ rhs: DOMNodeModel) -> Bool {
        if lhs === rhs {
            return true
        }
        if nodeIsElementLike(lhs), nodeIsElementLike(rhs) {
            return selectorNodeName(for: lhs) == selectorNodeName(for: rhs)
        }
        if lhs.nodeType == .cdataSection {
            return rhs.nodeType == .text
        }
        if rhs.nodeType == .cdataSection {
            return lhs.nodeType == .text
        }
        return lhs.nodeType == rhs.nodeType
    }

    func selectorSiblingElements(for node: DOMNodeModel) -> [DOMNodeModel] {
        guard let parent = node.parent else {
            return [node]
        }
        return parent.regularChildren.filter(nodeIsElementLike)
    }

    func selectorNodeName(for node: DOMNodeModel) -> String {
        let rawName = node.localName.isEmpty ? node.nodeName : node.localName
        return rawName.lowercased()
    }

    func nodeIsElementLike(_ node: DOMNodeModel) -> Bool {
        if node.nodeType == .element {
            return true
        }
        guard node.nodeType == .unknown else {
            return false
        }
        let nodeName = selectorNodeName(for: node)
        return !nodeName.isEmpty && !nodeName.hasPrefix("#")
    }

    func classNames(for node: DOMNodeModel) -> [String] {
        guard let classValue = attributeValue(named: "class", on: node) else {
            return []
        }
        return classValue
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    func attributeValue(named name: String, on node: DOMNodeModel) -> String? {
        node.attributes.first(where: { $0.name == name })?.value
    }

    func nodeIsInsideEmbeddedDocument(_ node: DOMNodeModel) -> Bool {
        var current = node.parent
        while let currentNode = current {
            if currentNode.nodeType == .document, currentNode.parent != nil {
                return true
            }
            current = currentNode.parent
        }
        return false
    }

    func escapedCSSIdentifier(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"([\\.\[\]\+\*\~\>\:\(\)\$\^\=\|\{\}\#\s])"#,
            with: #"\\$1"#,
            options: .regularExpression
        )
    }

    func escapedCSSAttributeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func nodePayloadDictionary(from node: DOMNodeModel) -> [String: Any] {
        var payload: [String: Any] = [
            "id": Int(node.localID),
            "nodeId": Int(node.localID),
            "backendNodeId": node.backendNodeID as Any,
            "backendNodeIdIsStable": node.backendNodeIDIsStable,
            "nodeType": node.nodeType.rawValue,
            "nodeName": node.nodeName,
            "localName": node.localName,
            "nodeValue": node.nodeValue,
            "frameId": node.frameID as Any,
            "attributes": node.attributes.flatMap { [$0.name, $0.value] },
            "childNodeCount": node.childCount,
            "childCount": node.childCount,
            "layoutFlags": node.layoutFlags,
            "isRendered": node.isRendered,
        ]

        if let pseudoType = node.pseudoType {
            payload["pseudoType"] = pseudoType
        }
        if let shadowRootType = node.shadowRootType {
            payload["shadowRootType"] = shadowRootType
        }

        if let contentDocument = node.contentDocument {
            payload["contentDocument"] = nodePayloadDictionary(from: contentDocument)
        } else {
            payload["children"] = node.regularChildren.map(nodePayloadDictionary(from:))
        }
        if !node.shadowRoots.isEmpty {
            payload["shadowRoots"] = node.shadowRoots.map(nodePayloadDictionary(from:))
        }
        if let templateContent = node.templateContent {
            payload["templateContent"] = nodePayloadDictionary(from: templateContent)
        }
        let pseudoElements = [node.beforePseudoElement, node.afterPseudoElement].compactMap { $0 }
        if !pseudoElements.isEmpty {
            payload["pseudoElements"] = pseudoElements.map(nodePayloadDictionary(from:))
        }

        return payload
    }

    func sendDOMCommand(
        _ method: String,
        targetIdentifier: String,
        parametersData: Data? = nil
    ) async throws -> [String: Any] {
        let data = try await sendDOMCommandData(
            method,
            targetIdentifier: targetIdentifier,
            parametersData: parametersData
        )
        guard !data.isEmpty else {
            return [:]
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            return object as? [String: Any] ?? [:]
        } catch {
            throw DOMOperationError.scriptFailure(error.localizedDescription)
        }
    }

    func sendDOMCommandData(
        _ method: String,
        targetIdentifier: String,
        parametersData: Data? = nil
    ) async throws -> Data {
        guard let session = await sharedTransport.attachedSession() else {
            throw DOMOperationError.contextInvalidated
        }
        do {
            return try await session.sendPageData(
                method: method,
                targetIdentifier: targetIdentifier,
                parametersData: parametersData
            )
        } catch let error as WITransportError {
            throw mapTransportError(error)
        } catch {
            throw DOMOperationError.scriptFailure(error.localizedDescription)
        }
    }

    func sendDOMCommand<Parameters: Encodable>(
        _ method: String,
        targetIdentifier: String,
        parameters: Parameters
    ) async throws -> [String: Any] {
        let data = try JSONEncoder().encode(parameters)
        return try await sendDOMCommand(
            method,
            targetIdentifier: targetIdentifier,
            parametersData: data
        )
    }

    func awaitTransportMessagesToDrain() async {
        guard let session = await sharedTransport.attachedSession() else {
            return
        }
        await session.waitForPendingMessages()
        await session.waitForPostActivePageEventsToDrain()
    }

    func syncSelectedNodeHighlight(contextID: DOMContextID) async {
        guard currentContext?.contextID == contextID,
              let targetIdentifier = phase.targetIdentifier ?? sharedTransport.currentPageTargetIdentifier() else {
            return
        }

        guard let selectedNode = document.selectedNode else {
            try? await hideHighlight()
            return
        }

        do {
            _ = try await sendDOMCommand(
                WITransportMethod.DOM.highlightNode,
                targetIdentifier: targetIdentifier,
                parameters: DOMHighlightNodeParameters(
                    nodeId: try transportNodeID(for: selectedNode),
                    reveal: true
                )
            )
        } catch {
            logSelectionDiagnostics(
                "syncSelectedNodeHighlight failed",
                extra: error.localizedDescription,
                level: .error
            )
        }
    }

    func mapTransportError(_ error: WITransportError) -> DOMOperationError {
        switch error {
        case .notAttached, .pageTargetUnavailable:
            return .contextInvalidated
        case .transportClosed:
            return .pageUnavailable
        case let .remoteError(_, _, message):
            return .scriptFailure(message)
        case let .requestTimedOut(_, method):
            return .scriptFailure("\(method) timed out.")
        case let .invalidResponse(reason):
            return .scriptFailure(reason)
        case let .invalidCommandEncoding(reason):
            return .scriptFailure(reason)
        case let .unsupported(reason), let .attachFailed(reason):
            return .scriptFailure(reason)
        case .alreadyAttached:
            return .contextInvalidated
        }
    }

    func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    func resetInteractionState() async {
        await cancelSelectionMode()
        await failPendingChildRequests()
        clearDeleteUndoHistory()
    }

    func applyRecoverableError(_ message: String?) {
        document.setErrorMessage(message)
        externalRecoverableErrorHandler?(message)
    }

    func failCurrentDocumentLoad(_ message: String?) {
        document.failDocumentLoad(message)
        externalRecoverableErrorHandler?(message)
    }

    func errorMessage(from error: any Error) -> String? {
        if let error = error as? DOMOperationError {
            switch error {
            case .pageUnavailable:
                return "Web view unavailable."
            case .contextInvalidated:
                return "Document context changed."
            case .invalidSelection:
                return "Selection is no longer valid."
            case let .scriptFailure(message):
                return message
            }
        }
        return error.localizedDescription
    }

    private func installPageWebViewLifetimeObserver(on webView: WKWebView) {
        pageWebViewAttachmentGeneration &+= 1
        let expectedGeneration = pageWebViewAttachmentGeneration
        let observer = WIPageWebViewLifetimeObserver { [weak self] in
            guard let self else {
                return
            }
            self.handleAttachedPageWebViewReleased(expectedGeneration: expectedGeneration)
        }
        unsafe objc_setAssociatedObject(
            webView,
            pageWebViewLifetimeObserverAssociationKey,
            observer,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func handleAttachedPageWebViewReleased(expectedGeneration: UInt64) {
        guard pageWebViewAttachmentGeneration == expectedGeneration,
              pageWebView == nil else {
            return
        }
        hasPageWebView = false
        updateSelectionAvailability()
    }
}

private struct DOMHighlightColor: Encodable {
    let r: Int
    let g: Int
    let b: Int
    let a: Double
}

private struct DOMHighlightConfig: Encodable {
    let showInfo: Bool
    let contentColor = DOMHighlightColor(r: 111, g: 168, b: 220, a: 0.66)
    let paddingColor = DOMHighlightColor(r: 147, g: 196, b: 125, a: 0.66)
    let borderColor = DOMHighlightColor(r: 255, g: 229, b: 153, a: 0.66)
    let marginColor = DOMHighlightColor(r: 246, g: 178, b: 107, a: 0.66)
}

private struct DOMSetInspectModeEnabledParameters: Encodable {

    let enabled: Bool
    let highlightConfig: DOMHighlightConfig?

    static let enabled = DOMSetInspectModeEnabledParameters(
        enabled: true,
        highlightConfig: DOMHighlightConfig(showInfo: false)
    )

    static let disabled = DOMSetInspectModeEnabledParameters(
        enabled: false,
        highlightConfig: nil
    )
}

extension WIDOMInspector {
#if DEBUG
    func recordInspectSelectionDiagnostic(_ event: InspectSelectionDiagnosticEvent) {
        inspectSelectionDiagnosticsForTesting.append(event)
    }
#endif

    func currentContextIDForSelectionDiagnostics() -> DOMContextID? {
        currentContext?.contextID
    }
}

private struct DOMRequestChildNodesParameters: Encodable {
    let nodeId: Int
    let depth: Int
}

private struct DOMRequestNodeParameters: Encodable {
    let objectId: String
}

private struct DOMQuerySelectorParameters: Encodable {
    let nodeId: Int
    let selector: String
}

private struct RuntimeEvaluateParameters: Encodable {
    let expression: String
    let objectGroup: String?
    let includeCommandLineAPI: Bool?
    let doNotPauseOnExceptionsAndMuteConsole: Bool?
    let returnByValue: Bool?
    let generatePreview: Bool?
    let emulateUserGesture: Bool?
}

private struct DOMNodeIdentifierParameters: Encodable {
    let nodeId: Int
}

private struct DOMSetAttributeValueParameters: Encodable {
    let nodeId: Int
    let name: String
    let value: String
}

private struct DOMRemoveAttributeParameters: Encodable {
    let nodeId: Int
    let name: String
}

private struct DOMHighlightNodeParameters: Encodable {
    let nodeId: Int
    let reveal: Bool
    let highlightConfig = DOMHighlightConfig(showInfo: false)
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private func normalizedDocumentURL(_ documentURL: String?) -> String? {
    guard let documentURL, !documentURL.isEmpty else {
        return nil
    }
    guard var components = URLComponents(string: documentURL) else {
        return documentURL
    }
    components.fragment = nil
    return components.string ?? documentURL
}

extension WIDOMInspector {
    func restoreInspectorHighlightAfterPointerDisconnect() async {
        if let contextID = currentContext?.contextID,
           document.selectedNode != nil {
            await syncSelectedNodeHighlight(contextID: contextID)
        } else {
            try? await hideHighlight()
        }
    }
}

#if DEBUG
extension WIDOMInspector {
    package enum TestInspectorMessage {
        case requestChildren(nodeID: Int, depth: Int, contextID: DOMContextID)
        case highlight(nodeID: Int, reveal: Bool, contextID: DOMContextID)
        case requestSnapshotReload(reason: String, contextID: DOMContextID)
    }

    package var testCurrentContextID: DOMContextID? {
        currentContext?.contextID
    }

    package var testCurrentDocumentURL: String? {
        currentContext?.documentURL
    }

    package var testIsReady: Bool {
        if case .ready = phase {
            return true
        }
        return false
    }

    package func testHandleTransportEvent(_ envelope: WITransportEventEnvelope) async {
        await handleTransportEvent(envelope)
    }

    package func testHandleInspectorMessage(_ message: TestInspectorMessage) {
        switch message {
        case let .requestChildren(nodeID, depth, contextID):
            Task { @MainActor [weak self] in
                await self?.performChildRequest(nodeID: nodeID, depth: depth, contextID: contextID)
            }
        case let .highlight(nodeID, reveal, contextID):
            guard currentContext?.contextID == contextID else {
                return
            }
            Task { @MainActor [weak self] in
                try? await self?.highlightNode(nodeID, reveal: reveal)
            }
        case let .requestSnapshotReload(_, contextID):
            guard let context = currentContext,
                  context.contextID == contextID,
                  let targetIdentifier = phase.targetIdentifier
            else {
                return
            }
            startLoadingDocumentEnsuringLoadingState(
                for: context,
                targetIdentifier: targetIdentifier,
                depth: configuration.snapshotDepth,
                isFreshDocument: false
            )
        }
    }

    package func testHandleInspectorSelection(_ payload: DOMSelectionSnapshotPayload?) {
        handleInspectorSelection(payload)
    }

    package func testWaitForBootstrap() async {
        await bootstrapTask?.value
    }

    package var testIsPageReadyForSelection: Bool {
        isPageReadyForSelection
    }

    package func testSetLoadingPhase(targetIdentifier: String) {
        guard let currentContext else {
            return
        }
        setPhase(.loadingDocument(currentContext, targetIdentifier: targetIdentifier))
    }

    package func testSetSelectionAvailability(
        pageWebView: WKWebView?,
        transportAttached: Bool,
        contextID: DOMContextID?,
        targetIdentifier: String?
    ) {
        setPageWebView(pageWebView)
        setDOMTransportAttached(transportAttached)

        guard let contextID else {
            currentContext = nil
            setPhase(.idle)
            return
        }

        let context = DOMContext(contextID: contextID, documentURL: nil)
        currentContext = context
        if let targetIdentifier {
            setPhase(.ready(context, targetIdentifier: targetIdentifier))
        } else {
            setPhase(.loadingDocument(context, targetIdentifier: nil))
        }
    }

    package func testDetachSharedTransportOnly() async {
        await sharedTransport.detach(client: .dom)
        setDOMTransportAttached(false)
    }

    package func testBeginFreshContext(
        documentURL: String?,
        targetIdentifier: String?,
        loadImmediately: Bool,
        isFreshDocument: Bool
    ) async {
        await beginFreshContext(
            documentURL: documentURL,
            targetIdentifier: targetIdentifier,
            loadImmediately: loadImmediately,
            isFreshDocument: isFreshDocument,
            reason: "testBeginFreshContext"
        )
    }

    package func testSetPendingInspectSelection(
        nodeID: Int,
        contextID: DOMContextID,
        outstandingLocalIDs: [UInt64],
        scopedRootLocalIDs: [UInt64]? = nil,
        activeStrategy: String? = nil,
        activeRequestGeneration: UInt64 = 0
    ) {
        let trackedIDs = Set(
            outstandingLocalIDs.map {
                DOMNodeModel.ID(documentIdentity: document.documentIdentity, localID: $0)
            }
        )
        let scopedRootIDs = (scopedRootLocalIDs ?? outstandingLocalIDs).map {
            DOMNodeModel.ID(documentIdentity: document.documentIdentity, localID: $0)
        }
        let resolvedActiveStrategy: SelectionMaterializationStrategy
        switch activeStrategy {
        case SelectionMaterializationStrategy.frameRelated.rawValue:
            resolvedActiveStrategy = .frameRelated
        case SelectionMaterializationStrategy.nestedDocumentRoots.rawValue:
            resolvedActiveStrategy = .nestedDocumentRoots
        case SelectionMaterializationStrategy.genericIncomplete.rawValue:
            resolvedActiveStrategy = .genericIncomplete
        case SelectionMaterializationStrategy.body.rawValue:
            resolvedActiveStrategy = .body
        case SelectionMaterializationStrategy.html.rawValue:
            resolvedActiveStrategy = .html
        case SelectionMaterializationStrategy.structuredChild.rawValue:
            resolvedActiveStrategy = .structuredChild
        case SelectionMaterializationStrategy.root.rawValue:
            resolvedActiveStrategy = .root
        default:
            resolvedActiveStrategy = .none
        }
        pendingInspectSelection = PendingInspectSelection(
            nodeID: nodeID,
            contextID: contextID,
            selectorPath: nil,
            resolutionTargetIdentifier: phase.targetIdentifier ?? sharedTransport.currentPageTargetIdentifier() ?? "page-test",
            transaction: selectionTransaction(for: contextID),
            scopedMaterializationRootNodeIDs: scopedRootIDs,
            materializedAncestorNodeIDs: trackedIDs,
            outstandingMaterializationNodeIDs: trackedIDs,
            activeMaterializationStrategy: resolvedActiveStrategy,
            activeRequestGeneration: activeRequestGeneration,
            genericDispatchDeferralCount: 0
        )
    }

    package func testSetLoadingPhaseCurrentContext(targetIdentifier: String) {
        guard let currentContext else {
            return
        }
        setPhase(.loadingDocument(currentContext, targetIdentifier: targetIdentifier))
    }

    package func testRefreshCurrentDocumentFromTransport(
        targetIdentifier: String,
        depth: Int,
        isFreshDocument: Bool
    ) async throws {
        guard let contextID = currentContext?.contextID else {
            return
        }
        try await refreshCurrentDocumentFromTransport(
            contextID: contextID,
            targetIdentifier: targetIdentifier,
            depth: depth,
            isFreshDocument: isFreshDocument
        )
    }

    package var testHasDeferredLoadingMutationState: Bool {
        deferredLoadingMutationState != nil
    }

    package func testMaterializePendingInspectSelection(
        nodeID: Int,
        contextID: DOMContextID,
        targetIdentifier: String,
        selectorPath: String? = nil
    ) async -> String {
        let outcome = await materializePendingInspectSelection(
            nodeID: nodeID,
            selectorPath: selectorPath,
            contextID: contextID,
            targetIdentifier: targetIdentifier,
            transaction: selectionTransaction(for: contextID)
        )
        switch outcome {
        case .requested:
            return "requested"
        case .waitingForMutation:
            return "waitingForMutation"
        case .exhausted:
            return "exhausted"
        }
    }

    package var testPendingInspectScopedMaterializationRootLocalIDs: [UInt64] {
        pendingInspectSelection?.scopedMaterializationRootNodeIDs.map(\.localID) ?? []
    }

    package var testDocumentRootLocalID: UInt64? {
        document.rootNode?.localID
    }

    package var testDocumentRootChildLocalIDs: [UInt64] {
        document.rootNode?.visibleDOMTreeChildren.map(\.localID) ?? []
    }

    package var testHasPendingInspectSelection: Bool {
        pendingInspectSelection != nil
    }

    package var testPendingChildRequestNodeIDs: [Int] {
        pendingChildRequests.keys
            .map(\.nodeID)
            .sorted()
    }

    package func testRegisterPendingChildRequest(
        nodeID: Int,
        contextID: DOMContextID,
        reportsToFrontend: Bool
    ) {
        _ = registerPendingChildRequest(
            nodeID: nodeID,
            contextID: contextID,
            reportsToFrontend: reportsToFrontend
        )
    }

    package func testApplyMutationBundleAndFinishPendingInspectMaterialization(
        _ bundle: DOMGraphMutationBundle,
        contextID: DOMContextID
    ) async {
        document.applyMutationBundle(bundle)
        let rejectedStructuralMutationParentLocalIDs = document.consumeRejectedStructuralMutationParentLocalIDs()
        recordPendingInspectProgressIfNeeded(
            from: bundle,
            contextID: contextID,
            reason: "test.bundle",
            rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
        )
        await applyPendingInspectSelectionIfPossible()
        await finishPendingInspectMaterialization(
            from: bundle,
            contextID: contextID,
            rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
        )
        await applyPendingInspectSelectionIfPossible()
        await finishPendingChildRequests(
            from: bundle,
            contextID: contextID,
            rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
        )
        await advancePendingInspectMaterializationIfIdle(
            contextID: contextID
        )
    }

    package func testHandleMutationBundleThroughTransportPath(
        _ bundle: DOMGraphMutationBundle,
        contextID: DOMContextID
    ) async {
        document.applyMutationBundle(bundle)
        let rejectedStructuralMutationParentLocalIDs = document.consumeRejectedStructuralMutationParentLocalIDs()
        recordPendingInspectProgressIfNeeded(
            from: bundle,
            contextID: contextID,
            reason: "test.transportBundle",
            rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
        )
        await applyPendingInspectSelectionIfPossible()
        await finishPendingInspectMaterialization(
            from: bundle,
            contextID: contextID,
            rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
        )
        await applyPendingInspectSelectionIfPossible()
        await finishPendingChildRequests(
            from: bundle,
            contextID: contextID,
            rejectedStructuralMutationParentLocalIDs: rejectedStructuralMutationParentLocalIDs
        )
        await advancePendingInspectMaterializationIfIdle(
            contextID: contextID
        )
    }
}
#endif
