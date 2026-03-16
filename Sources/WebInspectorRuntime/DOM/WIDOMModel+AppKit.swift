#if canImport(AppKit)
import AppKit

extension WIDOMModel {
    package func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?) {
        withFrontendStore { frontendStore in
            frontendStore.setDOMContextMenuProvider(provider)
        }
    }

    func copyToSystemPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
#endif
