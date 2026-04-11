import Foundation
import WebInspectorKit

struct BrowserLaunchConfiguration {
    static let defaultInspectorTabs: [WITab] = [.dom(), .network(), .console()]

    let initialURL: URL
    let autoOpenInspectorTabs: [WITab]
    let shouldAutoOpenInspector: Bool
    let shouldAutoStartDOMSelection: Bool
    let shouldShowDiagnostics: Bool

    init(
        initialURL: URL,
        autoOpenInspectorTabs: [WITab] = BrowserLaunchConfiguration.defaultInspectorTabs,
        shouldAutoOpenInspector: Bool = false,
        shouldAutoStartDOMSelection: Bool = false,
        shouldShowDiagnostics: Bool = false
    ) {
        self.initialURL = initialURL
        self.autoOpenInspectorTabs = autoOpenInspectorTabs
        self.shouldAutoOpenInspector = shouldAutoOpenInspector
        self.shouldAutoStartDOMSelection = shouldAutoStartDOMSelection
        self.shouldShowDiagnostics = shouldShowDiagnostics
    }

    static func current(processInfo: ProcessInfo = .processInfo) -> BrowserLaunchConfiguration {
        let environment = processInfo.environment

        return BrowserLaunchConfiguration(
            initialURL: resolveInitialURL(from: environment),
            autoOpenInspectorTabs: resolveAutoOpenInspectorTabs(from: environment),
            shouldAutoOpenInspector: environment["WEBSPECTOR_AUTO_OPEN_INSPECTOR"] == "1",
            shouldAutoStartDOMSelection: environment["WEBSPECTOR_AUTO_START_DOM_SELECTION"] == "1",
            shouldShowDiagnostics: environment["WEBSPECTOR_UI_TEST_DIAGNOSTICS"] == "1"
        )
    }

    private static func resolveInitialURL(from environment: [String: String]) -> URL {
        if let configuredURLString = environment["WEBSPECTOR_INITIAL_URL"],
           let configuredURL = URL(string: configuredURLString) {
            return configuredURL
        }

        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1",
           let previewURL = URL(string: "about:blank") {
            return previewURL
        }

        if environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil,
           let blankURL = URL(string: "about:blank") {
            return blankURL
        }

        return URL(string: "https://www.google.com")!
    }

    private static func resolveAutoOpenInspectorTabs(from environment: [String: String]) -> [WITab] {
        guard let rawValue = environment["WEBSPECTOR_AUTO_OPEN_INSPECTOR_TABS"] else {
            return defaultInspectorTabs
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
            case "console":
                tabs.append(.console())
            default:
                continue
            }
        }

        return tabs.isEmpty ? defaultInspectorTabs : tabs
    }
}
