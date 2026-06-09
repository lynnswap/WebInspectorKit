import Foundation
import Testing
@testable import Monocly

#if os(iOS)
import UIKit
import WebKit

@Suite(.serialized)
@MainActor
struct BrowserSessionRestoreTests {
    @Test
    func sessionStoreSavesAndLoadsMultipleTabsAndStateBlobs() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let firstID = UUID()
            let secondID = UUID()
            let firstDate = Date(timeIntervalSince1970: 100)
            let secondDate = Date(timeIntervalSince1970: 200)
            let snapshot = BrowserSessionSnapshot(
                selectedTabID: secondID,
                tabs: [
                    BrowserTabSnapshot(
                        id: firstID,
                        url: try #require(URL(string: "https://example.com/first")),
                        title: "First",
                        createdAt: firstDate,
                        lastUsedAt: firstDate,
                        stateFileName: BrowserTabSnapshot.stateFileName(for: firstID)
                    ),
                    BrowserTabSnapshot(
                        id: secondID,
                        url: try #require(URL(string: "https://example.com/second")),
                        title: "Second",
                        createdAt: secondDate,
                        lastUsedAt: secondDate,
                        stateFileName: BrowserTabSnapshot.stateFileName(for: secondID)
                    )
                ]
            )
            let tabStateDataByID = [
                firstID: Data("first-state".utf8),
                secondID: Data("second-state".utf8)
            ]

            try sessionStore.save(snapshot: snapshot, tabStateDataByID: tabStateDataByID)

