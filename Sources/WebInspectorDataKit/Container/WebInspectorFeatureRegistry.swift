import Synchronization

private final class _WebInspectorFeatureSlot: @unchecked Sendable {
    let state: _WebInspectorStatePublisher<WebInspectorFeatureState>

    init(state: WebInspectorFeatureState = .disabled) {
        self.state = _WebInspectorStatePublisher(state)
    }
}

/// The ID-keyed owner for generic feature state and observation.
package final class WebInspectorFeatureRegistry: @unchecked Sendable {
    private struct Storage {
        var slots: [WebInspectorFeatureID: _WebInspectorFeatureSlot] = [:]
        var isFinished = false
    }

    private let storage = Mutex(Storage())

    package init(enabledFeatures: Set<WebInspectorFeatureID>) {
        storage.withLock { storage in
            for featureID in enabledFeatures {
                storage.slots[featureID] = _WebInspectorFeatureSlot()
            }
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

    package func finish() {
        let publishers = storage.withLock { storage in
            guard !storage.isFinished else {
                return [_WebInspectorStatePublisher<WebInspectorFeatureState>]()
            }
            storage.isFinished = true
            return storage.slots.values.map(\.state)
        }
        for publisher in publishers { publisher.finish() }
    }

    private func slot(
        for featureID: WebInspectorFeatureID
    ) -> _WebInspectorFeatureSlot {
        let result = storage.withLock {
            storage -> (slot: _WebInspectorFeatureSlot, finish: Bool) in
            if let slot = storage.slots[featureID] {
                return (slot, false)
            }
            let slot = _WebInspectorFeatureSlot()
            storage.slots[featureID] = slot
            return (slot, storage.isFinished)
        }
        if result.finish { result.slot.state.finish() }
        return result.slot
    }
}
