#if canImport(UIKit)
import WebInspectorCore

@MainActor
package enum NetworkDetailMode: CaseIterable, Hashable {
    case request
    case response

    package var title: String {
        switch self {
        case .request:
            String(localized: "network.section.request", bundle: .module)
        case .response:
            String(localized: "network.section.response", bundle: .module)
        }
    }

    package var bodyRole: NetworkBodyRole {
        switch self {
        case .request:
            .request
        case .response:
            .response
        }
    }
}
#endif
