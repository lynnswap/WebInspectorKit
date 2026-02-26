import Testing
import WebKit
@testable import WebInspectorKit
@testable import WebInspectorKitCore

@MainActor
struct WISessionControllerStateTests {
    @Test
    func lifecycleTransitionsKeepSelectionOrdering() {
        let controller = WISessionController()
        controller.configureTabs([.dom(), .network()])
        let webView = makeTestWebView()

        controller.selectedTabID = "wi_network"
        controller.connect(to: webView)

        #expect(controller.lifecycle == .active)
        #expect(controller.selectedTabID == "wi_network")

        controller.connect(to: nil)
        #expect(controller.lifecycle == .suspended)
        #expect(controller.selectedTabID == "wi_network")

        controller.disconnect()
        #expect(controller.lifecycle == .disconnected)
        #expect(controller.selectedTabID == nil)
    }

    @Test
    func configureTabsNormalizesInvalidSelectionToFirstTab() {
        let controller = WISessionController()
        let customA = WITabDescriptor(
            id: "a",
            title: "A",
            systemImage: "a.circle"
        ) { _ in
            #if canImport(UIKit)
            UIViewController()
            #elseif canImport(AppKit)
            NSViewController()
            #endif
        }
        let customB = WITabDescriptor(
            id: "b",
            title: "B",
            systemImage: "b.circle"
        ) { _ in
            #if canImport(UIKit)
            UIViewController()
            #elseif canImport(AppKit)
            NSViewController()
            #endif
        }

        controller.selectedTabID = "missing"
        controller.configureTabs([customA, customB])

        #expect(controller.selectedTabID == "a")
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }
}
