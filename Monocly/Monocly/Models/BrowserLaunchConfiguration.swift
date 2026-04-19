import Foundation
import WebInspectorKit

struct BrowserUITestFixturePage {
    let identifier: String
    let url: URL
    let selectionTargets: [BrowserUITestSelectionTarget]
}

struct BrowserUITestSelectionTarget {
    let identifier: String
    let selector: String
    let expectedPreview: String
    let expectedSelector: String
}

enum BrowserUITestScenario: String {
    case domNavigationBackForward = "domNavigationBackForward"
    case domOpenInspectorAfterInitialLoad = "domOpenInspectorAfterInitialLoad"

    struct FixtureDefinition {
        struct SelectionTargetDefinition {
            let identifier: String
            let selector: String
            let expectedPreview: String
            let expectedSelector: String
        }

        let identifier: String
        let filename: String
        let html: String
        let selectionTargets: [SelectionTargetDefinition]
    }

    var defaultInspectorTabs: [WITab] {
        switch self {
        case .domNavigationBackForward:
            [.dom()]
        case .domOpenInspectorAfterInitialLoad:
            [.dom()]
        }
    }

    var shouldAutoOpenInspector: Bool {
        switch self {
        case .domNavigationBackForward:
            true
        case .domOpenInspectorAfterInitialLoad:
            false
        }
    }

    var shouldShowDiagnostics: Bool {
        switch self {
        case .domNavigationBackForward:
            true
        case .domOpenInspectorAfterInitialLoad:
            true
        }
    }

    var showsInspectorHarnessPanel: Bool {
        switch self {
        case .domNavigationBackForward, .domOpenInspectorAfterInitialLoad:
            true
        }
    }

    var fixtureDefinitions: [FixtureDefinition] {
        switch self {
        case .domNavigationBackForward, .domOpenInspectorAfterInitialLoad:
            [
                .init(
                    identifier: "page1",
                    filename: "dom-page-1.html",
                    html: """
                    <!doctype html>
                    <html lang="en">
                    <head>
                        <meta charset="utf-8">
                        <title>DOM Page 1</title>
                    </head>
                    <body>
                        <main id="dom-page-1">
                            <h1>DOM Page 1</h1>
                            <p>alpha</p>
                            <a
                                id="page-2-link"
                                href="dom-page-2.html"
                                style="display:inline-block;margin-top:16px;padding:12px 16px;background:#0a84ff;color:#fff;text-decoration:none;border-radius:10px;"
                            >Go to Page 2</a>
                        </main>
                    </body>
                    </html>
                    """,
                    selectionTargets: [
                        .init(
                            identifier: "node1",
                            selector: "html",
                            expectedPreview: "<html>",
                            expectedSelector: "html"
                        )
                    ]
                ),
                .init(
                    identifier: "page2",
                    filename: "dom-page-2.html",
                    html: """
                    <!doctype html>
                    <html lang="en">
                    <head>
                        <meta charset="utf-8">
                        <title>DOM Page 2</title>
                    </head>
                    <body>
                        <main id="dom-page-2">
                            <h1>DOM Page 2</h1>
                            <p>beta</p>
                        </main>
                    </body>
                    </html>
                    """,
                    selectionTargets: [
                        .init(
                            identifier: "node1",
                            selector: "p",
                            expectedPreview: "<p>",
                            expectedSelector: "p"
                        )
                    ]
                )
            ]
        }
    }
}

struct BrowserLaunchConfiguration {
    let initialURL: URL
    let autoOpenInspectorTabs: [WITab]
    let shouldAutoOpenInspector: Bool
    let shouldAutoStartDOMSelection: Bool
    let shouldShowDiagnostics: Bool
    let uiTestScenario: BrowserUITestScenario?
    let uiTestFixturePages: [BrowserUITestFixturePage]

