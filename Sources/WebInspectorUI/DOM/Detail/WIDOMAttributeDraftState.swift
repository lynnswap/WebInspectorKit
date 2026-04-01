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

package struct WIDOMAttributeDraftState: Equatable, Sendable {
    package private(set) var baselineValue = ""
    package private(set) var baselineExists = false
    package private(set) var draftValue = ""
    package private(set) var preservesDeletedBaseline = false

    package var isDirty: Bool {
        if baselineExists {
            return draftValue != baselineValue
        }
        return preservesDeletedBaseline || !draftValue.isEmpty
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
    }

    package mutating func updateDraft(_ value: String) {
        draftValue = value
    }

    @discardableResult
    package mutating func reconcile(externalValue: String?) -> WIDOMAttributeDraftReconcileResult {
        guard let externalValue else {
            if isDirty {
                baselineExists = false
                preservesDeletedBaseline = true
                return .preserveDirty
            }
            clear()
            return .clear
        }

        if isDirty {
            if draftValue == externalValue {
                begin(value: externalValue)
                return .refreshClean
            }
            baselineValue = externalValue
            baselineExists = true
            preservesDeletedBaseline = false
            return .preserveDirty
        }

        begin(value: externalValue)
        return .refreshClean
    }

    package mutating func markCommitted() {
        baselineValue = draftValue
        baselineExists = true
        preservesDeletedBaseline = false
    }

    package mutating func clear() {
        baselineValue = ""
        baselineExists = false
        draftValue = ""
        preservesDeletedBaseline = false
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

    package mutating func updateDraft(_ value: String) {
        draftState.updateDraft(value)
    }

    package mutating func markCommitted() {
        draftState.markCommitted()
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

package func resolveAttributeSheetDraftSessionAfterSuccessfulSave(
    _ session: WIDOMAttributeDraftSession?,
    key: WIDOMAttributeDraftKey,
    submittedValue: String
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
    session.markCommitted()
    return nil
}
