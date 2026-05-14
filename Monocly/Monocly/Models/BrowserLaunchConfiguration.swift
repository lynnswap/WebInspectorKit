import Foundation
import WebInspectorKit

struct BrowserLaunchConfiguration {
    let initialURL: URL
    let autoOpenInspectorTabs: [WITab]
    let shouldAutoOpenInspector: Bool

    init(
        initialURL: URL,
        autoOpenInspectorTabs: [WITab] = [.dom, .network],
        shouldAutoOpenInspector: Bool = false
    ) {
        self.initialURL = initialURL
        self.autoOpenInspectorTabs = autoOpenInspectorTabs
        self.shouldAutoOpenInspector = shouldAutoOpenInspector
    }

    static func current(processInfo: ProcessInfo = .processInfo) -> BrowserLaunchConfiguration {
        let environment = processInfo.environment
        return BrowserLaunchConfiguration(
            initialURL: resolveInitialURL(from: environment),
            autoOpenInspectorTabs: resolveAutoOpenInspectorTabs(from: environment),
            shouldAutoOpenInspector: environment["WEBSPECTOR_AUTO_OPEN_INSPECTOR"] == "1"
        )
    }

    private static func resolveInitialURL(from environment: [String: String]) -> URL {
        if let rawInitialURL = environment["WEBSPECTOR_INITIAL_URL"],
           let initialURL = URL(string: rawInitialURL) {
            return initialURL
        }

        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return URL(string: "about:blank")!
        }

        if environment["XCTestConfigurationFilePath"] != nil {
            return URL(string: "about:blank")!
        }

        return URL(string: "https://www.google.com")!
    }

    private static func resolveAutoOpenInspectorTabs(from environment: [String: String]) -> [WITab] {
        guard let rawTabs = environment["WEBSPECTOR_AUTO_OPEN_INSPECTOR_TABS"] else {
            return [.dom, .network]
        }

        let tabs = rawTabs
            .split(separator: ",")
            .compactMap { tab(named: String($0)) }

        return tabs.isEmpty ? [.dom, .network] : tabs
    }

    private static func tab(named rawName: String) -> WITab? {
        switch rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dom", WITab.dom.id:
            .dom
        case "network", WITab.network.id:
            .network
        default:
            nil
        }
    }
}
