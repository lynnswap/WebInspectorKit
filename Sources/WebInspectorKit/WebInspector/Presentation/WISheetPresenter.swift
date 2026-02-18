#if canImport(UIKit)
import UIKit
import WebKit

@MainActor
public final class WISheetPresenter {
    public static let shared = WISheetPresenter()

    public init() {}

    public func present(
        from presenter: UIViewController,
        inspector controller: WISessionController,
        webView: WKWebView?,
        tabs: [WIPaneDescriptor] = [.dom(), .element(), .network()]
    ) {
        if let existing = findPresentedContainer(from: presenter) {
            existing.setTabs(tabs)
            existing.setInspectorController(controller)
            existing.setPageWebView(webView)
            return
        }

        normalizeSelection(controller, tabs: tabs)
        let container = WIContainerViewController(controller, webView: webView, tabs: tabs)
        container.modalPresentationStyle = .pageSheet
        applyDefaultDetents(to: container)
        presenter.present(container, animated: true)
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

    private func findPresentedContainer(from presenter: UIViewController) -> WIContainerViewController? {
        if let direct = presenter.presentedViewController as? WIContainerViewController {
            return direct
        }

        var cursor: UIViewController? = presenter
        while let current = cursor {
            if let container = current as? WIContainerViewController {
                return container
            }
            cursor = current.presentedViewController
        }

        cursor = presenter
        while let current = cursor {
            if let container = current as? WIContainerViewController {
                return container
            }
            cursor = current.presentingViewController
        }

        return nil
    }
}
#endif
