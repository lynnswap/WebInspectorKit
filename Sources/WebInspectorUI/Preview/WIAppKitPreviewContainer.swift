#if DEBUG && canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI

@MainActor
struct WIAppKitPreviewContainer: NSViewControllerRepresentable {
    let builder: () -> NSViewController

    func makeNSViewController(context: Context) -> NSViewController {
        builder()
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}
#endif
