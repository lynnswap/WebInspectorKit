#if canImport(UIKit)
import UIKit

extension NetworkStatusSeverity {
    var color: UIColor {
        switch self {
        case .success:
            return .systemGreen
        case .notice:
            return .systemYellow
        case .warning:
            return .systemOrange
        case .error:
            return .systemRed
        case .neutral:
            return .secondaryLabel
        }
    }
}
#endif
