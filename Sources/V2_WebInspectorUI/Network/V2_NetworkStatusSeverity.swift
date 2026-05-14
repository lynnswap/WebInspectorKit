#if canImport(UIKit)
import UIKit
#endif

package enum V2_NetworkStatusSeverity: Sendable {
    case success
    case notice
    case warning
    case error
    case neutral
}

#if canImport(UIKit)
extension V2_NetworkStatusSeverity {
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
