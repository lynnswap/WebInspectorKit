#if canImport(UIKit)
import UIKit
import WebInspectorCore

@MainActor
package enum NetworkDetailMode: CaseIterable, Hashable {
    case overview
    case requestBody
    case responseBody

    package var title: String {
        switch self {
        case .overview:
            webInspectorLocalized("network.detail.section.overview", default: "Overview")
        case .requestBody:
            webInspectorLocalized("network.section.body.request", default: "Request Body")
        case .responseBody:
            webInspectorLocalized("network.section.body.response", default: "Response Body")
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
