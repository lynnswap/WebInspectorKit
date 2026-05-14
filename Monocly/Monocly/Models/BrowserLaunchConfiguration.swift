import Foundation
import WebInspectorKit

struct BrowserLaunchConfiguration {
    let initialURL: URL
    let shouldAutoOpenInspector: Bool

    init(
        initialURL: URL,
        shouldAutoOpenInspector: Bool = false
    ) {
        self.initialURL = initialURL
        self.shouldAutoOpenInspector = shouldAutoOpenInspector
    }

    static func current(processInfo: ProcessInfo = .processInfo) -> BrowserLaunchConfiguration {
        let environment = processInfo.environment
        return BrowserLaunchConfiguration(
            initialURL: resolveInitialURL(from: environment),
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
}
