import Foundation
import WebKit

@MainActor
package protocol WISPIBridgeClient {
    func objectResult(target: NSObject, selectorName: String) -> NSObject?
    func boolResult(target: NSObject, selectorName: String) -> Bool?

    @discardableResult
    func setResourceLoadDelegate(on webView: WKWebView, selectorName: String, delegate: AnyObject?) -> Bool

    @discardableResult
    func invokeVoid(target: NSObject, selectorName: String) -> Bool

    @discardableResult
    func invokeActionState(
        target: NSObject,
        selectorName: String,
        stateRawValue: Int,
        notify: Bool
    ) -> Bool

    func makeContentWorld(
        configurationClassName: String,
        worldSelectorName: String,
        setters: [String: Bool]
    ) -> WKContentWorld?

    func makeJSBuffer(
        data: Data,
        classNames: [String],
        allocSelectorName: String,
        initSelectorName: String
    ) -> AnyObject?

    @discardableResult
    func addBuffer(
        controller: WKUserContentController,
        selectorName: String,
        buffer: AnyObject,
        name: String,
        world: WKContentWorld,
        isPublicSignature: Bool
    ) -> Bool

    @discardableResult
    func removeBuffer(
        controller: WKUserContentController,
        selectorName: String,
        name: String,
        world: WKContentWorld
    ) -> Bool
}
