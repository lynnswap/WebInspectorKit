#if canImport(UIKit)
import UIKit
#endif

package enum NetworkStatusSeverity: Sendable {
    case success
    case notice
    case warning
    case error
    case neutral
}

#if canImport(UIKit)
extension NetworkStatusSeverity {
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
