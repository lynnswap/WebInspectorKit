import Testing
@testable import WebInspectorKit

#if canImport(AppKit)
import AppKit

@MainActor
struct ContainerViewControllerAppKitTabTests {
    @Test
    func loadViewIfNeededDoesNotCrashWhenSelectionCallbackArrivesBeforeTabItemsExist() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WIContainerViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.tabViewItems.count == 2)
        #expect(container.selectedTabViewItemIndex == 0)
        #expect(controller.selectedTabID == "tab_a")
    }

    private func makeDescriptor(id: String, title: String) -> WIPaneDescriptor {
        WIPaneDescriptor(
            id: id,
            title: title,
            systemImage: "circle"
        ) { _ in
            NSViewController()
        }
    }
}
#endif
