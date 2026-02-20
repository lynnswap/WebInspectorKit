#if canImport(UIKit)
import UIKit

@inline(__always)
func wiSecondaryActionSymbolName() -> String {
    if #available(iOS 26.0, *) {
        return "ellipsis"
    }
    return "ellipsis.circle"
}

@MainActor
func wiApplyClearNavigationBarStyle(to navigationController: UINavigationController) {
    navigationController.view.backgroundColor = .clear
    navigationController.navigationBar.isTranslucent = true

    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.backgroundColor = .clear
    appearance.backgroundEffect = nil
    appearance.shadowColor = .clear

    navigationController.navigationBar.standardAppearance = appearance
    navigationController.navigationBar.scrollEdgeAppearance = appearance
    navigationController.navigationBar.compactAppearance = appearance
    navigationController.navigationBar.compactScrollEdgeAppearance = appearance
}
#endif
