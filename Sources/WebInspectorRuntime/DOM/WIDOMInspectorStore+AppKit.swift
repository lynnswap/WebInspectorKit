#if canImport(AppKit)
import AppKit

extension WIDOMInspectorStore {
    package func setDOMContextMenuProvider(_ provider: ((Int?) -> NSMenu?)?) {
        withFrontendStore { frontendStore in
            frontendStore.setDOMContextMenuProvider(provider)
        }
    }
}
#endif
