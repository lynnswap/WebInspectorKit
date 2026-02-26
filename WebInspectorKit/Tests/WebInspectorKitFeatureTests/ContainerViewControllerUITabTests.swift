import Testing
import WebKit
@testable import WebInspectorKit
@testable import WebInspectorKitCore

#if canImport(UIKit)
import UIKit

@MainActor
struct ContainerViewControllerUITabTests {
    @Test
    func compactLayoutAutoInsertsElementTabWhenOnlyDOMAndNetworkRequested() {
        let resolved = WIUIKitTabLayoutPolicy.resolveTabs(
            from: [.dom(), .network()],
            horizontalSizeClass: .compact
        )

        #expect(resolved.map(\.id) == ["wi_dom", "wi_element", "wi_network"])
    }

    @Test
    func regularLayoutRemovesElementTabEvenWhenExplicitlyRequested() {
        let resolved = WIUIKitTabLayoutPolicy.resolveTabs(
            from: [.dom(), .element(), .network()],
            horizontalSizeClass: .regular
        )

        #expect(resolved.map(\.id) == ["wi_dom", "wi_network"])
    }

    @Test
    func unspecifiedLayoutAlsoRemovesElementTab() {
        let resolved = WIUIKitTabLayoutPolicy.resolveTabs(
            from: [.dom(), .element(), .network()],
            horizontalSizeClass: .unspecified
        )

        #expect(resolved.map(\.id) == ["wi_dom", "wi_network"])
    }

    @Test
    func regularLayoutRemovesElementWhenNoDOMTabExists() {
        let resolved = WIUIKitTabLayoutPolicy.resolveTabs(
            from: [.element()],
            horizontalSizeClass: .regular
        )

        #expect(resolved.map(\.id).isEmpty)
    }

    @Test
    func normalizedSelectedTabMovesElementSelectionToDOMWhenElementDisappears() {
        let normalized = WIUIKitTabLayoutPolicy.normalizedSelectedTabID(
            currentSelectedTabID: "wi_element",
            resolvedTabs: [.dom(), .network()]
        )

        #expect(normalized == "wi_dom")
    }

