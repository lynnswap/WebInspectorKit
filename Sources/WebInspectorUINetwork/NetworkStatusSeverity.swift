import WebInspectorUIBase

#if canImport(UIKit)
import UIKit
#endif

extension NetworkDisplay {
    package enum StatusSeverity: Equatable, Sendable {
        case success
        case notice
        case warning
        case error
        case neutral
    }
}

#if canImport(UIKit)
extension NetworkDisplay.StatusSeverity {
    var color: UIColor {
        switch self {
        case .success:
            .systemGreen
        case .notice:
            .systemYellow
        case .warning:
            .systemOrange
        case .error:
            .systemRed
        case .neutral:
            .secondaryLabel
        }
    }
}
#endif
