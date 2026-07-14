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

    package func install(
        _ featureID: WebInspectorFeatureID,
        retry: @escaping @Sendable () async -> Void
    ) {
        storage.withLock { storage in
            guard !storage.isFinished else { return }
            let slot = storage.slots[featureID] ?? _WebInspectorFeatureSlot()
            slot.retry = retry
            storage.slots[featureID] = slot
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
        let retry = storage.withLock {
            storage -> (@Sendable () async -> Void)? in
            guard !storage.isFinished else { return nil }
            return storage.slots[featureID]?.retry
        }
        await retry?()
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
