import Foundation
import OSLog
import WebKit
#if canImport(UIKit)
import UIKit
#endif

private let spiRuntimeLogger = Logger(subsystem: "WebInspectorKit", category: "SPIRuntime")

@MainActor
package enum WIBridgeMode: String, Sendable {
    case legacyJSON
    case privateCore
    case privateFull

    fileprivate var rank: Int {
        switch self {
        case .legacyJSON:
            return 0
        case .privateCore:
            return 1
        case .privateFull:
            return 2
        }
    }
}

package enum WISPISymbols {
    package static func deobfuscate(_ reverseTokens: [String]) -> String {
        reverseTokens.reversed().joined()
    }

    package static let worldWithConfigurationSelector = deobfuscate([":", "Configuration", "With", "world", "_"])
    package static let publicAddBufferSelector = deobfuscate([":", "World", "content", ":", "name", ":", "Buffer", "add"])
    package static let publicRemoveBufferSelector = deobfuscate([":", "World", "content", ":", "Name", "With", "Buffer", "remove"])
    package static let privateAddBufferSelector = deobfuscate([":", "name", ":", "World", "content", ":", "Buffer", "add", "_"])
    package static let privateRemoveBufferSelector = deobfuscate([":", "World", "content", ":", "Name", "With", "Buffer", "remove", "_"])
    package static let setResourceLoadDelegateSelector = deobfuscate([":", "Delegate", "Load", "Resource", "set", "_"])
    package static let allocSelector = deobfuscate(["alloc"])
    package static let initWithDataSelector = deobfuscate([":", "Data", "With", "init"])
    package static let contextMenuInteractionSelector = deobfuscate(["Interaction", "Menu", "context", "_"])
    package static let hasVisibleMenuSelector = deobfuscate(["Menu", "Visible", "has", "_"])
    package static let updateMenuInPlaceSelector = deobfuscate(["Place", "In", "Menu", "update", "_"])
    package static let updateForAutomaticSelectionSelector = deobfuscate(["Selection", "Automatic", "For", "update", "_"])
    package static let setActionStateNotifyingObserversSelector = deobfuscate([":", "Observers", "notifying", ":", "State", "set", "_"])
    package static let updateViewSelector = deobfuscate(["View", "update", "_"])

    package static let contentWorldConfigurationClass = deobfuscate(["Configuration", "World", "Content", "WK", "_"])
    package static let privateJSHandleClass = deobfuscate(["Handle", "JS", "WK", "_"])
    package static let publicJSHandleClass = deobfuscate(["Handle", "JS", "WK"])
    package static let privateSerializedNodeClass = deobfuscate(["Node", "Serialized", "WK", "_"])
    package static let publicSerializedNodeClass = deobfuscate(["Node", "Serialized", "JS", "WK"])
    package static let privateJSBufferClass = deobfuscate(["Buffer", "JS", "WK", "_"])
    package static let publicJSScriptingBufferClass = deobfuscate(["Buffer", "Scripting", "JS", "WK"])

    package static let enableJSHandleSetterNames = [
        deobfuscate([":", "Creation", "Handle", "JS", "Allow", "set"]),
        deobfuscate([":", "Enabled", "Creation", "Handle", "JS", "set"]),
    ]
    package static let enableNodeSerializationSetterNames = [
        deobfuscate([":", "Serialization", "Node", "Allow", "set"]),
        deobfuscate([":", "Enabled", "Serialization", "Node", "set"]),
    ]
}