            let restoredSession = try #require(sessionStore.load())
            #expect(restoredSession.snapshot == snapshot)
            #expect(restoredSession.tabStateDataByID == tabStateDataByID)
        }
    }

    @Test
    func sessionStoreIgnoresCorruptJSON() throws {
        try withTemporarySessionStore { sessionStore, rootDirectoryURL in
            try FileManager.default.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
            try Data("{".utf8).write(to: rootDirectoryURL.appendingPathComponent("session.json"))

            #expect(sessionStore.load() == nil)
        }
    }

    @Test
    func sessionStoreLoadsSnapshotWhenStateBlobIsMissing() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let tabID = UUID()
            let snapshot = BrowserSessionSnapshot(
                selectedTabID: tabID,
                tabs: [
                    BrowserTabSnapshot(
                        id: tabID,
                        url: try #require(URL(string: "https://example.com/missing-state")),
                        title: "Missing State",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 200),
                        stateFileName: BrowserTabSnapshot.stateFileName(for: tabID)
                    )
                ]
            )

            try sessionStore.save(snapshot: snapshot, tabStateDataByID: [:])

            let restoredSession = try #require(sessionStore.load())
            #expect(restoredSession.snapshot == snapshot)
            #expect(restoredSession.tabStateDataByID.isEmpty)
        }
    }

    @Test
    func sessionStoreScopesSnapshotsBySceneSessionIdentifier() throws {
        try withTemporaryBrowserSessionDirectory { browserSessionDirectoryURL in
            let firstStore = BrowserSessionStore(
                sceneSessionPersistentIdentifier: "scene/a",
                browserSessionDirectoryURL: browserSessionDirectoryURL
            )
            let secondStore = BrowserSessionStore(
                sceneSessionPersistentIdentifier: "scene/b",
                browserSessionDirectoryURL: browserSessionDirectoryURL
            )
            let firstID = UUID()
            let secondID = UUID()
            let firstSnapshot = BrowserSessionSnapshot(
                selectedTabID: firstID,
                tabs: [
                    BrowserTabSnapshot(
                        id: firstID,
                        url: try #require(URL(string: "https://example.com/first-scene")),
                        title: "First Scene",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabSnapshot.stateFileName(for: firstID)
                    )
                ]
            )
            let secondSnapshot = BrowserSessionSnapshot(
                selectedTabID: secondID,
                tabs: [
                    BrowserTabSnapshot(
                        id: secondID,
                        url: try #require(URL(string: "https://example.com/second-scene")),
                        title: "Second Scene",
                        createdAt: Date(timeIntervalSince1970: 200),
                        lastUsedAt: Date(timeIntervalSince1970: 200),
                        stateFileName: BrowserTabSnapshot.stateFileName(for: secondID)
                    )
                ]
            )

            try firstStore.save(snapshot: firstSnapshot, tabStateDataByID: [:])
            try secondStore.save(snapshot: secondSnapshot, tabStateDataByID: [:])

            #expect(firstStore.rootDirectoryURL != secondStore.rootDirectoryURL)
            #expect(firstStore.load()?.snapshot == firstSnapshot)
            #expect(secondStore.load()?.snapshot == secondSnapshot)
        }
    }

    @Test
    func browserStoreCreatesFallbackTabWithoutSnapshot() throws {
        let fallbackURL = try #require(URL(string: "https://fallback.example/"))
        let store = BrowserStore(
            restoring: nil,
            fallbackURL: fallbackURL,
            sessionStore: nil
        )

        #expect(store.tabs.count == 1)
        #expect(store.selectedTabID == store.tabs[0].id)
        #expect(store.currentURL == fallbackURL)
        #expect(store.webView === store.tabs[0].webView)
    }

    @Test
    func browserStoreRestoresTabsAndSelectedWebViewFromSnapshot() throws {
        let firstID = UUID()
        let secondID = UUID()
        let fallbackURL = try #require(URL(string: "https://fallback.example/"))
        let selectedURL = try #require(URL(string: "https://example.com/selected"))
        let restoredSession = BrowserRestoredSession(
            snapshot: BrowserSessionSnapshot(
                selectedTabID: secondID,
                tabs: [
                    BrowserTabSnapshot(
                        id: firstID,
                        url: try #require(URL(string: "https://example.com/first")),
                        title: "First",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabSnapshot.stateFileName(for: firstID)
                    ),
                    BrowserTabSnapshot(
                        id: secondID,
                        url: selectedURL,
                        title: "Selected",
                        createdAt: Date(timeIntervalSince1970: 200),
                        lastUsedAt: Date(timeIntervalSince1970: 300),
                        stateFileName: BrowserTabSnapshot.stateFileName(for: secondID)
                    )
                ]
            ),
            tabStateDataByID: [:]
        )

        let store = BrowserStore(
            restoring: restoredSession,
            fallbackURL: fallbackURL,
            sessionStore: nil
        )

        #expect(store.tabs.map(\.id) == [firstID, secondID])
        #expect(store.selectedTabID == secondID)
        #expect(store.currentURL == selectedURL)
        #expect(store.displayTitle == "Selected")
        #expect(store.webView === store.tabs[1].webView)
    }

    @Test
    func browserStoreNormalizesInvalidSelectedTabToFirstRestoredTab() throws {
        let tabID = UUID()
        let restoredURL = try #require(URL(string: "https://example.com/restored"))
        let restoredSession = BrowserRestoredSession(
            snapshot: BrowserSessionSnapshot(
                selectedTabID: UUID(),
                tabs: [
                    BrowserTabSnapshot(
                        id: tabID,
                        url: restoredURL,
                        title: "Restored",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabSnapshot.stateFileName(for: tabID)
                    )
                ]
            ),
            tabStateDataByID: [:]
        )

        let store = BrowserStore(
            restoring: restoredSession,
            fallbackURL: try #require(URL(string: "https://fallback.example/")),
            sessionStore: nil
        )

        #expect(store.selectedTabID == tabID)
        #expect(store.currentURL == restoredURL)
    }

    @Test
    func restoredStoreDoesNotReplaceSelectedTabURLWithFallbackInitialURL() throws {
        let tabID = UUID()
        let restoredURL = try #require(URL(string: "https://example.com/restored"))
        let fallbackURL = try #require(URL(string: "https://fallback.example/"))
        let restoredSession = BrowserRestoredSession(
            snapshot: BrowserSessionSnapshot(
                selectedTabID: tabID,
                tabs: [
                    BrowserTabSnapshot(
                        id: tabID,
                        url: restoredURL,
                        title: "Restored",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabSnapshot.stateFileName(for: tabID)
                    )
                ]
            ),
            tabStateDataByID: [:]
        )
        let store = BrowserStore(
            restoring: restoredSession,
            fallbackURL: fallbackURL,
            sessionStore: nil
        )

        store.loadInitialRequestIfNeeded()

        #expect(store.currentURL == restoredURL)
        #expect(store.currentURL != fallbackURL)
    }

    @Test
    func restoredInteractionStateDoesNotTriggerInitialURLLoad() throws {
        let tabID = UUID()
        let restoredURL = try #require(URL(string: "https://example.com/restored-state"))
        let restoredState = Data("restored-state".utf8)
        let restoredSession = BrowserRestoredSession(
            snapshot: BrowserSessionSnapshot(
                selectedTabID: tabID,
                tabs: [
                    BrowserTabSnapshot(
                        id: tabID,
                        url: restoredURL,
                        title: "Restored State",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabSnapshot.stateFileName(for: tabID)
                    )
                ]
            ),
            tabStateDataByID: [tabID: restoredState]
        )
        let store = BrowserStore(
            restoring: restoredSession,
            fallbackURL: try #require(URL(string: "https://fallback.example/")),
            sessionStore: nil
        )
        let tab = try #require(store.selectedTab)

        store.loadInitialRequestIfNeeded()

        #expect(tab.initialRequestLoadCount == 0)
        #expect(store.currentURL == restoredURL)
    }

    @Test
    func explicitNavigationDoesNotSaveStaleRestoredInteractionStateForNewURL() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let tabID = UUID()
            let restoredState = Data("restored-state".utf8)
            let newURL = try #require(URL(string: "https://example.com/new-page"))
            let restoredSession = BrowserRestoredSession(
                snapshot: BrowserSessionSnapshot(
                    selectedTabID: tabID,
                    tabs: [
                        BrowserTabSnapshot(
                            id: tabID,
                            url: try #require(URL(string: "https://example.com/restored-state")),
                            title: "Restored State",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100),
                            stateFileName: BrowserTabSnapshot.stateFileName(for: tabID)
                        )
                    ]
                ),
                tabStateDataByID: [tabID: restoredState]
            )
            let store = BrowserStore(
                restoring: restoredSession,
                fallbackURL: try #require(URL(string: "https://fallback.example/")),
                sessionStore: sessionStore
            )

            store.loadInitialRequestIfNeeded()
            store.load(url: newURL)
            store.preserveSession(immediate: true)

            let savedSession = try #require(sessionStore.load())
            #expect(savedSession.snapshot.tabs.first?.url == newURL)
            #expect(savedSession.tabStateDataByID[tabID] == nil)
        }
    }

    @Test
    func failedNavigationKeepsSynchronizedInteractionStateSaveable() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let tabID = UUID()
            let restoredURL = try #require(URL(string: "https://example.com/restored-state"))
            let restoredState = Data("restored-state".utf8)
            let restoredSession = BrowserRestoredSession(
                snapshot: BrowserSessionSnapshot(
                    selectedTabID: tabID,
                    tabs: [
                        BrowserTabSnapshot(
                            id: tabID,
                            url: restoredURL,
                            title: "Restored State",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100),
                            stateFileName: BrowserTabSnapshot.stateFileName(for: tabID)
                        )
                    ]
                ),
                tabStateDataByID: [tabID: restoredState]
            )
            let store = BrowserStore(
                restoring: restoredSession,
                fallbackURL: try #require(URL(string: "https://fallback.example/")),
                sessionStore: sessionStore
            )
            let tab = try #require(store.selectedTab)

            store.loadInitialRequestIfNeeded()
            tab.webView(tab.webView, didStartProvisionalNavigation: nil)
            tab.webView(
                tab.webView,
                didFailProvisionalNavigation: nil,
                withError: URLError(.notConnectedToInternet)
            )
            store.preserveSession(immediate: true)

            let savedSession = try #require(sessionStore.load())
            #expect(savedSession.snapshot.tabs.first?.url == restoredURL)
            #expect(savedSession.tabStateDataByID[tabID] != nil)
        }
    }

    @Test
    func loadingProgressRemainsVisibleAtCompletedEstimatedProgressUntilNavigationSettles() throws {
        let store = BrowserStore(
            url: try #require(URL(string: "about:blank")),
            automaticallyLoadsInitialRequest: false,
            sessionStore: nil
        )
        let tab = try #require(store.selectedTab)

        tab.webView(tab.webView, didStartProvisionalNavigation: nil)
        tab.estimatedProgress = 1

        #expect(tab.isShowingProgress)
        #expect(store.isShowingProgress)
    }

    @Test
    func explicitNavigationShowsProgressImmediatelyFromCompletedPreviousProgress() throws {
        let store = BrowserStore(
            url: try #require(URL(string: "about:blank")),
            automaticallyLoadsInitialRequest: false,
            sessionStore: nil
        )
        let tab = try #require(store.selectedTab)
        tab.isLoading = false
        tab.estimatedProgress = 1
        let nextURL = try #require(URL(string: "https://example.com/next"))

        store.load(url: nextURL)

        #expect(store.currentURL == nextURL)
        #expect(tab.isLoading)
        #expect(tab.estimatedProgress == .zero)
        #expect(store.isShowingProgress)
    }

    @Test
    func sameDocumentNavigationSettlesProgressStartedForHistoryNavigation() throws {
        let store = BrowserStore(
            url: try #require(URL(string: "about:blank")),
            automaticallyLoadsInitialRequest: false,
            sessionStore: nil
        )
        let tab = try #require(store.selectedTab)
        tab.isLoading = true
        tab.estimatedProgress = 0.5

        tab.handleSameDocumentNavigationBridge(tab.webView, navigation: nil, navigationType: 0)

        #expect(tab.isLoading == false)
        #expect(store.isShowingProgress == false)
    }

    @Test
    func autosavePreservesPendingRestoredStateForUnselectedTabs() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let selectedID = UUID()
            let backgroundID = UUID()
            let backgroundState = Data("background-state".utf8)
            let restoredSession = BrowserRestoredSession(
                snapshot: BrowserSessionSnapshot(
                    selectedTabID: selectedID,
                    tabs: [
                        BrowserTabSnapshot(
                            id: selectedID,
                            url: try #require(URL(string: "https://example.com/selected")),
                            title: "Selected",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 200),
                            stateFileName: BrowserTabSnapshot.stateFileName(for: selectedID)
                        ),
                        BrowserTabSnapshot(
                            id: backgroundID,
                            url: try #require(URL(string: "https://example.com/background")),
                            title: "Background",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100),
                            stateFileName: BrowserTabSnapshot.stateFileName(for: backgroundID)
                        )
                    ]
                ),
                tabStateDataByID: [backgroundID: backgroundState]
            )
            let store = BrowserStore(
                restoring: restoredSession,
                fallbackURL: try #require(URL(string: "https://fallback.example/")),
                sessionStore: sessionStore
            )

            store.loadInitialRequestIfNeeded()
            store.preserveSession(immediate: true)

            let savedSession = try #require(sessionStore.load())
            #expect(savedSession.tabStateDataByID[backgroundID] == backgroundState)
        }
    }

    @Test
    func restoredTitleSurvivesInitialNilWebViewTitleObservation() throws {
        let tabID = UUID()
        let store = BrowserStore(
            restoring: BrowserRestoredSession(
                snapshot: BrowserSessionSnapshot(
                    selectedTabID: tabID,
                    tabs: [
                        BrowserTabSnapshot(
                            id: tabID,
                            url: try #require(URL(string: "https://example.com/restored-title")),
                            title: "Restored Title",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100),
                            stateFileName: BrowserTabSnapshot.stateFileName(for: tabID)
                        )
                    ]
                ),
                tabStateDataByID: [:]
            ),
            fallbackURL: try #require(URL(string: "https://fallback.example/")),
            sessionStore: nil
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        #expect(store.tabs[0].snapshot(stateFileName: "tab.state").title == "Restored Title")
        #expect(store.displayTitle == "Restored Title")
    }

    @Test
    func rootReattachesInspectorSessionAfterSelectedTabWebViewChanges() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let restoredSession = BrowserRestoredSession(
            snapshot: BrowserSessionSnapshot(
                selectedTabID: firstID,
                tabs: [
                    BrowserTabSnapshot(
                        id: firstID,
                        url: try #require(URL(string: "about:blank#first")),
                        title: "First",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabSnapshot.stateFileName(for: firstID)
                    ),
                    BrowserTabSnapshot(
                        id: secondID,
                        url: try #require(URL(string: "about:blank#second")),
                        title: "Second",
                        createdAt: Date(timeIntervalSince1970: 200),
                        lastUsedAt: Date(timeIntervalSince1970: 200),
                        stateFileName: BrowserTabSnapshot.stateFileName(for: secondID)
                    )
                ]
            ),
            tabStateDataByID: [:]
        )
        let store = BrowserStore(
            restoring: restoredSession,
            fallbackURL: try #require(URL(string: "about:blank")),
            sessionStore: nil
        )
        let rootViewController = BrowserRootViewController(
            store: store,
            launchConfiguration: BrowserLaunchConfiguration(initialURL: try #require(URL(string: "about:blank")))
        )
        rootViewController.loadViewIfNeeded()
        rootViewController.viewControllers.first?.loadViewIfNeeded()
        let firstWebView = store.tabs[0].webView
        let secondWebView = store.tabs[1].webView
        var attachTargets: [WKWebView] = []
        rootViewController.setInspectorSessionAttachedForTesting(to: firstWebView)
        rootViewController.onAttachInspectorSessionForTesting = { webView in
            attachTargets.append(webView)
        }

        store.selectTab(id: secondID)
        try await Task.sleep(nanoseconds: 100_000_000)
        await rootViewController.waitForInspectorSessionTransitions()

        #expect(attachTargets.contains { $0 === secondWebView })
    }

    @Test
    func mainSceneDelegateConnectsWithRestoredBrowserStore() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let windowScene = try makeWindowScene()
            let selectedTabID = UUID()
            let restoredURL = try #require(URL(string: "https://example.com/restored"))
            let launchConfiguration = BrowserLaunchConfiguration(
                initialURL: try #require(URL(string: "https://fallback.example/"))
            )
            let snapshot = BrowserSessionSnapshot(
                selectedTabID: selectedTabID,
                tabs: [
                    BrowserTabSnapshot(
                        id: selectedTabID,
                        url: restoredURL,
                        title: "Restored",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabSnapshot.stateFileName(for: selectedTabID)
                    )
                ]
            )
            try sessionStore.save(snapshot: snapshot, tabStateDataByID: [:])
            let sceneDelegate = MonoclyMainSceneDelegate()
            defer {
                sceneDelegate.disconnect(windowScene: windowScene)
            }

            sceneDelegate.connect(
                windowScene: windowScene,
                launchConfiguration: launchConfiguration,
                sessionStore: sessionStore
            )

            let rootViewController = try #require(sceneDelegate.rootViewController)
            #expect(rootViewController.store.selectedTabID == selectedTabID)
            #expect(rootViewController.store.currentURL == restoredURL)
        }
    }

    @Test
    func mainSceneDelegateForcesSaveWhenSceneResignsActive() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let windowScene = try makeWindowScene()
            let launchConfiguration = BrowserLaunchConfiguration(
                initialURL: try #require(URL(string: "https://initial.example/"))
            )
            let sceneDelegate = MonoclyMainSceneDelegate()
            defer {
                sceneDelegate.disconnect(windowScene: windowScene)
            }
            sceneDelegate.connect(
                windowScene: windowScene,
                launchConfiguration: launchConfiguration,
                sessionStore: sessionStore
            )
            let rootViewController = try #require(sceneDelegate.rootViewController)
            let navigatedURL = try #require(URL(string: "https://example.com/navigated"))

            rootViewController.store.loadInitialRequestIfNeeded()
            rootViewController.store.load(url: navigatedURL)
            sceneDelegate.sceneWillResignActive(windowScene)

            let restoredSession = try #require(sessionStore.load())
            #expect(restoredSession.snapshot.selectedTabID == rootViewController.store.selectedTabID)
            #expect(restoredSession.snapshot.tabs.first?.url == navigatedURL)
        }
    }

    @Test
    func mainSceneDelegateForcesSaveWhenSceneDisconnects() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let windowScene = try makeWindowScene()
            let launchConfiguration = BrowserLaunchConfiguration(
                initialURL: try #require(URL(string: "https://initial.example/"))
            )
            let sceneDelegate = MonoclyMainSceneDelegate()
            sceneDelegate.connect(
                windowScene: windowScene,
                launchConfiguration: launchConfiguration,
                sessionStore: sessionStore
            )
            let rootViewController = try #require(sceneDelegate.rootViewController)
            let navigatedURL = try #require(URL(string: "https://example.com/disconnect"))

            rootViewController.store.loadInitialRequestIfNeeded()
            rootViewController.store.load(url: navigatedURL)
            sceneDelegate.disconnect(windowScene: windowScene)

            let restoredSession = try #require(sessionStore.load())
            #expect(restoredSession.snapshot.selectedTabID == rootViewController.store.selectedTabID)
            #expect(restoredSession.snapshot.tabs.first?.url == navigatedURL)
        }
    }

    private func withTemporarySessionStore<T>(
        _ body: (BrowserSessionStore, URL) throws -> T
    ) throws -> T {
        try withTemporaryBrowserSessionDirectory { rootDirectoryURL in
            try body(BrowserSessionStore(rootDirectoryURL: rootDirectoryURL), rootDirectoryURL)
        }
    }

    private func withTemporaryBrowserSessionDirectory<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let rootDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoclyBrowserSession-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootDirectoryURL)
        }
        return try body(rootDirectoryURL)
    }

    private func makeWindowScene() throws -> UIWindowScene {
        try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
    }
}
#endif
