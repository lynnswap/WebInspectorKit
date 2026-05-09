#if canImport(UIKit)
import WebInspectorEngine

@MainActor
enum NetworkEntryDetailMode: CaseIterable, Hashable {
    case overview
    case requestBody
    case responseBody

    var title: String {
        switch self {
        case .overview:
            wiLocalized("network.detail.section.overview", default: "Overview")
        case .requestBody:
            wiLocalized("network.section.body.request", default: "Request Body")
        case .responseBody:
            wiLocalized("network.section.body.response", default: "Response Body")
        }
    }

    var systemImageName: String {
        switch self {
        case .overview:
            "list.bullet.rectangle"
        case .requestBody:
            "arrow.up.doc"
        case .responseBody:
            "arrow.down.doc"
        }
    }

    var bodyRole: NetworkBody.Role? {
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
