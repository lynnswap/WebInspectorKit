#if canImport(UIKit)
import UIKit

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
