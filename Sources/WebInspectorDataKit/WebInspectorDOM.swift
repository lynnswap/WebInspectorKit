import Foundation
import WebInspectorProxyKit

package enum WebInspectorDOMWireEvent: Sendable {
    case dom(WebInspectorRoutedEvent<DOM.Event>)
    case inspector(WebInspectorRoutedEvent<Inspector.Event>)
    case css(WebInspectorRoutedEvent<CSS.Event>)
    case page(WebInspectorRoutedEvent<Page.Event>)
}

private struct WebInspectorDOMRecoveryRequest: Error, Sendable {
    let reason: WebInspectorRecoveryReason
    let fingerprint: WebInspectorRecoveryFingerprint
    let resetPublishedDocument: Bool
}

/// Sole semantic owner of DOM, CSS, highlight, and element-picker state.
package actor WebInspectorDOMFeature: WebInspectorModelFeature {
    package static let id = WebInspectorFeatureID.dom

    private enum PickerEnableIntent {
        case activate
        case cancelAfterEnable
        case selected(Result<DOMNode.ID, any Error>)
        case resolveRemoteObject(
            Runtime.RemoteObject.ID,
            WebInspectorCanonicalDOMEventScope
        )
    }

    private enum PickerOperationPhase {
        case enabling(
            task: Task<Void, Never>,
            intent: PickerEnableIntent
        )
        case active
        case resolvingSelection(task: Task<Void, Never>)
        case disabling(task: Task<Void, Never>)
        case retiring

        var task: Task<Void, Never>? {
            switch self {
            case let .enabling(task, _),
                let .resolvingSelection(task),
                let .disabling(task):
                task
            case .active, .retiring:
                nil
            }
        }
    }

    private struct PickerOperation {
        let id: UInt64
        let continuation: CheckedContinuation<DOMNode.ID, any Error>
        var phase: PickerOperationPhase
    }

    private enum PickerState {
        case idle
        case operation(PickerOperation)
        case unavailable(WebInspectorFeatureError)
    }

    private let registry: WebInspectorFeatureRegistry
    private let pickerPublisher: _WebInspectorStatePublisher<WebInspectorElementPickerState>
    private var connection: WebInspectorFeatureConnection?
    private var store: WebInspectorModelStoreSink?
    private var orderedScope: WebInspectorOrderedEventScope<WebInspectorDOMWireEvent>?
    private var reducer: WebInspectorCanonicalDOMReducer?
    private var cssReducer: WebInspectorCanonicalCSSReducer?
    private var currentBindingScope: WebInspectorCanonicalDOMEventScope?
    private var loadedStyles: [CSSStyles.ID: WebInspectorCSSStylesRecord] = [:]
    private var state: WebInspectorFeatureState = .disabled
    private var recoveryBudget = WebInspectorFeatureRecoveryBudget()
    private var closeRequested = false
    private var explicitRetryRequested = false
    private var retryWaiter: CheckedContinuation<Void, Never>?

    private var pickerState: PickerState = .idle
    private var nextPickerOperationID: UInt64 = 0

    package init(
        registry: WebInspectorFeatureRegistry,
        pickerPublisher: _WebInspectorStatePublisher<WebInspectorElementPickerState>
    ) {
        self.registry = registry
        self.pickerPublisher = pickerPublisher
    }

    package func run(
        connection: WebInspectorFeatureConnection,
        store: WebInspectorModelStoreSink
    ) async -> WebInspectorFeatureTermination {
        self.connection = connection
        self.store = store
        closeRequested = false
        explicitRetryRequested = false
        recoveryBudget = WebInspectorFeatureRecoveryBudget()
        // Do not replace the reducers here: after detach they still describe
        // the last committed records that the next bootstrap must delete in
        // its atomic attachment-generation replacement transaction.
        currentBindingScope = nil
        await publish(.synchronizing(generation: await currentGeneration()))

        while !closeRequested {
            do {
                try await runOrderedScope()
                return closeRequested ? .detached : .connectionFailed(
                    connectionFailure(
                        code: "dom.scope.ended",
                        phase: "events",
                        message: "The DOM event scope ended unexpectedly."
                    )
                )
            } catch is CancellationError {
                return .detached
            } catch let request as WebInspectorDOMRecoveryRequest {
                await orderedScope?.close()
                orderedScope = nil
                if request.resetPublishedDocument {
                    do {
                        try await resetPublishedDocument()
                    } catch {
                        return termination(for: error)
                    }
                }
                let generation = await currentGeneration()
                let decision = recoveryBudget.consume(
                    request.fingerprint,
                    generation: generation
                )
                guard decision == .retry else {
                    let summary = WebInspectorFailureDescription(
                        code: "dom.recovery.exhausted",
                        phase: request.fingerprint.phase,
                        message: String(describing: request.reason)
                    )
                    await publish(
                        .unavailable(
                            generation: generation,
                            error: .recoveryBudgetExhausted(summary)
                        )
                    )
                    await waitForExplicitRetry()
                    recoveryBudget.begin(
                        generation: await currentGeneration(),
                        explicitRetry: true
                    )
                    continue
                }
                await publish(
                    .recovering(
                        generation: generation,
                        reason: request.reason
                    )
                )
            } catch {
                await orderedScope?.close()
                orderedScope = nil
                if isConnectionTerminal(error) {
                    return termination(for: error)
                }
                let generation = await currentGeneration()
                let summary = webInspectorFailureDescription(
                    error,
                    code: "dom.bootstrap.failed",
                    phase: "bootstrap"
                )
                await publish(
                    .unavailable(
                        generation: generation,
                        error: .bootstrap(summary)
                    )
                )
                await waitForExplicitRetry()
                recoveryBudget.begin(
                    generation: await currentGeneration(),
                    explicitRetry: true
                )
            }
        }
        return .detached
    }

    package func retry() async {
        guard case .unavailable = state else { return }
        explicitRetryRequested = true
        retryWaiter?.resume()
        retryWaiter = nil
    }

    package func close() async {
        guard !closeRequested else { return }
        closeRequested = true
        explicitRetryRequested = true
        retryWaiter?.resume()
        retryWaiter = nil
        await retirePicker(
            with: WebInspectorCommandError.containerClosed,
            disableBackend: true
        )
        await orderedScope?.close()
        orderedScope = nil
        connection = nil
        store = nil
        await publish(.disabled)
    }

    // MARK: DOM commands

    package func requestChildren(of id: DOMNode.ID, depth: Int) async throws {
        let rawID = try validatedRawNodeID(id)
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        do {
            try await connection.page.dom.requestChildNodes(rawID, depth: depth)
        } catch {
            throw webInspectorCommandError(error, featureID: .dom, phase: "DOM.requestChildNodes")
        }
    }

    package func setAttribute(
        _ name: String,
        value: String,
        on id: DOMNode.ID,
        undo: WebInspectorUndoPolicy
    ) async throws -> DOMMutationOutcome {
        let rawID = try validatedRawNodeID(id)
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        do {
            try await connection.page.dom.setAttributeValue(rawID, name: name, value: value)
            let capability = try await makeUndoCapabilityIfNeeded(undo)
            return DOMMutationOutcome(
                requestedNodeIDs: [id],
                appliedNodeIDs: [id],
                failures: [],
                undo: capability
            )
        } catch {
            throw webInspectorCommandError(error, featureID: .dom, phase: "DOM.setAttributeValue")
        }
    }

    package func setOuterHTML(
        _ html: String,
        of id: DOMNode.ID,
        undo: WebInspectorUndoPolicy
    ) async throws -> DOMMutationOutcome {
        let rawID = try validatedRawNodeID(id)
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        do {
            try await connection.page.dom.setOuterHTML(rawID, html: html)
            let capability = try await makeUndoCapabilityIfNeeded(undo)
            return DOMMutationOutcome(
                requestedNodeIDs: [id],
                appliedNodeIDs: [id],
                failures: [],
                undo: capability
            )
        } catch {
            throw webInspectorCommandError(error, featureID: .dom, phase: "DOM.setOuterHTML")
        }
    }

    package func removeNodes(
        _ ids: [DOMNode.ID],
        undo: WebInspectorUndoPolicy
    ) async throws -> DOMMutationOutcome {
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        var applied: [DOMNode.ID] = []
        var failures: [DOMMutationFailure] = []
        for id in ids {
            do {
                let rawID = try validatedRawNodeID(id)
                try await connection.page.dom.removeNode(rawID)
                applied.append(id)
            } catch {
                failures.append(
                    DOMMutationFailure(nodeID: id, message: String(describing: error))
                )
            }
        }
        let capability = applied.isEmpty
            ? nil
            : try await makeUndoCapabilityIfNeeded(undo)
        return DOMMutationOutcome(
            requestedNodeIDs: ids,
            appliedNodeIDs: applied,
            failures: failures,
            undo: capability
        )
    }

    package func text(
        _ representation: DOMTextRepresentation,
        for id: DOMNode.ID
    ) async throws -> String {
        switch representation {
        case .html:
            let rawID = try validatedRawNodeID(id)
            guard let connection else { throw WebInspectorCommandError.containerClosed }
            do { return try await connection.page.dom.outerHTML(of: rawID) }
            catch {
                throw webInspectorCommandError(error, featureID: .dom, phase: "DOM.getOuterHTML")
            }
        case .selectorPath, .xPath:
            guard var reducer else { throw WebInspectorCommandError.staleIdentifier }
            let snapshot = reducer.snapshot()
            return representation == .selectorPath
                ? snapshot.selectorPath(for: id)
                : snapshot.xPath(for: id)
        }
    }

    package func highlight(_ id: DOMNode.ID) async throws {
        let rawID = try validatedRawNodeID(id)
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        do { try await connection.page.dom.highlightNode(rawID) }
        catch {
            throw webInspectorCommandError(error, featureID: .dom, phase: "DOM.highlightNode")
        }
    }

    package func hideHighlight() async throws {
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        do { try await connection.page.dom.hideHighlight() }
        catch {
            throw webInspectorCommandError(error, featureID: .dom, phase: "DOM.hideHighlight")
        }
    }

    package func undo(in scope: WebInspectorDOMDocumentScopeStorage) async throws {
        try validate(scope)
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        do { try await connection.page.dom.undo() }
        catch { throw webInspectorCommandError(error, featureID: .dom, phase: "DOM.undo") }
    }

    package func redo(in scope: WebInspectorDOMDocumentScopeStorage) async throws {
        try validate(scope)
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        do { try await connection.page.dom.redo() }
        catch { throw webInspectorCommandError(error, featureID: .dom, phase: "DOM.redo") }
    }

    // MARK: CSS commands

    package func loadStyles(for id: DOMNode.ID) async throws -> CSSStyles.ID {
        let rawID = try validatedRawNodeID(id)
        guard let connection, let reducer, let canonical = reducer.record(for: id.canonicalStorage)
        else { throw WebInspectorCommandError.staleIdentifier }
        let stylesID = CSSStyles.ID(nodeID: id)
        let loading = WebInspectorCSSStylesRecord(
            nodeID: id,
            phase: .loading,
            sections: [],
            computedProperties: [],
            cascadeRevision: cssReducer?.cascadeRevision(in: id.canonicalStorage.documentScope) ?? 0
        )
        try await commitStyles(stylesID, record: loading, rank: canonical.insertionOrdinal)
        do {
            async let matched = connection.page.css.matchedStyles(for: rawID)
            async let inline = connection.page.css.inlineStyles(for: rawID)
            async let computed = connection.page.css.computedStyle(for: rawID)
            let record = WebInspectorCSSStylesRecord(
                nodeID: id,
                phase: .loaded,
                sections: CSSStyleSectionBuilder.makeSections(
                    matched: try await matched,
                    inline: try await inline
                ),
                computedProperties: try await computed.map(CSSComputedProperty.init),
                cascadeRevision: cssReducer?.cascadeRevision(in: id.canonicalStorage.documentScope) ?? 0
            )
            try await commitStyles(stylesID, record: record, rank: canonical.insertionOrdinal)
            return stylesID
        } catch {
            let failure = WebInspectorFeatureError.command(
                webInspectorFailureDescription(error, code: "css.load", phase: "CSS.loadStyles")
            )
            let failed = WebInspectorCSSStylesRecord(
                nodeID: id,
                phase: .failed(failure),
                sections: [],
                computedProperties: [],
                cascadeRevision: loading.cascadeRevision
            )
            try? await commitStyles(stylesID, record: failed, rank: canonical.insertionOrdinal)
            throw webInspectorCommandError(error, featureID: .dom, phase: "CSS.loadStyles")
        }
    }

    package func refreshStyles(_ id: CSSStyles.ID) async throws {
        _ = try await loadStyles(for: id.nodeID)
    }

    package func setProperty(
        _ propertyID: CSSStyleProperty.ID,
        enabled: Bool,
        undo: WebInspectorUndoPolicy
    ) async throws -> DOMUndoCapability? {
        guard let location = propertyLocation(for: propertyID), let connection
        else { throw WebInspectorCommandError.staleIdentifier }
        guard let text = CSSStyleTextRewriter.rewrittenStyleText(
            style: location.style,
            propertyIndex: location.propertyIndex,
            enabled: enabled
        ) else { throw WebInspectorCommandError.staleIdentifier }
        do {
            _ = try await connection.page.css.setStyleText(location.style.id, text: text)
            return try await makeUndoCapabilityIfNeeded(undo)
        } catch {
            throw webInspectorCommandError(error, featureID: .dom, phase: "CSS.setStyleText")
        }
    }

    package func setDeclarationText(
        _ text: String,
        for propertyID: CSSStyleProperty.ID,
        undo: WebInspectorUndoPolicy
    ) async throws -> DOMUndoCapability? {
        guard let location = propertyLocation(for: propertyID), let connection
        else { throw WebInspectorCommandError.staleIdentifier }
        guard let rewritten = CSSStyleTextRewriter.rewrittenStyleText(
            style: location.style,
            propertyIndex: location.propertyIndex,
            replacementText: text
        ) else { throw WebInspectorCommandError.staleIdentifier }
        do {
            _ = try await connection.page.css.setStyleText(location.style.id, text: rewritten)
            return try await makeUndoCapabilityIfNeeded(undo)
        } catch {
            throw webInspectorCommandError(error, featureID: .dom, phase: "CSS.setStyleText")
        }
    }

    // MARK: Picker

    package func pickElement() async throws -> DOMNode.ID {
        guard !closeRequested else {
            throw WebInspectorCommandError.containerClosed
        }
        switch pickerState {
        case .idle:
            break
        case let .unavailable(error):
            throw WebInspectorElementPickerError.unavailable(error)
        case .operation:
            throw WebInspectorElementPickerError.busy
        }
        guard let connection else { throw WebInspectorCommandError.containerClosed }
        nextPickerOperationID &+= 1
        let operationID = nextPickerOperationID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = Task {
                    await self.runPickerEnable(
                        operationID: operationID,
                        connection: connection
                    )
                }
                pickerState = .operation(
                    PickerOperation(
                        id: operationID,
                        continuation: continuation,
                        phase: .enabling(task: task, intent: .activate)
                    )
                )
                pickerPublisher.publish(.enabling)
            }
        } onCancel: {
            Task { await self.cancelPicker(operationID: operationID) }
        }
    }

    package func cancelElementPicker() async {
        guard case let .operation(operation) = pickerState else { return }
        cancelPicker(operationID: operation.id)
    }

    package func retryElementPicker() async {
        guard case .unavailable = pickerState else { return }
        pickerState = .idle
        pickerPublisher.publish(.idle)
    }

    // MARK: Ordered scope

    private func runOrderedScope() async throws {
        guard let connection, let store else { throw CancellationError() }
        let descriptor = WebInspectorOrderedScopeDescriptor<WebInspectorDOMWireEvent>(
            decoders: [
                DOMWireCoding.eventDecoder.routed().map(WebInspectorDOMWireEvent.dom),
                InspectorWireCoding.eventDecoder.routed().map(WebInspectorDOMWireEvent.inspector),
                CSSWireCoding.eventDecoder.routed().map(WebInspectorDOMWireEvent.css),
                PageWireCoding.eventDecoder.routed().map(WebInspectorDOMWireEvent.page),
            ],
            capabilities: [
                DOMWireCoding.capability,
                InspectorWireCoding.capability,
                CSSWireCoding.capability,
                PageWireCoding.capability,
            ]
        )
        let scope = try await connection.page.orderedScope(
            descriptor: descriptor,
            buffering: .bounded(2_048)
        )
        orderedScope = scope
        let reply = try await scope.command(DOMWireCoding.getDocument())
        let prefix = try await scope.drain(through: reply.boundary)
        if prefix.contains(where: invalidatesDOMBootstrap) {
            throw WebInspectorDOMRecoveryRequest(
                reason: .targetChanged,
                fingerprint: WebInspectorRecoveryFingerprint(
                    code: "dom.bootstrap.invalidated",
                    phase: "bootstrap"
                ),
                resetPublishedDocument: true
            )
        }
        let route = try featureScope(from: reply)
        let oldIDs: [DOMNode.ID]
        if var reducer {
            oldIDs = reducer.snapshot().records.map { DOMNode.ID(canonical: $0.id) }
        } else {
            oldIDs = []
        }
        let oldStyleIDs = Array(loadedStyles.keys)
        let baseReducer = WebInspectorCanonicalDOMReducer(
            storeID: connection.storeID,
            attachmentGeneration: connection.attachmentGeneration
        )
        let root = reply.value
        let boundary = reply.boundary.watermark.rawValue
        let result = try await store.commit(
            updating: webInspectorDOMBindingTimelineKey,
            initialValue: WebInspectorDOMBindingTimeline()
        ) { timeline, _ in
            let binding = try timeline.issue(after: boundary, route: route)
            var staged = baseReducer
            var canonical = try staged.bootstrap(scope: binding, root: root)
            staged.reconcilePrimaryTree(
                rootID: WebInspectorDOMNodeIdentityStorage(
                    documentScope: WebInspectorDOMDocumentScopeStorage(
                        storeID: connection.storeID,
                        attachmentGeneration: connection.attachmentGeneration,
                        eventScope: binding
                    ),
                    rawNodeID: root.id
                ),
                transaction: &canonical
            )
            var transaction = WebInspectorModelTransaction()
            transaction.append(contentsOf: oldIDs.map {
                webInspectorDOMNodeSchema.delete(id: $0)
            })
            transaction.append(contentsOf: oldStyleIDs.map {
                webInspectorCSSStylesSchema.delete(id: $0)
            })
            transaction.append(
                contentsOf: webInspectorDOMSnapshotMutations(staged.snapshot())
            )
            transaction.setFeatureState(
                .ready(
                    generation: route.generation,
                    revision: WebInspectorStoreRevision(rawValue: 0)
                ),
                for: .dom
            )
            return (transaction, (staged, binding))
        }
        reducer = result.output.0
        currentBindingScope = result.output.1
        cssReducer = WebInspectorCanonicalCSSReducer(
            storeID: connection.storeID,
            attachmentGeneration: connection.attachmentGeneration
        )
        loadedStyles.removeAll(keepingCapacity: true)
        let ready = WebInspectorFeatureState.ready(
            generation: route.generation,
            revision: result.revision
        )
        transition(to: ready)

        for try await event in scope.events {
            if closeRequested { return }
            switch event {
            case let .reset(generation):
                throw WebInspectorDOMRecoveryRequest(
                    reason: .targetChanged,
                    fingerprint: WebInspectorRecoveryFingerprint(
                        code: "dom.generation.reset",
                        phase: "events"
                    ),
                    resetPublishedDocument: generation.rawValue
                        != route.generation.rawValue
                )
            case let .event(_, event):
                try await apply(event)
            }
        }
    }

    private func apply(_ event: WebInspectorDOMWireEvent) async throws {
        switch event {
        case let .dom(routed):
            let route = try featureScope(from: routed)
            guard let binding = binding(for: route) else { return }
            switch routed.value {
            case .documentUpdated:
                throw WebInspectorDOMRecoveryRequest(
                    reason: .targetChanged,
                    fingerprint: WebInspectorRecoveryFingerprint(
                        code: "dom.document.updated",
                        phase: "events",
                        method: routed.method.rawValue
                    ),
                    resetPublishedDocument: true
                )
            case let .inspect(rawID):
                resolvePicker(rawNodeID: rawID, binding: binding)
            default:
                try await reduceDOM(routed.value, binding: binding, method: routed.method.rawValue)
            }
        case let .inspector(routed):
            guard let binding = binding(for: try featureScope(from: routed)) else { return }
            if case let .inspect(object, _) = routed.value, let objectID = object.id {
                resolvePicker(remoteObjectID: objectID, binding: binding)
            }
        case let .css(routed):
            guard let binding = binding(for: try featureScope(from: routed)) else { return }
            try await reduceCSS(routed.value, binding: binding, method: routed.method.rawValue)
        case let .page(routed):
            switch routed.value {
            case let .frameNavigated(frame) where frame.parentID == nil:
                throw WebInspectorDOMRecoveryRequest(
                    reason: .targetChanged,
                    fingerprint: WebInspectorRecoveryFingerprint(
                        code: "dom.main-frame.navigated",
                        phase: "events",
                        method: routed.method.rawValue
                    ),
                    resetPublishedDocument: true
                )
            case let .frameDetached(frameID):
                try await reduceFrameDetached(frameID)
            case .frameNavigated, .unknown:
                break
            }
        }
    }

    private func reduceDOM(
        _ event: DOM.Event,
        binding: WebInspectorCanonicalDOMEventScope,
        method: String
    ) async throws {
        guard var staged = reducer, let store else { return }
        do {
            var canonical = try staged.apply(scope: binding, event: event)
            staged.reconcilePrimaryTree(
                rootID: staged.primaryDocumentRootID,
                transaction: &canonical
            )
            guard !canonical.isEmpty else { return }
            var transaction = WebInspectorModelTransaction()
            transaction.append(contentsOf: webInspectorDOMMutations(canonical, staged: staged))
            let revision = try await store.commit(transaction)
            reducer = staged
            refreshReadyRevision(revision)
        } catch let error as WebInspectorCanonicalDOMError {
            throw WebInspectorDOMRecoveryRequest(
                reason: .snapshotConflict(
                    webInspectorFailureDescription(error, code: "dom.relation", phase: "events")
                ),
                fingerprint: WebInspectorRecoveryFingerprint(
                    code: "dom.relation.\(String(describing: error))",
                    phase: "events",
                    method: method
                ),
                resetPublishedDocument: false
            )
        }
    }

    private func reduceCSS(
        _ event: CSS.Event,
        binding: WebInspectorCanonicalDOMEventScope,
        method: String
    ) async throws {
        guard var staged = cssReducer else { return }
        do {
            let canonical = try staged.apply(scope: binding, event: event)
            cssReducer = staged
            guard !canonical.isEmpty, !loadedStyles.isEmpty, let store else { return }
            var transaction = WebInspectorModelTransaction()
            for (id, current) in loadedStyles {
                let record = WebInspectorCSSStylesRecord(
                    nodeID: current.nodeID,
                    phase: .needsRefresh,
                    sections: current.sections,
                    computedProperties: current.computedProperties,
                    cascadeRevision: staged.cascadeRevision(
                        in: current.nodeID.canonicalStorage.documentScope
                    )
                )
                loadedStyles[id] = record
                let rank = reducer?.record(for: current.nodeID.canonicalStorage)?.insertionOrdinal ?? 0
                transaction.append(
                    webInspectorCSSStylesMutation(id: id, record: record, canonicalRank: rank)
                )
            }
            let revision = try await store.commit(transaction)
            refreshReadyRevision(revision)
        } catch let error as WebInspectorCanonicalCSSError {
            throw WebInspectorDOMRecoveryRequest(
                reason: .snapshotConflict(
                    webInspectorFailureDescription(error, code: "css.relation", phase: "events")
                ),
                fingerprint: WebInspectorRecoveryFingerprint(
                    code: "css.relation.\(String(describing: error))",
                    phase: "events",
                    method: method
                ),
                resetPublishedDocument: false
            )
        }
    }

    private func reduceFrameDetached(_ frameID: FrameID) async throws {
        guard var stagedDOM = reducer, var stagedCSS = cssReducer, let store else { return }
        var dom = try stagedDOM.frameWasDetached(frameID)
        stagedDOM.reconcilePrimaryTree(
            rootID: stagedDOM.primaryDocumentRootID,
            transaction: &dom
        )
        _ = stagedCSS.frameWasDetached(frameID)
        guard !dom.isEmpty else { return }
        var transaction = WebInspectorModelTransaction()
        transaction.append(contentsOf: webInspectorDOMMutations(dom, staged: stagedDOM))
        let revision = try await store.commit(transaction)
        reducer = stagedDOM
        cssReducer = stagedCSS
        refreshReadyRevision(revision)
    }

    private func resetPublishedDocument() async throws {
        guard var reducer, let store else { return }
        let canonical = reducer.reset()
        var transaction = WebInspectorModelTransaction()
        transaction.append(contentsOf: canonical.deletedRecordIDs.map {
            webInspectorDOMNodeSchema.delete(id: DOMNode.ID(canonical: $0))
        })
        transaction.append(contentsOf: loadedStyles.keys.map(webInspectorCSSStylesSchema.delete))
        let generation = await currentGeneration()
        transaction.setFeatureState(.synchronizing(generation: generation), for: .dom)
        _ = try await store.commit(transaction)
        self.reducer = reducer
        loadedStyles.removeAll(keepingCapacity: true)
        currentBindingScope = nil
        transition(to: .synchronizing(generation: generation))
        await retirePicker(
            with: WebInspectorElementPickerError.targetChanged,
            disableBackend: false
        )
    }

    // MARK: Helpers

    private struct CSSPropertyLocation {
        let style: CSS.Style
        let propertyIndex: Int
    }

    private func propertyLocation(
        for id: CSSStyleProperty.ID
    ) -> CSSPropertyLocation? {
        for record in loadedStyles.values {
            for section in record.sections {
                if let index = section.proxyStyle.properties.firstIndex(
                    where: { $0.id.rawValue == id.rawValue }
                ) {
                    return CSSPropertyLocation(
                        style: section.proxyStyle,
                        propertyIndex: index
                    )
                }
            }
        }
        return nil
    }

    private func commitStyles(
        _ id: CSSStyles.ID,
        record: WebInspectorCSSStylesRecord,
        rank: UInt64
    ) async throws {
        guard let store else { throw WebInspectorCommandError.containerClosed }
        var transaction = WebInspectorModelTransaction()
        transaction.append(
            webInspectorCSSStylesMutation(id: id, record: record, canonicalRank: rank)
        )
        let revision = try await store.commit(transaction)
        loadedStyles[id] = record
        refreshReadyRevision(revision)
    }

    private func validatedRawNodeID(_ id: DOMNode.ID) throws -> DOM.Node.ID {
        guard let reducer,
            reducer.record(for: id.canonicalStorage) != nil,
            let expectedScope = activeDocumentScope,
            id.canonicalStorage.documentScope == expectedScope
        else { throw WebInspectorCommandError.staleIdentifier }
        return id.canonicalStorage.rawNodeID
    }

    private func validate(_ scope: WebInspectorDOMDocumentScopeStorage) throws {
        guard let expectedScope = activeDocumentScope,
            scope == expectedScope
        else { throw WebInspectorCommandError.targetChanged }
    }

    private var activeDocumentScope: WebInspectorDOMDocumentScopeStorage? {
        guard let connection, let currentBindingScope else { return nil }
        return WebInspectorDOMDocumentScopeStorage(
            storeID: connection.storeID,
            attachmentGeneration: connection.attachmentGeneration,
            eventScope: currentBindingScope
        )
    }

    private func makeUndoCapabilityIfNeeded(
        _ policy: WebInspectorUndoPolicy
    ) async throws -> DOMUndoCapability? {
        guard policy == .automatic else { return nil }
        guard let connection, let scope = activeDocumentScope
        else { throw WebInspectorCommandError.targetChanged }
        try await connection.page.dom.markUndoableState()
        return DOMUndoCapability(owner: self, scope: scope)
    }

    private func binding(
        for route: WebInspectorFeatureEventScope
    ) -> WebInspectorCanonicalDOMEventScope? {
        guard let currentBindingScope,
            currentBindingScope.modelScope.generation == route.generation,
            currentBindingScope.semanticTargetID == route.semanticTargetID,
            currentBindingScope.agentTargetID == route.agentTargetID
        else { return nil }
        return currentBindingScope
    }

    private func featureScope<Value: Sendable>(
        from event: WebInspectorRoutedEvent<Value>
    ) throws -> WebInspectorFeatureEventScope {
        guard let semantic = event.semanticTarget, let agent = event.agentTarget else {
            throw WebInspectorDOMRecoveryRequest(
                reason: .malformedDomainEvent(
                    WebInspectorFailureDescription(
                        code: "dom.route.missing",
                        phase: "events",
                        message: "DOM event lacked semantic or agent target authority."
                    )
                ),
                fingerprint: WebInspectorRecoveryFingerprint(
                    code: "dom.route.missing",
                    phase: "events",
                    method: event.method.rawValue
                ),
                resetPublishedDocument: false
            )
        }
        return WebInspectorFeatureEventScope(
            generation: WebInspectorPageGeneration(rawValue: event.generation.rawValue),
            semanticTarget: WebInspectorFeatureTarget(semantic),
            agentTarget: WebInspectorFeatureTarget(agent)
        )
    }

    private func featureScope<Value: Sendable>(
        from reply: WebInspectorScopedReply<Value>
    ) throws -> WebInspectorFeatureEventScope {
        guard let semantic = reply.semanticTarget, let agent = reply.agentTarget else {
            throw WebInspectorFeatureError.bootstrap(
                WebInspectorFailureDescription(
                    code: "dom.bootstrap.route",
                    phase: "bootstrap",
                    message: "DOM.getDocument reply lacked target authority."
                )
            )
        }
        return WebInspectorFeatureEventScope(
            generation: WebInspectorPageGeneration(rawValue: reply.generation.rawValue),
            semanticTarget: WebInspectorFeatureTarget(semantic),
            agentTarget: WebInspectorFeatureTarget(agent)
        )
    }

    private func invalidatesDOMBootstrap(
        _ event: WebInspectorPageEvent<WebInspectorDOMWireEvent>
    ) -> Bool {
        switch event {
        case .reset:
            return true
        case let .event(_, .dom(event)):
            if case .documentUpdated = event.value { return true }
            return false
        case let .event(_, .page(event)):
            if case let .frameNavigated(frame) = event.value,
                frame.parentID == nil
            { return true }
            return false
        case .event:
            return false
        }
    }

    private func transition(to newState: WebInspectorFeatureState) {
        webInspectorLogFeatureTransition(
            feature: .dom,
            from: state,
            to: newState
        )
        state = newState
        registry.publish(newState, for: .dom)
    }

    private func publish(_ newState: WebInspectorFeatureState) async {
        if let store {
            var transaction = WebInspectorModelTransaction()
            transaction.setFeatureState(newState, for: .dom)
            do {
                let revision = try await store.commit(transaction)
                if case let .ready(generation, _) = newState {
                    transition(to: .ready(generation: generation, revision: revision))
                    return
                }
            } catch {
                WebInspectorDataKitLog.debug("DOM state publication failed: \(error)")
            }
        }
        transition(to: newState)
    }

    private func refreshReadyRevision(_ revision: WebInspectorStoreRevision) {
        guard case let .ready(generation, _) = state else { return }
        transition(to: .ready(generation: generation, revision: revision))
    }

    private func currentGeneration() async -> WebInspectorPageGeneration {
        guard let connection,
            let generation = try? await connection.page.generation
        else { return WebInspectorPageGeneration(rawValue: 0) }
        return WebInspectorPageGeneration(rawValue: generation.rawValue)
    }

    private func waitForExplicitRetry() async {
        if explicitRetryRequested {
            explicitRetryRequested = false
            return
        }
        await withCheckedContinuation { continuation in
            retryWaiter = continuation
        }
        explicitRetryRequested = false
    }

    private func isConnectionTerminal(_ error: any Error) -> Bool {
        guard let proxy = error as? WebInspectorProxyError else { return false }
        switch proxy {
        case .closed, .disconnected, .transportFailure:
            return true
        default:
            return false
        }
    }

    private func termination(for error: any Error) -> WebInspectorFeatureTermination {
        if error is CancellationError { return .detached }
        return .connectionFailed(
            connectionFailure(
                code: "dom.connection",
                phase: "events",
                message: String(describing: error)
            )
        )
    }

    private func connectionFailure(
        code: String,
        phase: String,
        message: String
    ) -> WebInspectorConnectionFailure {
        .native(
            WebInspectorFailureDescription(
                code: code,
                phase: phase,
                message: message
            )
        )
    }

    private func runPickerEnable(
        operationID: UInt64,
        connection: WebInspectorFeatureConnection
    ) async {
        let result: Result<Void, any Error>
        do {
            try await connection.page.dom.setInspectMode(enabled: true)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        finishPickerEnable(
            result,
            operationID: operationID,
            connection: connection
        )
    }

    private func finishPickerEnable(
        _ result: Result<Void, any Error>,
        operationID: UInt64,
        connection: WebInspectorFeatureConnection
    ) {
        guard case let .operation(operation) = pickerState,
            operation.id == operationID,
            case let .enabling(_, intent) = operation.phase
        else { return }

        switch intent {
        case .activate:
            switch result {
            case .success:
                var active = operation
                active.phase = .active
                pickerState = .operation(active)
                pickerPublisher.publish(.active)
            case let .failure(error):
                finishPickerOperation(
                    .failure(
                        WebInspectorElementPickerError.enableFailed(
                            webInspectorFailureDescription(
                                error,
                                code: "picker.enable",
                                phase: "DOM.setInspectModeEnabled"
                            )
                        )
                    ),
                    operationID: operationID
                )
            }
        case .cancelAfterEnable:
            switch result {
            case .success:
                beginPickerDisable(
                    operationID: operationID,
                    connection: connection,
                    publishState: false
                )
            case .failure:
                finishPickerOperation(
                    .failure(CancellationError()),
                    operationID: operationID
                )
            }
        case let .selected(selection):
            // The inspect event is backend proof that searching was enabled and
            // then returned to idle; a later command reply cannot supersede it.
            finishPickerOperation(selection, operationID: operationID)
        case let .resolveRemoteObject(remoteObjectID, binding):
            beginPickerResolution(
                remoteObjectID: remoteObjectID,
                binding: binding,
                operationID: operationID,
                connection: connection,
                publishState: false
            )
        }
    }

    private func cancelPicker(operationID: UInt64) {
        guard case let .operation(operation) = pickerState,
            operation.id == operationID
        else { return }

        switch operation.phase {
        case let .enabling(task, intent):
            switch intent {
            case .activate:
                var cancelPending = operation
                cancelPending.phase = .enabling(
                    task: task,
                    intent: .cancelAfterEnable
                )
                pickerState = .operation(cancelPending)
                pickerPublisher.publish(.disabling)
            case .cancelAfterEnable:
                return
            case .selected, .resolveRemoteObject:
                task.cancel()
                finishPickerOperation(
                    .failure(CancellationError()),
                    operationID: operationID
                )
            }
        case .active:
            guard let connection else {
                preconditionFailure("An active picker must retain its feature connection.")
            }
            beginPickerDisable(
                operationID: operationID,
                connection: connection,
                publishState: true
            )
        case let .resolvingSelection(task):
            task.cancel()
            finishPickerOperation(
                .failure(CancellationError()),
                operationID: operationID
            )
        case .disabling, .retiring:
            return
        }
    }

    private func beginPickerDisable(
        operationID: UInt64,
        connection: WebInspectorFeatureConnection,
        publishState: Bool
    ) {
        guard case var .operation(operation) = pickerState,
            operation.id == operationID
        else { return }
        let task = Task {
            await self.runPickerDisable(
                operationID: operationID,
                connection: connection
            )
        }
        operation.phase = .disabling(task: task)
        pickerState = .operation(operation)
        if publishState {
            pickerPublisher.publish(.disabling)
        }
    }

    private func runPickerDisable(
        operationID: UInt64,
        connection: WebInspectorFeatureConnection
    ) async {
        var lastError: (any Error)?
        for _ in 0..<2 {
            guard !Task.isCancelled else { return }
            do {
                try await connection.page.dom.setInspectMode(enabled: false)
                finishPickerDisable(.success(()), operationID: operationID)
                return
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error
            }
        }
        guard let lastError else {
            preconditionFailure("The bounded picker disable loop must record a failure.")
        }
        finishPickerDisable(.failure(lastError), operationID: operationID)
    }

    private func finishPickerDisable(
        _ result: Result<Void, any Error>,
        operationID: UInt64
    ) {
        guard case let .operation(operation) = pickerState,
            operation.id == operationID,
            case .disabling = operation.phase
        else { return }

        switch result {
        case .success:
            finishPickerOperation(
                .failure(CancellationError()),
                operationID: operationID
            )
        case let .failure(error):
            let description = webInspectorFailureDescription(
                error,
                code: "picker.disable",
                phase: "DOM.setInspectModeEnabled"
            )
            let failure = WebInspectorFeatureError.command(description)
            pickerState = .unavailable(failure)
            pickerPublisher.publish(.unavailable(failure))
            operation.continuation.resume(
                throwing: WebInspectorElementPickerError.disableFailed(description)
            )
        }
    }

    private func resolvePicker(
        rawNodeID: DOM.Node.ID,
        binding: WebInspectorCanonicalDOMEventScope
    ) {
        guard case var .operation(operation) = pickerState else { return }
        let result = pickerSelectionResult(
            rawNodeID: rawNodeID,
            binding: binding,
            phase: "DOM.inspect"
        )

        switch operation.phase {
        case let .enabling(task, .activate):
            operation.phase = .enabling(
                task: task,
                intent: .selected(result)
            )
            pickerState = .operation(operation)
            pickerPublisher.publish(.resolvingSelection)
        case .active:
            pickerPublisher.publish(.resolvingSelection)
            finishPickerOperation(result, operationID: operation.id)
        case .enabling, .resolvingSelection, .disabling, .retiring:
            return
        }
    }

    private func resolvePicker(
        remoteObjectID: Runtime.RemoteObject.ID,
        binding: WebInspectorCanonicalDOMEventScope
    ) {
        guard case var .operation(operation) = pickerState else { return }

        switch operation.phase {
        case let .enabling(task, .activate):
            operation.phase = .enabling(
                task: task,
                intent: .resolveRemoteObject(remoteObjectID, binding)
            )
            pickerState = .operation(operation)
            pickerPublisher.publish(.resolvingSelection)
        case .active:
            guard let connection else {
                preconditionFailure("An active picker must retain its feature connection.")
            }
            beginPickerResolution(
                remoteObjectID: remoteObjectID,
                binding: binding,
                operationID: operation.id,
                connection: connection,
                publishState: true
            )
        case .enabling, .resolvingSelection, .disabling, .retiring:
            return
        }
    }

    private func beginPickerResolution(
        remoteObjectID: Runtime.RemoteObject.ID,
        binding: WebInspectorCanonicalDOMEventScope,
        operationID: UInt64,
        connection: WebInspectorFeatureConnection,
        publishState: Bool
    ) {
        guard case var .operation(operation) = pickerState,
            operation.id == operationID
        else { return }
        let task = Task {
            await self.runPickerResolution(
                remoteObjectID: remoteObjectID,
                binding: binding,
                operationID: operationID,
                connection: connection
            )
        }
        operation.phase = .resolvingSelection(task: task)
        pickerState = .operation(operation)
        if publishState {
            pickerPublisher.publish(.resolvingSelection)
        }
    }

    private func runPickerResolution(
        remoteObjectID: Runtime.RemoteObject.ID,
        binding: WebInspectorCanonicalDOMEventScope,
        operationID: UInt64,
        connection: WebInspectorFeatureConnection
    ) async {
        let result: Result<DOMNode.ID, any Error>
        do {
            let rawNodeID = try await connection.page.dom.requestNode(
                forRemoteObject: remoteObjectID
            )
            result = pickerSelectionResult(
                rawNodeID: rawNodeID,
                binding: binding,
                phase: "DOM.requestNode"
            )
        } catch {
            guard !Task.isCancelled else { return }
            result = .failure(
                WebInspectorElementPickerError.selectionResolutionFailed(
                    webInspectorFailureDescription(
                        error,
                        code: "picker.resolve",
                        phase: "DOM.requestNode"
                    )
                )
            )
        }
        finishPickerOperation(result, operationID: operationID)
    }

    private func pickerSelectionResult(
        rawNodeID: DOM.Node.ID,
        binding: WebInspectorCanonicalDOMEventScope,
        phase: String
    ) -> Result<DOMNode.ID, any Error> {
        do {
            guard let reducer,
                let canonical = try reducer.nodeID(for: rawNodeID, in: binding)
            else { throw WebInspectorCommandError.staleIdentifier }
            return .success(DOMNode.ID(canonical: canonical))
        } catch {
            return .failure(
                WebInspectorElementPickerError.selectionResolutionFailed(
                    webInspectorFailureDescription(
                        error,
                        code: "picker.resolve",
                        phase: phase
                    )
                )
            )
        }
    }

    private func finishPickerOperation(
        _ result: Result<DOMNode.ID, any Error>,
        operationID: UInt64
    ) {
        guard case let .operation(operation) = pickerState,
            operation.id == operationID
        else { return }
        pickerState = .idle
        pickerPublisher.publish(.idle)
        operation.continuation.resume(with: result)
    }

    private func retirePicker(
        with error: any Error,
        disableBackend: Bool
    ) async {
        guard case var .operation(operation) = pickerState else {
            pickerState = .idle
            pickerPublisher.publish(.idle)
            return
        }
        operation.phase.task?.cancel()
        operation.phase = .retiring
        pickerState = .operation(operation)
        if disableBackend, let connection {
            // Connection teardown is the physical cleanup authority. Failure is
            // terminal with that connection and cannot make the picker reusable.
            _ = try? await connection.page.dom.setInspectMode(enabled: false)
        }
        finishPickerOperation(.failure(error), operationID: operation.id)
    }
}

