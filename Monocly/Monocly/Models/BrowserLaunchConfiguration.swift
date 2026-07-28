import Foundation
import WebInspectorKit

struct BrowserLaunchConfiguration {
    enum InspectorFixtureURLValidationError: Error, Equatable, CustomStringConvertible {
        case requiresAbsoluteHTTPURL
        case requiresLoopbackHost

        var description: String {
            switch self {
            case .requiresAbsoluteHTTPURL:
                "The inspector fixture URL must be an absolute HTTP URL."
            case .requiresLoopbackHost:
                "The inspector fixture URL must use 127.0.0.1 or localhost."
            }
        }
    }

    private enum Runtime {
        case standard
        case inspectorFixture(URL)
        case xcodeTestOrPreview(URL)
    }

    static let inspectorFixtureURLEnvironmentKey = "MONOCLY_INSPECTOR_FIXTURE_URL"

    static let standard = BrowserLaunchConfiguration(runtime: .standard)

    static func xcodeTestOrPreview(
        initialURL: URL = URL(string: "about:blank")!
    ) -> BrowserLaunchConfiguration {
        BrowserLaunchConfiguration(runtime: .xcodeTestOrPreview(initialURL))
    }

    private let runtime: Runtime

    var initialURL: URL {
        switch runtime {
        case .standard:
            URL(string: "https://www.google.com")!
        case .inspectorFixture(let url):
            url
        case .xcodeTestOrPreview(let url):
            url
        }
    }

    var shouldAutoOpenInspector: Bool {
        switch runtime {
        case .inspectorFixture:
            true
        case .standard, .xcodeTestOrPreview:
            false
        }
    }

    var sessionPersistenceMode: BrowserSession.PersistenceMode {
        switch runtime {
        case .standard:
            .persistent
        case .inspectorFixture, .xcodeTestOrPreview:
            .ephemeral
        }
    }

    private init(runtime: Runtime) {
        self.runtime = runtime
    }

    static func current(processInfo: ProcessInfo = .processInfo) -> BrowserLaunchConfiguration {
        current(environment: processInfo.environment)
    }

    static func current(environment: [String: String]) -> BrowserLaunchConfiguration {
        do {
            return try resolve(environment: environment)
        } catch {
            preconditionFailure(
                "Invalid \(inspectorFixtureURLEnvironmentKey): \(error)"
            )
        }
    }

    static func resolve(environment: [String: String]) throws -> BrowserLaunchConfiguration {
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil {
            return .xcodeTestOrPreview()
        }

        guard let rawFixtureURL = environment[inspectorFixtureURLEnvironmentKey] else {
            return .standard
        }

        guard let fixtureURL = URL(string: rawFixtureURL),
              fixtureURL.scheme?.lowercased() == "http",
              fixtureURL.host != nil else {
            throw InspectorFixtureURLValidationError.requiresAbsoluteHTTPURL
        }

        guard let host = fixtureURL.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" else {
            throw InspectorFixtureURLValidationError.requiresLoopbackHost
        }

        return BrowserLaunchConfiguration(runtime: .inspectorFixture(fixtureURL))
    }
}
