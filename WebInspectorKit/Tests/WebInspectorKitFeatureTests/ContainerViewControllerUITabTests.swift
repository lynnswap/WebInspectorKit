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
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B"),
            makeDescriptor(id: "tab_c", title: "C")
        ]
        let container = WIContainerViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.tabs.count == descriptors.count)
        #expect(container.tabs.map(\.identifier) == ["tab_a", "tab_b", "tab_c"])
    }

    @Test
    func selectedTabMatchesControllerSelection() {
        let controller = WISessionController()
        controller.selectedTabID = "tab_b"
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WIContainerViewController(controller, webView: nil, tabs: descriptors)

        container.loadViewIfNeeded()

        #expect(container.selectedTab?.identifier == "tab_b")
    }

    @Test
    func invalidSelectionFallsBackToCurrentSelectionAndNormalizesController() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WIContainerViewController(
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
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ]
        let container = WIContainerViewController(
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
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "duplicate", title: "First"),
            makeDescriptor(id: "duplicate", title: "Second")
        ]
        let container = WIContainerViewController(controller, webView: nil, tabs: descriptors)

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

    @Test
    func selectingNetworkTabDoesNotCrashWhenNetworkTabLoads() {
        let controller = WISessionController()
        let container = WIContainerViewController(
            controller,
            webView: makeTestWebView(),
            tabs: [.dom(), .network()]
        )

        container.loadViewIfNeeded()
        container.viewWillAppear(false)

        guard
            let domTab = container.tabs.first(where: { $0.identifier == "wi_dom" }),
            let networkTab = container.tabs.first(where: { $0.identifier == "wi_network" })
        else {
            Issue.record("Expected DOM and Network tabs")
            return
        }

        container.selectedTab = networkTab
        container.tabBarController(container, didSelectTab: networkTab, previousTab: domTab)

        #expect(container.selectedTab?.identifier == "wi_network")
        #expect(controller.selectedTabID == "wi_network")

        guard let networkController = container.children.first(where: { $0 is NetworkTabViewController }) else {
            Issue.record("Expected network tab view controller")
            return
        }

        networkController.loadViewIfNeeded()
        #expect(networkController is NetworkTabViewController)
    }

    private func makeDescriptor(id: String, title: String) -> WITabDescriptor {
        WITabDescriptor(
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
