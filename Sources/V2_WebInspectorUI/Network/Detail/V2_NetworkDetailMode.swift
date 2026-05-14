#if canImport(UIKit)
import UIKit
import V2_WebInspectorCore

@MainActor
package enum V2_NetworkDetailMode: CaseIterable, Hashable {
    case overview
    case requestBody
    case responseBody

    package var title: String {
        switch self {
        case .overview:
            v2WILocalized("network.detail.section.overview", default: "Overview")
        case .requestBody:
            v2WILocalized("network.section.body.request", default: "Request Body")
        case .responseBody:
            v2WILocalized("network.section.body.response", default: "Response Body")
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
