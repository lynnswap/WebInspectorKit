import Foundation
import WebInspectorProxyKit

/// Loads the styles of the selected element of one context and applies the
/// CSS edits made to them.
///
/// The editor owns the state of that work: the load in flight, the edits in
/// flight, the stylesheets it has seen, and the style-tracking leases. What
/// it needs from the attachment, such as the selection, the targets, and
/// whether an edit still belongs to the current page and document, it reads
/// from the context that each call passes in. It stores no reference to the
/// context, so an edit that is waiting for its turn does not keep a released
/// context alive.
@MainActor
final class CSSStyleEditor {
    /// What an edit was made against. The edit is stale once any of it has
    /// been replaced.
    private struct MutationAuthority {
        struct StyleSheet {
            var id: CSS.StyleSheet.ID
            var revision: UInt64
            var contentRevision: UInt64?
        }

        var target: WebInspectorContext.TargetAuthority
        var node: DOMNode?
        var styles: CSSStyles?
        var styleSheet: StyleSheet?
    }

    @MainActor
    private enum StyleTextMutation {
        case setProperty(enabled: Bool)
        case setDeclarationText(String)

        func submittedDeclaration(
            in styles: CSSStyles,
            propertyID: CSSStyleProperty.ID
        ) -> CSSDeclarationIdentity? {
            switch self {
            case let .setProperty(enabled):
                styles.canSubmitSetStyleText(for: propertyID, enabled: enabled)
            case let .setDeclarationText(text):
                styles.canSubmitSetDeclarationText(for: propertyID, text: text)
            }
        }

        func intent(
            in styles: CSSStyles,
            declaration: CSSDeclarationIdentity
        ) -> CSSStyles.SetStyleTextIntent? {
            switch self {
            case let .setProperty(enabled):
                styles.setStyleTextIntent(for: declaration, enabled: enabled)
            case let .setDeclarationText(text):
                styles.setDeclarationTextIntent(for: declaration, text: text)
            }
        }
    }

    @MainActor
    private final class ToggleOperation {
        var task: Task<Void, Never>?
    }

    /// The context of a requested edit, which runs in its own task and must
    /// not keep the context alive between its commands.
    @MainActor
    private final class WeakContextReference {
        private weak var context: WebInspectorContext?

        init(_ context: WebInspectorContext) {
            self.context = context
        }

        func withContext<Output>(
            _ operation: (WebInspectorContext) throws -> Output
        ) throws -> Output {
            guard let context else {
                throw CancellationError()
            }
            return try operation(context)
        }

        func withContextIfPresent(_ operation: (WebInspectorContext) -> Void) {
            guard let context else {
                return
            }
            operation(context)
        }
    }

    private struct SelectedStylePayloads {
        var matchedStyles: CSS.MatchedStyles
        var inlineStyles: CSS.InlineStyles
        var computedProperties: [CSS.ComputedProperty]
    }

    let inspectorBaselineStore = CSSInspectorBaselineStore()
    let trackingLeases: CSSStyleTrackingLeases
    private let operationGate = CSSOperationGate()
    private var styleSheets = CSSStyleSheetLifetimes()
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var isHydrationActive = false
    private var toggleOperations: [CSSStyleProperty.ID: ToggleOperation] = [:]

    init(domainEnablement: WebInspectorDomainEnablementRegistry) {
        trackingLeases = CSSStyleTrackingLeases(domainEnablement: domainEnablement)
    }

    // MARK: - Lifetime of the work in flight

    /// Cancels the work in flight when the context is released. A requested
    /// edit keeps the editor alive until it ends, so the editor cannot do
    /// this in its own `deinit`.
    func cancelTasks() {
        refreshTask?.cancel()
        trackingLeases.cancelPendingAcquisitions()
        for operation in toggleOperations.values {
            operation.task?.cancel()
            operation.task = nil
        }
    }

