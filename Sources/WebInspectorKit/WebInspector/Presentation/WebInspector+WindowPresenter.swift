#if canImport(AppKit)
import AppKit
import WebKit

extension WebInspector {
    @MainActor
    public final class WindowPresenter: NSObject, NSWindowDelegate {
        public static let shared = WindowPresenter()

        private weak var inspectorWindow: NSWindow?

        public override init() {
            super.init()
        }

        public func present(
            parentWindow: NSWindow?,
            inspector controller: Controller,
            webView: WKWebView?,
            tabs: [TabDescriptor] = [.dom(), .element(), .network()]
        ) {
            if let inspectorWindow,
               let existingContainer = inspectorWindow.contentViewController as? ContainerViewController {
                existingContainer.setInspectorController(controller)
                existingContainer.setPageWebView(webView)
                existingContainer.setTabs(tabs)
                inspectorWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let container = ContainerViewController(controller, webView: webView, tabs: tabs)
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

        public func windowWillClose(_ notification: Notification) {
            guard let closingWindow = notification.object as? NSWindow else {
                return
            }
            if closingWindow === inspectorWindow {
                inspectorWindow = nil
            }
        }
    }
}
#endif