package struct WISPICapabilities: Sendable {
    package let hasContentWorldConfiguration: Bool
    package let hasJSHandleClass: Bool
    package let hasSerializedNodeClass: Bool
    package let hasJSBufferClass: Bool
    package let hasWorldWithConfigurationSelector: Bool
    package let hasPublicAddBufferSelector: Bool
    package let hasPublicRemoveBufferSelector: Bool
    package let hasPrivateAddBufferSelector: Bool
    package let hasPrivateRemoveBufferSelector: Bool
    package let hasSetResourceLoadDelegateSelector: Bool

    package init(
        hasContentWorldConfiguration: Bool,
        hasJSHandleClass: Bool,
        hasSerializedNodeClass: Bool,
        hasJSBufferClass: Bool,
        hasWorldWithConfigurationSelector: Bool,
        hasPublicAddBufferSelector: Bool,
        hasPublicRemoveBufferSelector: Bool,
        hasPrivateAddBufferSelector: Bool,
        hasPrivateRemoveBufferSelector: Bool,
        hasSetResourceLoadDelegateSelector: Bool = false
    ) {
        self.hasContentWorldConfiguration = hasContentWorldConfiguration
        self.hasJSHandleClass = hasJSHandleClass
        self.hasSerializedNodeClass = hasSerializedNodeClass
        self.hasJSBufferClass = hasJSBufferClass
        self.hasWorldWithConfigurationSelector = hasWorldWithConfigurationSelector
        self.hasPublicAddBufferSelector = hasPublicAddBufferSelector
        self.hasPublicRemoveBufferSelector = hasPublicRemoveBufferSelector
        self.hasPrivateAddBufferSelector = hasPrivateAddBufferSelector
        self.hasPrivateRemoveBufferSelector = hasPrivateRemoveBufferSelector
        self.hasSetResourceLoadDelegateSelector = hasSetResourceLoadDelegateSelector
    }

    package var supportsPrivateCore: Bool {
        hasContentWorldConfiguration
            && hasJSHandleClass
            && hasSerializedNodeClass
            && hasWorldWithConfigurationSelector
    }

    package var supportsPrivateFull: Bool {
        supportsPrivateCore
            && hasJSBufferClass
            && (
                (hasPublicAddBufferSelector && hasPublicRemoveBufferSelector)
                    || (hasPrivateAddBufferSelector && hasPrivateRemoveBufferSelector)
            )
    }
}

