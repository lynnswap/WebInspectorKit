import SwiftUI
import WebInspectorKit

struct ContentView: View {
    private struct AutoInspectorPresentationTrigger: Equatable {
        let navigationCount: Int
        let hasWindowScene: Bool
    }

    @Environment(\.windowScene) private var windowScene
    @State private var model: BrowserViewModel?
    @State private var inspectorController: WIModel?
    @State private var didAutoPresentInspector = false
    
    var body: some View {
        if let model, let inspectorController {
            NavigationStack {
                inspectorContent(model: model, inspectorController: inspectorController)
            }
        } else {
            Color.clear
                .onAppear {
                    model = BrowserViewModel(url: initialBrowserURL())
                    inspectorController = WIModel()
                }
        }
    }

    @ViewBuilder
    private func inspectorContent(model: BrowserViewModel, inspectorController: WIModel) -> some View {
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
                    inspectorController: inspectorController
                )
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        _ = presentWebInspector(
                            windowScene: windowScene,
                            model: model,
                            inspectorController: inspectorController
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
        inspectorController: WIModel
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
            inspectorController: inspectorController,
            tabs: autoInspectorTabs(from: environment)
        )
        didAutoPresentInspector = didPresent
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
}

#Preview {
    ContentView()
}
