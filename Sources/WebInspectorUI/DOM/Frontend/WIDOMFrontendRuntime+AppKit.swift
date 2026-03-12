#if canImport(AppKit)
import AppKit

extension WIDOMFrontendRuntime {
    package func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?) {
        webView?.domContextMenuProvider = provider
    }
}
#endif
