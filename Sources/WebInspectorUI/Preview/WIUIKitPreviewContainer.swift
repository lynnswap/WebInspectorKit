#if DEBUG && canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import UIKit

@MainActor
struct WIUIKitPreviewContainer: UIViewControllerRepresentable {
    let builder: () -> UIViewController

    func makeUIViewController(context: Context) -> UIViewController {
        builder()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
#endif
