#if canImport(AppKit)
import AppKit
import WebKit

@MainActor
public final class WIWindowPresenter: NSObject, NSWindowDelegate {
    public static let shared = WIWindowPresenter()

    private weak var inspectorWindow: NSWindow?

    public override init() {
        super.init()
    }

    public func present(
        parentWindow: NSWindow?,
        inspector controller: WISessionController,
        webView: WKWebView?,
        tabs: [WIPaneDescriptor] = [.dom(), .element(), .network()]
    ) {
        if let inspectorWindow,
           let existingContainer = inspectorWindow.contentViewController as? WIContainerViewController {
            existingContainer.setTabs(tabs)
            existingContainer.setInspectorController(controller)
            existingContainer.setPageWebView(webView)
            inspectorWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        normalizeSelection(controller, tabs: tabs)
        let container = WIContainerViewController(controller, webView: webView, tabs: tabs)
        let window = NSWindow(contentViewController: container)
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

    private func normalizeSelection(_ controller: WISessionController, tabs: [WIPaneDescriptor]) {
        controller.configureTabs(tabs)
        guard let selectedTabID = controller.selectedTabID else {
            controller.selectedTabID = tabs.first?.id
            return
        }
        if tabs.contains(where: { $0.id == selectedTabID }) == false {
            controller.selectedTabID = tabs.first?.id
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }
        if closingWindow === inspectorWindow {
            inspectorWindow = nil
        }
    }
}
#endif
