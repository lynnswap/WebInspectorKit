import SwiftUI
import WebInspectorKit

#if canImport(UIKit)
import UIKit

@MainActor
func presentWebInspector(
    windowScene: WindowScene?,
    model: BrowserViewModel,
    inspectorController: WebInspector.Controller
) {
    guard let presenter = resolvePresenter(from: windowScene) else {
        return
    }

    if let existing = findInspectorSheetController(from: presenter) {
        existing.update(model: model, inspectorController: inspectorController)
        return
    }

    let controller = InspectorSheetController(
        model: model,
        inspectorController: inspectorController
    )
    presenter.present(controller, animated: true)
}

@MainActor
private func findInspectorSheetController(from presenter: UIViewController) -> InspectorSheetController? {
    if let sheetController = findInspectorSheetControllerInPresentingChain(from: presenter) {
        return sheetController
    }
    return findInspectorSheetControllerInPresentedChain(from: presenter)
}

@MainActor
private func findInspectorSheetControllerInPresentingChain(
    from presenter: UIViewController
) -> InspectorSheetController? {
    var cursor: UIViewController? = presenter
    while let current = cursor {
        if let sheetController = current as? InspectorSheetController {
            return sheetController
        }
        cursor = current.presentingViewController
    }
    return nil
}

@MainActor
private func findInspectorSheetControllerInPresentedChain(
    from presenter: UIViewController
) -> InspectorSheetController? {
    var cursor: UIViewController? = presenter
    while let current = cursor {
        if let sheetController = current as? InspectorSheetController {
            return sheetController
        }
        cursor = current.presentedViewController
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

@MainActor
private final class InspectorSheetController: UIHostingController<InspectorSheetView> {
    init(model: BrowserViewModel, inspectorController: WebInspector.Controller) {
        super.init(rootView: InspectorSheetView(model: model, inspectorController: inspectorController))
        modalPresentationStyle = .pageSheet
        view.backgroundColor = .clear
        applyDetents(animated: false)
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(model: BrowserViewModel, inspectorController: WebInspector.Controller) {
        rootView = InspectorSheetView(model: model, inspectorController: inspectorController)
        applyDetents(animated: true)
    }

    private func applyDetents(animated: Bool) {
        guard let sheet = sheetPresentationController else {
            return
        }
        let changes = {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.largestUndimmedDetentIdentifier = .large
        }
        if animated {
            sheet.animateChanges(changes)
        } else {
            changes()
        }
    }
}

#elseif canImport(AppKit)
import AppKit

@MainActor
func presentWebInspector(
    windowScene: WindowScene?,
    model: BrowserViewModel,
    inspectorController: WebInspector.Controller
) {
    WebInspectorWindowCoordinator.shared.present(
        parentWindow: windowScene,
        model: model,
        inspectorController: inspectorController
    )
}

@MainActor
private final class WebInspectorWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = WebInspectorWindowCoordinator()
    private weak var inspectorWindow: NSWindow?

    func present(
        parentWindow: NSWindow?,
        model: BrowserViewModel,
        inspectorController: WebInspector.Controller
    ) {
        if let inspectorWindow {
            updateContent(
                for: inspectorWindow,
                model: model,
                inspectorController: inspectorController
            )
            inspectorWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(
            rootView: InspectorSheetView(model: model, inspectorController: inspectorController)
        )
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Web Inspector"
        window.setContentSize(NSSize(width: 960, height: 720))
        window.minSize = NSSize(width: 640, height: 480)
        window.delegate = self

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

        inspectorWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }
        if closingWindow === inspectorWindow {
            inspectorWindow = nil
        }
    }

    private func updateContent(
        for window: NSWindow,
        model: BrowserViewModel,
        inspectorController: WebInspector.Controller
    ) {
        if let host = window.contentViewController as? NSHostingController<InspectorSheetView> {
            host.rootView = InspectorSheetView(model: model, inspectorController: inspectorController)
            return
        }
        window.contentViewController = NSHostingController(
            rootView: InspectorSheetView(model: model, inspectorController: inspectorController)
        )
    }
}
#endif
