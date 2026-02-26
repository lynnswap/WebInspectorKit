import WebInspectorKit

#if canImport(UIKit)
import UIKit

@MainActor
func presentWebInspector(
    windowScene: WindowScene?,
    model: BrowserViewModel,
    inspectorController: WISession
) {
    guard let presenter = resolvePresenter(from: windowScene) else {
        return
    }

    if let existing = findPresentedContainer(from: presenter) {
        existing.setTabs([.dom(), .network()])
        existing.setInspectorController(inspectorController)
        existing.setPageWebView(model.webView)
        return
    }

    let container = WITabViewController(
        inspectorController,
        webView: model.webView,
        tabs: [.dom(), .network()]
    )
    container.modalPresentationStyle = .pageSheet
    applyDefaultDetents(to: container)
    presenter.present(container, animated: true)
}

@MainActor
private func findPresentedContainer(from presenter: UIViewController) -> WITabViewController? {
    if let direct = presenter.presentedViewController.flatMap(inspectorContainer(in:)) {
        return direct
    }

    var cursor: UIViewController? = presenter
    while let current = cursor {
        if let container = inspectorContainer(in: current) {
            return container
        }
        cursor = current.presentedViewController
    }

    cursor = presenter
    while let current = cursor {
        if let container = inspectorContainer(in: current) {
            return container
        }
        cursor = current.presentingViewController
    }

    return nil
}

@MainActor
private func inspectorContainer(in viewController: UIViewController) -> WITabViewController? {
    if let container = viewController as? WITabViewController {
        return container
    }
    if let navigationController = viewController as? UINavigationController {
        for child in navigationController.viewControllers {
            if let container = inspectorContainer(in: child) {
                return container
            }
        }
    }
    if let tabController = viewController as? UITabBarController,
       let selected = tabController.selectedViewController {
        return inspectorContainer(in: selected)
    }
    if let splitController = viewController as? UISplitViewController {
        for child in splitController.viewControllers {
            if let container = inspectorContainer(in: child) {
                return container
            }
        }
    }
    return nil
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
private func applyDefaultDetents(to controller: UIViewController) {
    guard let sheet = controller.sheetPresentationController else {
        return
    }
    sheet.detents = [.medium(), .large()]
    sheet.selectedDetentIdentifier = .medium
    sheet.prefersGrabberVisible = false
    sheet.prefersScrollingExpandsWhenScrolledToEdge = false
    sheet.largestUndimmedDetentIdentifier = .large
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
private final class InspectorWindowStore {
    weak var window: NSWindow?
}

@MainActor
private let inspectorWindowStore = InspectorWindowStore()

@MainActor
func presentWebInspector(
    windowScene: WindowScene?,
    model: BrowserViewModel,
    inspectorController: WISession
) {
    if let existingWindow = inspectorWindowStore.window,
       let existingContainer = existingWindow.contentViewController as? WITabViewController {
        existingContainer.setTabs([.dom(), .network()])
        existingContainer.setInspectorController(inspectorController)
        existingContainer.setPageWebView(model.webView)
        existingWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }

    let container = WITabViewController(
        inspectorController,
        webView: model.webView,
        tabs: [.dom(), .network()]
    )
    let window = NSWindow(contentViewController: container)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .docModalWindow]
    window.title = "Web Inspector"
    window.setContentSize(NSSize(width: 960, height: 720))
    window.minSize = NSSize(width: 640, height: 480)

    if let parentWindow = windowScene {
        let parentFrame = parentWindow.frame
        let origin = NSPoint(
            x: parentFrame.midX - (window.frame.width / 2),
            y: parentFrame.midY - (window.frame.height / 2)
        )
        window.setFrameOrigin(origin)
    } else {
        window.center()
    }

    inspectorWindowStore.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}
#endif
