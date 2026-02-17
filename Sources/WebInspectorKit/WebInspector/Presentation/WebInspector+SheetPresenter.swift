#if canImport(UIKit)
import UIKit
import WebKit

extension WebInspector {
    @MainActor
    public final class SheetPresenter {
        public static let shared = SheetPresenter()

        public init() {}

        public func present(
            from presenter: UIViewController,
            inspector controller: Controller,
            webView: WKWebView?,
            tabs: [TabDescriptor] = [.dom(), .element(), .network()]
        ) {
            if let existing = findPresentedContainer(from: presenter) {
                existing.setInspectorController(controller)
                existing.setPageWebView(webView)
                existing.setTabs(tabs)
                return
            }

            let container = ContainerViewController(controller, webView: webView, tabs: tabs)
            container.modalPresentationStyle = .pageSheet
            applyDefaultDetents(to: container)
            presenter.present(container, animated: true)
        }

        private func applyDefaultDetents(to controller: UIViewController) {
            guard let sheet = controller.sheetPresentationController else {
                return
            }
            let changes = {
                sheet.detents = [.medium(), .large()]
                sheet.selectedDetentIdentifier = .medium
                sheet.prefersGrabberVisible = true
                sheet.prefersScrollingExpandsWhenScrolledToEdge = false
                sheet.largestUndimmedDetentIdentifier = .large
            }
            sheet.animateChanges(changes)
        }

        private func findPresentedContainer(from presenter: UIViewController) -> ContainerViewController? {
            if let direct = presenter.presentedViewController as? ContainerViewController {
                return direct
            }

            var cursor: UIViewController? = presenter
            while let current = cursor {
                if let container = current as? ContainerViewController {
                    return container
                }
                cursor = current.presentedViewController
            }

            cursor = presenter
            while let current = cursor {
                if let container = current as? ContainerViewController {
                    return container
                }
                cursor = current.presentingViewController
            }

            return nil
        }
    }
}
#endif