    @Test
    func containerUsesCompactHostWhenSizeClassIsCompact() {
        let controller = WISessionController()
        let container = WIContainerViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])

        #expect(container.activeHostKindForTesting == "compact")
        #expect(container.activeHostViewControllerForTesting is WICompactTabHostViewController)
        #expect(container.resolvedTabIDsForTesting == ["wi_dom", "wi_element", "wi_network"])
    }

    @Test
    func containerSwitchesHostWhenSizeClassChanges() {
        let controller = WISessionController()
        let container = WIContainerViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])

        configureSizeClass(.regular, for: container, requestedTabs: [.dom(), .network()])

        #expect(container.activeHostKindForTesting == "regular")
        #expect(container.activeHostViewControllerForTesting is WIRegularTabHostViewController)
        #expect(container.activeHostViewControllerForTesting is UINavigationController)
        #expect(container.resolvedTabIDsForTesting == ["wi_dom", "wi_network"])
    }

    @Test
    func regularHostHidesElementTabEvenWhenExplicitlyRequested() {
        let controller = WISessionController()
        let custom = makeDescriptor(id: "custom", title: "Custom")
        let container = WIContainerViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .element(), custom, .network()]
        )

        container.loadViewIfNeeded()
        configureSizeClass(.regular, for: container, requestedTabs: [.dom(), .element(), custom, .network()])

        #expect(container.resolvedTabIDsForTesting == ["wi_dom", "custom", "wi_network"])

        guard let regularHost = container.activeHostViewControllerForTesting as? WIRegularTabHostViewController else {
            Issue.record("Expected regular host")
            return
        }

        #expect(regularHost.displayedTabIDsForTesting == ["wi_dom", "custom", "wi_network"])
    }

    @Test
    func regularHostNormalizesNilSelectionToFirstTabAndNotifiesController() {
        let controller = WISessionController()
        let host = WIRegularTabHostViewController()
        var notifiedTabIDs: [WITabDescriptor.ID] = []
        host.onSelectedTabIDChange = { tabID in
            notifiedTabIDs.append(tabID)
        }

        host.loadViewIfNeeded()
        host.setTabDescriptors(
            [.dom(), .network()],
            context: WITabContext(controller: controller, horizontalSizeClass: .regular)
        )

        host.setSelectedTabID("wi_network")
        host.setSelectedTabID(nil)

        #expect(notifiedTabIDs.last == "wi_dom")
    }

    @Test
    func compactToRegularNormalizesElementSelectionToDOM() {
        let controller = WISessionController()
        controller.selectedTabID = "wi_element"

        let container = WIContainerViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )
        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])
        controller.selectedTabID = "wi_element"
        #expect(controller.selectedTabID == "wi_element")

        configureSizeClass(.regular, for: container, requestedTabs: [.dom(), .network()])

        #expect(controller.selectedTabID == "wi_dom")
        #expect(container.resolvedTabIDsForTesting == ["wi_dom", "wi_network"])
    }

    @Test
    func compactHostCreatesUniqueUITabIdentifiersForDuplicateDescriptors() {
        let controller = WISessionController()
        let descriptors = [
            makeDescriptor(id: "duplicate", title: "First"),
            makeDescriptor(id: "duplicate", title: "Second")
        ]
        let container = WIContainerViewController(
            controller,
            webView: nil,
            tabs: descriptors
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: descriptors)

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }

        let identifiers = compactHost.displayedTabIdentifiersForTesting
        #expect(identifiers.count == 2)
        #expect(Set(identifiers).count == 2)

        guard
            let firstIdentifier = identifiers.first,
            let secondTab = compactHost.tabs.last
        else {
            Issue.record("Expected two tabs")
            return
        }

        compactHost.selectedTab = secondTab
        controller.selectedTabID = "duplicate"

        #expect(compactHost.selectedTab?.identifier == firstIdentifier)
    }

    @Test
    func compactHostSelectionUpdatesControllerSelectionWhenConnected() {
        let controller = WISessionController()
        let container = WIContainerViewController(
            controller,
            webView: makeTestWebView(),
            tabs: [.dom(), .network()]
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])
        container.viewWillAppear(false)

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }

        guard
            let domTab = compactHost.tabs.first(where: { $0.identifier == "wi_dom" }),
            let networkTab = compactHost.tabs.first(where: { $0.identifier == "wi_network" })
        else {
            Issue.record("Expected DOM and Network tabs")
            return
        }

        compactHost.selectedTab = networkTab
        compactHost.tabBarController(compactHost, didSelectTab: networkTab, previousTab: domTab)

        #expect(controller.selectedTabID == "wi_network")
    }

    @Test
    func compactHostWrapsTabsInNavigationController() {
        let controller = WISessionController()
        let container = WIContainerViewController(
            controller,
            webView: nil,
            tabs: [.dom(), .network()]
        )

        container.loadViewIfNeeded()
        configureSizeClass(.compact, for: container, requestedTabs: [.dom(), .network()])

        guard let compactHost = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }

        #expect(compactHost.allTabRootsAreNavigationControllersForTesting)
        #expect(compactHost.networkTabRootIsNavigationControllerForTesting)
    }

    @Test
    func domDescriptorReturnsDOMTreeControllerInCompactSizeClass() {
        let controller = WISessionController()
        let descriptor = WITabDescriptor.dom()
        let viewController = descriptor.makeViewController(
            context: WITabContext(
                controller: controller,
                horizontalSizeClass: .compact
            )
        )

        #expect(viewController is DOMTreeTabViewController)
    }

    @Test
    func domDescriptorReturnsSplitControllerInRegularSizeClass() {
        let controller = WISessionController()
        let descriptor = WITabDescriptor.dom()
        let viewController = descriptor.makeViewController(
            context: WITabContext(
                controller: controller,
                horizontalSizeClass: .regular
            )
        )

        #expect(viewController is DOMInspectorTabViewController)
    }

    @Test
    func domDescriptorReturnsSplitControllerWhenSizeClassIsUnspecified() {
        let controller = WISessionController()
        let descriptor = WITabDescriptor.dom()
        let viewController = descriptor.makeViewController(
            context: WITabContext(controller: controller)
        )

        #expect(viewController is DOMInspectorTabViewController)
    }

    @Test
    func networkDescriptorReturnsCompactControllerInCompactSizeClass() {
        let controller = WISessionController()
        let descriptor = WITabDescriptor.network()
        let viewController = descriptor.makeViewController(
            context: WITabContext(
                controller: controller,
                horizontalSizeClass: .compact
            )
        )

        #expect(viewController is NetworkCompactTabViewController)
    }

    @Test
    func networkDescriptorReturnsSplitControllerInRegularSizeClass() {
        let controller = WISessionController()
        let descriptor = WITabDescriptor.network()
        let viewController = descriptor.makeViewController(
            context: WITabContext(
                controller: controller,
                horizontalSizeClass: .regular
            )
        )

        #expect(viewController is NetworkTabViewController)
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

    private func configureSizeClass(
        _ sizeClass: UIUserInterfaceSizeClass,
        for container: WIContainerViewController,
        requestedTabs: [WITabDescriptor]
    ) {
        container.horizontalSizeClassOverrideForTesting = sizeClass
        container.setTabs(requestedTabs)
    }
}
#endif
