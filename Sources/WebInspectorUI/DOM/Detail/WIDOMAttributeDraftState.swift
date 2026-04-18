import WebInspectorEngine

package enum WIDOMAttributeDraftReconcileResult: Equatable, Sendable {
    case refreshClean
    case preserveDirty
    case clear
}

package enum WIDOMAttributeDraftSessionReconcileResult: Equatable, Sendable {
    case keep(WIDOMAttributeDraftSession)
    case clear
    case deferClear
}

package enum WIDOMAttributeDraftPhase: Equatable, Sendable {
    case clean
    case editing
    case awaitingModelEcho(submittedValue: String, previousValue: String?)
}

package struct WIDOMAttributeDraftState: Equatable, Sendable {
    package private(set) var baselineValue = ""
    package private(set) var baselineExists = false
    package private(set) var draftValue = ""
    package private(set) var preservesDeletedBaseline = false
    package private(set) var phase: WIDOMAttributeDraftPhase = .clean

    package var isDirty: Bool {
        phase != .clean
    }

    package var isAwaitingModelEcho: Bool {
        if case .awaitingModelEcho = phase {
            return true
        }
        return false
    }

    package init() {}

    package init(value: String) {
        baselineValue = value
        baselineExists = true
        draftValue = value
    }

    package mutating func begin(value: String) {
        baselineValue = value
        baselineExists = true
        draftValue = value
        preservesDeletedBaseline = false
        phase = .clean
    }

    package mutating func userEditedDraft(_ value: String) {
        draftValue = value
        syncPhaseToCurrentBaseline()
    }

    @discardableResult
    package mutating func externalBaselineAdvanced(
        _ externalValue: String
    ) -> WIDOMAttributeDraftReconcileResult {
        if !isDirty {
            begin(value: externalValue)
            return .refreshClean
        }

        baselineValue = externalValue
        baselineExists = true
        preservesDeletedBaseline = false
        if draftValue == externalValue {
            begin(value: externalValue)
            return .refreshClean
        }
        phase = .editing
        return .preserveDirty
    }

    @discardableResult
    package mutating func modelEchoMatched(
        submittedValue: String
    ) -> WIDOMAttributeDraftReconcileResult {
        baselineValue = submittedValue
        baselineExists = true
        preservesDeletedBaseline = false
        if draftValue == submittedValue {
            begin(value: submittedValue)
            return .refreshClean
        }
        phase = .editing
        return .preserveDirty
    }

    @discardableResult
    package mutating func selectionOrAttributeInvalidated(
        exists: Bool
    ) -> WIDOMAttributeDraftReconcileResult {
        guard exists == false else {
            return isDirty ? .preserveDirty : .refreshClean
        }

        if isDirty {
            baselineExists = false
            preservesDeletedBaseline = true
            phase = .editing
            return .preserveDirty
        }
        clear()
        return .clear
    }

    package mutating func markAwaitingModelEcho(
        submittedValue: String,
        previousValue: String?
    ) {
        guard draftValue == submittedValue else {
            return
        }
        phase = .awaitingModelEcho(
            submittedValue: submittedValue,
            previousValue: previousValue
        )
    }

    package mutating func markCommitted() {
        begin(value: draftValue)
    }

    package mutating func clear() {
        baselineValue = ""
        baselineExists = false
        draftValue = ""
        preservesDeletedBaseline = false
        phase = .clean
    }

    @discardableResult
    package mutating func applyObservedExternalValue(
        _ externalValue: String?
    ) -> WIDOMAttributeDraftReconcileResult {
        switch phase {
        case let .awaitingModelEcho(submittedValue, _):
            if let externalValue {
                if externalValue == submittedValue {
                    return modelEchoMatched(submittedValue: submittedValue)
                }
                return externalBaselineAdvanced(externalValue)
            }
            return selectionOrAttributeInvalidated(exists: false)
        case .clean, .editing:
            if let externalValue {
                return externalBaselineAdvanced(externalValue)
            }
            return selectionOrAttributeInvalidated(exists: false)
        }
    }

    package mutating func updateDraft(_ value: String) {
        userEditedDraft(value)
    }

    private var matchesCurrentBaseline: Bool {
        if baselineExists {
            return draftValue == baselineValue
        }
        return !preservesDeletedBaseline && draftValue.isEmpty
    }

    private mutating func syncPhaseToCurrentBaseline(
        fallback: WIDOMAttributeDraftPhase = .editing
    ) {
        phase = matchesCurrentBaseline ? .clean : fallback
    }
}

package struct WIDOMAttributeDraftKey: Hashable, Sendable, Identifiable {
    package let nodeID: DOMNodeModel.ID
    package let attributeName: String

    package var id: Self {
        self
    }
}

