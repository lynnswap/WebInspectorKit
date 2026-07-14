import Synchronization

private final class _WebInspectorFeatureSlot: @unchecked Sendable {
    let state: _WebInspectorStatePublisher<WebInspectorFeatureState>
    var retry: (@Sendable () async -> Void)?

    init(state: WebInspectorFeatureState = .disabled) {
        self.state = _WebInspectorStatePublisher(state)
    }
}

/// The ID-keyed owner for generic feature state, observation, and retry.
/// Concrete DOM/Network/Console facades delegate here instead of introducing
/// a central switch over feature implementations.
package final class WebInspectorFeatureRegistry: @unchecked Sendable {
    private let slots = Mutex<[WebInspectorFeatureID: _WebInspectorFeatureSlot]>([:])

    package init(enabledFeatures: Set<WebInspectorFeatureID>) {
        slots.withLock { slots in
            for featureID in enabledFeatures {
                slots[featureID] = _WebInspectorFeatureSlot()
            }
        }
    }

    package func install(
        _ featureID: WebInspectorFeatureID,
        retry: @escaping @Sendable () async -> Void
    ) {
        slots.withLock { slots in
            let slot = slots[featureID] ?? _WebInspectorFeatureSlot()
            slot.retry = retry
            slots[featureID] = slot
        }
    }

    package func publish(
        _ state: WebInspectorFeatureState,
        for featureID: WebInspectorFeatureID
    ) {
        slot(for: featureID).state.publish(state)
    }

    package func state(
        for featureID: WebInspectorFeatureID
    ) -> WebInspectorFeatureState {
        slot(for: featureID).state.current
    }

    package func updates(
        for featureID: WebInspectorFeatureID
    ) -> WebInspectorStateUpdates<WebInspectorFeatureState> {
        slot(for: featureID).state.updates()
    }

    package func retry(_ featureID: WebInspectorFeatureID) async {
        let retry = slots.withLock { $0[featureID]?.retry }
        await retry?()
    }

    package func finish() {
        let publishers = slots.withLock {
            $0.values.map(\.state)
        }
        for publisher in publishers { publisher.finish() }
    }

    private func slot(
        for featureID: WebInspectorFeatureID
    ) -> _WebInspectorFeatureSlot {
        slots.withLock { slots in
            if let slot = slots[featureID] { return slot }
            let slot = _WebInspectorFeatureSlot()
            slots[featureID] = slot
            return slot
        }
    }
}