@MainActor
package final class WISPIRuntime {
    package static let shared = WISPIRuntime()

    private static let worldWithConfigurationSelector = NSSelectorFromString(WISPISymbols.worldWithConfigurationSelector)
    private static let publicAddBufferSelector = NSSelectorFromString(WISPISymbols.publicAddBufferSelector)
    private static let publicRemoveBufferSelector = NSSelectorFromString(WISPISymbols.publicRemoveBufferSelector)
    private static let privateAddBufferSelector = NSSelectorFromString(WISPISymbols.privateAddBufferSelector)
    private static let privateRemoveBufferSelector = NSSelectorFromString(WISPISymbols.privateRemoveBufferSelector)
    private static let setResourceLoadDelegateSelector = NSSelectorFromString(WISPISymbols.setResourceLoadDelegateSelector)
    #if canImport(UIKit)
    private static let contextMenuInteractionSelector = NSSelectorFromString(WISPISymbols.contextMenuInteractionSelector)
    private static let hasVisibleMenuSelector = NSSelectorFromString(WISPISymbols.hasVisibleMenuSelector)
    private static let updateMenuInPlaceSelector = NSSelectorFromString(WISPISymbols.updateMenuInPlaceSelector)
    private static let updateForAutomaticSelectionSelector = NSSelectorFromString(WISPISymbols.updateForAutomaticSelectionSelector)
    private static let setActionStateNotifyingObserversSelector = NSSelectorFromString(WISPISymbols.setActionStateNotifyingObserversSelector)
    private static let updateViewSelector = NSSelectorFromString(WISPISymbols.updateViewSelector)
    #endif

    private var startupCapabilitiesCache: WISPICapabilities?
    private var startupModeCache: WIBridgeMode?
    private var cachedWorldByName: [String: WKContentWorld] = [:]
    private let bridgeClient: WISPIBridgeClient

    private init(bridgeClient: WISPIBridgeClient = WISPIObjCBridgeClient()) {
        self.bridgeClient = bridgeClient
    }

    package func startupCapabilities() -> WISPICapabilities {
        if let startupCapabilitiesCache {
            return startupCapabilitiesCache
        }
        let capabilities = probeCapabilities(userContentController: nil)
        startupCapabilitiesCache = capabilities
        return capabilities
    }

    package func startupMode() -> WIBridgeMode {
        if let startupModeCache {
            return startupModeCache
        }
        let mode = mode(for: startupCapabilities())
        startupModeCache = mode
        spiRuntimeLogger.debug("bridge_mode=\(mode.rawValue, privacy: .public)")
        return mode
    }

    package func modeForAttachment(webView: WKWebView?) -> WIBridgeMode {
        let startup = startupMode()
        guard let webView else {
            return startup
        }

        let attachmentCapabilities = probeCapabilities(userContentController: webView.configuration.userContentController)
        let attachment = mode(for: attachmentCapabilities)
        let resolved = minimumMode(startup, attachment)

        if startup != .legacyJSON, resolved == .legacyJSON {
            spiRuntimeLogger.error(
                "runtime_probe_failed startup=\(startup.rawValue, privacy: .public) attach=\(attachment.rawValue, privacy: .public)"
            )
        }

        return resolved
    }

    package func makeBridgeWorld(named worldName: String) -> WKContentWorld {
        if let cached = cachedWorldByName[worldName] {
            return cached
        }

        let world = makeConfiguredBridgeWorld() ?? WKContentWorld.world(name: worldName)
        cachedWorldByName[worldName] = world
        return world
    }

    package func probeCapabilities(userContentController: WKUserContentController?) -> WISPICapabilities {
        let configurationClass: AnyClass? = NSClassFromString(WISPISymbols.contentWorldConfigurationClass)
        let hasContentWorldConfiguration = configurationClass != nil
        let hasJSHandleClass = NSClassFromString(WISPISymbols.privateJSHandleClass) != nil
            || NSClassFromString(WISPISymbols.publicJSHandleClass) != nil
        let hasSerializedNodeClass = NSClassFromString(WISPISymbols.privateSerializedNodeClass) != nil
            || NSClassFromString(WISPISymbols.publicSerializedNodeClass) != nil
        let hasJSBufferClass = NSClassFromString(WISPISymbols.privateJSBufferClass) != nil
            || NSClassFromString(WISPISymbols.publicJSScriptingBufferClass) != nil
        let hasWorldWithConfigurationSelector = WKContentWorld.responds(to: Self.worldWithConfigurationSelector)

        let controller: WKUserContentController = userContentController ?? WKUserContentController()
        let hasPublicAddBufferSelector = controller.responds(to: Self.publicAddBufferSelector)
            || WKUserContentController.instancesRespond(to: Self.publicAddBufferSelector)
        let hasPublicRemoveBufferSelector = controller.responds(to: Self.publicRemoveBufferSelector)
            || WKUserContentController.instancesRespond(to: Self.publicRemoveBufferSelector)
        let hasPrivateAddBufferSelector = controller.responds(to: Self.privateAddBufferSelector)
            || WKUserContentController.instancesRespond(to: Self.privateAddBufferSelector)
        let hasPrivateRemoveBufferSelector = controller.responds(to: Self.privateRemoveBufferSelector)
            || WKUserContentController.instancesRespond(to: Self.privateRemoveBufferSelector)
        let hasSetResourceLoadDelegateSelector = WKWebView.instancesRespond(to: Self.setResourceLoadDelegateSelector)

        return WISPICapabilities(
            hasContentWorldConfiguration: hasContentWorldConfiguration,
            hasJSHandleClass: hasJSHandleClass,
            hasSerializedNodeClass: hasSerializedNodeClass,
            hasJSBufferClass: hasJSBufferClass,
            hasWorldWithConfigurationSelector: hasWorldWithConfigurationSelector,
            hasPublicAddBufferSelector: hasPublicAddBufferSelector,
            hasPublicRemoveBufferSelector: hasPublicRemoveBufferSelector,
            hasPrivateAddBufferSelector: hasPrivateAddBufferSelector,
            hasPrivateRemoveBufferSelector: hasPrivateRemoveBufferSelector,
            hasSetResourceLoadDelegateSelector: hasSetResourceLoadDelegateSelector
        )
    }

    package func canSetResourceLoadDelegate(on webView: WKWebView) -> Bool {
        webView.responds(to: Self.setResourceLoadDelegateSelector)
            || WKWebView.instancesRespond(to: Self.setResourceLoadDelegateSelector)
    }

    @discardableResult
    package func setResourceLoadDelegate(on webView: WKWebView, delegate: AnyObject?) -> Bool {
        guard canSetResourceLoadDelegate(on: webView) else {
            spiRuntimeLogger.notice(
                "selector_missing selector=\(WISPISymbols.setResourceLoadDelegateSelector, privacy: .public)"
            )
            return false
        }

        return bridgeClient.setResourceLoadDelegate(
            on: webView,
            selectorName: WISPISymbols.setResourceLoadDelegateSelector,
            delegate: delegate
        )
    }

    #if canImport(UIKit)
    package func hasVisibleMenu(for barButtonItem: UIBarButtonItem) -> Bool {
        guard let interaction = contextMenuInteractionObject(for: barButtonItem) else {
            return false
        }
        return WISPIObjCInvoker.boolResult(from: interaction, selector: Self.hasVisibleMenuSelector) ?? false
    }

    @discardableResult
    package func updateMenuInPlace(for barButtonItem: UIBarButtonItem) -> Bool {
        WISPIObjCInvoker.boolResult(from: barButtonItem, selector: Self.updateMenuInPlaceSelector) ?? false
    }

    package func updateForAutomaticSelection(for barButtonItem: UIBarButtonItem) {
        guard barButtonItem.responds(to: Self.updateForAutomaticSelectionSelector) else {
            return
        }
        _ = bridgeClient.invokeVoid(
            target: barButtonItem,
            selectorName: WISPISymbols.updateForAutomaticSelectionSelector
        )
    }

    package func setMenuActionState(_ action: UIAction, to state: UIMenuElement.State) {
        guard action.responds(to: Self.setActionStateNotifyingObserversSelector) else {
            action.state = state
            return
        }
        _ = bridgeClient.invokeActionState(
            target: action,
            selectorName: WISPISymbols.setActionStateNotifyingObserversSelector,
            stateRawValue: state.rawValue,
            notify: true
        )
    }

    package func requestUpdate(for barButtonItem: UIBarButtonItem) {
        guard barButtonItem.responds(to: Self.updateViewSelector) else {
            return
        }
        _ = bridgeClient.invokeVoid(
            target: barButtonItem,
            selectorName: WISPISymbols.updateViewSelector
        )
    }

    package func updateVisibleMenu(
        for barButtonItem: UIBarButtonItem,
        menuProvider: @escaping (UIMenu) -> UIMenu
    ) {
        guard
            let interaction = contextMenuInteractionObject(for: barButtonItem) as? UIContextMenuInteraction
        else {
            return
        }
        interaction.updateVisibleMenu(menuProvider)
    }

    private func contextMenuInteractionObject(for barButtonItem: UIBarButtonItem) -> NSObject? {
        WISPIObjCInvoker.objectResult(from: barButtonItem, selector: Self.contextMenuInteractionSelector)
    }
    #endif
}

extension WISPIRuntime {
    package func mode(for capabilities: WISPICapabilities) -> WIBridgeMode {
        if capabilities.supportsPrivateFull {
            return .privateFull
        }
        if capabilities.supportsPrivateCore {
            return .privateCore
        }
        return .legacyJSON
    }

    func minimumMode(_ lhs: WIBridgeMode, _ rhs: WIBridgeMode) -> WIBridgeMode {
        lhs.rank <= rhs.rank ? lhs : rhs
    }

    func makeConfiguredBridgeWorld() -> WKContentWorld? {
        guard startupMode() != .legacyJSON else {
            return nil
        }

        var setters: [String: Bool] = [:]
        for setter in WISPISymbols.enableJSHandleSetterNames {
            setters[setter] = true
        }
        for setter in WISPISymbols.enableNodeSerializationSetterNames {
            setters[setter] = true
        }

        guard
            let world = bridgeClient.makeContentWorld(
                configurationClassName: WISPISymbols.contentWorldConfigurationClass,
                worldSelectorName: WISPISymbols.worldWithConfigurationSelector,
                setters: setters
            )
        else {
            spiRuntimeLogger.error("runtime_probe_failed: worldWithConfiguration invocation failed")
            return nil
        }

        return world
    }
}
