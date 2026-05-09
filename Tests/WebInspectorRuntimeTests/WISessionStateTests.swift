#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorUI

@MainActor
struct WISessionStateTests {
    @Test
    func defaultSessionUsesDOMAndNetworkTabs() {
        let session = WISession()

        #expect(session.interface.tabs.map(\.id) == [WITab.dom.id, WITab.network.id])
        #expect(session.interface.selectedTab == .dom)
    }

    @Test
    func duplicateTabsAreCoalescedByIdentifier() {
        let replacementDOM = WITab.custom(id: WITab.dom.id, title: "DOM", image: nil) { _ in
            TestViewController()
        }

        let session = WISession(tabs: [.dom, replacementDOM, .network, .network])

        #expect(session.interface.tabs.map(\.id) == [WITab.dom.id, WITab.network.id])
    }

    @Test
    func selectionFollowsTabIdentityAcrossReplacement() {
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectTab(.network)

        let replacementNetwork = WITab.custom(id: WITab.network.id, title: "Network", image: nil) { _ in
            TestViewController()
        }
        session.interface.setTabs([replacementNetwork])

        #expect(session.interface.selectedTab?.id == WITab.network.id)
        #expect(session.interface.selectedItemID == WITab.network.id)
    }

    @Test
    func invalidSelectionFallsBackToFirstTabAfterTabReplacement() {
        let session = WISession(tabs: [.dom, .network])
        session.interface.selectTab(.network)

        let customTab = WITab.custom(id: "custom", title: "Custom", image: nil) { _ in
            TestViewController()
        }
        session.interface.setTabs([customTab])

        #expect(session.interface.selectedTab?.id == "custom")
        #expect(session.interface.selectedItemID == "custom")
    }
}

private final class TestViewController: UIViewController {}
#endif
