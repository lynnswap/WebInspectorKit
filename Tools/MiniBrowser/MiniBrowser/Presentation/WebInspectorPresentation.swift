import WebInspectorKit

#if canImport(UIKit)
import UIKit

@MainActor
func presentWebInspector(
    windowScene: WindowScene?,
    model: BrowserViewModel,
    inspectorController: WISessionController
) {
    guard let presenter = resolvePresenter(from: windowScene) else {
        return
    }

    WISheetPresenter.shared.present(
        from: presenter,
        inspector: inspectorController,
        webView: model.webView,
        tabs: [.dom(), .element(), .network()]
    )
}

@MainActor
private func resolvePresenter(from windowScene: UIWindowScene?) -> UIViewController? {
    if let presenter = topViewController(from: bestRootViewController(in: windowScene)) {
        return presenter
    }

    let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
    for scene in scenes {
        if let presenter = topViewController(from: bestRootViewController(in: scene)) {
            return presenter
        }
    }
    return nil
}

@MainActor
private func bestRootViewController(in windowScene: UIWindowScene?) -> UIViewController? {
    guard let windowScene else {
        return nil
    }
    let windows = windowScene.windows
    if let keyWindow = windows.first(where: \.isKeyWindow) {
        return keyWindow.rootViewController
    }
    return windows.first?.rootViewController
}

@MainActor
private func topViewController(from root: UIViewController?) -> UIViewController? {
    guard let root else {
        return nil
    }
    if let presented = root.presentedViewController {
        return topViewController(from: presented)
    }
    if let navigation = root as? UINavigationController {
        return topViewController(from: navigation.visibleViewController)
    }
    if let tab = root as? UITabBarController {
        return topViewController(from: tab.selectedViewController)
    }
    if let split = root as? UISplitViewController {
        return topViewController(from: split.viewControllers.last)
    }
    return root
}

#elseif canImport(AppKit)
import AppKit

@MainActor
func presentWebInspector(
    windowScene: WindowScene?,
    model: BrowserViewModel,
    inspectorController: WISessionController
) {
    WIWindowPresenter.shared.present(
        parentWindow: windowScene,
        inspector: inspectorController,
        webView: model.webView,
        tabs: [.dom(), .element(), .network()]
    )
}
#endif
