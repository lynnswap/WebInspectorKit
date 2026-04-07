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

    package mutating func updateDraft(_ value: String) {
        draftValue = value
        syncPhaseToCurrentBaseline()
    }

    @discardableResult
    package mutating func reconcile(externalValue: String?) -> WIDOMAttributeDraftReconcileResult {
        switch phase {
        case let .awaitingModelEcho(submittedValue, previousValue):
            return reconcileAwaitingModelEcho(
                externalValue: externalValue,
                submittedValue: submittedValue,
                previousValue: previousValue
            )
        case .clean, .editing:
            return reconcileLocalDraft(externalValue: externalValue)
        }
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

    private mutating func reconcileLocalDraft(
        externalValue: String?
    ) -> WIDOMAttributeDraftReconcileResult {
        guard let externalValue else {
            if isDirty {
                baselineExists = false
                preservesDeletedBaseline = true
                phase = .editing
                return .preserveDirty
            }
            clear()
            return .clear
        }

        if isDirty {
            baselineValue = externalValue
            baselineExists = true
            preservesDeletedBaseline = false
            if matchesCurrentBaseline {
                begin(value: externalValue)
                return .refreshClean
            }
            phase = .editing
            return .preserveDirty
        }

        begin(value: externalValue)
        return .refreshClean
    }

    private mutating func reconcileAwaitingModelEcho(
        externalValue: String?,
        submittedValue: String,
        previousValue: String?
    ) -> WIDOMAttributeDraftReconcileResult {
        guard let externalValue else {
            baselineExists = false
            preservesDeletedBaseline = true
            phase = .editing
            return .preserveDirty
        }

        baselineValue = externalValue
        baselineExists = true
        preservesDeletedBaseline = false
        if externalValue == submittedValue {
            begin(value: externalValue)
            return .refreshClean
        }
        if let previousValue,
           externalValue == previousValue {
            return .preserveDirty
        }
        syncPhaseToCurrentBaseline(fallback: .editing)
        if phase == .clean {
            begin(value: externalValue)
            return .refreshClean
        }
        return .preserveDirty
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

    package mutating func updateDraft(_ value: String) {
        draftState.updateDraft(value)
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

    @discardableResult
    package mutating func reconcile(externalValue: String?) -> WIDOMAttributeDraftReconcileResult {
        draftState.reconcile(externalValue: externalValue)
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
    switch updatedSession.reconcile(externalValue: externalValue) {
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
