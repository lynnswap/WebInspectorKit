import CoreGraphics
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
    case domAdFixture = "domAdFixture"
    case domRemoteURL = "domRemoteURL"

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

    var defaultInspectorTabs: [V2_WITab] {
        switch self {
        case .domNavigationBackForward:
            [.dom]
        case .domOpenInspectorAfterInitialLoad:
            [.dom]
        case .domAdFixture:
            [.dom]
        case .domRemoteURL:
            [.dom]
        }
    }

    var shouldAutoOpenInspector: Bool {
        switch self {
        case .domNavigationBackForward:
            true
        case .domOpenInspectorAfterInitialLoad:
            false
        case .domAdFixture:
            true
        case .domRemoteURL:
            true
        }
    }

    var shouldShowDiagnostics: Bool {
        switch self {
        case .domNavigationBackForward:
            true
        case .domOpenInspectorAfterInitialLoad:
            true
        case .domAdFixture:
            true
        case .domRemoteURL:
            true
        }
    }

    var showsInspectorHarnessPanel: Bool {
        switch self {
        case .domNavigationBackForward, .domOpenInspectorAfterInitialLoad, .domAdFixture, .domRemoteURL:
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
        case .domAdFixture:
            [
                .init(
                    identifier: "ad-fixture",
                    filename: "dom-ad-fixture.html",
                    html: """
                    <!doctype html>
                    <html lang="en">
                    <head>
                        <meta charset="utf-8">
                        <meta name="viewport" content="width=device-width, initial-scale=1">
                        <title>DOM Ad Fixture</title>
                        <style>
                            :root {
                                color-scheme: light;
                            }
                            body {
                                margin: 0;
                                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                                background: #f5f7fb;
                                color: #101828;
                            }
                            main {
                                padding: 20px 16px 120px;
                            }
                            h1 {
                                margin: 0 0 12px;
                                font-size: 28px;
                            }
                            .fixture-note {
                                margin: 0 0 20px;
                                color: #d92d20;
                                font-size: 22px;
                                line-height: 1.35;
                            }
                            .ad-shell {
                                position: relative;
                                width: min(100%, 360px);
                                margin: 0 auto;
                                border-radius: 18px;
                                overflow: hidden;
                                box-shadow: 0 18px 44px rgba(16, 24, 40, 0.22);
                                background: #d7e7ff;
                            }
                            .ad-frame {
                                display: block;
                                width: 100%;
                                height: 132px;
                                border: 0;
                                background: #0f2742;
                            }
                            .utility-frame {
                                position: absolute;
                                left: -9999px;
                                top: -9999px;
                                width: 0;
                                height: 0;
                                border: 0;
                                visibility: hidden;
                            }
                            .footer-copy {
                                margin: 20px 0 0;
                                color: #475467;
                            }
                        </style>
                    </head>
                    <body>
                        <iframe id="fixture-utility-uspapi" class="utility-frame" title="utility uspapi"></iframe>
                        <iframe id="fixture-utility-googlefc" class="utility-frame" title="utility googlefc"></iframe>
                        <main id="fixture-root">
                            <h1>DOM Ad Fixture</h1>
                            <p class="fixture-note">
                                <span id="fixture-warning">Fixture red text above the ad banner.</span>
                            </p>
                            <section id="fixture-ad-shell" class="ad-shell">
                                <iframe
                                    id="fixture-ad-slot"
                                    class="ad-frame"
                                    title="fixture ad slot"
                                    scrolling="no"
                                    loading="eager"
                                    referrerpolicy="no-referrer"
                                ></iframe>
                            </section>
                            <p class="footer-copy">Footer copy after the fixture banner.</p>
                        </main>
                        <script>
                            document.getElementById("fixture-utility-uspapi").srcdoc = `
                            <!doctype html>
                            <html lang="en">
                            <body>
                                <div id="__uspapiLocator">utility uspapi</div>
                            </body>
                            </html>`;

                            document.getElementById("fixture-utility-googlefc").srcdoc = `
                            <!doctype html>
                            <html lang="en">
                            <body>
                                <div id="googlefcPresent">utility googlefc</div>
                            </body>
                            </html>`;

                            document.getElementById("fixture-ad-slot").srcdoc = `
                            <!doctype html>
                            <html lang="en">
                            <body style="margin:0;background:#0f2742;">
                                <style>
                                    body {
                                        margin: 0;
                                        background: #0f2742;
                                        display: flex;
                                        align-items: stretch;
                                        gap: 8px;
                                        padding: 10px;
                                        box-sizing: border-box;
                                        height: 132px;
                                    }
                                    #fixture-ad-cta {
                                        display: block;
                                        width: 112px;
                                        height: 100%;
                                        flex: 0 0 112px;
                                        margin: 0;
                                        border: 0;
                                        border-radius: 12px;
                                        background: rgba(255,255,255,0.96);
                                        color: #1ea88f;
                                        font: 700 15px -apple-system, BlinkMacSystemFont, sans-serif;
                                    }
                                </style>
                                <img
                                    id="fixture-ad-image"
                                    alt="Fixture Ad"
                                    style="display:block;flex:1 1 auto;width:0;height:100%;object-fit:cover;border-radius:12px;"
                                    src="data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 360 132'><rect width='360' height='132' fill='%230c7be8'/><rect x='12' y='12' width='336' height='108' rx='16' fill='%23112a45'/><text x='28' y='58' font-family='-apple-system,BlinkMacSystemFont,sans-serif' font-size='28' fill='white'>Fixture Banner</text><text x='28' y='88' font-family='-apple-system,BlinkMacSystemFont,sans-serif' font-size='16' fill='%23c8ddff'>Native pick target inside iframe</text></svg>"
                                />
                                <button id="fixture-ad-cta" type="button">Tap CTA</button>
                            </body>
                            </html>`;
                        </script>
                    </body>
                    </html>
                    """,
                    selectionTargets: []
                )
            ]
        case .domRemoteURL:
            []
        }
    }
}

