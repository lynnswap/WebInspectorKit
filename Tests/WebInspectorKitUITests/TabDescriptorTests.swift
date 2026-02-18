import Testing
import WebKit
@testable import WebInspectorKit
@testable import WebInspectorKitCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
struct TabDescriptorTests {
    @Test
    func duplicateTabIDsUseLastActivationDefinition() {
        let controller = WebInspector.Controller()
        let webView = makeTestWebView()

        let first = WebInspector.TabDescriptor(
            id: "duplicate",
            title: "First",
            systemImage: "1.circle",
            role: .inspector,
            requires: [.network],
            activation: .init(networkLiveLogging: false)
        ) { _ in
            makeDummyController()
        }

        let second = WebInspector.TabDescriptor(
            id: "duplicate",
            title: "Second",
            systemImage: "2.circle",
            role: .inspector,
            requires: [.network],
            activation: .init(networkLiveLogging: true)
        ) { _ in
            makeDummyController()
        }

        controller.configureTabs([first, second])
        controller.connect(to: webView)
        controller.selectedTabID = "duplicate"

        #expect(controller.network.session.mode == .active)
    }

    @Test
    func configureTabsSetsFirstTabAsSelectedWhenNoSelectionExists() {
        let controller = WebInspector.Controller()

        controller.configureTabs([
            WebInspector.TabDescriptor(
                id: "tab_a",
                title: "A",
                systemImage: "a.circle"
            ) { _ in
                makeDummyController()
            },
            WebInspector.TabDescriptor(
                id: "tab_b",
                title: "B",
                systemImage: "b.circle"
            ) { _ in
                makeDummyController()
            }
        ])

        #expect(controller.selectedTabID == "tab_a")
    }

    @Test
    func configureTabsReplacesInvalidSelectionWithFirstTab() {
        let controller = WebInspector.Controller()
        controller.configureTabs([
            WebInspector.TabDescriptor(
                id: "tab_a",
                title: "A",
                systemImage: "a.circle"
            ) { _ in
                makeDummyController()
            },
            WebInspector.TabDescriptor(
                id: "tab_b",
                title: "B",
                systemImage: "b.circle"
            ) { _ in
                makeDummyController()
            }
        ])
        controller.selectedTabID = "tab_b"

        controller.configureTabs([
            WebInspector.TabDescriptor(
                id: "tab_c",
                title: "C",
                systemImage: "c.circle"
            ) { _ in
                makeDummyController()
            }
        ])

        #expect(controller.selectedTabID == "tab_c")
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func makeDummyController() -> WebInspector.PlatformViewController {
        #if canImport(UIKit)
        return UIViewController()
        #elseif canImport(AppKit)
        return NSViewController()
        #endif
    }
}
