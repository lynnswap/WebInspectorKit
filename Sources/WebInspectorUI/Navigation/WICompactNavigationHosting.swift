#if canImport(UIKit)
import UIKit

@MainActor
protocol WICompactNavigationHosting where Self: UIViewController {
    var providesCompactNavigationController: Bool { get }
}
#endif
