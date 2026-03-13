import SwiftUI
import WebInspectorKit
import OSLog

struct ContentView: View {
    private struct AutoInspectorPresentationTrigger: Equatable {
        let navigationCount: Int
        let hasWindowScene: Bool
    }

    @Environment(\.windowScene) private var windowScene
    @State private var model: BrowserViewModel?
    @State private var sessionController: WISessionController?
    @State private var didAutoPresentInspector = false
    @State private var didAutoStartSelection = false

    private let logger = Logger(subsystem: "MiniBrowser", category: "ContentView")
    
    var body: some View {
        if let model, let sessionController {
            NavigationStack {
                inspectorContent(model: model, sessionController: sessionController)
            }
        } else {
            Color.clear
                .onAppear {
                    model = BrowserViewModel(url: initialBrowserURL())
                    sessionController = WISessionController()
                }
        }
    }

    @ViewBuilder
    private func inspectorContent(model: BrowserViewModel, sessionController: WISessionController) -> some View {
        ContentWebView(model: model)
            .task(
                id: AutoInspectorPresentationTrigger(
                    navigationCount: model.didFinishNavigationCount,
                    hasWindowScene: windowScene != nil
                )
            ) {
                maybeAutoPresentInspector(
                    windowScene: windowScene,
                    model: model,
                    sessionController: sessionController
                )
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        _ = presentWebInspector(
                            windowScene: windowScene,
                            model: model,
                            sessionController: sessionController
                        )
                    } label: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("MiniBrowser.openInspectorButton")
                }
            }
            .overlay(alignment: .bottomLeading) {
                if ProcessInfo.processInfo.environment["MINIBROWSER_UI_TEST_DIAGNOSTICS"] == "1" {
                    MiniBrowserTestDiagnosticsView(model: model)
                        .padding(12)
                }
            }
    }

    private func initialBrowserURL() -> URL {
        let environment = ProcessInfo.processInfo.environment

        if let configuredURLString = environment["MINIBROWSER_INITIAL_URL"],
           let configuredURL = URL(string: configuredURLString) {
            return configuredURL
        }

        if environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil,
           let blankURL = URL(string: "about:blank") {
            return blankURL
        }

        return URL(string: "https://www.google.com")!
    }

    @MainActor
    private func maybeAutoPresentInspector(
        windowScene: WindowScene?,
        model: BrowserViewModel,
        sessionController: WISessionController
    ) {
        guard !didAutoPresentInspector else {
            return
        }

        let environment = ProcessInfo.processInfo.environment
        guard environment["MINIBROWSER_AUTO_OPEN_INSPECTOR"] == "1" else {
            return
        }
        guard model.didFinishNavigationCount > 0 else {
            return
        }

        let didPresent = presentWebInspector(
            windowScene: windowScene,
            model: model,
            sessionController: sessionController,
            tabs: autoInspectorTabs(from: environment)
        )
        didAutoPresentInspector = didPresent
        maybeAutoStartSelectionIfNeeded(
            didPresent: didPresent,
            sessionController: sessionController,
            environment: environment
        )
    }

    private func autoInspectorTabs(from environment: [String: String]) -> [WITab] {
        guard let rawValue = environment["MINIBROWSER_AUTO_OPEN_INSPECTOR_TABS"] else {
            return [.dom(), .network()]
        }

        let requested = rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        var tabs: [WITab] = []
        for entry in requested {
            switch entry {
            case "dom":
                tabs.append(.dom())
            case "network":
                tabs.append(.network())
            default:
                continue
            }
        }

        return tabs.isEmpty ? [.dom(), .network()] : tabs
    }

    @MainActor
    private func maybeAutoStartSelectionIfNeeded(
        didPresent: Bool,
        sessionController: WISessionController,
        environment: [String: String]
    ) {
        guard didPresent else {
            return
        }
        guard didAutoStartSelection == false else {
            return
        }
        guard environment["MINIBROWSER_AUTO_START_DOM_SELECTION"] == "1" else {
            return
        }
        didAutoStartSelection = true

        Task { @MainActor in
            logger.notice("auto-starting DOM selection mode for diagnostics")
            for _ in 0..<100 {
                if sessionController.domStore.hasPageWebView {
                    sessionController.domStore.toggleSelectionMode()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            logger.error("auto-starting DOM selection mode timed out before page web view became available")
            didAutoStartSelection = false
        }
    }
}

#Preview {
    ContentView()
}