/// Public typed facade over the container-owned DOM feature actor.
public final class WebInspectorDOM: WebInspectorRetryableFeatureHandle, Sendable {
    private let owner: WebInspectorDOMFeature
    private let registry: WebInspectorFeatureRegistry
    private let pickerPublisher: _WebInspectorStatePublisher<WebInspectorElementPickerState>

    package init(
        owner: WebInspectorDOMFeature,
        registry: WebInspectorFeatureRegistry,
        pickerPublisher: _WebInspectorStatePublisher<WebInspectorElementPickerState>
    ) {
        self.owner = owner
        self.registry = registry
        self.pickerPublisher = pickerPublisher
    }

    public var state: WebInspectorFeatureState { registry.state(for: .dom) }
    public var stateUpdates: WebInspectorStateUpdates<WebInspectorFeatureState> {
        registry.updates(for: .dom)
    }
    public var elementPickerState: WebInspectorElementPickerState {
        pickerPublisher.current
    }
    public var elementPickerStateUpdates: WebInspectorStateUpdates<WebInspectorElementPickerState> {
        pickerPublisher.updates()
    }

    public func retry() async { await owner.retry() }
    public func pickElement() async throws -> DOMNode.ID { try await owner.pickElement() }
    public func cancelElementPicker() async { await owner.cancelElementPicker() }
    public func retryElementPicker() async { await owner.retryElementPicker() }
    public func requestChildren(of id: DOMNode.ID, depth: Int = 1) async throws {
        try await owner.requestChildren(of: id, depth: depth)
    }
    public func setAttribute(
        _ name: String,
        value: String,
        on id: DOMNode.ID,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome {
        try await owner.setAttribute(name, value: value, on: id, undo: undo)
    }
    public func setOuterHTML(
        _ html: String,
        of id: DOMNode.ID,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome {
        try await owner.setOuterHTML(html, of: id, undo: undo)
    }
    public func removeNodes(
        _ ids: [DOMNode.ID],
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome {
        try await owner.removeNodes(ids, undo: undo)
    }
    public func text(
        _ representation: DOMTextRepresentation,
        for id: DOMNode.ID
    ) async throws -> String {
        try await owner.text(representation, for: id)
    }
    public func highlight(_ id: DOMNode.ID) async throws { try await owner.highlight(id) }
    public func hideHighlight() async throws { try await owner.hideHighlight() }
    public func loadStyles(for id: DOMNode.ID) async throws -> CSSStyles.ID {
        try await owner.loadStyles(for: id)
    }
    public func refreshStyles(_ id: CSSStyles.ID) async throws {
        try await owner.refreshStyles(id)
    }
    public func setProperty(
        _ id: CSSStyleProperty.ID,
        enabled: Bool,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability? {
        try await owner.setProperty(id, enabled: enabled, undo: undo)
    }
    public func setDeclarationText(
        _ text: String,
        for id: CSSStyleProperty.ID,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability? {
        try await owner.setDeclarationText(text, for: id, undo: undo)
    }
}
