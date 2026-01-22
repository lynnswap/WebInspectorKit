#if os(iOS)
import Foundation

@_silgen_name("MiniBrowserInstallWebProcessProxyHook")
private func minibrowser_installWebProcessProxyHook()

enum WebProcessProxyHook {
    static func install() {
        minibrowser_installWebProcessProxyHook()
    }
}
#else
enum WebProcessProxyHook {
    static func install() {
    }
}
#endif
