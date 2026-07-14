#if canImport(UIKit)
import WebInspectorUIBase

@MainActor
package enum NetworkBodyPreviewFactory {
    package static func make(
        scrollEdgeSink: any NetworkBodyScrollEdgeSink
    ) -> NetworkBodyPreviewViewController {
        NetworkBodyViewController(scrollEdgeSink: scrollEdgeSink)
    }
}
#endif
