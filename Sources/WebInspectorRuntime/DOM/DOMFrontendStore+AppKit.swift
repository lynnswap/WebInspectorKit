#if canImport(AppKit)
import AppKit

extension DOMFrontendStore {
    func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?) {
        webView?.domContextMenuProvider = provider
    }
}
#endif