    init(
        initialURL: URL,
        autoOpenInspectorTabs: [WITab] = [.dom(), .network()],
        shouldAutoOpenInspector: Bool = false,
        shouldAutoStartDOMSelection: Bool = false,
        shouldShowDiagnostics: Bool = false,
        uiTestScenario: BrowserUITestScenario? = nil,
        uiTestFixturePages: [BrowserUITestFixturePage] = []
    ) {
        self.initialURL = initialURL
        self.autoOpenInspectorTabs = autoOpenInspectorTabs
        self.shouldAutoOpenInspector = shouldAutoOpenInspector
        self.shouldAutoStartDOMSelection = shouldAutoStartDOMSelection
        self.shouldShowDiagnostics = shouldShowDiagnostics
        self.uiTestScenario = uiTestScenario
        self.uiTestFixturePages = uiTestFixturePages
    }

    static func current(processInfo: ProcessInfo = .processInfo) -> BrowserLaunchConfiguration {
        let environment = processInfo.environment
        let uiTestScenario = resolveUITestScenario(from: environment)
        let uiTestFixturePages = resolveUITestFixturePages(for: uiTestScenario)

        return BrowserLaunchConfiguration(
            initialURL: resolveInitialURL(
                from: environment,
                uiTestFixturePages: uiTestFixturePages
            ),
            autoOpenInspectorTabs: resolveAutoOpenInspectorTabs(
                from: environment,
                uiTestScenario: uiTestScenario
            ),
            shouldAutoOpenInspector: environment["WEBSPECTOR_AUTO_OPEN_INSPECTOR"] == "1"
                || uiTestScenario?.shouldAutoOpenInspector == true,
            shouldAutoStartDOMSelection: environment["WEBSPECTOR_AUTO_START_DOM_SELECTION"] == "1",
            shouldShowDiagnostics: environment["WEBSPECTOR_UI_TEST_DIAGNOSTICS"] == "1"
                || uiTestScenario?.shouldShowDiagnostics == true,
            uiTestScenario: uiTestScenario,
            uiTestFixturePages: uiTestFixturePages
        )
    }

    private static func resolveInitialURL(
        from environment: [String: String],
        uiTestFixturePages: [BrowserUITestFixturePage]
    ) -> URL {
        if let configuredURLString = environment["WEBSPECTOR_INITIAL_URL"],
           let configuredURL = URL(string: configuredURLString) {
            return configuredURL
        }

        if let fixtureURL = uiTestFixturePages.first?.url {
            return fixtureURL
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

    private static func resolveAutoOpenInspectorTabs(
        from environment: [String: String],
        uiTestScenario: BrowserUITestScenario?
    ) -> [WITab] {
        guard let rawValue = environment["WEBSPECTOR_AUTO_OPEN_INSPECTOR_TABS"] else {
            return uiTestScenario?.defaultInspectorTabs ?? [.dom(), .network()]
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

    private static func resolveUITestScenario(from environment: [String: String]) -> BrowserUITestScenario? {
        guard let rawValue = environment["MONOCLY_UI_TEST_SCENARIO"] else {
            return nil
        }
        return BrowserUITestScenario(rawValue: rawValue)
    }

    private static func resolveUITestFixturePages(
        for scenario: BrowserUITestScenario?,
        fileManager: FileManager = .default
    ) -> [BrowserUITestFixturePage] {
        guard let scenario else {
            return []
        }

        let fixturesDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("MonoclyUITestFixtures", isDirectory: true)
            .appendingPathComponent(scenario.rawValue, isDirectory: true)
        try? fileManager.createDirectory(
            at: fixturesDirectoryURL,
            withIntermediateDirectories: true
        )

        return scenario.fixtureDefinitions.compactMap { definition in
            let fileURL = fixturesDirectoryURL.appendingPathComponent(definition.filename)
            do {
                try definition.html.write(to: fileURL, atomically: true, encoding: .utf8)
                return BrowserUITestFixturePage(
                    identifier: definition.identifier,
                    url: fileURL,
                    selectionTargets: definition.selectionTargets.map {
                        BrowserUITestSelectionTarget(
                            identifier: $0.identifier,
                            selector: $0.selector,
                            expectedPreview: $0.expectedPreview,
                            expectedSelector: $0.expectedSelector
                        )
                    }
                )
            } catch {
                return nil
            }
        }
    }
}