package struct WIDOMAttributeDraftSession: Equatable, Sendable, Identifiable {
    package let key: WIDOMAttributeDraftKey
    package var draftState: WIDOMAttributeDraftState

    package init(key: WIDOMAttributeDraftKey, value: String) {
        self.key = key
        self.draftState = .init(value: value)
    }

    package var id: WIDOMAttributeDraftKey {
        key
    }

    package var draftValue: String {
        draftState.draftValue
    }

    package var isDirty: Bool {
        draftState.isDirty
    }

    package var phase: WIDOMAttributeDraftPhase {
        draftState.phase
    }

    package var isAwaitingModelEcho: Bool {
        draftState.isAwaitingModelEcho
    }

    @discardableResult
    package mutating func externalBaselineAdvanced(
        _ externalValue: String
    ) -> WIDOMAttributeDraftReconcileResult {
        draftState.externalBaselineAdvanced(externalValue)
    }

    @discardableResult
    package mutating func modelEchoMatched(
        submittedValue: String
    ) -> WIDOMAttributeDraftReconcileResult {
        draftState.modelEchoMatched(submittedValue: submittedValue)
    }

    @discardableResult
    package mutating func selectionOrAttributeInvalidated(
        exists: Bool
    ) -> WIDOMAttributeDraftReconcileResult {
        draftState.selectionOrAttributeInvalidated(exists: exists)
    }

    @discardableResult
    package mutating func applyObservedExternalValue(
        _ externalValue: String?
    ) -> WIDOMAttributeDraftReconcileResult {
        draftState.applyObservedExternalValue(externalValue)
    }

    package mutating func userEditedDraft(_ value: String) {
        draftState.userEditedDraft(value)
    }

    package mutating func updateDraft(_ value: String) {
        userEditedDraft(value)
    }

    package mutating func markCommitted() {
        draftState.markCommitted()
    }

    package mutating func markAwaitingModelEcho(
        submittedValue: String,
        previousValue: String?
    ) {
        draftState.markAwaitingModelEcho(
            submittedValue: submittedValue,
            previousValue: previousValue
        )
    }
}

@MainActor
package func reconcileAttributeDraftSession(
    _ session: WIDOMAttributeDraftSession,
    selectedNode: DOMNodeModel?,
    allowTransientDeselection: Bool
) -> WIDOMAttributeDraftSessionReconcileResult {
    guard let selectedNode else {
        return allowTransientDeselection ? .deferClear : .clear
    }
    guard selectedNode.id == session.key.nodeID else {
        return .clear
    }

    var updatedSession = session
    let externalValue = selectedNode.attributes.first(where: { $0.name == session.key.attributeName })?.value
    switch updatedSession.applyObservedExternalValue(externalValue) {
    case .refreshClean, .preserveDirty:
        return .keep(updatedSession)
    case .clear:
        return .clear
    }
}

package func resolveInlineAttributeDraftSessionAfterSuccessfulSave(
    currentSession: WIDOMAttributeDraftSession?,
    key: WIDOMAttributeDraftKey,
    submittedValue: String,
    previousValue: String?
) -> WIDOMAttributeDraftSession? {
    return resolveAttributeDraftSessionAfterSuccessfulSave(
        currentSession,
        key: key,
        submittedValue: submittedValue,
        previousValue: previousValue,
        dismissOnSuccessfulSave: false
    )
}

package func resolveAttributeSheetDraftSessionAfterSuccessfulSave(
    _ session: WIDOMAttributeDraftSession?,
    key: WIDOMAttributeDraftKey,
    submittedValue: String
) -> WIDOMAttributeDraftSession? {
    resolveAttributeDraftSessionAfterSuccessfulSave(
        session,
        key: key,
        submittedValue: submittedValue,
        previousValue: nil,
        dismissOnSuccessfulSave: true
    )
}

private func resolveAttributeDraftSessionAfterSuccessfulSave(
    _ session: WIDOMAttributeDraftSession?,
    key: WIDOMAttributeDraftKey,
    submittedValue: String,
    previousValue: String?,
    dismissOnSuccessfulSave: Bool
) -> WIDOMAttributeDraftSession? {
    guard var session else {
        return nil
    }
    guard session.key == key else {
        return session
    }
    guard session.draftValue == submittedValue else {
        return session
    }
    if dismissOnSuccessfulSave {
        return nil
    }
    if submittedValue == previousValue {
        session.markCommitted()
        return session
    }
    session.markAwaitingModelEcho(
        submittedValue: submittedValue,
        previousValue: previousValue
    )
    return session
}
