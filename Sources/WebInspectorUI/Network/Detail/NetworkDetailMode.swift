#if canImport(UIKit)
import WebInspectorCore
import UIKit

@MainActor
package enum NetworkDetailMode: CaseIterable, Hashable {
    case overview
    case requestBody
    case responseBody

    package var title: String {
        switch self {
        case .overview:
            String(localized: "network.detail.section.overview", bundle: .module)
        case .requestBody:
            String(localized: "network.section.body.request", bundle: .module)
        case .responseBody:
            String(localized: "network.section.body.response", bundle: .module)
        }
    }

    package var systemImageName: String {
        switch self {
        case .overview:
            "list.bullet.rectangle"
        case .requestBody:
            "arrow.up.doc"
        case .responseBody:
            "arrow.down.doc"
        }
    }

    package var bodyRole: NetworkBodyRole? {
        switch self {
        case .overview:
            nil
        case .requestBody:
            .request
        case .responseBody:
            .response
        }
    }
}
#endif
