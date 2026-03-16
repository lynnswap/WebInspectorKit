import Foundation
import WebKit

@MainActor
package protocol WISPIBridgeClient {
    @discardableResult
    func setResourceLoadDelegate(on webView: WKWebView, selectorName: String, delegate: AnyObject?) -> Bool

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
