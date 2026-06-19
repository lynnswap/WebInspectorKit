import Foundation
import Testing
@testable import Monocly

#if os(iOS)
import UIKit
import WebKit
import WebInspectorKit

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
            let snapshot = BrowserSessionStore.Snapshot(
                selectedTabID: secondID,
                tabs: [
                    BrowserTabStore.Snapshot(
                        id: firstID,
                        url: try #require(URL(string: "https://example.com/first")),
                        title: "First",
                        createdAt: firstDate,
                        lastUsedAt: firstDate,
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: firstID)
                    ),
                    BrowserTabStore.Snapshot(
                        id: secondID,
                        url: try #require(URL(string: "https://example.com/second")),
                        title: "Second",
                        createdAt: secondDate,
                        lastUsedAt: secondDate,
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: secondID)
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
            let snapshot = BrowserSessionStore.Snapshot(
                selectedTabID: tabID,
                tabs: [
                    BrowserTabStore.Snapshot(
                        id: tabID,
                        url: try #require(URL(string: "https://example.com/missing-state")),
                        title: "Missing State",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 200),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: tabID)
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
            let firstSnapshot = BrowserSessionStore.Snapshot(
                selectedTabID: firstID,
                tabs: [
                    BrowserTabStore.Snapshot(
                        id: firstID,
                        url: try #require(URL(string: "https://example.com/first-scene")),
                        title: "First Scene",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: firstID)
                    )
                ]
            )
            let secondSnapshot = BrowserSessionStore.Snapshot(
                selectedTabID: secondID,
                tabs: [
                    BrowserTabStore.Snapshot(
                        id: secondID,
                        url: try #require(URL(string: "https://example.com/second-scene")),
                        title: "Second Scene",
                        createdAt: Date(timeIntervalSince1970: 200),
                        lastUsedAt: Date(timeIntervalSince1970: 200),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: secondID)
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
        let restoredSession = BrowserSessionStore.RestoredSession(
            snapshot: BrowserSessionStore.Snapshot(
                selectedTabID: secondID,
                tabs: [
                    BrowserTabStore.Snapshot(
                        id: firstID,
                        url: try #require(URL(string: "https://example.com/first")),
                        title: "First",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: firstID)
                    ),
                    BrowserTabStore.Snapshot(
                        id: secondID,
                        url: selectedURL,
                        title: "Selected",
                        createdAt: Date(timeIntervalSince1970: 200),
                        lastUsedAt: Date(timeIntervalSince1970: 300),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: secondID)
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
        let restoredSession = BrowserSessionStore.RestoredSession(
            snapshot: BrowserSessionStore.Snapshot(
                selectedTabID: UUID(),
                tabs: [
                    BrowserTabStore.Snapshot(
                        id: tabID,
                        url: restoredURL,
                        title: "Restored",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: tabID)
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
        let restoredSession = BrowserSessionStore.RestoredSession(
            snapshot: BrowserSessionStore.Snapshot(
                selectedTabID: tabID,
                tabs: [
                    BrowserTabStore.Snapshot(
                        id: tabID,
                        url: restoredURL,
                        title: "Restored",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: tabID)
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
        let restoredSession = BrowserSessionStore.RestoredSession(
            snapshot: BrowserSessionStore.Snapshot(
                selectedTabID: tabID,
                tabs: [
                    BrowserTabStore.Snapshot(
                        id: tabID,
                        url: restoredURL,
                        title: "Restored State",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: tabID)
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
    func restoredInteractionStateNavigationPolicySuppressesAppLinksOnlyDuringHTTPMainFrameRestore() throws {
        let appLinkURL = try #require(URL(string: "https://www.google.com/search?q=monocly"))
        let policy = BrowserTabStore.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: true,
            isMainFrame: true,
            url: appLinkURL,
            shouldOpenAppLinks: true
        )

        #expect(policy?.rawValue == WKNavigationActionPolicy.allow.rawValue + 2)
        #expect(BrowserTabStore.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: false,
            isMainFrame: true,
            url: appLinkURL,
            shouldOpenAppLinks: true
        ) == nil)
        #expect(BrowserTabStore.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: true,
            isMainFrame: false,
            url: appLinkURL,
            shouldOpenAppLinks: true
        ) == nil)
        #expect(BrowserTabStore.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: true,
            isMainFrame: true,
            url: appLinkURL,
            shouldOpenAppLinks: false
        ) == nil)
        #expect(BrowserTabStore.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: true,
            isMainFrame: true,
            url: try #require(URL(string: "google://search?q=monocly")),
            shouldOpenAppLinks: true
        ) == nil)
    }

    @Test
    func explicitNavigationDoesNotSaveStaleRestoredInteractionStateForNewURL() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let tabID = UUID()
            let restoredState = Data("restored-state".utf8)
            let newURL = try #require(URL(string: "https://example.com/new-page"))
            let restoredSession = BrowserSessionStore.RestoredSession(
                snapshot: BrowserSessionStore.Snapshot(
                    selectedTabID: tabID,
                    tabs: [
                        BrowserTabStore.Snapshot(
                            id: tabID,
                            url: try #require(URL(string: "https://example.com/restored-state")),
                            title: "Restored State",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100),
                            stateFileName: BrowserTabStore.Snapshot.stateFileName(for: tabID)
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
            let restoredSession = BrowserSessionStore.RestoredSession(
                snapshot: BrowserSessionStore.Snapshot(
                    selectedTabID: tabID,
                    tabs: [
                        BrowserTabStore.Snapshot(
                            id: tabID,
                            url: restoredURL,
                            title: "Restored State",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100),
                            stateFileName: BrowserTabStore.Snapshot.stateFileName(for: tabID)
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
            let restoredSession = BrowserSessionStore.RestoredSession(
                snapshot: BrowserSessionStore.Snapshot(
                    selectedTabID: selectedID,
                    tabs: [
                        BrowserTabStore.Snapshot(
                            id: selectedID,
                            url: try #require(URL(string: "https://example.com/selected")),
                            title: "Selected",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 200),
                            stateFileName: BrowserTabStore.Snapshot.stateFileName(for: selectedID)
                        ),
                        BrowserTabStore.Snapshot(
                            id: backgroundID,
                            url: try #require(URL(string: "https://example.com/background")),
                            title: "Background",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100),
                            stateFileName: BrowserTabStore.Snapshot.stateFileName(for: backgroundID)
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
    func browserStoreDebouncedAutosaveUsesInjectedScheduler() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let scheduler = ManualDelayScheduler()
            let navigatedURL = try #require(URL(string: "https://example.com/debounced-save"))
            let store = BrowserStore(
                url: try #require(URL(string: "about:blank")),
                automaticallyLoadsInitialRequest: false,
                sessionStore: sessionStore,
                saveDelayScheduler: scheduler
            )

            store.load(url: navigatedURL)

            #expect(scheduler.hasScheduledDelay)
            #expect(sessionStore.load() == nil)

            scheduler.fire()

            let savedSession = try #require(sessionStore.load())
            #expect(savedSession.snapshot.tabs.first?.url == navigatedURL)
            #expect(scheduler.hasScheduledDelay == false)
        }
    }

    @Test
    func browserStoreImmediateSaveCancelsPendingDebounce() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let scheduler = ManualDelayScheduler()
            let navigatedURL = try #require(URL(string: "https://example.com/immediate-save"))
            let store = BrowserStore(
                url: try #require(URL(string: "about:blank")),
                automaticallyLoadsInitialRequest: false,
                sessionStore: sessionStore,
                saveDelayScheduler: scheduler
            )

            store.load(url: navigatedURL)
            #expect(scheduler.hasScheduledDelay)

            store.preserveSession(immediate: true)

            #expect(scheduler.hasScheduledDelay == false)
            let savedSession = try #require(sessionStore.load())
            #expect(savedSession.snapshot.tabs.first?.url == navigatedURL)
        }
    }

    @Test
    func restoredTitleSurvivesInitialEmptyOrNilWebViewTitleObservation() async throws {
        let tabID = UUID()
        let store = BrowserStore(
            restoring: BrowserSessionStore.RestoredSession(
                snapshot: BrowserSessionStore.Snapshot(
                    selectedTabID: tabID,
                    tabs: [
                        BrowserTabStore.Snapshot(
                            id: tabID,
                            url: try #require(URL(string: "https://example.com/restored-title")),
                            title: "Restored Title",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100),
                            stateFileName: BrowserTabStore.Snapshot.stateFileName(for: tabID)
                        )
                    ]
                ),
                tabStateDataByID: [:]
            ),
            fallbackURL: try #require(URL(string: "https://fallback.example/")),
            sessionStore: nil
        )
        let tab = try #require(store.tabs.first)

        await tab.waitUntilTitleObservationApplied()

        #expect(store.tabs[0].snapshot(stateFileName: "tab.state").title == "Restored Title")
        #expect(store.displayTitle == "Restored Title")
    }

    @Test
    func rootReattachesInspectorSessionAfterSelectedTabWebViewChanges() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let restoredSession = BrowserSessionStore.RestoredSession(
            snapshot: BrowserSessionStore.Snapshot(
                selectedTabID: firstID,
                tabs: [
                    BrowserTabStore.Snapshot(
                        id: firstID,
                        url: try #require(URL(string: "about:blank#first")),
                        title: "First",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: firstID)
                    ),
                    BrowserTabStore.Snapshot(
                        id: secondID,
                        url: try #require(URL(string: "about:blank#second")),
                        title: "Second",
                        createdAt: Date(timeIntervalSince1970: 200),
                        lastUsedAt: Date(timeIntervalSince1970: 200),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: secondID)
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
        let selectedWebViewInstalled = WebViewIdentitySignal()
        let inspectorSessionAttached = WebViewIdentitySignal()
        rootViewController.setInspectorSessionAttachedForTesting(to: firstWebView)
        rootViewController.onSelectedWebViewInstalledForTesting = { webView in
            selectedWebViewInstalled.record(webView)
        }
        rootViewController.onAttachInspectorSessionForTesting = { webView in
            inspectorSessionAttached.record(webView)
        }

        store.selectTab(id: secondID)
        await selectedWebViewInstalled.wait(for: secondWebView)
        await rootViewController.waitForInspectorSessionTransitions()
        await inspectorSessionAttached.wait(for: secondWebView)
    }

    @Test
    func attachmentLifecycleAttachesLatestWebViewAfterInFlightSelectionChange() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            store: fixture.store,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )

        lifecycle.request(.attached)
        await actions.waitUntilAttachStarted(count: 1)

        fixture.store.selectTab(id: fixture.secondTabID)
        lifecycle.selectedWebViewDidChange(to: fixture.secondWebView)
        actions.releaseAttach()
        await actions.waitUntilAttachStarted(count: 2)
        actions.releaseAttach()
        await lifecycle.waitForTransitions()

        #expect(actions.attachedWebViews == [fixture.firstWebView, fixture.secondWebView])
        #expect(actions.detachCount == 0)
    }

    @Test
    func attachmentLifecycleFinalizesByDetachingAfterInFlightAttachCompletes() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            store: fixture.store,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )

        lifecycle.request(.attached)
        await actions.waitUntilAttachStarted(count: 1)
        #expect(lifecycle.finalize())

        actions.releaseAttach()
        await actions.waitUntilDetachCount(1)
        await lifecycle.waitForTransitions()
        lifecycle.request(.attached)

        #expect(actions.attachedWebViews == [fixture.firstWebView])
        #expect(actions.detachCount == 1)
    }

    @Test
    func attachmentLifecycleDoesNotAutomaticallyRetryFailedAttach() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            store: fixture.store,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )

        lifecycle.request(.attached)
        await actions.waitUntilAttachStarted(count: 1)
        actions.releaseAttach(result: .failure(NSError(domain: "BrowserSessionRestoreTests", code: 1)))
        await lifecycle.waitForTransitions()

        #expect(actions.attachedWebViews == [fixture.firstWebView])
        #expect(actions.detachCount == 0)

        lifecycle.request(.attached)
        await actions.waitUntilAttachStarted(count: 2)
        actions.releaseAttach()
        await lifecycle.waitForTransitions()

        #expect(actions.attachedWebViews == [fixture.firstWebView, fixture.firstWebView])
        #expect(actions.detachCount == 0)
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
            let snapshot = BrowserSessionStore.Snapshot(
                selectedTabID: selectedTabID,
                tabs: [
                    BrowserTabStore.Snapshot(
                        id: selectedTabID,
                        url: restoredURL,
                        title: "Restored",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: selectedTabID)
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

    private struct AttachmentLifecycleFixture {
        var secondTabID: UUID
        var store: BrowserStore
        var firstWebView: WKWebView
        var secondWebView: WKWebView
    }

    private func makeAttachmentLifecycleFixture() throws -> AttachmentLifecycleFixture {
        let firstID = UUID()
        let secondID = UUID()
        let restoredSession = BrowserSessionStore.RestoredSession(
            snapshot: BrowserSessionStore.Snapshot(
                selectedTabID: firstID,
                tabs: [
                    BrowserTabStore.Snapshot(
                        id: firstID,
                        url: try #require(URL(string: "about:blank#first")),
                        title: "First",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: firstID)
                    ),
                    BrowserTabStore.Snapshot(
                        id: secondID,
                        url: try #require(URL(string: "about:blank#second")),
                        title: "Second",
                        createdAt: Date(timeIntervalSince1970: 200),
                        lastUsedAt: Date(timeIntervalSince1970: 200),
                        stateFileName: BrowserTabStore.Snapshot.stateFileName(for: secondID)
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
        return AttachmentLifecycleFixture(
            secondTabID: secondID,
            store: store,
            firstWebView: store.tabs[0].webView,
            secondWebView: store.tabs[1].webView
        )
    }

    @MainActor
    private final class ManualDelayScheduler: MainActorDelayScheduling {
        private var operation: (@Sendable @MainActor () -> Void)?

        var hasScheduledDelay: Bool {
            operation != nil
        }

        func cancel() {
            operation = nil
        }

        func schedule(after duration: Duration, operation: @escaping @Sendable @MainActor () -> Void) {
            self.operation = operation
        }

        func schedule(nanoseconds: UInt64, operation: @escaping @Sendable @MainActor () -> Void) {
            self.operation = operation
        }

        func fire() {
            let operation = operation
            self.operation = nil
            operation?()
        }
    }

    @MainActor
    private final class WebViewIdentitySignal {
        private var seenWebViewIDs: Set<ObjectIdentifier> = []
        private var waitersByWebViewID: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]

        func record(_ webView: WKWebView) {
            let webViewID = ObjectIdentifier(webView)
            seenWebViewIDs.insert(webViewID)
            let waiters = waitersByWebViewID.removeValue(forKey: webViewID) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }

        func wait(for webView: WKWebView) async {
            let webViewID = ObjectIdentifier(webView)
            guard seenWebViewIDs.contains(webViewID) == false else {
                return
            }
            await withCheckedContinuation { continuation in
                waitersByWebViewID[webViewID, default: []].append(continuation)
            }
        }
    }

    @MainActor
    private final class ControlledInspectorAttachmentActions {
        private(set) var attachedWebViews: [WKWebView] = []
        private(set) var detachCount = 0
        private var attachContinuation: CheckedContinuation<Void, Never>?
        private var attachResult: Result<Void, any Error> = .success(())
        private var attachStartedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var detachWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func attach(_ inspectorSession: WebInspectorSession, _ webView: WKWebView) async throws {
            attachedWebViews.append(webView)
            resumeAttachStartedWaiters()
            await withCheckedContinuation { continuation in
                attachContinuation = continuation
            }
            let result = attachResult
            attachResult = .success(())
            try result.get()
        }

        func detach(_ inspectorSession: WebInspectorSession) async {
            detachCount += 1
            resumeDetachWaiters()
        }

        func waitUntilAttachStarted(count: Int) async {
            guard attachedWebViews.count < count else {
                return
            }
            await withCheckedContinuation { continuation in
                attachStartedWaiters.append((count, continuation))
            }
        }

        func waitUntilDetachCount(_ count: Int) async {
            guard detachCount < count else {
                return
            }
            await withCheckedContinuation { continuation in
                detachWaiters.append((count, continuation))
            }
        }

        func releaseAttach(result: Result<Void, any Error> = .success(())) {
            attachResult = result
            let continuation = attachContinuation
            attachContinuation = nil
            continuation?.resume()
        }

        private func resumeAttachStartedWaiters() {
            let readyWaiters = attachStartedWaiters.filter { attachedWebViews.count >= $0.0 }
            attachStartedWaiters.removeAll { attachedWebViews.count >= $0.0 }
            for waiter in readyWaiters {
                waiter.1.resume()
            }
        }

        private func resumeDetachWaiters() {
            let readyWaiters = detachWaiters.filter { detachCount >= $0.0 }
            detachWaiters.removeAll { detachCount >= $0.0 }
            for waiter in readyWaiters {
                waiter.1.resume()
            }
        }
    }
}
#endif
