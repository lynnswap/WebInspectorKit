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
        let controller = WISessionController()
        let webView = makeTestWebView()

        let first = WITabDescriptor(
            id: "duplicate",
            title: "First",
            systemImage: "1.circle",
            role: .inspector,
            requires: [.network],
            activation: .init(networkLiveLogging: false)
        ) { _ in
            makeDummyController()
        }

        let second = WITabDescriptor(
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
        let controller = WISessionController()

        controller.configureTabs([
            WITabDescriptor(
                id: "tab_a",
                title: "A",
                systemImage: "a.circle"
            ) { _ in
                makeDummyController()
            },
            WITabDescriptor(
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
        let controller = WISessionController()
        controller.configureTabs([
            WITabDescriptor(
                id: "tab_a",
                title: "A",
                systemImage: "a.circle"
            ) { _ in
                makeDummyController()
            },
            WITabDescriptor(
                id: "tab_b",
                title: "B",
                systemImage: "b.circle"
            ) { _ in
                makeDummyController()
            }
        ])
        controller.selectedTabID = "tab_b"

        controller.configureTabs([
            WITabDescriptor(
                id: "tab_c",
                title: "C",
                systemImage: "c.circle"
            ) { _ in
                makeDummyController()
            }
        ])

        #expect(controller.selectedTabID == "tab_c")
    }

    @Test
    func repeatedConfigureTabsNormalizesSelectionAcrossInvalidAndDuplicateIDs() {
        let controller = WISessionController()

        controller.configureTabs([
            makeDescriptor(id: "tab_a", title: "A"),
            makeDescriptor(id: "tab_b", title: "B")
        ])
        controller.selectedTabID = "tab_b"
        #expect(controller.selectedTabID == "tab_b")

        controller.configureTabs([
            makeDescriptor(id: "duplicate", title: "First"),
            makeDescriptor(id: "duplicate", title: "Second"),
            makeDescriptor(id: "tab_c", title: "C")
        ])
        #expect(controller.selectedTabID == "duplicate")

        controller.selectedTabID = "missing"
        controller.configureTabs([
            makeDescriptor(id: "tab_final", title: "Final")
        ])
        #expect(controller.selectedTabID == "tab_final")
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func makeDescriptor(id: String, title: String) -> WITabDescriptor {
        WITabDescriptor(
            id: id,
            title: title,
            systemImage: "circle"
        ) { _ in
            makeDummyController()
        }
    }

    private func makeDummyController() -> WIPlatformViewController {
        #if canImport(UIKit)
        return UIViewController()
        #elseif canImport(AppKit)
        return NSViewController()
        #endif
    }
}
