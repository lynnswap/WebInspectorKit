#if canImport(UIKit)
import WebInspectorUIBase
import Foundation
import WebInspectorDataKit

extension NetworkDetailViewController {
    @MainActor
    package enum Mode: CaseIterable, Hashable {
        case preview
        case headers
        case security

        nonisolated package static var allCases: [NetworkDetailViewController.Mode] {
            [.headers, .preview, .security]
        }

        package var title: String {
            switch self {
            case .preview:
                String(localized: "network.detail.mode.preview", defaultValue: "Preview", bundle: WebInspectorUILocalization.bundle)
            case .headers:
                String(localized: "network.section.headers", defaultValue: "Headers", bundle: WebInspectorUILocalization.bundle)
            case .security:
                String(
                    localized: "network.detail.mode.security",
                    defaultValue: "Security",
                    bundle: WebInspectorUILocalization.bundle
                )
            }
        }
    }
}
#endif
