#if canImport(AppKit)
import AppKit

extension DOMInspectorRuntime {
    func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?) {
        bridge.setDOMContextMenuProvider(provider)
    }
}
#endif
