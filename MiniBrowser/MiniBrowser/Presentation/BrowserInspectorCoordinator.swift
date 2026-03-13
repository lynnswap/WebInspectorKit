import WebInspectorKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class BrowserInspectorCoordinator {
#if canImport(UIKit)
    func present(
        from presenter: UIViewController,
        browserStore: BrowserStore,
        sessionController: WISessionController,
        tabs: [WITab] = [.dom(), .network()]
    ) -> Bool {
        let anchor = resolvePresentationAnchor(from: presenter)

        if let existing = findPresentedContainer(from: anchor) {
            existing.setTabs(tabs)
            existing.setSessionController(sessionController)
            existing.setPageWebView(browserStore.webView)
            return true
        }

        let container = WIContainerViewController(
            sessionController,
            webView: browserStore.webView,
            tabs: tabs
        )
        container.modalPresentationStyle = .pageSheet
        applyDefaultDetents(to: container)
        anchor.present(container, animated: true)
        return true
    }

    private func resolvePresentationAnchor(from presenter: UIViewController) -> UIViewController {
        let baseController = presenter.view.window?.rootViewController ?? presenter.navigationController ?? presenter
        return topViewController(from: baseController) ?? presenter
    }

    private func findPresentedContainer(from presenter: UIViewController) -> WIContainerViewController? {
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

    private func inspectorContainer(in viewController: UIViewController) -> WIContainerViewController? {
        if let container = viewController as? WIContainerViewController {
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
    private final class InspectorWindowStore {
        weak var window: NSWindow?
    }

    private static let inspectorWindowStore = InspectorWindowStore()

    func present(
        from parentWindow: NSWindow?,
        browserStore: BrowserStore,
        sessionController: WISessionController,
        tabs: [WITab] = [.dom(), .network()]
    ) -> Bool {
        if let existingWindow = Self.inspectorWindowStore.window,
           let existingContainer = existingWindow.contentViewController as? WIContainerViewController {
            existingContainer.setTabs(tabs)
            existingContainer.setSessionController(sessionController)
            existingContainer.setPageWebView(browserStore.webView)
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }

        let container = WIContainerViewController(
            sessionController,
            webView: browserStore.webView,
            tabs: tabs
        )
        let window = NSWindow(contentViewController: container)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Web Inspector"
        window.setContentSize(NSSize(width: 960, height: 720))
        window.minSize = NSSize(width: 640, height: 480)

        if let parentWindow {
            let parentFrame = parentWindow.frame
            let origin = NSPoint(
                x: parentFrame.midX - (window.frame.width / 2),
                y: parentFrame.midY - (window.frame.height / 2)
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        Self.inspectorWindowStore.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
#endif
}
