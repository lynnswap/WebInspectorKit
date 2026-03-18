import Foundation
import WebInspectorBridgeObjCShim
import WebKit

@MainActor
package struct WISPIObjCBridgeClient: WISPIBridgeClient {
    package init() {}

    package func setResourceLoadDelegate(on webView: WKWebView, selectorName: String, delegate: AnyObject?) -> Bool {
        WIKRuntimeBridge.invokeSetResourceLoadDelegate(on: webView, selectorName: selectorName, delegate: delegate)
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
