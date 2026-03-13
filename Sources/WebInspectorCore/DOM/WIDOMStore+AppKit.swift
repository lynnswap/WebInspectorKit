#if canImport(AppKit)
import AppKit

extension WIDOMStore {
    package func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?) {
        withFrontendBridge { frontendBridge in
            frontendBridge.setDOMContextMenuProvider(provider)
        }
    }
}
#endif
