#if canImport(UIKit)
import WebInspectorCore

@MainActor
package enum NetworkDetailMode: CaseIterable, Hashable {
    case preview
    case headers

    package var title: String {
        switch self {
        case .preview:
            String(localized: "network.detail.mode.preview", defaultValue: "Preview", bundle: .module)
        case .headers:
            String(localized: "network.section.headers", defaultValue: "Headers", bundle: .module)
        }
    }
}
#endif
