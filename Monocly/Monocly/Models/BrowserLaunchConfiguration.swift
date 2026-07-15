import Foundation
import WebInspectorKit

struct BrowserLaunchConfiguration {
    let initialURL: URL
    let shouldAutoOpenInspector: Bool
    let sessionPersistenceMode: BrowserSession.PersistenceMode

    init(
        initialURL: URL,
        shouldAutoOpenInspector: Bool = false,
        sessionPersistenceMode: BrowserSession.PersistenceMode = .persistent
    ) {
        self.initialURL = initialURL
        self.shouldAutoOpenInspector = shouldAutoOpenInspector
        self.sessionPersistenceMode = sessionPersistenceMode
    }

    static func current(processInfo: ProcessInfo = .processInfo) -> BrowserLaunchConfiguration {
        current(environment: processInfo.environment)
    }

    static func current(environment: [String: String]) -> BrowserLaunchConfiguration {
        return BrowserLaunchConfiguration(
            initialURL: resolveInitialURL(from: environment),
            shouldAutoOpenInspector: environment["WEBSPECTOR_AUTO_OPEN_INSPECTOR"] == "1",
            sessionPersistenceMode: resolveSessionPersistenceMode(from: environment)
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

    private static func resolveSessionPersistenceMode(
        from environment: [String: String]
    ) -> BrowserSession.PersistenceMode {
        if environment["WEBSPECTOR_EPHEMERAL_SESSION"] == "1" {
            return .ephemeral
        }

        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return .ephemeral
        }

        if environment["XCTestConfigurationFilePath"] != nil {
            return .ephemeral
        }

        return .persistent
    }
}
