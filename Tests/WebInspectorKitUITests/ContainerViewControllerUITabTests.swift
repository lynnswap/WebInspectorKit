import Testing
import WebKit
@testable import WebInspectorKit
@testable import WebInspectorKitCore

#if canImport(UIKit)
import UIKit

@MainActor
struct ContainerViewControllerUITabTests {
    @Test
    func rebuildTabsBuildsUITabsFromDescriptors() {
        let controller = WebInspector.Controller()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B"),
            makeDescriptor(id: "tab_c", title: "C")
        ]
        let container = WebInspector.ContainerViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.tabs.count == descriptors.count)
        #expect(container.tabs.map(\.identifier) == ["tab_a", "tab_b", "tab_c"])
    }

    @Test
    func selectedTabMatchesControllerSelection() {
        let controller = WebInspector.Controller()
        controller.selectedTabID = "tab_b"
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WebInspector.ContainerViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.selectedTab?.identifier == "tab_b")
    }

    @Test
    func invalidSelectionFallsBackToCurrentSelectionAndNormalizesController() {
        let controller = WebInspector.Controller()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WebInspector.ContainerViewController(
            controller,
            webView: makeTestWebView(),
            tabs: descriptors
        )

        container.loadViewIfNeeded()
        container.viewWillAppear(false)

        guard
            let first = container.tabs.first,
            let second = container.tabs.last
        else {
            Issue.record("Expected two tabs")
            return
        }

        container.selectedTab = second
        container.tabBarController(container, didSelectTab: second, previousTab: first)
        #expect(controller.selectedTabID == "tab_b")

        controller.selectedTabID = "missing"
        #expect(container.selectedTab?.identifier == "tab_b")
        #expect(controller.selectedTabID == "tab_b")
    }

    @Test
    func didSelectTabDelegateUpdatesControllerSelectionWhenConnected() {
        let controller = WebInspector.Controller()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WebInspector.ContainerViewController(
            controller,
            webView: makeTestWebView(),
            tabs: descriptors
        )

        container.loadViewIfNeeded()
        container.viewWillAppear(false)

        guard
            let first = container.tabs.first,
            let second = container.tabs.last
        else {
            Issue.record("Expected two tabs")
            return
        }

        container.tabBarController(container, didSelectTab: second, previousTab: first)

        #expect(controller.selectedTabID == "tab_b")
    }

    @Test
    func duplicateTabIDsCreateUniqueUITabIdentifiersAndKeepPrimarySelectionMapping() {
        let controller = WebInspector.Controller()
        let descriptors = [
            makeDescriptor(id: "duplicate", title: "First"),
            makeDescriptor(id: "duplicate", title: "Second")
        ]
        let container = WebInspector.ContainerViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.tabs.count == 2)
        let identifiers = container.tabs.map(\.identifier)
        #expect(Set(identifiers).count == 2)

        guard
            let firstIdentifier = identifiers.first,
            let secondTab = container.tabs.last
        else {
            Issue.record("Expected two tabs")
            return
        }

        container.selectedTab = secondTab
        controller.selectedTabID = "duplicate"

        #expect(container.selectedTab?.identifier == firstIdentifier)
    }

    private func makeDescriptor(id: String, title: String) -> WebInspector.TabDescriptor {
        WebInspector.TabDescriptor(
            id: id,
            title: title,
            systemImage: "circle"
        ) { _ in
            UIViewController()
        }
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }
}
#endif