struct BrowserLaunchConfiguration {
    let initialURL: URL
    let autoOpenInspectorTabs: [V2_WITab]
    let shouldAutoOpenInspector: Bool
    let shouldAutoStartDOMSelection: Bool
    let shouldShowDiagnostics: Bool
    let uiTestScenario: BrowserUITestScenario?
    let uiTestFixturePages: [BrowserUITestFixturePage]
    let uiTestRemoteURL: URL?
    let uiTestRemoteTap: CGVector?

    init(
        initialURL: URL,
        autoOpenInspectorTabs: [V2_WITab] = V2_WITab.defaults,
        shouldAutoOpenInspector: Bool = false,
        shouldAutoStartDOMSelection: Bool = false,
        shouldShowDiagnostics: Bool = false,
        uiTestScenario: BrowserUITestScenario? = nil,
        uiTestFixturePages: [BrowserUITestFixturePage] = [],
        uiTestRemoteURL: URL? = nil,
        uiTestRemoteTap: CGVector? = nil
    ) {
        self.initialURL = initialURL
        self.autoOpenInspectorTabs = autoOpenInspectorTabs
        self.shouldAutoOpenInspector = shouldAutoOpenInspector
        self.shouldAutoStartDOMSelection = shouldAutoStartDOMSelection
        self.shouldShowDiagnostics = shouldShowDiagnostics
        self.uiTestScenario = uiTestScenario
        self.uiTestFixturePages = uiTestFixturePages
        self.uiTestRemoteURL = uiTestRemoteURL
        self.uiTestRemoteTap = uiTestRemoteTap
    }

    static func current(processInfo: ProcessInfo = .processInfo) -> BrowserLaunchConfiguration {
        let environment = processInfo.environment
        let uiTestScenario = resolveUITestScenario(from: environment)
        let uiTestFixturePages = resolveUITestFixturePages(for: uiTestScenario)
        let uiTestRemoteURL = resolveUITestRemoteURL(
            from: environment,
            scenario: uiTestScenario
        )
        let uiTestRemoteTap = resolveUITestRemoteTap(from: environment)

        return BrowserLaunchConfiguration(
            initialURL: resolveInitialURL(
                from: environment,
                uiTestFixturePages: uiTestFixturePages,
                uiTestRemoteURL: uiTestRemoteURL
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
            uiTestFixturePages: uiTestFixturePages,
            uiTestRemoteURL: uiTestRemoteURL,
            uiTestRemoteTap: uiTestRemoteTap
        )
    }

    private static func resolveInitialURL(
        from environment: [String: String],
        uiTestFixturePages: [BrowserUITestFixturePage],
        uiTestRemoteURL: URL?
    ) -> URL {
        if let configuredURLString = environment["WEBSPECTOR_INITIAL_URL"],
           let configuredURL = URL(string: configuredURLString) {
            return configuredURL
        }

        if let uiTestRemoteURL {
            return uiTestRemoteURL
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
    ) -> [V2_WITab] {
        guard let rawValue = environment["WEBSPECTOR_AUTO_OPEN_INSPECTOR_TABS"] else {
            return uiTestScenario?.defaultInspectorTabs ?? V2_WITab.defaults
        }

        let requested = rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        var tabs: [V2_WITab] = []
        for entry in requested {
            switch entry {
            case "dom":
                tabs.append(.dom)
            case "network":
                tabs.append(.network)
            default:
                continue
            }
        }

        return tabs.isEmpty ? V2_WITab.defaults : tabs
    }

    private static func resolveUITestScenario(from environment: [String: String]) -> BrowserUITestScenario? {
        guard let rawValue = environment["MONOCLY_UI_TEST_SCENARIO"] else {
            return nil
        }
        return BrowserUITestScenario(rawValue: rawValue)
    }

    private static func resolveUITestRemoteURL(
        from environment: [String: String],
        scenario: BrowserUITestScenario?
    ) -> URL? {
        guard scenario == .domRemoteURL,
              let rawValue = environment["MONOCLY_UI_TEST_REMOTE_URL"] else {
            return nil
        }
        return URL(string: rawValue)
    }

    private static func resolveUITestRemoteTap(
        from environment: [String: String]
    ) -> CGVector? {
        guard let rawX = environment["MONOCLY_UI_TEST_REMOTE_TAP_X"],
              let rawY = environment["MONOCLY_UI_TEST_REMOTE_TAP_Y"],
              let x = Double(rawX),
              let y = Double(rawY) else {
            return nil
        }
        return CGVector(dx: x, dy: y)
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
