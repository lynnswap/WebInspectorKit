import Foundation
import ObjectiveC
import WebKit

@MainActor
package final class WIUserContentControllerStateRegistry {
    package static let shared = WIUserContentControllerStateRegistry()

    private final class StateBox {
        var domBridgeScriptInstalled = false
        var domBootstrapSignature: String?
        var networkBridgeScriptInstalled = false
        var networkTokenBootstrapSignature: String?
    }

    private init() {}

    package func domBridgeScriptInstalled(on controller: WKUserContentController) -> Bool {
        stateBox(for: controller)?.domBridgeScriptInstalled ?? false
    }

    package func setDOMBridgeScriptInstalled(_ installed: Bool, on controller: WKUserContentController) {
        guard let state = stateBox(for: controller, createIfNeeded: true) else {
            return
        }
        state.domBridgeScriptInstalled = installed
    }

    package func domBootstrapSignature(on controller: WKUserContentController) -> String? {
        stateBox(for: controller)?.domBootstrapSignature
    }

    package func setDOMBootstrapSignature(_ signature: String?, on controller: WKUserContentController) {
        guard let state = stateBox(for: controller, createIfNeeded: true) else {
            return
        }
        state.domBootstrapSignature = signature
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
        unsafe objc_setAssociatedObject(
            controller,
            userContentControllerStateAssociationKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

nonisolated(unsafe) private let userContentControllerStateAssociationKey = unsafe malloc(1)!

@MainActor
private extension WIUserContentControllerStateRegistry {
    private func stateBox(
        for controller: WKUserContentController,
        createIfNeeded: Bool = false
    ) -> StateBox? {
        if let existing = unsafe objc_getAssociatedObject(
            controller,
            userContentControllerStateAssociationKey
        ) as? StateBox {
            return existing
        }

        guard createIfNeeded else {
            return nil
        }

        let created = StateBox()
        unsafe objc_setAssociatedObject(
            controller,
            userContentControllerStateAssociationKey,
            created,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return created
    }
}
