import Foundation
import OSLog
import WebKit
import WebInspectorTransport

@MainActor
final class DOMTransportDriver: NSObject, DOMPageDriving, PageAgent, InspectorTransportCapabilityProviding {
    private struct SetChildNodesParams: Decodable {
        let parentId: Int
        let nodes: [WITransportDOMNode]
    }

    private struct InspectParams: Decodable {
        let nodeId: Int
    }

    private struct ChildNodeInsertedParams: Decodable {
        let parentNodeId: Int
        let previousNodeId: Int?
        let node: WITransportDOMNode
    }

    private struct ChildNodeRemovedParams: Decodable {
        let parentNodeId: Int
        let nodeId: Int
    }

    private struct ChildNodeCountUpdatedParams: Decodable {
        let nodeId: Int
        let childNodeCount: Int
    }

    private struct AttributeModifiedParams: Decodable {
        let nodeId: Int
        let name: String
        let value: String
    }

    private struct AttributeRemovedParams: Decodable {
        let nodeId: Int
        let name: String
    }

    private struct CharacterDataModifiedParams: Decodable {
        let nodeId: Int
        let characterData: String
    }

    private struct SelectionUpdate {
        let requiredDepth: Int
        let payload: DOMSelectionSnapshotPayload
    }

    private struct EntrySelectionFallback {
        let requiredDepth: Int
        let payload: DOMSelectionSnapshotPayload
    }

    private struct SelectionRequest {
        let token: Int
        let continuation: CheckedContinuation<DOMSelectionModeResult, Error>
    }

    fileprivate struct CSSMatchedStylesResponse: Decodable {
        let matchedCSSRules: [CSSRuleMatch]?
    }

    fileprivate struct CSSInlineStylesResponse: Decodable {
        let inlineStyle: CSSStylePayload?
        let attributesStyle: CSSStylePayload?
    }

    fileprivate struct CSSRuleMatch: Decodable {
        let rule: CSSRulePayload
        let matchingSelectors: [Int]
    }

    fileprivate struct CSSRulePayload: Decodable {
        let selectorList: CSSSelectorListPayload
        let sourceURL: String?
        let style: CSSStylePayload
        let groupings: [CSSGroupingPayload]?
    }

    fileprivate struct CSSSelectorListPayload: Decodable {
        let text: String
        let selectors: [CSSSelectorPayload]
    }

    fileprivate struct CSSSelectorPayload: Decodable {
        let text: String
    }

    fileprivate struct CSSGroupingPayload: Decodable {
        let text: String?
    }

    fileprivate struct CSSStylePayload: Decodable {
        let cssProperties: [CSSPropertyPayload]
    }

    fileprivate struct CSSPropertyPayload: Decodable {
        let name: String
        let value: String
        let priority: String?
        let parsedOk: Bool?
        let status: String?
        let implicit: Bool?
    }

    private let registry: WISharedTransportRegistry
    private let logger = Logger(subsystem: "WebInspectorKit", category: "DOMTransportDriver")
    private let eventConsumerIdentifier = UUID()
    private weak var graphStore: DOMGraphStore?
    weak var eventSink: (any DOMProtocolEventSink)?

    weak var webView: WKWebView?

    private var configuration: DOMConfiguration
    private var lease: WISharedTransportRegistry.Lease?
    private var attachTask: Task<Void, Never>?
    private var autoSnapshotEnabled = false

    private var childNodeContinuations: [Int: [CheckedContinuation<[WITransportDOMNode], Error>]] = [:]
    private var selectionRequest: SelectionRequest?
    private var selectionTask: Task<Void, Never>?
    private var nextSelectionToken = 1
    private var pendingSelectedNodeID: Int?

    private var nextUndoToken = 1
    private var undoStack: [Int] = []
    private var redoStack: [Int] = []

    init(
        configuration: DOMConfiguration,
        graphStore: DOMGraphStore,
        registry: WISharedTransportRegistry = .shared
    ) {
        self.configuration = configuration
        self.graphStore = graphStore
        self.registry = registry
    }

    isolated deinit {
        tearDownLifecycle()
    }

    package var inspectorTransportCapabilities: Set<InspectorTransportCapability> {
        lease?.inspectorTransportCapabilities ?? []
    }

    package var inspectorTransportSupportSnapshot: WITransportSupportSnapshot? {
        lease?.supportSnapshot
    }

    func updateConfiguration(_ configuration: DOMConfiguration) {
        self.configuration = configuration
    }

    func setAutoSnapshot(enabled: Bool) async {
        autoSnapshotEnabled = enabled
    }

    func rememberPendingSelection(nodeId: Int?) {
        pendingSelectedNodeID = nodeId
    }

    func reloadDocument(preserveState: Bool) async throws {
        let requestedDepth = preserveState ? configuration.fullReloadDepth : configuration.rootBootstrapDepth
        let root = try await fetchDocumentTree(maxDepth: requestedDepth, hydrateUnknownChildren: false)
        applyDocument(root: root, preserveState: preserveState)
    }

    func reloadDocument(preserveState: Bool, requestedDepth: Int?) async throws {
        let resolvedDepth = max(
            preserveState ? configuration.fullReloadDepth : configuration.rootBootstrapDepth,
            requestedDepth ?? 0
        )
        let root = try await fetchDocumentTree(maxDepth: resolvedDepth, hydrateUnknownChildren: false)
        applyDocument(root: root, preserveState: preserveState)
    }

    func requestChildNodes(parentNodeId: Int) async throws -> [DOMGraphNodeDescriptor] {
        let childNodes = try await requestChildNodePayloads(parentNodeId: parentNodeId)
        return childNodes.map(nodeDescriptor(from:))
    }

    func captureSnapshot(maxDepth: Int) async throws -> String {
        let envelope = try await captureSnapshotEnvelope(maxDepth: maxDepth)
        return try jsonString(from: envelope)
    }

    func captureSubtree(nodeId: Int, maxDepth: Int) async throws -> String {
        let envelope = try await captureSubtreeEnvelope(nodeId: nodeId, maxDepth: maxDepth)
        return try jsonString(from: envelope)
    }

    func matchedStyles(nodeId: Int, maxRules: Int) async throws -> DOMMatchedStylesPayload {
        let lease = try activeLease()
        try await lease.ensureAttached()
        try await lease.ensureCSSDomainReady()

        async let inlineResponse = inlineStylesResult(nodeId: nodeId, lease: lease)
        async let matchedResponse = matchedStylesResult(nodeId: nodeId, lease: lease)

        return try await makeMatchedStylesPayload(
            nodeId: nodeId,
            maxRules: maxRules,
            inlineResult: inlineResponse,
            matchedResult: matchedResponse
        )
    }

    func captureSnapshotEnvelope(maxDepth: Int) async throws -> Any {
        let root = try await fetchDocumentTree(maxDepth: maxDepth, hydrateUnknownChildren: true)
        return makeSnapshotEnvelope(root: root)
    }

    func captureSubtreeEnvelope(nodeId: Int, maxDepth: Int) async throws -> Any {
        let subtree = try await fetchSubtree(nodeId: nodeId, maxDepth: maxDepth)
        return nodeDictionary(from: subtree)
    }

