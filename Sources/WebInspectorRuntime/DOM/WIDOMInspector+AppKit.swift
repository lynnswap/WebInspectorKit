#if canImport(AppKit)
import AppKit
import WebInspectorBridge

extension WIDOMInspector {
    func activatePageWindowForSelectionIfPossible() {
        guard
            let pageWebView,
            let pageWindow = WIAppKitBridge.window(for: pageWebView)
        else {
            return
        }

        pageWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    package func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?) {
        inspectorBridge.setDOMContextMenuProvider(provider)
    }

    func copyToSystemPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
#endif
