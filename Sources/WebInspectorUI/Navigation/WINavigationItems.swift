#if canImport(UIKit)
import UIKit

@MainActor
func wiApplyClearNavigationBarStyle(to navigationController: UINavigationController) {
    navigationController.view.backgroundColor = .clear
    navigationController.navigationBar.isTranslucent = true

    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.backgroundColor = .clear
    appearance.backgroundEffect = nil
    appearance.shadowColor = nil

    navigationController.navigationBar.standardAppearance = appearance
    navigationController.navigationBar.scrollEdgeAppearance = appearance
    navigationController.navigationBar.compactAppearance = appearance
    navigationController.navigationBar.compactScrollEdgeAppearance = appearance
}
#endif
