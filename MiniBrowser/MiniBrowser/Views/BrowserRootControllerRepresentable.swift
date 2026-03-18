import SwiftUI

#if canImport(UIKit)
import UIKit

struct BrowserRootControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BrowserRootViewController {
        BrowserRootViewController(launchConfiguration: .current())
    }

    func updateUIViewController(_ uiViewController: BrowserRootViewController, context: Context) {}
}
#elseif canImport(AppKit)
import AppKit

struct BrowserRootControllerRepresentable: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> BrowserRootViewController {
        BrowserRootViewController(launchConfiguration: .current())
    }

    func updateNSViewController(_ nsViewController: BrowserRootViewController, context: Context) {}
}
#endif