    /// Cancels the style load in flight and makes its result stale.
    func invalidateRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
    }

    func cancelToggleOperations() {
        for operation in toggleOperations.values {
            operation.task?.cancel()
            operation.task = nil
        }
        toggleOperations = [:]
    }

    /// Drops what belongs to the document that was replaced.
    func resetForNewDocument() {
        cancelToggleOperations()
        inspectorBaselineStore.reset()
        styleSheets.removeAll()
        invalidateRefresh()
    }

    /// Drops the baselines and the stylesheets of a target that was
    /// destroyed.
    func forgetTarget(_ targetID: WebInspectorTarget.ID, isCurrentPage: Bool) {
        if isCurrentPage {
            inspectorBaselineStore.reset()
            styleSheets.invalidateAll()
        } else {
            inspectorBaselineStore.reset(targetID: targetID)
            styleSheets.invalidate(targetID: targetID)
        }
    }

    func invalidateStyleSheets(frameID: FrameID) {
        styleSheets.invalidate(frameID: frameID)
    }

    // MARK: - Events

    func apply(_ event: CSS.Event, in context: WebInspectorContext) {
        switch event {
        case let .styleSheetChanged(id):
            styleSheets.advanceContentRevision(id)
            markSelectedStylesNeedsRefresh(in: context)
        case .mediaQueryResultChanged:
            markSelectedStylesNeedsRefresh(in: context)
        case let .styleSheetAdded(header):
            styleSheets.record(header)
            markSelectedStylesNeedsRefresh(in: context)
        case let .styleSheetRemoved(id):
            styleSheets.invalidate(id)
            markSelectedStylesNeedsRefresh(in: context)
        case let .nodeLayoutFlagsChanged(id):
            markSelectedStylesNeedsRefresh(for: DOMNode.ID(id), in: context)
        case .unknown:
            break
        }
    }

    func markSelectedStylesNeedsRefresh(
        for nodeID: DOMNode.ID,
        in context: WebInspectorContext
    ) {
        guard context.selectedNode?.id == nodeID else {
            return
        }
        markSelectedStylesNeedsRefresh(in: context)
    }

    func markSelectedStylesNeedsRefresh(in context: WebInspectorContext) {
        refreshGeneration += 1
        guard let styles = context.selectedNode?.elementStyles else {
            return
        }
        styles.markNeedsRefresh()
        refreshSelectedStylesIfHydrationActive(in: context)
    }

    // MARK: - Loading

    func setHydrationActive(_ active: Bool, in context: WebInspectorContext) {
        guard isHydrationActive != active else {
            return
        }
        isHydrationActive = active
        guard active, let styles = context.selectedNode?.elementStyles else {
            return
        }
        switch styles.phase {
        case .needsRefresh, .failed:
            refreshSelectedStyles(in: context)
        case .loading, .loaded, .unavailable:
            break
        }
    }

    func refreshSelectedStyles(in context: WebInspectorContext) {
        refreshTask?.cancel()
        refreshTask = nil

        guard let selectedNode = context.selectedNode else {
            return
        }
        guard selectedNode.nodeType == 1 else {
            selectedNode.setElementStyles(nil)
            return
        }

        let styles = selectedNode.elementStyles
            ?? CSSStyles(nodeID: selectedNode.id, inspectorBaselineStore: inspectorBaselineStore)
        selectedNode.setElementStyles(styles)
        refreshGeneration += 1
        let generation = refreshGeneration
        styles.markLoading(generation: generation)
        refreshTask = Task { [weak self, weak context, weak selectedNode, styles] in
            guard let self, let context, let selectedNode else {
                return
            }
            await self.loadStyles(for: selectedNode, into: styles, generation: generation, in: context)
        }
    }

    private func refreshSelectedStylesIfHydrationActive(in context: WebInspectorContext) {
        guard isHydrationActive else {
            return
        }
        refreshSelectedStyles(in: context)
    }

    private func loadStyles(
        for node: DOMNode,
        into styles: CSSStyles,
        generation: Int,
        in context: WebInspectorContext
    ) async {
        guard isCurrentRefresh(node: node, generation: generation, in: context) else {
            styles.cancelLoading(generation: generation)
            return
        }
        guard context.currentPage != nil else {
            styles.markUnavailable(generation: generation)
            return
        }

        do {
            let target = try context.domTarget(owning: node.id.proxyID)
            try await withExclusiveOperation(on: target) {
                guard isCurrentRefresh(node: node, generation: generation, in: context) else {
                    styles.cancelLoading(generation: generation)
                    return
                }
                guard try await trackingLeases.ensure(on: target) else {
                    styles.markUnavailable(generation: generation)
                    return
                }
                guard isCurrentRefresh(node: node, generation: generation, in: context) else {
                    styles.cancelLoading(generation: generation)
                    return
                }
                guard let payloads = try await selectedStylePayloads(
                    for: node,
                    target: target,
                    generation: generation,
                    in: context
                ) else {
                    styles.cancelLoading(generation: generation)
                    return
                }
                styles.load(
                    matchedStyles: payloads.matchedStyles,
                    inlineStyles: payloads.inlineStyles,
                    computedProperties: payloads.computedProperties,
                    generation: generation
                )
            }
        } catch is CancellationError {
            styles.cancelLoading(generation: generation)
        } catch let error as WebInspectorProxyError {
            styles.fail(error, generation: generation)
        } catch {
            styles.fail(.commandFailed(
                domain: "CSS",
                method: "getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode",
                message: String(describing: error)
            ), generation: generation)
        }
    }

    #if DEBUG
    func waitForQueuedOperationCountForTesting(
        _ count: Int,
        for target: WebInspectorTarget
    ) async throws {
        try await operationGate.waitForQueuedOperationCount(count, for: target.id)
    }
    #endif

    private func withExclusiveOperation<Output>(
        on target: WebInspectorTarget,
        _ operation: () async throws -> Output
    ) async throws -> Output {
        try await operationGate.acquire(targetID: target.id)
        do {
            try Task.checkCancellation()
            let output = try await operation()
            await operationGate.release(targetID: target.id)
            return output
        } catch {
            await operationGate.release(targetID: target.id)
            throw error
        }
    }

    private func selectedStylePayloads(
        for node: DOMNode,
        target: WebInspectorTarget,
        generation: Int,
        in context: WebInspectorContext
    ) async throws -> SelectedStylePayloads? {
        let matchedStyles = try await target.css.matchedStyles(for: node.id.proxyID)
        guard isCurrentRefresh(node: node, generation: generation, in: context) else {
            return nil
        }
        let inlineStyles = try await target.css.inlineStyles(for: node.id.proxyID)
        guard isCurrentRefresh(node: node, generation: generation, in: context) else {
            return nil
        }
        let computedProperties = try await target.css.computedStyle(for: node.id.proxyID)
        guard isCurrentRefresh(node: node, generation: generation, in: context) else {
            return nil
        }
        return SelectedStylePayloads(
            matchedStyles: matchedStyles,
            inlineStyles: inlineStyles,
            computedProperties: computedProperties
        )
    }

    private func isCurrentRefresh(
        node: DOMNode,
        generation: Int,
        in context: WebInspectorContext
    ) -> Bool {
        Task.isCancelled == false && context.selectedNode === node && refreshGeneration == generation
    }

    // MARK: - Editing

    func setProperty(
        _ id: CSSStyleProperty.ID,
        enabled: Bool,
        registersUndo: Bool,
        in context: WebInspectorContext
    ) async throws {
        try await setStyleText(
            .setProperty(enabled: enabled),
            for: id,
            staleMessage: "CSS property is stale, already mutating, or not editable.",
            registersUndo: registersUndo,
            in: context
        )
    }

    func setDeclarationText(
        _ text: String,
        for id: CSSStyleProperty.ID,
        registersUndo: Bool,
        in context: WebInspectorContext
    ) async throws {
        try await setStyleText(
            .setDeclarationText(text),
            for: id,
            staleMessage: "CSS declaration is stale, already mutating, or not editable.",
            registersUndo: registersUndo,
            in: context
        )
    }

    private func setStyleText(
        _ mutation: StyleTextMutation,
        for id: CSSStyleProperty.ID,
        staleMessage: String,
        registersUndo: Bool,
        in context: WebInspectorContext
    ) async throws {
        guard toggleOperations[id] == nil,
              let node = context.selectedNode,
              let styles = node.elementStyles,
              let submittedDeclaration = mutation.submittedDeclaration(
                  in: styles,
                  propertyID: id
              ) else {
            throw WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "setStyleText",
                message: staleMessage
            )
        }

        let target = try context.cssTarget(owning: submittedDeclaration.styleID)
        let submissionAuthority = mutationAuthority(
            target: target,
            styleSheetID: submittedDeclaration.styleID.owningStyleSheetID,
            node: node,
            styles: styles,
            in: context
        )
        let operation = beginToggleOperation(for: id)
        defer {
            finishToggleOperation(for: id, operation: operation)
        }
        try await withExclusiveOperation(on: target) {
            try validate(submissionAuthority, in: context)
            try validateToggleOperation(id, operation: operation)
            try await refreshStylesForMutationIfNeeded(
                node: node,
                styles: styles,
                target: target,
                in: context
            )
            try validate(submissionAuthority, in: context)
            try validateToggleOperation(id, operation: operation)
            guard let intent = mutation.intent(
                in: styles,
                declaration: submittedDeclaration
            ),
                  try context.cssTarget(owning: intent.styleID).id == target.id else {
                throw WebInspectorProxyError.commandFailed(
                    domain: "CSS",
                    method: "setStyleText",
                    message: "CSS declaration changed before the queued mutation could run."
                )
            }
            let commandAuthority = mutationAuthority(
                target: target,
                styleSheetID: intent.styleID.owningStyleSheetID,
                node: node,
                styles: styles,
                in: context
            )
            let result = try await target.css.setStyleText(intent.styleID, text: intent.text)
            try validate(commandAuthority, in: context)
            try validateToggleOperation(id, operation: operation)
            try await WebInspectorContext.markDOMUndoableStateIfNeeded(on: target, registersUndo: registersUndo)
            try validate(commandAuthority, in: context)
            try validateToggleOperation(id, operation: operation)
            context.recordDOMEditHistoryTarget(target, registersUndo: registersUndo)
            styles.applySetStyleText(result: result, for: id)
        }
        refreshSelectedStylesIfHydrationActive(in: context)
    }

    func setRuleSelector(
        _ selector: String,
        for id: CSSStyleRule.ID,
        registersUndo: Bool,
        in context: WebInspectorContext
    ) async throws {
        let proxyID = id.proxyID
        let target = try context.cssTarget(owning: proxyID)
        let submissionAuthority = mutationAuthority(
            target: target,
            styleSheetID: proxyID.owningStyleSheetID,
            tracksStyleSheetContentRevision: true,
            in: context
        )
        try await withExclusiveOperation(on: target) {
            try validate(submissionAuthority, in: context)
            let commandAuthority = mutationAuthority(
                target: target,
                styleSheetID: proxyID.owningStyleSheetID,
                in: context
            )
            _ = try await target.css.setRuleSelector(proxyID, selector: selector)
            try validate(commandAuthority, in: context)
            try await WebInspectorContext.markDOMUndoableStateIfNeeded(on: target, registersUndo: registersUndo)
            try validate(commandAuthority, in: context)
            context.recordDOMEditHistoryTarget(target, registersUndo: registersUndo)
        }
        refreshSelectedStylesIfHydrationActive(in: context)
    }

    func setStyleSheetText(
        _ text: String,
        for id: CSS.StyleSheet.ID,
        registersUndo: Bool,
        in context: WebInspectorContext
    ) async throws {
        let target = try context.cssTarget(owning: id)
        let submissionAuthority = mutationAuthority(target: target, styleSheetID: id, in: context)
        try await withExclusiveOperation(on: target) {
            try validate(submissionAuthority, in: context)
            let commandAuthority = mutationAuthority(target: target, styleSheetID: id, in: context)
            try await target.css.setStyleSheetText(id, text: text)
            try validate(commandAuthority, in: context)
            styleSheets.advanceContentRevision(id)
            markSelectedStylesNeedsRefresh(in: context)
            try await WebInspectorContext.markDOMUndoableStateIfNeeded(on: target, registersUndo: registersUndo)
            try validate(commandAuthority, in: context)
            context.recordDOMEditHistoryTarget(target, registersUndo: registersUndo)
        }
    }

    /// Starts toggling a property without waiting for the result.
    /// - Returns: `false` when the property cannot be toggled now.
    @discardableResult
    func requestSetProperty(
        _ id: CSSStyleProperty.ID,
        enabled: Bool,
        registersUndo: Bool,
        in context: WebInspectorContext
    ) -> Bool {
        let mutation = StyleTextMutation.setProperty(enabled: enabled)
        guard toggleOperations[id] == nil,
              let node = context.selectedNode,
              let styles = node.elementStyles,
              let submittedDeclaration = mutation.submittedDeclaration(
                  in: styles,
                  propertyID: id
              ) else {
            return false
        }
        let target: WebInspectorTarget
        do {
            target = try context.cssTarget(owning: submittedDeclaration.styleID)
        } catch {
            context.failIfTerminal(error, operation: "CSS.setStyleText")
            return false
        }
        let submissionAuthority = mutationAuthority(
            target: target,
            styleSheetID: submittedDeclaration.styleID.owningStyleSheetID,
            node: node,
            styles: styles,
            in: context
        )
        let operation = beginToggleOperation(for: id)
        let weakContext = WeakContextReference(context)

        let task = Task { [self, target, styles, submissionAuthority, operation, weakContext] in
            do {
                try Task.checkCancellation()
                try await performRequestedStyleTextMutation(
                    mutation,
                    propertyID: id,
                    submittedDeclaration: submittedDeclaration,
                    node: node,
                    styles: styles,
                    target: target,
                    submissionAuthority: submissionAuthority,
                    operation: operation,
                    registersUndo: registersUndo,
                    context: weakContext
                )
                finishToggleOperation(for: id, operation: operation)
            } catch is CancellationError {
                finishToggleOperation(for: id, operation: operation)
            } catch let error as WebInspectorProxyError where error == Self.staleMutationError {
                finishToggleOperation(for: id, operation: operation)
            } catch {
                let isCurrent = isCurrentToggleOperation(for: id, operation: operation)
                finishToggleOperation(for: id, operation: operation)
                guard isCurrent, Task.isCancelled == false else {
                    return
                }
                weakContext.withContextIfPresent { context in
                    context.failIfTerminal(error, operation: "CSS.setStyleText")
                    self.refreshSelectedStyles(in: context)
                }
            }
        }
        if toggleOperations[id] === operation {
            operation.task = task
        } else {
            task.cancel()
        }
        return true
    }

    private func performRequestedStyleTextMutation(
        _ mutation: StyleTextMutation,
        propertyID: CSSStyleProperty.ID,
        submittedDeclaration: CSSDeclarationIdentity,
        node: DOMNode,
        styles: CSSStyles,
        target: WebInspectorTarget,
        submissionAuthority: MutationAuthority,
        operation: ToggleOperation,
        registersUndo: Bool,
        context: WeakContextReference
    ) async throws {
        try await operationGate.acquire(targetID: target.id)
        do {
            try await refreshRequestedStylesForMutationIfNeeded(
                node: node,
                styles: styles,
                target: target,
                submissionAuthority: submissionAuthority,
                propertyID: propertyID,
                operation: operation,
                context: context
            )
            let (intent, commandAuthority) = try context.withContext { context in
                try validate(submissionAuthority, in: context)
                try validateToggleOperation(propertyID, operation: operation)
                guard let intent = mutation.intent(
                    in: styles,
                    declaration: submittedDeclaration
                ),
                      try context.cssTarget(owning: intent.styleID).id == target.id else {
                    throw WebInspectorProxyError.commandFailed(
                        domain: "CSS",
                        method: "setStyleText",
                        message: "CSS declaration changed before the queued mutation could run."
                    )
                }
                return (
                    intent,
                    mutationAuthority(
                        target: target,
                        styleSheetID: intent.styleID.owningStyleSheetID,
                        node: node,
                        styles: styles,
                        in: context
                    )
                )
            }

            let result = try await target.css.setStyleText(intent.styleID, text: intent.text)
            try context.withContext { context in
                try validate(commandAuthority, in: context)
                try validateToggleOperation(propertyID, operation: operation)
            }
            try await WebInspectorContext.markDOMUndoableStateIfNeeded(on: target, registersUndo: registersUndo)
            try context.withContext { context in
                try validate(commandAuthority, in: context)
                try validateToggleOperation(propertyID, operation: operation)
                context.recordDOMEditHistoryTarget(target, registersUndo: registersUndo)
                styles.applySetStyleText(result: result, for: propertyID)
                refreshSelectedStylesIfHydrationActive(in: context)
            }
            await operationGate.release(targetID: target.id)
        } catch {
            await operationGate.release(targetID: target.id)
            throw error
        }
    }

    private func refreshRequestedStylesForMutationIfNeeded(
        node: DOMNode,
        styles: CSSStyles,
        target: WebInspectorTarget,
        submissionAuthority: MutationAuthority,
        propertyID: CSSStyleProperty.ID,
        operation: ToggleOperation,
        context: WeakContextReference
    ) async throws {
        let generation = try context.withContext { context in
            try validate(submissionAuthority, in: context)
            try validateToggleOperation(propertyID, operation: operation)
            return try beginStylesRefreshForMutationIfNeeded(styles)
        }
        guard let generation else {
            return
        }

        // Submission requires a previously materialized editable declaration,
        // which proves this target already owns an active style-tracking lease.
        // Reacquiring here would create a second lease owner for the same pane.
        do {
            let matchedStyles = try await target.css.matchedStyles(for: node.id.proxyID)
            try context.withContext {
                try validateRequestedStyleRefresh(
                    node: node,
                    generation: generation,
                    submissionAuthority: submissionAuthority,
                    propertyID: propertyID,
                    operation: operation,
                    in: $0
                )
            }
            let inlineStyles = try await target.css.inlineStyles(for: node.id.proxyID)
            try context.withContext {
                try validateRequestedStyleRefresh(
                    node: node,
                    generation: generation,
                    submissionAuthority: submissionAuthority,
                    propertyID: propertyID,
                    operation: operation,
                    in: $0
                )
            }
            let computedProperties = try await target.css.computedStyle(for: node.id.proxyID)
            try context.withContext {
                try validateRequestedStyleRefresh(
                    node: node,
                    generation: generation,
                    submissionAuthority: submissionAuthority,
                    propertyID: propertyID,
                    operation: operation,
                    in: $0
                )
                styles.load(
                    matchedStyles: matchedStyles,
                    inlineStyles: inlineStyles,
                    computedProperties: computedProperties,
                    generation: generation
                )
            }
        } catch is CancellationError {
            styles.cancelLoading(generation: generation)
            throw CancellationError()
        } catch let error as WebInspectorProxyError {
            if error == Self.staleMutationError {
                styles.cancelLoading(generation: generation)
            } else {
                styles.fail(error, generation: generation)
            }
            throw error
        } catch {
            let proxyError = WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode",
                message: String(describing: error)
            )
            styles.fail(proxyError, generation: generation)
            throw proxyError
        }
    }

    private func refreshStylesForMutationIfNeeded(
        node: DOMNode,
        styles: CSSStyles,
        target: WebInspectorTarget,
        in context: WebInspectorContext
    ) async throws {
        guard let generation = try beginStylesRefreshForMutationIfNeeded(styles) else {
            return
        }

        do {
            guard try await trackingLeases.ensure(on: target) else {
                styles.markUnavailable(generation: generation)
                throw WebInspectorProxyError.commandFailed(
                    domain: "CSS",
                    method: "setStyleText",
                    message: "CSS tracking is unavailable for the selected target."
                )
            }
            guard let payloads = try await selectedStylePayloads(
                for: node,
                target: target,
                generation: generation,
                in: context
            ) else {
                styles.cancelLoading(generation: generation)
                throw Self.staleMutationError
            }
            styles.load(
                matchedStyles: payloads.matchedStyles,
                inlineStyles: payloads.inlineStyles,
                computedProperties: payloads.computedProperties,
                generation: generation
            )
        } catch is CancellationError {
            styles.cancelLoading(generation: generation)
            throw CancellationError()
        } catch let error as WebInspectorProxyError {
            if error != Self.staleMutationError {
                styles.fail(error, generation: generation)
            }
            throw error
        } catch {
            let proxyError = WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "getMatchedStylesForNode/getInlineStylesForNode/getComputedStyleForNode",
                message: String(describing: error)
            )
            styles.fail(proxyError, generation: generation)
            throw proxyError
        }
    }

    /// Starts a load that an edit needs before it can run.
    /// - Returns: The generation of the load, or `nil` when the styles are
    ///   already loaded.
    private func beginStylesRefreshForMutationIfNeeded(
        _ styles: CSSStyles
    ) throws -> Int? {
        switch styles.phase {
        case .loaded:
            return nil
        case .loading, .needsRefresh:
            break
        case .unavailable, .failed:
            throw WebInspectorProxyError.commandFailed(
                domain: "CSS",
                method: "setStyleText",
                message: "Current CSS declarations are unavailable."
            )
        }

        invalidateRefresh()
        let generation = refreshGeneration
        styles.markLoading(generation: generation)
        return generation
    }

    private func validateRequestedStyleRefresh(
        node: DOMNode,
        generation: Int,
        submissionAuthority: MutationAuthority,
        propertyID: CSSStyleProperty.ID,
        operation: ToggleOperation,
        in context: WebInspectorContext
    ) throws {
        try validate(submissionAuthority, in: context)
        try validateToggleOperation(propertyID, operation: operation)
        guard isCurrentRefresh(node: node, generation: generation, in: context) else {
            throw Self.staleMutationError
        }
    }

    // MARK: - Whether an edit still applies

    private static var staleMutationError: WebInspectorProxyError {
        .disconnected("CSS mutation no longer belongs to the current document.")
    }

    private func mutationAuthority(
        target: WebInspectorTarget,
        styleSheetID: CSS.StyleSheet.ID?,
        tracksStyleSheetContentRevision: Bool = false,
        node: DOMNode? = nil,
        styles: CSSStyles? = nil,
        in context: WebInspectorContext
    ) -> MutationAuthority {
        MutationAuthority(
            target: context.targetAuthority(for: target),
            node: node,
            styles: styles,
            styleSheet: styleSheetID.map { id in
                MutationAuthority.StyleSheet(
                    id: id,
                    revision: styleSheets.revision(of: id),
                    contentRevision: tracksStyleSheetContentRevision
                        ? styleSheets.contentRevision(of: id)
                        : nil
                )
            }
        )
    }

    private func validate(
        _ authority: MutationAuthority,
        in context: WebInspectorContext
    ) throws {
        try Task.checkCancellation()
        guard context.isCurrent(authority.target) else {
            throw Self.staleMutationError
        }
        if let styleSheet = authority.styleSheet,
           styleSheet.revision != styleSheets.revision(of: styleSheet.id) {
            throw Self.staleMutationError
        }
        if let styleSheet = authority.styleSheet,
           let contentRevision = styleSheet.contentRevision,
           contentRevision != styleSheets.contentRevision(of: styleSheet.id) {
            throw Self.staleMutationError
        }
        if let node = authority.node,
           let styles = authority.styles {
            guard context.isRegistered(node),
                  context.selectedNode === node,
                  node.elementStyles === styles else {
                throw Self.staleMutationError
            }
        }
    }

    private func beginToggleOperation(for id: CSSStyleProperty.ID) -> ToggleOperation {
        let operation = ToggleOperation()
        toggleOperations[id] = operation
        return operation
    }

    private func isCurrentToggleOperation(
        for id: CSSStyleProperty.ID,
        operation: ToggleOperation
    ) -> Bool {
        toggleOperations[id] === operation
    }

    private func validateToggleOperation(
        _ id: CSSStyleProperty.ID,
        operation: ToggleOperation
    ) throws {
        guard isCurrentToggleOperation(for: id, operation: operation) else {
            throw Self.staleMutationError
        }
    }

    private func finishToggleOperation(
        for id: CSSStyleProperty.ID,
        operation: ToggleOperation
    ) {
        guard toggleOperations[id] === operation else {
            return
        }
        operation.task = nil
        toggleOperations[id] = nil
    }
}
