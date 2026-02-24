import Foundation
import WebInspectorKitSPIObjC
import WebKit

@MainActor
package struct WISPIObjCBridgeClient: WISPIBridgeClient {
    package init() {}

    package func objectResult(target: NSObject, selectorName: String) -> NSObject? {
        WIKRuntimeBridge.objectResult(fromTarget: target, selectorName: selectorName)
    }

    package func boolResult(target: NSObject, selectorName: String) -> Bool? {
        WIKRuntimeBridge.boolResult(fromTarget: target, selectorName: selectorName)?.boolValue
    }

    package func setResourceLoadDelegate(on webView: WKWebView, selectorName: String, delegate: AnyObject?) -> Bool {
        WIKRuntimeBridge.invokeSetResourceLoadDelegate(on: webView, selectorName: selectorName, delegate: delegate)
    }

    package func invokeVoid(target: NSObject, selectorName: String) -> Bool {
        WIKRuntimeBridge.invokeVoid(onTarget: target, selectorName: selectorName)
    }

    package func invokeActionState(
        target: NSObject,
        selectorName: String,
        stateRawValue: Int,
        notify: Bool
    ) -> Bool {
        WIKRuntimeBridge.invokeActionState(onTarget: target, selectorName: selectorName, stateRawValue: stateRawValue, notifyObservers: notify)
    }

    package func makeContentWorld(
        configurationClassName: String,
        worldSelectorName: String,
        setters: [String: Bool]
    ) -> WKContentWorld? {
        let values = setters.mapValues(NSNumber.init(value:))
        return WIKRuntimeBridge.makeContentWorld(withConfigurationClassName: configurationClassName, worldSelectorName: worldSelectorName, setters: values)
    }

    package func makeJSBuffer(
        data: Data,
        classNames: [String],
        allocSelectorName: String,
        initSelectorName: String
    ) -> AnyObject? {
        WIKRuntimeBridge.makeJSBuffer(with: data, classNames: classNames, allocSelectorName: allocSelectorName, initSelectorName: initSelectorName) as AnyObject?
    }

    package func addBuffer(
        controller: WKUserContentController,
        selectorName: String,
        buffer: AnyObject,
        name: String,
        world: WKContentWorld,
        isPublicSignature: Bool
    ) -> Bool {
        WIKRuntimeBridge.addBuffer(on: controller, selectorName: selectorName, buffer: buffer, name: name, contentWorld: world, isPublicSignature: isPublicSignature)
    }

    package func removeBuffer(
        controller: WKUserContentController,
        selectorName: String,
        name: String,
        world: WKContentWorld
    ) -> Bool {
        WIKRuntimeBridge.removeBuffer(on: controller, selectorName: selectorName, name: name, contentWorld: world)
    }
}