    func beginSelectionMode() async throws -> DOMSelectionModeResult {
        guard webView != nil else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        let lease = try activeLease()
        try await lease.ensureAttached()
        try await lease.ensureDOMEventIngress()

        if selectionRequest != nil {
            await cancelSelectionMode()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let token = installSelectionRequest(continuation)
            selectionTask?.cancel()
            selectionTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    _ = try await lease.sendPage(EngineDOMSetInspectModeEnabled(enabled: true))
                } catch {
                    self.finishSelectionRequest(token: token, result: .failure(error))
                }
            }
        }
    }

    func cancelSelectionMode() async {
        selectionTask?.cancel()
        selectionTask = nil
        finishSelectionRequest(result: .success(.init(cancelled: true, requiredDepth: 0)))
        do {
            _ = try await activeLease().sendPage(EngineDOMSetInspectModeEnabled(enabled: false))
        } catch {
            // Best effort.
        }
    }

    func highlight(nodeId: Int) async {
        do {
            _ = try await activeLease().sendPage(EngineDOMHighlightNode(nodeId: nodeId))
        } catch {
            logger.debug("highlight failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func hideHighlight() async {
        do {
            _ = try await activeLease().sendPage(EngineDOMHideHighlight())
        } catch {
            logger.debug("hide highlight failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeNode(nodeId: Int) async {
        do {
            _ = try await activeLease().sendPage(EngineDOMRemoveNode(nodeId: nodeId))
        } catch {
            logger.debug("remove node failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeNodeWithUndo(nodeId: Int) async -> Int? {
        do {
            let lease = try activeLease()
            try await lease.ensureAttached()
            _ = try await lease.sendPage(EngineDOMMarkUndoableState())
            _ = try await lease.sendPage(EngineDOMRemoveNode(nodeId: nodeId))

            let token = nextUndoToken
            nextUndoToken += 1
            undoStack.append(token)
            redoStack.removeAll(keepingCapacity: true)
            return token
        } catch {
            logger.debug("remove node with undo failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func undoRemoveNode(undoToken: Int) async -> Bool {
        guard undoStack.last == undoToken else {
            return false
        }
        do {
            _ = try await activeLease().sendPage(EngineDOMUndo())
            undoStack.removeLast()
            redoStack.append(undoToken)
            return true
        } catch {
            logger.debug("undo failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func redoRemoveNode(undoToken: Int, nodeId: Int?) async -> Bool {
        _ = nodeId
        guard redoStack.last == undoToken else {
            return false
        }
        do {
            _ = try await activeLease().sendPage(EngineDOMRedo())
            redoStack.removeLast()
            undoStack.append(undoToken)
            return true
        } catch {
            logger.debug("redo failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func setAttribute(nodeId: Int, name: String, value: String) async {
        do {
            _ = try await activeLease().sendPage(
                EngineDOMSetAttributeValue(nodeId: nodeId, name: name, value: value)
            )
        } catch {
            logger.debug("set attribute failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeAttribute(nodeId: Int, name: String) async {
        do {
            _ = try await activeLease().sendPage(
                EngineDOMRemoveAttribute(nodeId: nodeId, name: name)
            )
        } catch {
            logger.debug("remove attribute failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func selectionCopyText(nodeId: Int, kind: DOMSelectionCopyKind) async throws -> String {
        switch kind {
        case .html:
            let response = try await activeLease().sendPage(
                WITransportCommands.DOM.GetOuterHTML(nodeId: nodeId)
            )
            return response.outerHTML

        case .selectorPath:
            if let selectorPath = try await resolvedSelectorPath(for: nodeId), !selectorPath.isEmpty {
                return selectorPath
            }
            return ""

        case .xpath:
            if let xpath = try await resolvedXPath(for: nodeId), !xpath.isEmpty {
                return xpath
            }
            return ""
        }
    }
}

// MARK: - PageAgent

extension DOMTransportDriver {
    func willDetachPageWebView(_ webView: WKWebView) {
        _ = webView
        tearDownLifecycle()
    }

    func didAttachPageWebView(_ webView: WKWebView, previousWebView: WKWebView?) {
        if previousWebView !== webView {
            undoStack.removeAll(keepingCapacity: true)
            redoStack.removeAll(keepingCapacity: true)
            pendingSelectedNodeID = nil
        }

        let lease = registry.acquireLease(for: webView)
        self.lease = lease
        lease.addDOMConsumer(eventConsumerIdentifier) { [weak self] event in
            self?.handle(event)
        }

        attachTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await lease.ensureAttached()
                if self.autoSnapshotEnabled {
                    try await self.reloadDocument(preserveState: false)
                }
                try await lease.ensureDOMEventIngress()
            } catch {
                guard self.shouldLogAttachFailure(error, lease: lease) else {
                    self.attachTask = nil
                    return
                }
                self.logger.error("dom transport attach failed: \(error.localizedDescription, privacy: .public)")
            }

            self.attachTask = nil
        }
    }

    func didClearPageWebView() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
        pendingSelectedNodeID = nil
    }
}

private extension DOMTransportDriver {
    func tearDownLifecycle() {
        attachTask?.cancel()
        attachTask = nil
        selectionTask?.cancel()
        selectionTask = nil
        pendingSelectedNodeID = nil
        finishPendingChildNodeRequests(with: WITransportError.transportClosed)
        finishSelectionRequest(result: .success(.init(cancelled: true, requiredDepth: 0)))
        releaseLease()
    }

    func releaseLease() {
        lease?.removeDOMConsumer(eventConsumerIdentifier)
        lease?.release()
        lease = nil
    }

    func activeLease() throws -> WISharedTransportRegistry.Lease {
        guard let lease else {
            throw WebInspectorCoreError.scriptUnavailable
        }
        return lease
    }

    func installSelectionRequest(
        _ continuation: CheckedContinuation<DOMSelectionModeResult, Error>
    ) -> Int {
        let token = nextSelectionToken
        nextSelectionToken += 1
        selectionRequest = SelectionRequest(token: token, continuation: continuation)
        return token
    }

    func activeSelectionToken() -> Int? {
        selectionRequest?.token
    }

    private func takeSelectionRequest(matching token: Int? = nil) -> SelectionRequest? {
        guard let selectionRequest else {
            return nil
        }
        if let token, selectionRequest.token != token {
            return nil
        }
        self.selectionRequest = nil
        return selectionRequest
    }

    func finishSelectionRequest(
        token: Int? = nil,
        result: Result<DOMSelectionModeResult, Error>
    ) {
        guard let request = takeSelectionRequest(matching: token) else {
            return
        }

        switch result {
        case let .success(value):
            request.continuation.resume(returning: value)
        case let .failure(error):
            request.continuation.resume(throwing: error)
        }
    }

    func shouldLogAttachFailure(_ error: Error, lease: WISharedTransportRegistry.Lease) -> Bool {
        if lease !== self.lease {
            return false
        }
        if error is CancellationError {
            return false
        }
        if let transportError = error as? WITransportError,
           case .transportClosed = transportError {
            return false
        }
        return true
    }

    func fetchDocumentTree(maxDepth: Int) async throws -> WITransportDOMNode {
        try await fetchDocumentTree(maxDepth: maxDepth, hydrateUnknownChildren: true)
    }

    func fetchDocumentTree(
        maxDepth: Int,
        hydrateUnknownChildren: Bool
    ) async throws -> WITransportDOMNode {
        let lease = try activeLease()
        try await lease.ensureAttached()
        try await lease.ensureDOMEventIngress()

        let requestedDepth = max(1, maxDepth)
        let rootResponse = try await lease.sendPage(
            WITransportCommands.DOM.GetDocument(depth: requestedDepth)
        )
        return try await populateChildren(
            for: rootResponse.root,
            depthRemaining: requestedDepth,
            allowUnknownChildren: hydrateUnknownChildren
        )
    }

    func fetchSubtree(nodeId: Int, maxDepth: Int) async throws -> WITransportDOMNode {
        if let entry = entry(for: nodeId) {
            let baseNode = makeNode(from: entry)
            return try await populateChildren(
                for: baseNode,
                depthRemaining: max(0, maxDepth),
                allowUnknownChildren: false
            )
        }

        let root = try await fetchDocumentTree(maxDepth: max(maxDepth, configuration.fullReloadDepth))
        if let node = findNode(nodeId: nodeId, in: root) {
            return try await populateChildren(
                for: node,
                depthRemaining: max(0, maxDepth),
                allowUnknownChildren: false
            )
        }

        throw WebInspectorCoreError.subtreeUnavailable
    }

    func populateChildren(
        for node: WITransportDOMNode,
        depthRemaining: Int,
        allowUnknownChildren: Bool
    ) async throws -> WITransportDOMNode {
        guard depthRemaining > 0 else {
            return node
        }

        if let existingChildren = node.children {
            var resolvedChildren: [WITransportDOMNode] = []
            resolvedChildren.reserveCapacity(existingChildren.count)
            for child in existingChildren {
                let populated = try await populateChildren(
                    for: child,
                    depthRemaining: depthRemaining - 1,
                    allowUnknownChildren: false
                )
                resolvedChildren.append(populated)
            }

            return WITransportDOMNode(
                nodeId: node.nodeId,
                nodeType: node.nodeType,
                nodeName: node.nodeName,
                localName: node.localName,
                nodeValue: node.nodeValue,
                childNodeCount: node.childNodeCount ?? resolvedChildren.count,
                children: resolvedChildren,
                attributes: node.attributes,
                documentURL: node.documentURL,
                baseURL: node.baseURL,
                frameId: node.frameId,
                layoutFlags: node.layoutFlags
            )
        }

        let childCount = node.childNodeCount ?? 0
        if node.childNodeCount == 0 {
            return node
        }
        guard allowUnknownChildren || childCount > 0 else {
            return node
        }

        let immediateChildren = try await requestChildNodePayloads(parentNodeId: node.nodeId)
        var resolvedChildren: [WITransportDOMNode] = []
        resolvedChildren.reserveCapacity(immediateChildren.count)
        for child in immediateChildren {
            let populated = try await populateChildren(
                for: child,
                depthRemaining: depthRemaining - 1,
                allowUnknownChildren: false
            )
            resolvedChildren.append(populated)
        }

        return WITransportDOMNode(
            nodeId: node.nodeId,
            nodeType: node.nodeType,
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            childNodeCount: node.childNodeCount ?? resolvedChildren.count,
            children: resolvedChildren,
            attributes: node.attributes,
            documentURL: node.documentURL,
            baseURL: node.baseURL,
            frameId: node.frameId,
            layoutFlags: node.layoutFlags
        )
    }

    func requestChildNodePayloads(parentNodeId: Int) async throws -> [WITransportDOMNode] {
        let lease = try activeLease()
        try await lease.ensureAttached()
        try await lease.ensureDOMEventIngress()

        return try await withCheckedThrowingContinuation { continuation in
            childNodeContinuations[parentNodeId, default: []].append(continuation)

            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.resume(throwing: WITransportError.transportClosed)
                    return
                }

                do {
                    _ = try await lease.sendPage(
                        EngineDOMRequestChildNodes(
                            nodeId: parentNodeId,
                            depth: configuration.expandedSubtreeFetchDepth
                        )
                    )
                } catch {
                    self.finishChildNodeRequests(for: parentNodeId, with: error)
                }
            }
        }
    }

    func handle(_ envelope: WITransportEventEnvelope) {
        switch envelope.method {
        case "DOM.setChildNodes":
            handleSetChildNodes(envelope)
        case "DOM.inspect":
            handleInspect(envelope)
        case "DOM.documentUpdated":
            handleDocumentUpdated()
        case "DOM.childNodeInserted",
             "DOM.childNodeRemoved",
             "DOM.childNodeCountUpdated",
             "DOM.attributeModified",
             "DOM.attributeRemoved",
             "DOM.characterDataModified":
            handleMutation(envelope)
        default:
            return
        }
    }

    func handleSetChildNodes(_ envelope: WITransportEventEnvelope) {
        forwardProtocolEvent(envelope)
        guard let params = try? envelope.decodeParams(SetChildNodesParams.self) else {
            return
        }

        finishChildNodeRequests(for: params.parentId, with: params.nodes)
        guard let parentEntry = entry(for: params.parentId) else {
            return
        }
        graphStore?.applyMutationBundle(
            .init(events: [
                .setChildNodes(parentNodeID: parentEntry.id.nodeID, nodes: params.nodes.map(nodeDescriptor(from:))),
            ])
        )
        invalidateMatchedStylesIfNeeded(changedNodeID: parentEntry.id.nodeID)
    }

    func handleInspect(_ envelope: WITransportEventEnvelope) {
        forwardProtocolEvent(envelope)
        guard let params = try? envelope.decodeParams(InspectParams.self) else {
            return
        }
        guard let token = activeSelectionToken() else {
            return
        }

        selectionTask?.cancel()
        selectionTask = nil

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                let selectionUpdate = try await self.makeSelectionUpdate(for: params.nodeId)
                _ = try? await self.activeLease().sendPage(
                    EngineDOMSetInspectModeEnabled(enabled: false)
                )
                let didApplySelection = self.graphStore?.applySelectionSnapshot(selectionUpdate.payload) ?? false
                if didApplySelection {
                    self.pendingSelectedNodeID = nil
                    self.invalidateMatchedStylesForCurrentSelection()
                } else {
                    _ = self.graphStore?.applySelectionSnapshot(nil)
                    self.pendingSelectedNodeID = selectionUpdate.payload.nodeID
                }
                self.finishSelectionRequest(
                    token: token,
                    result: .success(
                        .init(cancelled: false, requiredDepth: selectionUpdate.requiredDepth)
                    )
                )
            } catch {
                _ = try? await self.activeLease().sendPage(
                    EngineDOMSetInspectModeEnabled(enabled: false)
                )
                self.finishSelectionRequest(token: token, result: .failure(error))
            }
        }
    }

    func handleDocumentUpdated() {
        finishPendingDocumentBoundOperations()
        forwardProtocolEvent(method: "DOM.documentUpdated", paramsData: Data("{}".utf8))
        pendingSelectedNodeID = nil
        guard autoSnapshotEnabled else {
            graphStore?.resetForDocumentUpdate()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await self.reloadDocument(preserveState: false)
            } catch {
                self.logger.debug("document reload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func handleMutation(_ envelope: WITransportEventEnvelope) {
        forwardProtocolEvent(envelope)
        guard let event = mutationEvent(for: envelope) else {
            return
        }

        graphStore?.applyMutationBundle(.init(events: [event]))
        restorePendingSelectionIfPossible()
        invalidateMatchedStylesIfNeeded(for: event)
    }

    func requiredDepth(for nodeId: Int) async throws -> Int {
        if let resolvedDepth = try await resolveInDocument(
            initialDepth: configuration.fullReloadDepth,
            resolve: { root in
                self.findDepth(nodeId: nodeId, in: root, currentDepth: 0)
            }
        ) {
            return resolvedDepth
        }

        if let entry = entry(for: nodeId),
           let fallback = selectionFallback(for: entry, fallbackNodeId: nodeId) {
            return fallback.requiredDepth
        }

        return configuration.selectionRecoveryDepth
    }

    func depth(for entry: DOMEntry) -> Int {
        var depth = 0
        var current = entry.parent
        while let resolved = current {
            depth += 1
            current = resolved.parent
        }
        return depth
    }

    func findDepth(nodeId: Int, in node: WITransportDOMNode, currentDepth: Int) -> Int? {
        if node.nodeId == nodeId {
            return currentDepth
        }
        for child in node.children ?? [] {
            if let depth = findDepth(nodeId: nodeId, in: child, currentDepth: currentDepth + 1) {
                return depth
            }
        }
        return nil
    }

    func resolveInDocument<T>(
        initialDepth: Int,
        resolve: (WITransportDOMNode) -> T?
    ) async throws -> T? {
        var requestedDepth = max(1, initialDepth)

        while true {
            let root = try await fetchDocumentTree(maxDepth: requestedDepth)
            if let resolved = resolve(root) {
                return resolved
            }

            guard let nextDepth = nextDocumentSearchDepth(afterLoading: root, currentDepth: requestedDepth) else {
                return nil
            }
            requestedDepth = nextDepth
        }
    }

    func nextDocumentSearchDepth(afterLoading root: WITransportDOMNode, currentDepth: Int) -> Int? {
        guard let expandableDepth = deepestExpandableDepth(in: root, currentDepth: 0),
              expandableDepth > currentDepth else {
            return nil
        }

        return max(currentDepth * 2, expandableDepth)
    }

    func deepestExpandableDepth(in node: WITransportDOMNode, currentDepth: Int) -> Int? {
        let resolvedChildren = node.children?.count ?? 0
        let declaredChildCount = node.childNodeCount ?? resolvedChildren

        var deepest: Int?
        if declaredChildCount > resolvedChildren {
            deepest = currentDepth + 1
        }

        for child in node.children ?? [] {
            if let childDepth = deepestExpandableDepth(in: child, currentDepth: currentDepth + 1) {
                deepest = max(deepest ?? childDepth, childDepth)
            }
        }

        return deepest
    }

    func mutationEvent(for envelope: WITransportEventEnvelope) -> DOMGraphMutationEvent? {
        switch envelope.method {
        case "DOM.childNodeInserted":
            guard let params = try? envelope.decodeParams(ChildNodeInsertedParams.self) else {
                return nil
            }
            return .childNodeInserted(
                parentNodeID: params.parentNodeId,
                previousNodeID: params.previousNodeId,
                node: nodeDescriptor(from: params.node)
            )

        case "DOM.childNodeRemoved":
            guard let params = try? envelope.decodeParams(ChildNodeRemovedParams.self) else {
                return nil
            }
            return .childNodeRemoved(parentNodeID: params.parentNodeId, nodeID: params.nodeId)

        case "DOM.childNodeCountUpdated":
            guard let params = try? envelope.decodeParams(ChildNodeCountUpdatedParams.self) else {
                return nil
            }
            return .childNodeCountUpdated(
                nodeID: params.nodeId,
                childCount: params.childNodeCount,
                layoutFlags: nil,
                isRendered: nil
            )

        case "DOM.attributeModified":
            guard let params = try? envelope.decodeParams(AttributeModifiedParams.self) else {
                return nil
            }
            return .attributeModified(
                nodeID: params.nodeId,
                name: params.name,
                value: params.value,
                layoutFlags: nil,
                isRendered: nil
            )

        case "DOM.attributeRemoved":
            guard let params = try? envelope.decodeParams(AttributeRemovedParams.self) else {
                return nil
            }
            return .attributeRemoved(
                nodeID: params.nodeId,
                name: params.name,
                layoutFlags: nil,
                isRendered: nil
            )

        case "DOM.characterDataModified":
            guard let params = try? envelope.decodeParams(CharacterDataModifiedParams.self) else {
                return nil
            }
            return .characterDataModified(
                nodeID: params.nodeId,
                value: params.characterData,
                layoutFlags: nil,
                isRendered: nil
            )

        default:
            return nil
        }
    }

    private func makeSelectionUpdate(for nodeId: Int) async throws -> SelectionUpdate {
        if let resolved = try await resolveInDocument(
            initialDepth: configuration.fullReloadDepth,
            resolve: { root in
                self.findSelectionUpdate(
                    nodeId: nodeId,
                    in: root,
                    ancestors: [],
                    currentDepth: 0
                )
            }
        ) {
            return resolved
        }

        if let entry = entry(for: nodeId),
           let fallback = selectionFallback(for: entry, fallbackNodeId: nodeId) {
            return SelectionUpdate(
                requiredDepth: fallback.requiredDepth,
                payload: fallback.payload
            )
        }

        return SelectionUpdate(
            requiredDepth: configuration.selectionRecoveryDepth,
            payload: .init(
                nodeID: nodeId,
                preview: "",
                attributes: [],
                path: [],
                selectorPath: "",
                styleRevision: 0
            )
        )
    }

    func finishChildNodeRequests(for parentNodeId: Int, with nodes: [WITransportDOMNode]) {
        let continuations = childNodeContinuations.removeValue(forKey: parentNodeId) ?? []
        for continuation in continuations {
            continuation.resume(returning: nodes)
        }
    }

    func finishChildNodeRequests(for parentNodeId: Int, with error: Error) {
        let continuations = childNodeContinuations.removeValue(forKey: parentNodeId) ?? []
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    func finishPendingChildNodeRequests(with error: Error) {
        let pending = childNodeContinuations
        childNodeContinuations.removeAll(keepingCapacity: false)
        for continuations in pending.values {
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
        }
    }

    func finishPendingDocumentBoundOperations() {
        finishPendingChildNodeRequests(with: CancellationError())

        let hadPendingSelection = selectionRequest != nil || selectionTask != nil
        selectionTask?.cancel()
        selectionTask = nil
        finishSelectionRequest(result: .success(.init(cancelled: true, requiredDepth: 0)))

        guard hadPendingSelection else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                _ = try await self.activeLease().sendPage(
                    EngineDOMSetInspectModeEnabled(enabled: false)
                )
            } catch {
                // Best effort.
            }
        }
    }

    func makeSnapshotEnvelope(root: WITransportDOMNode) -> [String: Any] {
        var envelope: [String: Any] = [
            "root": nodeDictionary(from: root)
        ]

        if let selectedNodeId = selectedNodeID() {
            envelope["selectedNodeId"] = selectedNodeId
        }

        return envelope
    }

    func selectedNodeID() -> Int? {
        graphStore?.selectedEntry?.id.nodeID
    }

    func nodeDictionary(from node: WITransportDOMNode) -> [String: Any] {
        var dictionary: [String: Any] = [
            "nodeId": node.nodeId,
            "nodeType": node.nodeType,
            "nodeName": node.nodeName,
            "localName": node.localName,
            "nodeValue": node.nodeValue,
        ]

        if let childNodeCount = node.childNodeCount {
            dictionary["childNodeCount"] = childNodeCount
        }
        if let children = node.children {
            dictionary["children"] = children.map(nodeDictionary(from:))
        }
        if let attributes = node.attributes {
            dictionary["attributes"] = attributes
        }
        if let documentURL = node.documentURL {
            dictionary["documentURL"] = documentURL
        }
        if let baseURL = node.baseURL {
            dictionary["baseURL"] = baseURL
        }
        if let frameId = node.frameId {
            dictionary["frameId"] = frameId
        }
        if let layoutFlags = node.layoutFlags {
            dictionary["layoutFlags"] = layoutFlags
        }

        return dictionary
    }

    func jsonString(from payload: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw WebInspectorCoreError.serializationFailed
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    func inlineStylesResult(
        nodeId: Int,
        lease: WISharedTransportRegistry.Lease
    ) async -> Result<CSSInlineStylesResponse, Error> {
        do {
            return .success(try await lease.sendPage(EngineCSSGetInlineStylesForNode(nodeId: nodeId)))
        } catch {
            logger.debug("inline styles fetch failed for node \(nodeId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    func matchedStylesResult(
        nodeId: Int,
        lease: WISharedTransportRegistry.Lease
    ) async -> Result<CSSMatchedStylesResponse, Error> {
        do {
            return .success(try await lease.sendPage(EngineCSSGetMatchedStylesForNode(nodeId: nodeId)))
        } catch {
            logger.debug("matched styles fetch failed for node \(nodeId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    func makeMatchedStylesPayload(
        nodeId: Int,
        maxRules: Int,
        inlineResult: Result<CSSInlineStylesResponse, Error>,
        matchedResult: Result<CSSMatchedStylesResponse, Error>
    ) throws -> DOMMatchedStylesPayload {
        let inline: CSSInlineStylesResponse?
        let matched: CSSMatchedStylesResponse?

        switch inlineResult {
        case let .success(response):
            inline = response
        case .failure:
            inline = nil
        }

        switch matchedResult {
        case let .success(response):
            matched = response
        case .failure:
            matched = nil
        }

        if case let .failure(inlineError) = inlineResult,
           case .failure = matchedResult {
            throw inlineError
        }
        if case let .failure(matchedError) = matchedResult,
           case .failure = inlineResult {
            throw matchedError
        }

        let effectiveMaxRules = maxRules > 0 ? maxRules : Int.max
        var rules: [DOMMatchedStyleRule] = []
        rules.reserveCapacity(8)

        if let inlineRule = makeInlineRule(from: inline?.inlineStyle ?? inline?.attributesStyle) {
            rules.append(inlineRule)
        }

        let authorRules = (matched?.matchedCSSRules ?? []).compactMap(makeAuthorRule(from:))
        rules.append(contentsOf: authorRules)

        let truncated = rules.count > effectiveMaxRules
        if truncated {
            rules = Array(rules.prefix(effectiveMaxRules))
        }

        return DOMMatchedStylesPayload(
            nodeId: nodeId,
            rules: rules,
            truncated: truncated,
            blockedStylesheetCount: 0
        )
    }

    func makeInlineRule(from style: CSSStylePayload?) -> DOMMatchedStyleRule? {
        guard let style else {
            return nil
        }
        let declarations = style.cssProperties.compactMap(makeDeclaration(from:))
        guard !declarations.isEmpty else {
            return nil
        }
        return DOMMatchedStyleRule(
            origin: .inline,
            selectorText: "element.style",
            declarations: declarations,
            sourceLabel: "<element>",
            atRuleContext: []
        )
    }

    func makeAuthorRule(from match: CSSRuleMatch) -> DOMMatchedStyleRule? {
        let declarations = match.rule.style.cssProperties.compactMap(makeDeclaration(from:))
        guard !declarations.isEmpty else {
            return nil
        }

        let selectorText: String
        if !match.matchingSelectors.isEmpty {
            let matchingSelectors: [String] = match.matchingSelectors.compactMap { index in
                guard match.rule.selectorList.selectors.indices.contains(index) else {
                    return nil
                }
                return match.rule.selectorList.selectors[index].text
            }
            selectorText = matchingSelectors.isEmpty ? match.rule.selectorList.text : matchingSelectors.joined(separator: ", ")
        } else {
            selectorText = match.rule.selectorList.text
        }

        let sourceLabel: String
        if let sourceURL = match.rule.sourceURL,
           let candidate = URL(string: sourceURL)?.lastPathComponent,
           !candidate.isEmpty {
            sourceLabel = candidate
        } else {
            sourceLabel = "<style>"
        }

        return DOMMatchedStyleRule(
            origin: .author,
            selectorText: selectorText,
            declarations: declarations,
            sourceLabel: sourceLabel,
            atRuleContext: match.rule.groupings?.compactMap(\.text) ?? []
        )
    }

    func makeDeclaration(from property: CSSPropertyPayload) -> DOMMatchedStyleDeclaration? {
        if property.parsedOk == false {
            return nil
        }
        if property.implicit == true {
            return nil
        }
        if let status = property.status,
           status == "inactive" || status == "disabled" {
            return nil
        }

        return DOMMatchedStyleDeclaration(
            name: property.name,
            value: property.value,
            important: property.priority == "important"
        )
    }

    func findNode(nodeId: Int, in node: WITransportDOMNode) -> WITransportDOMNode? {
        if node.nodeId == nodeId {
            return node
        }
        for child in node.children ?? [] {
            if let found = findNode(nodeId: nodeId, in: child) {
                return found
            }
        }
        return nil
    }

    func selectorPath(for nodeId: Int) -> String? {
        guard let entry = entry(for: nodeId) else {
            return nil
        }
        if !entry.selectorPath.isEmpty {
            return entry.selectorPath
        }
        return makeSelectorPath(for: entry)
    }

    func xpath(for nodeId: Int) -> String? {
        guard let entry = entry(for: nodeId) else {
            return nil
        }
        return makeXPath(for: entry)
    }

    func resolvedSelectorPath(for nodeId: Int) async throws -> String? {
        if let pathNodes = try await resolvedPathNodes(for: nodeId) {
            let selectorPath = selectorPath(for: pathNodes)
            if !selectorPath.isEmpty {
                return selectorPath
            }
        }

        guard let entry = entry(for: nodeId) else {
            return nil
        }
        if !entry.selectorPath.isEmpty {
            return entry.selectorPath
        }
        guard hasCompleteSiblingContext(for: entry) else {
            return nil
        }
        return makeSelectorPath(for: entry)
    }

    func resolvedXPath(for nodeId: Int) async throws -> String? {
        if let pathNodes = try await resolvedPathNodes(for: nodeId) {
            let xpath = xpath(for: pathNodes)
            if !xpath.isEmpty {
                return xpath
            }
        }

        guard let entry = entry(for: nodeId), hasCompleteSiblingContext(for: entry) else {
            return nil
        }
        return makeXPath(for: entry)
    }

    func resolvedPathNodes(for nodeId: Int) async throws -> [WITransportDOMNode]? {
        guard let entry = entry(for: nodeId) else {
            return nil
        }

        return try await resolveInDocument(
            initialDepth: max(configuration.fullReloadDepth, depth(for: entry)),
            resolve: { root in
                self.findPathNodes(nodeId: nodeId, in: root, ancestors: [])
            }
        )
    }

    func entry(for nodeId: Int) -> DOMEntry? {
        graphStore?.entry(forNodeID: nodeId)
    }

    func selectionPayload(from entry: DOMEntry, fallbackNodeId nodeId: Int) -> DOMSelectionSnapshotPayload {
        DOMSelectionSnapshotPayload(
            nodeID: entry.id.nodeID,
            preview: entry.preview.isEmpty ? preview(for: entry) : entry.preview,
            attributes: entry.attributes,
            path: entry.path.isEmpty ? pathComponents(for: entry) : entry.path,
            selectorPath: selectorPath(for: nodeId) ?? "",
            styleRevision: entry.styleRevision
        )
    }

    func selectionPayload(
        from node: WITransportDOMNode,
        ancestors: [WITransportDOMNode]
    ) -> DOMSelectionSnapshotPayload {
        let pathNodes = ancestors + [node]
        return DOMSelectionSnapshotPayload(
            nodeID: node.nodeId,
            preview: preview(for: node),
            attributes: selectionAttributes(for: node),
            path: pathNodes.map(pathComponent(for:)).filter { !$0.isEmpty },
            selectorPath: selectorPath(for: pathNodes),
            styleRevision: 0
        )
    }

    private func findSelectionUpdate(
        nodeId: Int,
        in node: WITransportDOMNode,
        ancestors: [WITransportDOMNode],
        currentDepth: Int
    ) -> SelectionUpdate? {
        if node.nodeId == nodeId {
            return SelectionUpdate(
                requiredDepth: currentDepth,
                payload: selectionPayload(from: node, ancestors: ancestors)
            )
        }

        let nextAncestors = ancestors + [node]
        for child in node.children ?? [] {
            if let resolved = findSelectionUpdate(
                nodeId: nodeId,
                in: child,
                ancestors: nextAncestors,
                currentDepth: currentDepth + 1
            ) {
                return resolved
            }
        }

        return nil
    }

    func findPathNodes(
        nodeId: Int,
        in node: WITransportDOMNode,
        ancestors: [WITransportDOMNode]
    ) -> [WITransportDOMNode]? {
        if node.nodeId == nodeId {
            return ancestors + [node]
        }

        let nextAncestors = ancestors + [node]
        for child in node.children ?? [] {
            if let path = findPathNodes(nodeId: nodeId, in: child, ancestors: nextAncestors) {
                return path
            }
        }

        return nil
    }

    private func selectionFallback(for entry: DOMEntry, fallbackNodeId nodeId: Int) -> EntrySelectionFallback? {
        return EntrySelectionFallback(
            requiredDepth: max(configuration.selectionRecoveryDepth, depth(for: entry)),
            payload: selectionPayload(from: entry, fallbackNodeId: nodeId)
        )
    }

    func applyDocument(root: WITransportDOMNode, preserveState: Bool) {
        let previousSelection = preserveState ? (pendingSelectedNodeID ?? selectedNodeID()) : nil
        let snapshot = DOMGraphSnapshot(
            root: nodeDescriptor(from: root),
            selectedNodeID: previousSelection
        )

        graphStore?.resetForDocumentUpdate()
        if preserveState == false {
            pendingSelectedNodeID = nil
        }
        graphStore?.applySnapshot(snapshot)
        if graphStore?.selectedEntry?.id.nodeID == pendingSelectedNodeID {
            pendingSelectedNodeID = nil
        }
        invalidateMatchedStylesForCurrentSelection()
    }

    func nodeDescriptor(from node: WITransportDOMNode) -> DOMGraphNodeDescriptor {
        let layoutFlags = node.layoutFlags ?? []
        return DOMGraphNodeDescriptor(
            nodeID: node.nodeId,
            nodeType: node.nodeType,
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            attributes: selectionAttributes(for: node),
            childCount: node.childNodeCount ?? node.children?.count ?? 0,
            layoutFlags: layoutFlags,
            isRendered: layoutFlags.contains("rendered"),
            children: (node.children ?? []).map(nodeDescriptor(from:))
        )
    }

    func invalidateMatchedStylesIfNeeded(for event: DOMGraphMutationEvent) {
        switch event {
        case let .childNodeInserted(parentNodeID, _, _),
             let .childNodeRemoved(parentNodeID, _),
             let .setChildNodes(parentNodeID, _):
            invalidateMatchedStylesIfNeeded(changedNodeID: parentNodeID)
        case let .attributeModified(nodeID, _, _, _, _),
             let .attributeRemoved(nodeID, _, _, _),
             let .characterDataModified(nodeID, _, _, _),
             let .childNodeCountUpdated(nodeID, _, _, _):
            invalidateMatchedStylesIfNeeded(changedNodeID: nodeID)
        case .replaceSubtree, .documentUpdated:
            invalidateMatchedStylesForCurrentSelection()
        }
    }

    func restorePendingSelectionIfPossible() {
        guard let pendingSelectedNodeID,
              let entry = entry(for: pendingSelectedNodeID),
              let fallback = selectionFallback(for: entry, fallbackNodeId: pendingSelectedNodeID),
              graphStore?.applySelectionSnapshot(fallback.payload) == true else {
            return
        }

        self.pendingSelectedNodeID = nil
        invalidateMatchedStylesForCurrentSelection()
    }

    func invalidateMatchedStylesIfNeeded(changedNodeID: Int) {
        guard let selectedEntry = graphStore?.selectedEntry else {
            return
        }
        if selectedEntry.id.nodeID == changedNodeID || isAncestor(nodeID: changedNodeID, of: selectedEntry) {
            graphStore?.invalidateMatchedStyles(for: selectedEntry.id.nodeID)
        }
    }

    func invalidateMatchedStylesForCurrentSelection() {
        graphStore?.invalidateMatchedStyles(for: nil)
    }

    func isAncestor(nodeID: Int, of entry: DOMEntry) -> Bool {
        var current = entry.parent
        while let resolved = current {
            if resolved.id.nodeID == nodeID {
                return true
            }
            current = resolved.parent
        }
        return false
    }

    func forwardProtocolEvent(_ envelope: WITransportEventEnvelope) {
        forwardProtocolEvent(method: envelope.method, paramsData: envelope.paramsData)
    }

    func forwardProtocolEvent(method: String, paramsData: Data) {
        eventSink?.domDidReceiveProtocolEvent(method: method, paramsData: paramsData)
    }

    func preview(for entry: DOMEntry) -> String {
        if !entry.preview.isEmpty {
            return entry.preview
        }
        return preview(
            nodeType: entry.nodeType,
            nodeName: entry.nodeName,
            localName: entry.localName,
            nodeValue: entry.nodeValue,
            attributes: entry.attributes
        )
    }

    func preview(for node: WITransportDOMNode) -> String {
        preview(
            nodeType: node.nodeType,
            nodeName: node.nodeName,
            localName: node.localName,
            nodeValue: node.nodeValue,
            attributes: selectionAttributes(for: node)
        )
    }

    func preview(
        nodeType: Int,
        nodeName: String,
        localName: String,
        nodeValue: String,
        attributes: [DOMAttribute]
    ) -> String {
        if nodeType == 3 {
            return nodeValue
        }

        let resolvedName = localName.isEmpty ? nodeName.lowercased() : localName
        guard !resolvedName.isEmpty else {
            return nodeValue
        }

        let renderedAttributes = attributes
            .prefix(3)
            .map { attribute in
                "\(attribute.name)=\"\(attribute.value)\""
            }
            .joined(separator: " ")

        if renderedAttributes.isEmpty {
            return "<\(resolvedName)>"
        }
        return "<\(resolvedName) \(renderedAttributes)>"
    }

    func pathComponents(for entry: DOMEntry) -> [String] {
        var components: [String] = []
        var current: DOMEntry? = entry

        while let resolved = current {
            let component = pathComponent(
                nodeType: resolved.nodeType,
                nodeName: resolved.nodeName,
                localName: resolved.localName
            )
            if !component.isEmpty {
                components.append(component)
            }
            current = resolved.parent
        }

        return components.reversed()
    }

    func pathComponent(for node: WITransportDOMNode) -> String {
        pathComponent(nodeType: node.nodeType, nodeName: node.nodeName, localName: node.localName)
    }

    func pathComponent(nodeType: Int, nodeName: String, localName: String) -> String {
        switch nodeType {
        case 3:
            return "#text"
        case 9:
            return ""
        default:
            return localName.isEmpty ? nodeName.lowercased() : localName
        }
    }

    func selectionAttributes(for node: WITransportDOMNode) -> [DOMAttribute] {
        guard let attributes = node.attributes else {
            return []
        }

        var result: [DOMAttribute] = []
        var index = 0
        while index + 1 < attributes.count {
            result.append(
                DOMAttribute(
                    nodeId: node.nodeId,
                    name: attributes[index],
                    value: attributes[index + 1]
                )
            )
            index += 2
        }
        return result
    }

    func selectorPath(for nodes: [WITransportDOMNode]) -> String {
        var components: [String] = []

        for (index, node) in nodes.enumerated().reversed() {
            guard node.nodeType == 1 else {
                continue
            }

            let attributes = selectionAttributes(for: node)
            if let idAttribute = attributes.first(where: { $0.name == "id" && !$0.value.isEmpty }) {
                components.append("#\(cssIdentifier(idAttribute.value))")
                break
            }

            let name = node.localName.isEmpty ? node.nodeName.lowercased() : node.localName
            guard !name.isEmpty else {
                continue
            }

            var component = name
            if let classAttribute = attributes.first(where: { $0.name == "class" && !$0.value.isEmpty }) {
                let classNames = classAttribute.value
                    .split(whereSeparator: \.isWhitespace)
                    .prefix(2)
                    .map { ".\(cssIdentifier(String($0)))" }
                    .joined()
                if !classNames.isEmpty {
                    component += classNames
                }
            }
            if index > 0,
               let nthChild = nthChildIndex(of: node, within: nodes[index - 1].children ?? []),
               let matchingSiblingCount = matchingSelectorSiblingCount(
                for: node,
                within: nodes[index - 1].children ?? []
               ),
               matchingSiblingCount > 1 {
                component += ":nth-child(\(nthChild))"
            }
            components.append(component)
        }

        return components.reversed().joined(separator: " > ")
    }

    func makeSelectorPath(for entry: DOMEntry) -> String {
        var components: [String] = []
        var current: DOMEntry? = entry

        while let resolved = current {
            guard resolved.nodeType == 1 else {
                current = resolved.parent
                continue
            }

            if let idAttribute = resolved.attributes.first(where: { $0.name == "id" && !$0.value.isEmpty }) {
                components.append("#\(cssIdentifier(idAttribute.value))")
                break
            }

            var component = resolved.localName.isEmpty ? resolved.nodeName.lowercased() : resolved.localName
            if let classAttribute = resolved.attributes.first(where: { $0.name == "class" && !$0.value.isEmpty }) {
                let classNames = classAttribute.value
                    .split(whereSeparator: \.isWhitespace)
                    .prefix(2)
                    .map { ".\(cssIdentifier(String($0)))" }
                    .joined()
                if !classNames.isEmpty {
                    component += classNames
                }
            }
            if let parent = resolved.parent,
               parent.children.count >= parent.childCount,
               let nthChild = nthChildIndex(of: resolved, within: parent.children),
               matchingSelectorSiblingCount(for: resolved, within: parent.children) > 1 {
                component += ":nth-child(\(nthChild))"
            }
            components.append(component)
            current = resolved.parent
        }

        return components.reversed().joined(separator: " > ")
    }

    func xpath(for nodes: [WITransportDOMNode]) -> String {
        var components: [String] = []

        for (index, node) in nodes.enumerated().reversed() {
            if node.nodeType == 9 {
                continue
            }
            let rawName = node.localName.isEmpty ? node.nodeName.lowercased() : node.localName
            let name = rawName.isEmpty ? "node()" : rawName.lowercased()

            let siblings = index > 0
                ? matchingXPathSiblings(forName: name, within: nodes[index - 1].children ?? [])
                : [node]

            let indexInSiblings = siblings.firstIndex(where: { $0.nodeId == node.nodeId }).map { $0 + 1 } ?? 1
            let component = siblings.count > 1 ? "\(name)[\(indexInSiblings)]" : name
            components.append(component)
        }

        return "/" + components.reversed().joined(separator: "/")
    }

    func makeXPath(for entry: DOMEntry) -> String {
        var components: [String] = []
        var current: DOMEntry? = entry

        while let resolved = current {
            if resolved.nodeType == 9 {
                current = resolved.parent
                continue
            }
            let rawName = resolved.localName.isEmpty ? resolved.nodeName.lowercased() : resolved.localName
            let name = rawName.isEmpty ? "node()" : rawName.lowercased()

            let siblings = resolved.parent?.children.filter {
                ($0.localName.isEmpty ? $0.nodeName.lowercased() : $0.localName.lowercased()) == name
            } ?? [resolved]

            let index: Int
            if let siblingIndex = siblings.firstIndex(where: { $0.id == resolved.id }) {
                index = siblingIndex + 1
            } else {
                index = 1
            }

            let component = siblings.count > 1 ? "\(name)[\(index)]" : name
            components.append(component)
            current = resolved.parent
        }

        return "/" + components.reversed().joined(separator: "/")
    }

    func nthChildIndex(of node: WITransportDOMNode, within siblings: [WITransportDOMNode]) -> Int? {
        let elementSiblings = siblings.filter { $0.nodeType == 1 }
        guard let index = elementSiblings.firstIndex(where: { $0.nodeId == node.nodeId }) else {
            return nil
        }
        return index + 1
    }

    func nthChildIndex(of node: DOMEntry, within siblings: [DOMEntry]) -> Int? {
        let elementSiblings = siblings.filter { $0.nodeType == 1 }
        guard let index = elementSiblings.firstIndex(where: { $0.id == node.id }) else {
            return nil
        }
        return index + 1
    }

    func matchingSelectorSiblingCount(for node: WITransportDOMNode, within siblings: [WITransportDOMNode]) -> Int? {
        let targetSelectorStem = selectorStem(for: node)
        guard !targetSelectorStem.isEmpty else {
            return nil
        }
        return siblings.filter { selectorStem(for: $0) == targetSelectorStem }.count
    }

    func matchingSelectorSiblingCount(for node: DOMEntry, within siblings: [DOMEntry]) -> Int {
        let targetSelectorStem = selectorStem(for: node)
        guard !targetSelectorStem.isEmpty else {
            return 0
        }
        return siblings.filter { selectorStem(for: $0) == targetSelectorStem }.count
    }

    func selectorStem(for node: WITransportDOMNode) -> String {
        let name = node.localName.isEmpty ? node.nodeName.lowercased() : node.localName
        guard !name.isEmpty else {
            return ""
        }

        var component = name
        let attributes = selectionAttributes(for: node)
        if let classAttribute = attributes.first(where: { $0.name == "class" && !$0.value.isEmpty }) {
            let classNames = classAttribute.value
                .split(whereSeparator: \.isWhitespace)
                .prefix(2)
                .map { ".\(cssIdentifier(String($0)))" }
                .joined()
            component += classNames
        }
        return component
    }

    func selectorStem(for node: DOMEntry) -> String {
        let name = node.localName.isEmpty ? node.nodeName.lowercased() : node.localName
        guard !name.isEmpty else {
            return ""
        }

        var component = name
        if let classAttribute = node.attributes.first(where: { $0.name == "class" && !$0.value.isEmpty }) {
            let classNames = classAttribute.value
                .split(whereSeparator: \.isWhitespace)
                .prefix(2)
                .map { ".\(cssIdentifier(String($0)))" }
                .joined()
            component += classNames
        }
        return component
    }

    func matchingXPathSiblings(forName name: String, within siblings: [WITransportDOMNode]) -> [WITransportDOMNode] {
        siblings.filter {
            let siblingName = $0.localName.isEmpty ? $0.nodeName.lowercased() : $0.localName.lowercased()
            return siblingName == name
        }
    }

    func hasCompleteSiblingContext(for entry: DOMEntry) -> Bool {
        var current: DOMEntry? = entry
        while let resolved = current, let parent = resolved.parent {
            guard parent.children.count >= parent.childCount else {
                return false
            }
            current = parent
        }
        return true
    }

    func cssIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: " ", with: "\\ ")
    }

    func makeNode(from entry: DOMEntry) -> WITransportDOMNode {
        WITransportDOMNode(
            nodeId: entry.id.nodeID,
            nodeType: entry.nodeType,
            nodeName: entry.nodeName,
            localName: entry.localName,
            nodeValue: entry.nodeValue,
            childNodeCount: entry.childCount,
            children: nil,
            attributes: entry.attributes.flatMap { [$0.name, $0.value] },
            documentURL: nil,
            baseURL: nil,
            frameId: nil,
            layoutFlags: entry.layoutFlags
        )
    }
}

private struct EngineDOMRequestChildNodes: WITransportPageCommand, Sendable {
    struct Parameters: Encodable, Sendable {
        let nodeId: Int
        let depth: Int?
    }

    typealias Response = WIEmptyTransportResponse
    let parameters: Parameters

    init(nodeId: Int, depth: Int?) {
        parameters = Parameters(nodeId: nodeId, depth: depth)
    }

    static let method = "DOM.requestChildNodes"
}

private struct EngineDOMRemoveNode: WITransportPageCommand, Sendable {
    struct Parameters: Encodable, Sendable {
        let nodeId: Int
    }

    typealias Response = WIEmptyTransportResponse
    let parameters: Parameters

    init(nodeId: Int) {
        parameters = Parameters(nodeId: nodeId)
    }

    static let method = "DOM.removeNode"
}

private struct EngineDOMSetAttributeValue: WITransportPageCommand, Sendable {
    struct Parameters: Encodable, Sendable {
        let nodeId: Int
        let name: String
        let value: String
    }

    typealias Response = WIEmptyTransportResponse
    let parameters: Parameters

    init(nodeId: Int, name: String, value: String) {
        parameters = Parameters(nodeId: nodeId, name: name, value: value)
    }

    static let method = "DOM.setAttributeValue"
}

private struct EngineDOMRemoveAttribute: WITransportPageCommand, Sendable {
    struct Parameters: Encodable, Sendable {
        let nodeId: Int
        let name: String
    }

    typealias Response = WIEmptyTransportResponse
    let parameters: Parameters

    init(nodeId: Int, name: String) {
        parameters = Parameters(nodeId: nodeId, name: name)
    }

    static let method = "DOM.removeAttribute"
}

private struct EngineDOMMarkUndoableState: WITransportPageCommand, Sendable {
    typealias Response = WIEmptyTransportResponse
    let parameters = WIEmptyTransportParameters()

    static let method = "DOM.markUndoableState"
}

private struct EngineDOMUndo: WITransportPageCommand, Sendable {
    typealias Response = WIEmptyTransportResponse
    let parameters = WIEmptyTransportParameters()

    static let method = "DOM.undo"
}

private struct EngineDOMRedo: WITransportPageCommand, Sendable {
    typealias Response = WIEmptyTransportResponse
    let parameters = WIEmptyTransportParameters()

    static let method = "DOM.redo"
}

private struct EngineDOMHighlightNode: WITransportPageCommand, Sendable {
    struct RGBAColor: Encodable, Sendable {
        let r: Int
        let g: Int
        let b: Int
        let a: Double?

        init(r: Int, g: Int, b: Int, a: Double? = nil) {
            self.r = r
            self.g = g
            self.b = b
            self.a = a
        }
    }

    struct HighlightConfig: Encodable, Sendable {
        let showInfo: Bool?
        let contentColor: RGBAColor?
        let paddingColor: RGBAColor?
        let borderColor: RGBAColor?
        let marginColor: RGBAColor?
    }

    struct Parameters: Encodable, Sendable {
        let nodeId: Int
        let highlightConfig: HighlightConfig
        let showRulers: Bool?
    }

    typealias Response = WIEmptyTransportResponse
    let parameters: Parameters

    init(nodeId: Int) {
        parameters = Parameters(
            nodeId: nodeId,
            highlightConfig: HighlightConfig(
                showInfo: false,
                contentColor: RGBAColor(r: 111, g: 168, b: 220, a: 0.66),
                paddingColor: RGBAColor(r: 147, g: 196, b: 125, a: 0.55),
                borderColor: RGBAColor(r: 255, g: 229, b: 153, a: 0.66),
                marginColor: RGBAColor(r: 246, g: 178, b: 107, a: 0.66)
            ),
            showRulers: false
        )
    }

    static let method = "DOM.highlightNode"
}

private struct EngineDOMHideHighlight: WITransportPageCommand, Sendable {
    typealias Response = WIEmptyTransportResponse
    let parameters = WIEmptyTransportParameters()

    static let method = "DOM.hideHighlight"
}

private struct EngineDOMSetInspectModeEnabled: WITransportPageCommand, Sendable {
    struct HighlightConfig: Encodable, Sendable {
        let showInfo: Bool?
    }

    struct Parameters: Encodable, Sendable {
        let enabled: Bool
        let highlightConfig: HighlightConfig?
        let showRulers: Bool?
    }

    typealias Response = WIEmptyTransportResponse
    let parameters: Parameters

    init(enabled: Bool) {
        parameters = Parameters(
            enabled: enabled,
            highlightConfig: enabled ? HighlightConfig(showInfo: false) : nil,
            showRulers: false
        )
    }

    static let method = "DOM.setInspectModeEnabled"
}

private struct EngineCSSGetMatchedStylesForNode: WITransportPageCommand, Sendable {
    struct Parameters: Encodable, Sendable {
        let nodeId: Int
        let includePseudo: Bool?
        let includeInherited: Bool?
    }

    typealias Response = DOMTransportDriver.CSSMatchedStylesResponse
    let parameters: Parameters

    init(nodeId: Int) {
        parameters = Parameters(nodeId: nodeId, includePseudo: false, includeInherited: false)
    }

    static let method = "CSS.getMatchedStylesForNode"
}

private struct EngineCSSGetInlineStylesForNode: WITransportPageCommand, Sendable {
    struct Parameters: Encodable, Sendable {
        let nodeId: Int
    }

    typealias Response = DOMTransportDriver.CSSInlineStylesResponse
    let parameters: Parameters

    init(nodeId: Int) {
        parameters = Parameters(nodeId: nodeId)
    }

    static let method = "CSS.getInlineStylesForNode"
}

#if DEBUG
extension DOMTransportDriver {
    func testNodeDescriptor(from node: WITransportDOMNode) -> DOMGraphNodeDescriptor {
        nodeDescriptor(from: node)
    }

    func testXPath(for nodes: [WITransportDOMNode]) -> String {
        xpath(for: nodes)
    }

    func testApplyDocument(root: WITransportDOMNode, preserveState: Bool) {
        applyDocument(root: root, preserveState: preserveState)
    }

    func testPopulateChildren(
        for node: WITransportDOMNode,
        depthRemaining: Int,
        allowUnknownChildren: Bool
    ) async throws -> WITransportDOMNode {
        try await populateChildren(
            for: node,
            depthRemaining: depthRemaining,
            allowUnknownChildren: allowUnknownChildren
        )
    }
}
#endif
