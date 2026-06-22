import WebInspectorUIBase
import WebInspectorCore

#if canImport(UIKit)
import UIKit
#endif

extension NetworkRequest.Display {
    package enum StatusSeverity: Equatable, Sendable {
        case success
        case notice
        case warning
        case error
        case neutral
    }
}

#if canImport(UIKit)
extension NetworkRequest.Display.StatusSeverity {
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
