import Foundation
import WebKit

@MainActor
package final class WIUserContentControllerStateRegistry {
    package static let shared = WIUserContentControllerStateRegistry()
    private static let compactionIntervalNanoseconds: UInt64 = 5_000_000_000

    private struct Entry {
        weak var controller: WKUserContentController?
        let state: StateBox
    }

    private final class StateBox {
        var domBridgeScriptInstalled = false
        var networkBridgeScriptInstalled = false
        var networkTokenBootstrapSignature: String?
    }

    private var storage: [ObjectIdentifier: Entry] = [:]
    private var compactionTask: Task<Void, Never>?

    private init() {}

    isolated deinit {
        compactionTask?.cancel()
    }

    package func domBridgeScriptInstalled(on controller: WKUserContentController) -> Bool {
        stateBox(for: controller)?.domBridgeScriptInstalled ?? false
    }

    package func setDOMBridgeScriptInstalled(_ installed: Bool, on controller: WKUserContentController) {
        guard let state = stateBox(for: controller, createIfNeeded: true) else {
            return
        }
        state.domBridgeScriptInstalled = installed
    }

    package func networkBridgeScriptInstalled(on controller: WKUserContentController) -> Bool {
        stateBox(for: controller)?.networkBridgeScriptInstalled ?? false
    }

    package func setNetworkBridgeScriptInstalled(_ installed: Bool, on controller: WKUserContentController) {
        guard let state = stateBox(for: controller, createIfNeeded: true) else {
            return
        }
        state.networkBridgeScriptInstalled = installed
    }

    package func networkTokenBootstrapSignature(on controller: WKUserContentController) -> String? {
        stateBox(for: controller)?.networkTokenBootstrapSignature
    }

    package func setNetworkTokenBootstrapSignature(_ signature: String?, on controller: WKUserContentController) {
        guard let state = stateBox(for: controller, createIfNeeded: true) else {
            return
        }
        state.networkTokenBootstrapSignature = signature
    }

    package func clearState(for controller: WKUserContentController) {
        storage.removeValue(forKey: ObjectIdentifier(controller))
        stopCompactionLoopIfNeeded()
    }
}

@MainActor
private extension WIUserContentControllerStateRegistry {
    private func stateBox(
        for controller: WKUserContentController,
        createIfNeeded: Bool = false
    ) -> StateBox? {
        compactStorage()
        let key = ObjectIdentifier(controller)
        if let existing = storage[key], existing.controller != nil {
            return existing.state
        }

        guard createIfNeeded else {
            return nil
        }
        let created = StateBox()
        storage[key] = Entry(controller: controller, state: created)
        startCompactionLoopIfNeeded()
        return created
    }

    private func compactStorage() {
        if storage.isEmpty {
            stopCompactionLoopIfNeeded()
            return
        }
        storage = storage.filter { _, entry in
            entry.controller != nil
        }
        stopCompactionLoopIfNeeded()
    }

    private func startCompactionLoopIfNeeded() {
        guard compactionTask == nil else {
            return
        }
        compactionTask = Task { @MainActor [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: Self.compactionIntervalNanoseconds)
                guard !Task.isCancelled else {
                    return
                }
                self.compactStorage()
                if self.storage.isEmpty {
                    return
                }
            }
        }
    }

    private func stopCompactionLoopIfNeeded() {
        guard storage.isEmpty else {
            return
        }
        compactionTask?.cancel()
        compactionTask = nil
    }
}
