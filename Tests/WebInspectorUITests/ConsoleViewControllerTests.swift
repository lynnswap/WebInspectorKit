import Testing
import WebKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct ConsoleViewControllerTests {
    @Test
    func defaultTabConfigurationStaysDOMAndNetwork() {
        let inspector = WIInspectorController()
        _ = WITabViewController(inspector, webView: nil)

        #expect(inspector.tabs.map(\.identifier) == [WITab.domTabID, WITab.networkTabID])
    }

#if canImport(UIKit)
    @Test
    func consoleTabCreatesConsoleViewControllerInUIKitHost() throws {
        let inspector = WIInspectorController()
        let controller = WITabViewController(inspector, webView: nil, tabs: [.console()])
        controller.horizontalSizeClassOverrideForTesting = .regular
        controller.loadViewIfNeeded()

        let host = try #require(controller.activeHostViewControllerForTesting as? WIRegularTabHostViewController)
        #expect(host.displayedRootViewControllerForTesting is WIConsoleViewController)
    }
#endif

#if canImport(AppKit)
    @Test
    func consoleTabCreatesConsoleViewControllerInAppKitHost() throws {
        let inspector = WIInspectorController()
        let controller = WITabViewController(inspector, webView: nil, tabs: [.console()])
        controller.loadViewIfNeeded()

        #expect(controller.visibleContentViewControllerForTesting is WIConsoleViewController)
    }

    @Test
    func appKitConsoleTableGetsInitialWidth() {
        let backend = PreviewConsoleBackend(
            support: WIBackendSupport(
                availability: .supported,
                backendKind: .nativeInspectorMacOS,
                capabilities: [.consoleDomain]
            )
        )
        let viewController = WIConsoleViewController(inspector: makeConsoleModel(backend: backend))
        viewController.loadViewIfNeeded()

        #expect(appKitTableWidth(for: viewController) > 0)
    }
#endif

    @Test
    func unavailableStateIsVisible() async {
        let backend = PreviewConsoleBackend(
            support: WIBackendSupport(
                availability: .unsupported,
                backendKind: .unsupported,
                failureReason: "Console unavailable for testing."
            )
        )
        let viewController = WIConsoleViewController(inspector: makeConsoleModel(backend: backend))
        viewController.loadViewIfNeeded()
        await drainMainQueue()

        #expect(emptyStateText(for: viewController).contains("Console unavailable"))
    }

    @Test
    func clearUpdatesDisplayedRows() async {
        let backend = PreviewConsoleBackend(
            support: WIBackendSupport(
                availability: .supported,
                backendKind: .nativeInspectorMacOS,
                capabilities: [.consoleDomain]
            )
        )
        backend.store.append(
            WIConsoleEntry(
                kind: .message,
                source: .javascript,
                level: .log,
                type: .log,
                text: "before clear",
                renderedText: "before clear"
            )
        )
        let model = makeConsoleModel(backend: backend)
        let viewController = WIConsoleViewController(inspector: model)
        viewController.loadViewIfNeeded()
        await drainMainQueue()

        #expect(rowCount(for: viewController) == 1)

        await model.clear()
        await drainMainQueue()

        #expect(rowCount(for: viewController) == 0)
    }

    #if canImport(UIKit)
    @Test
    func repeatCountUpdatesReconfigureVisibleUIKitRow() async {
        let backend = PreviewConsoleBackend(
            support: WIBackendSupport(
                availability: .supported,
                backendKind: .nativeInspectorIOS,
                capabilities: [.consoleDomain]
            )
        )
        let entry = WIConsoleEntry(
            kind: .message,
            source: .javascript,
            level: .log,
            type: .log,
            text: "repeat me",
            renderedText: "repeat me"
        )
        backend.store.append(entry)

        let viewController = WIConsoleViewController(inspector: makeConsoleModel(backend: backend))
        viewController.loadViewIfNeeded()
        await drainMainQueue()

        #expect(firstRowAccessoryCount(for: viewController) == 0)

        backend.store.updateRepeatCount(forLastEntry: 3, timestamp: nil)
        await drainMainQueue()

        #expect(firstRowAccessoryCount(for: viewController) == 1)
    }
    #endif
}

@MainActor
private extension ConsoleViewControllerTests {
    func makeConsoleModel(backend: any WIConsoleBackend) -> WIConsoleModel {
        WIConsoleModel(
            session: ConsoleSession(
                runtime: WIConsoleRuntime(backend: backend)
            )
        )
    }

    func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    func emptyStateText(for viewController: WIConsoleViewController) -> String {
#if canImport(UIKit)
        viewController.emptyStateTextForTesting ?? ""
#else
        viewController.emptyStateTextForTesting
#endif
    }

    func rowCount(for viewController: WIConsoleViewController) -> Int {
        viewController.rowCountForTesting
    }

    func firstRowAccessoryCount(for viewController: WIConsoleViewController) -> Int {
#if canImport(UIKit)
        viewController.firstRowAccessoryCountForTesting
#else
        0
#endif
    }

    func appKitTableWidth(for viewController: WIConsoleViewController) -> CGFloat {
#if canImport(AppKit)
        viewController.tableViewWidthForTesting
#else
        0
#endif
    }
}

@MainActor
private final class PreviewConsoleBackend: WIConsoleBackend {
    weak var webView: WKWebView?
    let store = ConsoleStore()
    let support: WIBackendSupport

    init(support: WIBackendSupport) {
        self.support = support
    }

    func attachPageWebView(_ newWebView: WKWebView?) async {
        webView = newWebView
    }

    func detachPageWebView(clearsStoreOnNextAttach: Bool) async {
        webView = nil
        _ = clearsStoreOnNextAttach
    }

    func clearConsole() async {
        store.clear(reason: .frontend)
    }

    func evaluate(_ expression: String) async {
        store.append(
            WIConsoleEntry(
                kind: .command,
                source: .other,
                level: .log,
                type: .command,
                text: expression,
                renderedText: expression
            )
        )
    }

    func tearDownForDeinit() {
        webView = nil
        store.reset()
    }
}
