#if canImport(UIKit)
import Foundation
import WebInspectorCore

extension NetworkDetailViewController {
    @MainActor
    package enum Mode: CaseIterable, Hashable {        case preview
        case headers

        nonisolated package static var allCases: [NetworkDetailViewController.Mode] {
            [.headers, .preview]
        }

        package var title: String {
            switch self {
            case .preview:
                String(localized: "network.detail.mode.preview", defaultValue: "Preview", bundle: .module)
            case .headers:
                String(localized: "network.section.headers", defaultValue: "Headers", bundle: .module)
            }
        }
    }
}
#endif
