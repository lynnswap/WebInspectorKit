import Foundation
import ObservationBridge
import Testing
@testable import Monocly

#if os(iOS)
import UIKit
import WebKit
import WebKitScreenTimeWorkaround

@MainActor
private func configuredInspectorFixtureURL() -> String? {
    ProcessInfo.processInfo.environment[BrowserLaunchConfiguration.inspectorFixtureURLEnvironmentKey]
}

@Suite(
    .serialized,
    .enabled(
        "Run Tools/InspectorFixture/server.py and pass its loopback URL as TEST_RUNNER_MONOCLY_INSPECTOR_FIXTURE_URL."
    ) {
        await configuredInspectorFixtureURL() != nil
    }
)
@MainActor
struct InspectorFixtureBehaviorTests {
    private let visit = "behavior-\(UUID().uuidString.lowercased())"
    private let pageAURL: URL

    init() throws {
        if #available(iOS 26.1, *) {
            try ScreenTimeWorkaround.install()
        }
        let rawFixtureURL = try #require(configuredInspectorFixtureURL())
        let fixtureURL = try BrowserLaunchConfiguration.resolve(environment: [
            BrowserLaunchConfiguration.inspectorFixtureURLEnvironmentKey: rawFixtureURL,
        ]).initialURL
        var pageA = URLComponents()
        pageA.path = "/a"
        pageA.queryItems = [URLQueryItem(name: "visit", value: visit)]
        pageAURL = try #require(pageA.url(relativeTo: fixtureURL)).absoluteURL
    }

    @Test(.timeLimit(.minutes(1)))
    func mutationBurstClickRevisesEveryCard() async throws {
        let page = try await FixtureBrowserPage.open(pageAURL)
        defer { page.close() }

        let mutation = try #require(try await page.run("""
            document.querySelector("#mutation-burst").click();
            const cards = Array.from(document.querySelectorAll(".fixture-card"));
            return [
              cards.length,
              cards.filter((card, index) => card.dataset.fixtureRevision === String(index + 1)).length,
              document.querySelector("#burst-status").textContent,
            ];
            """) as? [Any])

        #expect(mutation[0] as? Int == 2_305)
        #expect(mutation[1] as? Int == 2_305)
        #expect(mutation[2] as? String == "2305 DOM mutations emitted")
    }

    @Test(.timeLimit(.minutes(1)))
    func publicNetworkBurstDeliversEachRequestIdentityOnce() async throws {
        let page = try await FixtureBrowserPage.open(pageAURL)
        defer { page.close() }
        let run = "behavior-burst"

        let status = try await page.run("""
            await window.runInspectorNetworkBurst(count, run);
            return document.querySelector("#network-burst-status").textContent;
            """, ["count": 3, "run": run]) as? String

        #expect(status == "Network burst complete: 3 / 3")
        #expect(try await page.networkBurstMetrics(visit: visit, run: run) == NetworkBurstMetrics(
            contiguousRequestCount: 3,
            duplicateCount: 0,
            maximumRequest: 2,
            minimumRequest: 0,
            receivedCount: 3,
            run: run,
            uniqueRequestCount: 3,
            visit: visit
        ))
    }

    @Test(.timeLimit(.minutes(1)))
    func historyControlsTraverseCommittedDocuments() async throws {
        let pageAPath = "/a?visit=\(visit)"
        let pageBPath = "/b?visit=b1&return=a2"
        let page = try await FixtureBrowserPage.open(pageAURL)
        defer { page.close() }

        try await page.navigate(byClicking: "#navigate-b")
        #expect(try await page.document() == FixtureDocument(page: "b", visit: "b1"))
        #expect(page.history() == FixtureHistory(back: [pageAPath], current: pageBPath, forward: []))

        try await page.navigate(byClicking: "#history-back")
        #expect(try await page.document() == FixtureDocument(page: "a", visit: visit))
        #expect(page.history() == FixtureHistory(back: [], current: pageAPath, forward: [pageBPath]))

        try await page.navigate(byClicking: "#history-forward")
        #expect(try await page.document() == FixtureDocument(page: "b", visit: "b1"))
        #expect(page.history() == FixtureHistory(back: [pageAPath], current: pageBPath, forward: []))
    }
}

private struct FixtureDocument: Equatable {
    var page: String
    var visit: String
}

private struct FixtureHistory: Equatable {
    var back: [String]
    var current: String?
    var forward: [String]
}

private struct NetworkBurstMetrics: Decodable, Equatable {
    var contiguousRequestCount: Int
    var duplicateCount: Int
    var maximumRequest: Int?
    var minimumRequest: Int?
    var receivedCount: Int
    var run: String
    var uniqueRequestCount: Int
    var visit: String
}

@MainActor
private final class FixtureBrowserPage {
    private let tab: BrowserTab
    private let window: UIWindow

    static func open(_ url: URL) async throws -> FixtureBrowserPage {
        let page = try FixtureBrowserPage(url: url)
        do {
            page.tab.loadInitialRequestIfNeeded()
            try await page.waitForNavigation(after: 0)
            return page
        } catch {
            page.close()
            throw error
        }
    }

    private init(url: URL) throws {
        let windowScene = try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        tab = BrowserTab(url: url, automaticallyLoadsInitialRequest: false)

        let rootViewController = UIViewController()
        rootViewController.view.addSubview(tab.webView)
        tab.webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tab.webView.leadingAnchor.constraint(equalTo: rootViewController.view.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: rootViewController.view.trailingAnchor),
            tab.webView.topAnchor.constraint(equalTo: rootViewController.view.topAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: rootViewController.view.bottomAnchor),
        ])
        window = UIWindow(windowScene: windowScene)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func close() {
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
    }

    func run(_ functionBody: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await tab.webView.callAsyncJavaScript(functionBody, arguments: arguments, contentWorld: .page)
    }

    func navigate(byClicking control: String) async throws {
        let committedNavigationCount = tab.didCommitNavigationCount
        _ = try await run("document.querySelector(control).click();", ["control": control])
        try await waitForNavigation(after: committedNavigationCount)
    }

    func document() async throws -> FixtureDocument {
        let values = try #require(try await run("""
            return [document.body.dataset.fixturePage, document.body.dataset.fixtureVisit];
            """) as? [String])
        return FixtureDocument(page: values[0], visit: values[1])
    }

    func history() -> FixtureHistory {
        let list = tab.webView.backForwardList
        return FixtureHistory(
            back: list.backList.map(\.url.fixturePathAndQuery),
            current: list.currentItem?.url.fixturePathAndQuery,
            forward: list.forwardList.map(\.url.fixturePathAndQuery)
        )
    }

    func networkBurstMetrics(visit: String, run: String) async throws -> NetworkBurstMetrics {
        let body = try #require(try await self.run("""
            const query = new URLSearchParams({ visit, run });
            const response = await fetch(`/metrics/network-burst?${query}`);
            return await response.text();
            """, ["visit": visit, "run": run]) as? String)
        return try JSONDecoder().decode(NetworkBurstMetrics.self, from: Data(body.utf8))
    }

    // A restored history entry can end its committed load with a benign cancellation instead of
    // didFinish, so a navigation is settled once it commits and BrowserTab stops loading.
    private func waitForNavigation(after committedNavigationCount: Int) async throws {
        let tab = tab
        let condition: @MainActor @Sendable () -> Bool = {
            tab.lastNavigationErrorDescription != nil
                || (tab.didCommitNavigationCount > committedNavigationCount && tab.isLoading == false)
        }
        let observation = withPortableContinuousObservation { _ in
            _ = condition()
        }
        defer { observation.cancel() }
        let values = await observation.values(condition)
        defer { values.cancel() }
        let didSettle = await values.waitUntilValue(true, timeout: .seconds(10))
        if !didSettle, let error = observation.error {
            throw error
        }
        try #require(didSettle, "The fixture navigation did not settle.")
        try #require(tab.lastNavigationErrorDescription == nil, "\(tab.lastNavigationErrorDescription ?? "")")
    }
}

private extension URL {
    var fixturePathAndQuery: String {
        query.map { "\(path())?\($0)" } ?? path()
    }
}
#endif
