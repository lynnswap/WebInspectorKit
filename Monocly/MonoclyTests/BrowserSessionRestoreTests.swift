import Foundation
import Observation
import ObservationBridge
import Testing
@testable import Monocly

#if os(iOS)
import UIKit
import WebKit
import WebInspectorKit
import WKViewportCoordinator
import WebKitScreenTimeWorkaround

@Suite(.serialized)
@MainActor
struct BrowserSessionRestoreTests {
    init() async throws {
        if #available(iOS 26.1, *) {
            try ScreenTimeWorkaround.install()
        }
        try await WebInspectorSession.prepare()
    }

    @Test
    func sessionStoreSavesAndLoadsMultipleTabsAndStateBlobs() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let firstID = UUID()
            let secondID = UUID()
            let firstDate = Date(timeIntervalSince1970: 100)
            let secondDate = Date(timeIntervalSince1970: 200)
            let snapshot = BrowserSession.Snapshot(
                selectedTabID: secondID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: firstID,
                        url: try #require(URL(string: "https://example.com/first")),
                        title: "First",
                        createdAt: firstDate,
                        lastUsedAt: firstDate
                    ),
                    BrowserSession.TabSnapshot(
                        id: secondID,
                        url: try #require(URL(string: "https://example.com/second")),
                        title: "Second",
                        createdAt: secondDate,
                        lastUsedAt: secondDate
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
            let snapshot = BrowserSession.Snapshot(
                selectedTabID: tabID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: tabID,
                        url: try #require(URL(string: "https://example.com/missing-state")),
                        title: "Missing State",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 200)
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
            let firstStore = BrowserSession.FileStorage(
                sceneSessionPersistentIdentifier: "scene/a",
                browserSessionDirectoryURL: browserSessionDirectoryURL
            )
            let secondStore = BrowserSession.FileStorage(
                sceneSessionPersistentIdentifier: "scene/b",
                browserSessionDirectoryURL: browserSessionDirectoryURL
            )
            let firstID = UUID()
            let secondID = UUID()
            let firstSnapshot = BrowserSession.Snapshot(
                selectedTabID: firstID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: firstID,
                        url: try #require(URL(string: "https://example.com/first-scene")),
                        title: "First Scene",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100)
                    )
                ]
            )
            let secondSnapshot = BrowserSession.Snapshot(
                selectedTabID: secondID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: secondID,
                        url: try #require(URL(string: "https://example.com/second-scene")),
                        title: "Second Scene",
                        createdAt: Date(timeIntervalSince1970: 200),
                        lastUsedAt: Date(timeIntervalSince1970: 200)
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
    func standardLaunchConfigurationUsesGoogleAndPersistentSessionWithoutOpeningInspector() throws {
        let configuration = try BrowserLaunchConfiguration.resolve(environment: [:])

        #expect(configuration.initialURL == URL(string: "https://www.google.com"))
        #expect(configuration.sessionPersistenceMode == .persistent)
        #expect(configuration.shouldAutoOpenInspector == false)
    }

    @Test
    func launchConfigurationUsesEphemeralSessionPersistenceForXCTestAndPreviews() throws {
        let testConfiguration = BrowserLaunchConfiguration.current(environment: [
            "XCTestConfigurationFilePath": "/tmp/Monocly.xctestconfiguration",
            BrowserLaunchConfiguration.inspectorFixtureURLEnvironmentKey: "http://127.0.0.1:8765/a",
        ])
        let previewConfiguration = BrowserLaunchConfiguration.current(environment: [
            "XCODE_RUNNING_FOR_PREVIEWS": "1"
        ])

        #expect(testConfiguration.initialURL == URL(string: "about:blank"))
        #expect(testConfiguration.sessionPersistenceMode == .ephemeral)
        #expect(testConfiguration.shouldAutoOpenInspector == false)
        #expect(previewConfiguration.initialURL == URL(string: "about:blank"))
        #expect(previewConfiguration.sessionPersistenceMode == .ephemeral)
        #expect(previewConfiguration.shouldAutoOpenInspector == false)
    }

    @Test
    func xcodeTestOrPreviewConfigurationAllowsExplicitInitialURLWithoutChangingRuntimePolicy() throws {
        let initialURL = try #require(URL(string: "https://test.example/initial"))
        let configuration = BrowserLaunchConfiguration.xcodeTestOrPreview(initialURL: initialURL)

        #expect(configuration.initialURL == initialURL)
        #expect(configuration.sessionPersistenceMode == .ephemeral)
        #expect(configuration.shouldAutoOpenInspector == false)
    }

    @Test
    func inspectorFixtureLaunchConfigurationKeepsItsThreeRuntimeValuesAtomic() throws {
        let fixtureURL = try #require(URL(string: "http://127.0.0.1:8765/a?visit=a1"))
        let configuration = try BrowserLaunchConfiguration.resolve(environment: [
            BrowserLaunchConfiguration.inspectorFixtureURLEnvironmentKey: fixtureURL.absoluteString
        ])

        #expect(configuration.initialURL == fixtureURL)
        #expect(configuration.sessionPersistenceMode == .ephemeral)
        #expect(configuration.shouldAutoOpenInspector)
    }

    @Test
    func inspectorFixtureLaunchConfigurationAcceptsLocalhost() throws {
        let fixtureURL = try #require(URL(string: "http://localhost:8765/a"))
        let configuration = try BrowserLaunchConfiguration.resolve(environment: [
            BrowserLaunchConfiguration.inspectorFixtureURLEnvironmentKey: fixtureURL.absoluteString
        ])

        #expect(configuration.initialURL == fixtureURL)
    }

    @Test
    func inspectorFixtureLaunchConfigurationRejectsNonHTTPAndNonLoopbackURLs() {
        #expect(throws: BrowserLaunchConfiguration.InspectorFixtureURLValidationError.requiresAbsoluteHTTPURL) {
            try BrowserLaunchConfiguration.resolve(environment: [
                BrowserLaunchConfiguration.inspectorFixtureURLEnvironmentKey: "https://127.0.0.1:8765/a"
            ])
        }
        #expect(throws: BrowserLaunchConfiguration.InspectorFixtureURLValidationError.requiresAbsoluteHTTPURL) {
            try BrowserLaunchConfiguration.resolve(environment: [
                BrowserLaunchConfiguration.inspectorFixtureURLEnvironmentKey: "/a"
            ])
        }
        #expect(throws: BrowserLaunchConfiguration.InspectorFixtureURLValidationError.requiresLoopbackHost) {
            try BrowserLaunchConfiguration.resolve(environment: [
                BrowserLaunchConfiguration.inspectorFixtureURLEnvironmentKey: "http://example.com/a"
            ])
        }
    }

    @Test
    func ephemeralPersistenceDoesNotRestoreOrScheduleAutosave() throws {
        let scheduler = ManualDelayScheduler()
        let browserWindow = BrowserWindow(
            initialState: .fresh(
                url: try #require(URL(string: "about:blank")),
                automaticallyLoadsInitialRequest: false
            ),
            sessionPersistence: .ephemeral,
            saveDelayScheduler: scheduler
        )

        #expect(BrowserSession.Persistence.ephemeral.restoredState() == nil)

        browserWindow.load(url: try #require(URL(string: "https://example.com/ephemeral")))
        browserWindow.preserveSession(immediate: true)

        #expect(scheduler.hasScheduledDelay == false)
    }

    @Test
    func persistentPersistenceRestoresStoredSessionBeforeFallback() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let tabID = UUID()
            let restoredURL = try #require(URL(string: "https://example.com/persistent-restored"))
            let snapshot = BrowserSession.Snapshot(
                selectedTabID: tabID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: tabID,
                        url: restoredURL,
                        title: "Persistent",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100)
                    )
                ]
            )
            try sessionStore.save(snapshot: snapshot, tabStateDataByID: [:])

            let persistence = BrowserSession.Persistence.persistent(storage: sessionStore)
            let browserWindow = BrowserWindow(
                initialState: .restored(
                    persistence.restoredState(),
                    fallbackURL: try #require(URL(string: "https://fallback.example/"))
                ),
                sessionPersistence: persistence
            )

            #expect(browserWindow.selectedTabID == tabID)
            #expect(browserWindow.currentURL == restoredURL)
        }
    }

    @Test
    func fileStorageLoadsLegacyStateFileNameWireSnapshot() throws {
        try withTemporarySessionStore { sessionStore, rootDirectoryURL in
            struct LegacyStoredSnapshot: Codable {
                let schemaVersion: Int
                let selectedTabID: UUID
                let tabs: [LegacyStoredTabSnapshot]
            }

            struct LegacyStoredTabSnapshot: Codable {
                let id: UUID
                let url: URL
                let title: String?
                let createdAt: Date
                let lastUsedAt: Date
                let stateFileName: String
            }

            let tabID = UUID()
            let stateFileName = "legacy-tab.state"
            let stateData = Data("legacy-state".utf8)
            let expectedSnapshot = BrowserSession.Snapshot(
                selectedTabID: tabID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: tabID,
                        url: try #require(URL(string: "https://example.com/legacy")),
                        title: "Legacy",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 200)
                    )
                ]
            )
            let legacySnapshot = LegacyStoredSnapshot(
                schemaVersion: BrowserSession.Snapshot.currentSchemaVersion,
                selectedTabID: expectedSnapshot.selectedTabID,
                tabs: expectedSnapshot.tabs.map { tab in
                    LegacyStoredTabSnapshot(
                        id: tab.id,
                        url: tab.url,
                        title: tab.title,
                        createdAt: tab.createdAt,
                        lastUsedAt: tab.lastUsedAt,
                        stateFileName: stateFileName
                    )
                }
            )

            try FileManager.default.createDirectory(
                at: rootDirectoryURL.appendingPathComponent("tabs", isDirectory: true),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(legacySnapshot)
                .write(to: rootDirectoryURL.appendingPathComponent("session.json"), options: .atomic)
            try stateData.write(
                to: rootDirectoryURL
                    .appendingPathComponent("tabs", isDirectory: true)
                    .appendingPathComponent(stateFileName),
                options: .atomic
            )

            let restoredState = try #require(sessionStore.load())
            #expect(restoredState.snapshot == expectedSnapshot)
            #expect(restoredState.tabStateDataByID[tabID] == stateData)
        }
    }

    @Test
    func browserStoreCreatesFallbackTabWithoutSnapshot() throws {
        let fallbackURL = try #require(URL(string: "https://fallback.example/"))
        let store = BrowserWindow(
            initialState: .restored(
                nil,
                fallbackURL: fallbackURL
            ),
            sessionPersistence: .ephemeral
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
        let restoredSession = BrowserSession.RestoredState(
            snapshot: BrowserSession.Snapshot(
                selectedTabID: secondID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: firstID,
                        url: try #require(URL(string: "https://example.com/first")),
                        title: "First",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100)
                    ),
                    BrowserSession.TabSnapshot(
                        id: secondID,
                        url: selectedURL,
                        title: "Selected",
                        createdAt: Date(timeIntervalSince1970: 200),
                        lastUsedAt: Date(timeIntervalSince1970: 300)
                    )
                ]
            ),
            tabStateDataByID: [:]
        )

        let store = BrowserWindow(
            initialState: .restored(
                restoredSession,
                fallbackURL: fallbackURL
            ),
            sessionPersistence: .ephemeral
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
        let restoredSession = BrowserSession.RestoredState(
            snapshot: BrowserSession.Snapshot(
                selectedTabID: UUID(),
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: tabID,
                        url: restoredURL,
                        title: "Restored",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100)
                    )
                ]
            ),
            tabStateDataByID: [:]
        )

        let store = BrowserWindow(
            initialState: .restored(
                restoredSession,
                fallbackURL: try #require(URL(string: "https://fallback.example/"))
            ),
            sessionPersistence: .ephemeral
        )

        #expect(store.selectedTabID == tabID)
        #expect(store.currentURL == restoredURL)
    }

    @Test
    func restoredStoreDoesNotReplaceSelectedTabURLWithFallbackInitialURL() throws {
        let tabID = UUID()
        let restoredURL = try #require(URL(string: "https://example.com/restored"))
        let fallbackURL = try #require(URL(string: "https://fallback.example/"))
        let restoredSession = BrowserSession.RestoredState(
            snapshot: BrowserSession.Snapshot(
                selectedTabID: tabID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: tabID,
                        url: restoredURL,
                        title: "Restored",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100)
                    )
                ]
            ),
            tabStateDataByID: [:]
        )
        let store = BrowserWindow(
            initialState: .restored(
                restoredSession,
                fallbackURL: fallbackURL
            ),
            sessionPersistence: .ephemeral
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
        let restoredSession = BrowserSession.RestoredState(
            snapshot: BrowserSession.Snapshot(
                selectedTabID: tabID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: tabID,
                        url: restoredURL,
                        title: "Restored State",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100)
                    )
                ]
            ),
            tabStateDataByID: [tabID: restoredState]
        )
        let store = BrowserWindow(
            initialState: .restored(
                restoredSession,
                fallbackURL: try #require(URL(string: "https://fallback.example/"))
            ),
            sessionPersistence: .ephemeral
        )
        let tab = try #require(store.selectedTab)

        store.loadInitialRequestIfNeeded()

        #expect(tab.initialRequestLoadCount == 0)
        #expect(store.currentURL == restoredURL)
    }

    @Test
    func restoredInteractionStateNavigationPolicySuppressesAppLinksOnlyDuringHTTPMainFrameRestore() throws {
        let appLinkURL = try #require(URL(string: "https://app-link.test/search?q=monocly"))
        let policy = BrowserTab.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: true,
            targetFrameIsMainFrame: true,
            url: appLinkURL,
            shouldOpenAppLinks: true
        )

        #expect(policy?.rawValue == WKNavigationActionPolicy.allow.rawValue + 2)
        #expect(BrowserTab.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: false,
            targetFrameIsMainFrame: true,
            url: appLinkURL,
            shouldOpenAppLinks: true
        ) == nil)
        #expect(BrowserTab.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: true,
            targetFrameIsMainFrame: false,
            url: appLinkURL,
            shouldOpenAppLinks: true
        ) == nil)
        #expect(BrowserTab.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: true,
            targetFrameIsMainFrame: nil,
            url: appLinkURL,
            shouldOpenAppLinks: true
        ) == nil)
        #expect(BrowserTab.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: true,
            targetFrameIsMainFrame: true,
            url: appLinkURL,
            shouldOpenAppLinks: false
        ) == nil)
        #expect(BrowserTab.restoredInteractionStateNavigationPolicy(
            isRestoringInteractionStateNavigation: true,
            targetFrameIsMainFrame: true,
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
            let restoredSession = BrowserSession.RestoredState(
                snapshot: BrowserSession.Snapshot(
                    selectedTabID: tabID,
                    tabs: [
                        BrowserSession.TabSnapshot(
                            id: tabID,
                            url: try #require(URL(string: "https://example.com/restored-state")),
                            title: "Restored State",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100)
                        )
                    ]
                ),
                tabStateDataByID: [tabID: restoredState]
            )
            let store = BrowserWindow(
                initialState: .restored(
                    restoredSession,
                    fallbackURL: try #require(URL(string: "https://fallback.example/"))
                ),
                sessionPersistence: .persistent(storage: sessionStore)
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
            let restoredSession = BrowserSession.RestoredState(
                snapshot: BrowserSession.Snapshot(
                    selectedTabID: tabID,
                    tabs: [
                        BrowserSession.TabSnapshot(
                            id: tabID,
                            url: restoredURL,
                            title: "Restored State",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100)
                        )
                    ]
                ),
                tabStateDataByID: [tabID: restoredState]
            )
            let store = BrowserWindow(
                initialState: .restored(
                    restoredSession,
                    fallbackURL: try #require(URL(string: "https://fallback.example/"))
                ),
                sessionPersistence: .persistent(storage: sessionStore)
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
        let store = BrowserWindow(
            initialState: .fresh(
                url: try #require(URL(string: "about:blank")),
                automaticallyLoadsInitialRequest: false
            ),
            sessionPersistence: .ephemeral
        )
        let tab = try #require(store.selectedTab)

        tab.webView(tab.webView, didStartProvisionalNavigation: nil)
        tab.estimatedProgress = 1

        #expect(tab.isShowingProgress)
        #expect(store.isShowingProgress)
    }

    @Test
    func explicitNavigationShowsProgressImmediatelyFromCompletedPreviousProgress() throws {
        let store = BrowserWindow(
            initialState: .fresh(
                url: try #require(URL(string: "about:blank")),
                automaticallyLoadsInitialRequest: false
            ),
            sessionPersistence: .ephemeral
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
        let store = BrowserWindow(
            initialState: .fresh(
                url: try #require(URL(string: "about:blank")),
                automaticallyLoadsInitialRequest: false
            ),
            sessionPersistence: .ephemeral
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
            let restoredSession = BrowserSession.RestoredState(
                snapshot: BrowserSession.Snapshot(
                    selectedTabID: selectedID,
                    tabs: [
                        BrowserSession.TabSnapshot(
                            id: selectedID,
                            url: try #require(URL(string: "https://example.com/selected")),
                            title: "Selected",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 200)
                        ),
                        BrowserSession.TabSnapshot(
                            id: backgroundID,
                            url: try #require(URL(string: "https://example.com/background")),
                            title: "Background",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100)
                        )
                    ]
                ),
                tabStateDataByID: [backgroundID: backgroundState]
            )
            let store = BrowserWindow(
                initialState: .restored(
                    restoredSession,
                    fallbackURL: try #require(URL(string: "https://fallback.example/"))
                ),
                sessionPersistence: .persistent(storage: sessionStore)
            )

            store.loadInitialRequestIfNeeded()
            store.preserveSession(immediate: true)

            let savedSession = try #require(sessionStore.load())
            #expect(savedSession.tabStateDataByID[backgroundID] == backgroundState)
        }
    }

    @Test
    func browserStoreDebouncedAutosaveUsesInjectedScheduler() async throws {
        try await withTemporarySessionStore { sessionStore, _ in
            let scheduler = ManualDelayScheduler()
            let navigatedURL = try #require(URL(string: "https://example.com/debounced-save"))
            let store = BrowserWindow(
                initialState: .fresh(
                    url: try #require(URL(string: "about:blank")),
                    automaticallyLoadsInitialRequest: false
                ),
                sessionPersistence: .persistent(storage: sessionStore),
                saveDelayScheduler: scheduler
            )

            store.load(url: navigatedURL)

            try await scheduler.waitUntilScheduled()
            #expect(sessionStore.load() == nil)

            scheduler.fire()

            let savedSession = try #require(sessionStore.load())
            #expect(savedSession.snapshot.tabs.first?.url == navigatedURL)
            #expect(scheduler.hasScheduledDelay == false)
        }
    }

    @Test
    func browserStoreImmediateSaveCancelsPendingDebounce() async throws {
        try await withTemporarySessionStore { sessionStore, _ in
            let scheduler = ManualDelayScheduler()
            let navigatedURL = try #require(URL(string: "https://example.com/immediate-save"))
            let store = BrowserWindow(
                initialState: .fresh(
                    url: try #require(URL(string: "about:blank")),
                    automaticallyLoadsInitialRequest: false
                ),
                sessionPersistence: .persistent(storage: sessionStore),
                saveDelayScheduler: scheduler
            )

            store.load(url: navigatedURL)
            try await scheduler.waitUntilScheduled()

            store.preserveSession(immediate: true)

            #expect(scheduler.hasScheduledDelay == false)
            let savedSession = try #require(sessionStore.load())
            #expect(savedSession.snapshot.tabs.first?.url == navigatedURL)
        }
    }

    @Test
    func childTabSnapshotMutationSchedulesAutosaveWithoutWindowRevision() async throws {
        try await withTemporarySessionStore { sessionStore, _ in
            let scheduler = ManualDelayScheduler()
            let store = BrowserWindow(
                initialState: .fresh(
                    url: try #require(URL(string: "about:blank")),
                    automaticallyLoadsInitialRequest: false
                ),
                sessionPersistence: .persistent(storage: sessionStore),
                saveDelayScheduler: scheduler
            )
            let tab = try #require(store.selectedTab)

            try await requireTestEvent { tab.titleObservationAppliedCountForTesting >= 1 }
            tab.pageTitle = "Observed Title"

            try await scheduler.waitUntilScheduled()

            scheduler.fire()

            let savedSession = try #require(sessionStore.load())
            #expect(savedSession.snapshot.tabs.first?.title == "Observed Title")
        }
    }

    @Test
    func restoredTitleSurvivesInitialEmptyOrNilWebViewTitleObservation() async throws {
        let tabID = UUID()
        let store = BrowserWindow(
            initialState: .restored(
                BrowserSession.RestoredState(
                snapshot: BrowserSession.Snapshot(
                    selectedTabID: tabID,
                    tabs: [
                        BrowserSession.TabSnapshot(
                            id: tabID,
                            url: try #require(URL(string: "https://example.com/restored-title")),
                            title: "Restored Title",
                            createdAt: Date(timeIntervalSince1970: 100),
                            lastUsedAt: Date(timeIntervalSince1970: 100)
                        )
                    ]
                ),
                tabStateDataByID: [:]
            ),
                fallbackURL: try #require(URL(string: "https://fallback.example/"))
            ),
            sessionPersistence: .ephemeral
        )
        let tab = try #require(store.tabs.first)

        try await requireTestEvent { tab.titleObservationAppliedCountForTesting >= 1 }

        #expect(store.tabs[0].snapshot().title == "Restored Title")
        #expect(store.displayTitle == "Restored Title")
    }

    @Test
    func rootReattachesInspectorSessionAfterSelectedTabWebViewChanges() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let restoredSession = BrowserSession.RestoredState(
            snapshot: BrowserSession.Snapshot(
                selectedTabID: firstID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: firstID,
                        url: try #require(URL(string: "about:blank#first")),
                        title: "First",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100)
                    ),
                    BrowserSession.TabSnapshot(
                        id: secondID,
                        url: try #require(URL(string: "about:blank#second")),
                        title: "Second",
                        createdAt: Date(timeIntervalSince1970: 200),
                        lastUsedAt: Date(timeIntervalSince1970: 200)
                    )
                ]
            ),
            tabStateDataByID: [:]
        )
        let store = BrowserWindow(
            initialState: .restored(
                restoredSession,
                fallbackURL: try #require(URL(string: "about:blank"))
            ),
            sessionPersistence: .ephemeral
        )
        let rootViewController = BrowserRootViewController(
            browserWindow: store,
            launchConfiguration: .xcodeTestOrPreview()
        )
        rootViewController.loadViewIfNeeded()
        rootViewController.viewControllers.first?.loadViewIfNeeded()
        let firstWebView = store.tabs[0].webView
        let secondWebView = store.tabs[1].webView
        firstWebView.underPageBackgroundColor = .white
        secondWebView.underPageBackgroundColor = .black
        let selectedWebViewInstalled = WebViewIdentitySignal()
        rootViewController.setInspectorSessionAttachedForTesting(to: firstWebView)
        rootViewController.onSelectedWebViewInstalledForTesting = { webView in
            selectedWebViewInstalled.record(webView)
        }

        store.selectTab(id: secondID)
        try await selectedWebViewInstalled.wait(for: secondWebView)
        await rootViewController.waitForInspectorSessionTransitions()

        #expect(rootViewController.inspectorSession.pageUserInterfaceStyle == .dark)
    }

    @Test
    func pageObservationTokenUpdatesChromeFromSelectedTabMutation() async throws {
        let initialURL = try #require(URL(string: "about:blank"))
        let scheduler = ManualDelayScheduler()
        let store = BrowserWindow(
            initialState: .fresh(
                url: initialURL,
                automaticallyLoadsInitialRequest: false
            ),
            sessionPersistence: .ephemeral
        )
        let pageViewController = BrowserPageViewController(
            browserWindow: store,
            inspectorSession: WebInspectorSession(),
            launchConfiguration: .xcodeTestOrPreview(initialURL: initialURL),
            progressHideScheduler: scheduler
        )

        let bindingCompleted = TestEventSignal()
        pageViewController.onSelectedTabBindingCompletedForTesting = bindingCompleted.record
        defer { pageViewController.onSelectedTabBindingCompletedForTesting = nil }
        pageViewController.loadViewIfNeeded()
        let tab = try #require(store.selectedTab)
        try await bindingCompleted.wait(for: 1)
        try await requireTestEvent { tab.titleObservationAppliedCountForTesting >= 1 }

        tab.pageTitle = "Native Title"
        tab.canGoBack = true
        tab.canGoForward = true
        tab.isLoading = true
        tab.estimatedProgress = 0.42
        tab.underPageBackgroundColor = .systemPink

        try #require(await waitForSelectedTabRendering(in: pageViewController) {
            pageViewController.navigationItem.title == "Native Title"
        })

        #expect(pageViewController.navigationItem.title == "Native Title")
        #expect(pageViewController.backButtonItemForTesting.isEnabled)
        #expect(pageViewController.forwardButtonItemForTesting.isEnabled)
        #expect(pageViewController.progressViewForTesting.isHidden == false)
        #expect(abs(pageViewController.progressViewForTesting.progress - Float(0.42)) < 0.001)
        #expect(pageViewController.view.backgroundColor == .systemPink)
    }

    @Test
    func historyButtonItemsKeepImagesWhenPrimaryActionsAreInstalled() throws {
        let initialURL = try #require(URL(string: "about:blank"))
        let store = BrowserWindow(
            initialState: .fresh(
                url: initialURL,
                automaticallyLoadsInitialRequest: false
            ),
            sessionPersistence: .ephemeral
        )
        let pageViewController = BrowserPageViewController(
            browserWindow: store,
            inspectorSession: WebInspectorSession(),
            launchConfiguration: .xcodeTestOrPreview(initialURL: initialURL),
            progressHideScheduler: ManualDelayScheduler()
        )

        pageViewController.loadViewIfNeeded()
        let backButtonItem = pageViewController.backButtonItemForTesting
        let forwardButtonItem = pageViewController.forwardButtonItemForTesting

        #expect(backButtonItem.image != nil)
        #expect(backButtonItem.primaryAction?.image != nil)
        #expect(forwardButtonItem.image != nil)
        #expect(forwardButtonItem.primaryAction?.image != nil)
    }

    @Test
    func toolbarItemsAreNotRecreatedForSelectedTabRenderingChanges() async throws {
        let initialURL = try #require(URL(string: "about:blank"))
        let store = BrowserWindow(
            initialState: .fresh(
                url: initialURL,
                automaticallyLoadsInitialRequest: false
            ),
            sessionPersistence: .ephemeral
        )
        let pageViewController = BrowserPageViewController(
            browserWindow: store,
            inspectorSession: WebInspectorSession(),
            launchConfiguration: .xcodeTestOrPreview(initialURL: initialURL),
            progressHideScheduler: ManualDelayScheduler()
        )

        let bindingCompleted = TestEventSignal()
        pageViewController.onSelectedTabBindingCompletedForTesting = bindingCompleted.record
        defer { pageViewController.onSelectedTabBindingCompletedForTesting = nil }
        pageViewController.loadViewIfNeeded()
        let tab = try #require(store.selectedTab)
        try await bindingCompleted.wait(for: 1)
        try await requireTestEvent { tab.titleObservationAppliedCountForTesting >= 1 }
        let backButtonItem = pageViewController.backButtonItemForTesting
        let forwardButtonItem = pageViewController.forwardButtonItemForTesting
        let inspectorButtonItem = pageViewController.inspectorButtonItemForTesting

        tab.pageTitle = "Updated Title"
        tab.isLoading = true
        tab.estimatedProgress = 0.75
        try #require(await waitForSelectedTabRendering(in: pageViewController) {
            pageViewController.navigationItem.title == "Updated Title"
                && pageViewController.progressViewForTesting.isHidden == false
                && abs(pageViewController.progressViewForTesting.progress - Float(0.75)) < 0.001
        })

        #expect(pageViewController.backButtonItemForTesting === backButtonItem)
        #expect(pageViewController.forwardButtonItemForTesting === forwardButtonItem)
        #expect(pageViewController.inspectorButtonItemForTesting === inspectorButtonItem)

        let installedChromeItems = pageViewController.toolbarItems
            ?? pageViewController.navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
            + pageViewController.navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
        #expect(installedChromeItems.contains { $0 === backButtonItem })
        #expect(installedChromeItems.contains { $0 === forwardButtonItem })
        #expect(installedChromeItems.contains { $0 === inspectorButtonItem })
    }

    @Test
    func inspectorSheetDismissReenablesExistingToolbarButtonWithoutTraitRefresh() async throws {
        let initialURL = try #require(URL(string: "about:blank"))
        let store = BrowserWindow(
            initialState: .fresh(
                url: initialURL,
                automaticallyLoadsInitialRequest: false
            ),
            sessionPersistence: .ephemeral
        )
        let pageViewController = BrowserPageViewController(
            browserWindow: store,
            inspectorSession: WebInspectorSession(),
            launchConfiguration: .xcodeTestOrPreview(initialURL: initialURL),
            progressHideScheduler: ManualDelayScheduler()
        )
        let navigationController = UINavigationController(rootViewController: pageViewController)
        let window = UIWindow(windowScene: try makeWindowScene())
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        defer {
            navigationController.dismiss(animated: false)
            window.isHidden = true
        }
        pageViewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        try #require(await waitForInspectorPresentationRendering(in: pageViewController) {
            pageViewController.inspectorPresentationObservationIsActiveForTesting
        })
        let inspectorButtonItem = pageViewController.inspectorButtonItemForTesting
        #expect(inspectorButtonItem.isEnabled)

        #expect(pageViewController.openInspectorAsSheetForTesting())
        let sheetController = try #require(pageViewController.presentedInspectorSheetForTesting)
        #expect(sheetController.automaticallyDetachesOnDismiss == false)
        try #require(await waitForInspectorPresentationRendering(in: pageViewController) {
            inspectorButtonItem.isEnabled == false
        })

        let presentationController = try #require(sheetController.presentationController)
        presentationController.delegate?.presentationControllerDidDismiss?(presentationController)

        try #require(await waitForInspectorPresentationRendering(in: pageViewController) {
            pageViewController.presentedInspectorSheetForTesting == nil
                && inspectorButtonItem.isEnabled
        })
        #expect(pageViewController.inspectorButtonItemForTesting === inspectorButtonItem)
    }

    @Test
    func javaScriptDialogPresenterFollowsPresentedInspector() throws {
        let fixture = try makeJavaScriptDialogFixture()
        defer { fixture.cleanup() }

        #expect(fixture.tab.findPresenter(for: fixture.tab.webView) === fixture.inspectorViewController)
    }

    @Test
    func javaScriptAlertDelegatesToDialogPresenterAboveInspectorAndResumesOnCompletion() async throws {
        let dialogPresenter = JavaScriptDialogPresenterSpy()
        let fixture = try makeJavaScriptDialogFixture(dialogPresenter: dialogPresenter)
        defer { fixture.cleanup() }

        await fixture.tab.presentJavaScriptAlert(
            message: "Fixture alert",
            webView: fixture.tab.webView
        )

        #expect(dialogPresenter.alertMessage == "Fixture alert")
        #expect(dialogPresenter.presenter === fixture.inspectorViewController)
        #expect(dialogPresenter.alertPresentationCount == 1)
    }

    @Test
    func javaScriptConfirmDelegatesToDialogPresenterAboveInspectorAndReturnsCompletionResult() async throws {
        let dialogPresenter = JavaScriptDialogPresenterSpy(confirmResult: false)
        let fixture = try makeJavaScriptDialogFixture(dialogPresenter: dialogPresenter)
        defer { fixture.cleanup() }

        let result = await fixture.tab.presentJavaScriptConfirm(
            message: "Fixture confirm",
            webView: fixture.tab.webView
        )

        #expect(result == false)
        #expect(dialogPresenter.confirmMessage == "Fixture confirm")
        #expect(dialogPresenter.presenter === fixture.inspectorViewController)
        #expect(dialogPresenter.confirmPresentationCount == 1)
    }

    @Test
    func javaScriptPromptDelegatesToDialogPresenterAboveInspectorAndReturnsCompletionText() async throws {
        let dialogPresenter = JavaScriptDialogPresenterSpy(promptResult: "Entered value")
        let fixture = try makeJavaScriptDialogFixture(dialogPresenter: dialogPresenter)
        defer { fixture.cleanup() }

        let result = await fixture.tab.presentJavaScriptPrompt(
            prompt: "Fixture prompt",
            defaultText: "Default value",
            webView: fixture.tab.webView
        )

        #expect(result == "Entered value")
        #expect(dialogPresenter.prompt == "Fixture prompt")
        #expect(dialogPresenter.defaultText == "Default value")
        #expect(dialogPresenter.presenter === fixture.inspectorViewController)
        #expect(dialogPresenter.promptPresentationCount == 1)
    }

    @Test
    func tabSwitchInstallsSelectedWebViewOnceAndPreservesTabIdentity() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let pageViewController = BrowserPageViewController(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            launchConfiguration: .xcodeTestOrPreview(),
            progressHideScheduler: ManualDelayScheduler()
        )
        var installedWebViewIDs: [ObjectIdentifier] = []
        let bindingCompleted = TestEventSignal()
        pageViewController.onSelectedTabBindingCompletedForTesting = bindingCompleted.record
        defer { pageViewController.onSelectedTabBindingCompletedForTesting = nil }
        pageViewController.onSelectedWebViewInstalled = { webView in
            installedWebViewIDs.append(ObjectIdentifier(webView))
        }

        pageViewController.loadViewIfNeeded()
        try await bindingCompleted.wait(for: 1)
        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        try await bindingCompleted.wait(for: 2)
        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        await pageViewController.rebindSelectedTabForTesting()

        #expect(installedWebViewIDs == [
            ObjectIdentifier(fixture.firstWebView),
            ObjectIdentifier(fixture.secondWebView)
        ])
        #expect(pageViewController.hostedWebViewForTesting === fixture.secondWebView)
        #expect(fixture.browserWindow.tabs[0].webView === fixture.firstWebView)
        #expect(fixture.browserWindow.tabs[1].webView === fixture.secondWebView)
    }

    @Test
    func returningToTabRecreatesViewportCoordinatorForRetainedWebView() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let firstWebView = try #require(fixture.firstWebView as? BrowserViewportWebView)
        let secondWebView = try #require(fixture.secondWebView as? BrowserViewportWebView)
        let pageViewController = BrowserPageViewController(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            launchConfiguration: .xcodeTestOrPreview(),
            progressHideScheduler: ManualDelayScheduler()
        )
        let installedWebViews = WebViewIdentitySignal()
        pageViewController.onSelectedWebViewInstalled = installedWebViews.record
        pageViewController.loadViewIfNeeded()
        try await installedWebViews.wait(for: firstWebView)
        let firstCoordinator = try #require(firstWebView.viewportCoordinator)
        #expect(firstCoordinator.hostViewController === pageViewController)

        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        try await installedWebViews.wait(for: secondWebView)
        #expect(firstWebView.viewportCoordinator == nil)
        #expect(secondWebView.viewportCoordinator?.hostViewController === pageViewController)

        let reinstalledWebViews = WebViewIdentitySignal()
        pageViewController.onSelectedWebViewInstalled = reinstalledWebViews.record
        fixture.browserWindow.selectTab(id: fixture.browserWindow.tabs[0].id)
        try await reinstalledWebViews.wait(for: firstWebView)
        let reinstalledCoordinator = try #require(firstWebView.viewportCoordinator)
        #expect(reinstalledCoordinator !== firstCoordinator)
        #expect(reinstalledCoordinator.hostViewController === pageViewController)
        #expect(secondWebView.viewportCoordinator == nil)
        #expect(pageViewController.hostedWebViewForTesting === firstWebView)
    }

    @Test
    func attachmentLifecycleAttachesLatestWebViewAfterInFlightSelectionChange() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        defer { actions.releaseAttach(result: .failure(CancellationError())) }
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )

        lifecycle.request(.attached)
        try await actions.waitUntilAttachStarted(count: 1)

        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        lifecycle.selectedWebViewDidChange(to: fixture.secondWebView)
        actions.releaseAttach()
        try await actions.waitUntilAttachStarted(count: 2)
        actions.releaseAttach()
        await lifecycle.waitForTransitions()

        #expect(actions.attachedWebViews == [fixture.firstWebView, fixture.secondWebView])
        #expect(actions.events == [
            .attach(ObjectIdentifier(fixture.firstWebView)),
            .detach,
            .attach(ObjectIdentifier(fixture.secondWebView))
        ])
    }

    @Test
    func attachmentLifecycleDetachesBeforeReplacingAttachedWebView() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        defer { actions.releaseAttach(result: .failure(CancellationError())) }
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )
        lifecycle.setAttachedForTesting(to: fixture.firstWebView)

        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        lifecycle.selectedWebViewDidChange(to: fixture.secondWebView)
        try await actions.waitUntilAttachStarted(count: 1)
        actions.releaseAttach()
        await lifecycle.waitForTransitions()

        #expect(actions.events == [
            .detach,
            .attach(ObjectIdentifier(fixture.secondWebView))
        ])
    }

    @Test
    func attachmentLifecycleFinalizesByDetachingAfterInFlightAttachCompletes() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        defer { actions.releaseAttach(result: .failure(CancellationError())) }
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )

        lifecycle.request(.attached)
        try await actions.waitUntilAttachStarted(count: 1)
        #expect(lifecycle.finalize())

        actions.releaseAttach()
        try await actions.waitUntilDetachCount(1)
        await lifecycle.waitForTransitions()
        lifecycle.request(.attached)

        #expect(actions.attachedWebViews == [fixture.firstWebView])
        #expect(actions.detachCount == 1)
    }

    @Test
    func attachmentLifecycleDoesNotAutomaticallyRetryFailedAttach() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        defer { actions.releaseAttach(result: .failure(CancellationError())) }
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )

        lifecycle.request(.attached)
        try await actions.waitUntilAttachStarted(count: 1)
        actions.releaseAttach(result: .failure(NSError(domain: "BrowserSessionRestoreTests", code: 1)))
        await lifecycle.waitForTransitions()

        #expect(actions.attachedWebViews == [fixture.firstWebView])
        #expect(actions.detachCount == 0)

        lifecycle.request(.attached)
        try await actions.waitUntilAttachStarted(count: 2)
        actions.releaseAttach()
        await lifecycle.waitForTransitions()

        #expect(actions.attachedWebViews == [fixture.firstWebView, fixture.firstWebView])
        #expect(actions.detachCount == 0)
    }

    @Test
    func inFlightAttachmentDoesNotRetainLifecycleOwnerOrStartPendingReattachment() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        defer { actions.releaseAttach(result: .failure(CancellationError())) }
        var lifecycle: BrowserInspectorSessionAttachmentLifecycle? = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )
        weak var retainedLifecycle = lifecycle

        lifecycle?.request(.attached)
        try await actions.waitUntilAttachStarted(count: 1)
        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        lifecycle?.selectedWebViewDidChange(to: fixture.secondWebView)

        lifecycle = nil
        #expect(retainedLifecycle == nil)

        actions.releaseAttach()
        try await actions.waitUntilAttachCompleted(count: 1)

        #expect(actions.attachedWebViews == [fixture.firstWebView])
        #expect(actions.detachCount == 0)
    }

    @Test
    func cancellingInFlightAttachmentRejectsLateCompletionAndPendingReattachment() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        defer { actions.releaseAttach(result: .failure(CancellationError())) }
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )

        lifecycle.request(.attached)
        try await actions.waitUntilAttachStarted(count: 1)
        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        lifecycle.selectedWebViewDidChange(to: fixture.secondWebView)

        lifecycle.cancel()
        actions.releaseAttach()
        try await actions.waitUntilAttachCompleted(count: 1)
        lifecycle.request(.attached)

        #expect(actions.attachedWebViews == [fixture.firstWebView])
        #expect(actions.attachCompletionCount == 1)
        #expect(actions.detachCount == 0)
    }

    @Test
    func mainSceneDelegateConnectsWithRestoredBrowserStore() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let windowScene = try makeWindowScene()
            let selectedTabID = UUID()
            let restoredURL = try #require(URL(string: "https://example.com/restored"))
            let launchConfiguration = BrowserLaunchConfiguration.xcodeTestOrPreview(
                initialURL: try #require(URL(string: "https://fallback.example/"))
            )
            let snapshot = BrowserSession.Snapshot(
                selectedTabID: selectedTabID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: selectedTabID,
                        url: restoredURL,
                        title: "Restored",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100)
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
                sessionPersistence: .persistent(storage: sessionStore)
            )

            let rootViewController = try #require(sceneDelegate.rootViewController)
            #expect(rootViewController.browserWindow.selectedTabID == selectedTabID)
            #expect(rootViewController.browserWindow.currentURL == restoredURL)
        }
    }

    @Test
    func mainSceneDelegateForcesSaveWhenSceneResignsActive() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let windowScene = try makeWindowScene()
            let launchConfiguration = BrowserLaunchConfiguration.xcodeTestOrPreview(
                initialURL: try #require(URL(string: "https://initial.example/"))
            )
            let sceneDelegate = MonoclyMainSceneDelegate()
            defer {
                sceneDelegate.disconnect(windowScene: windowScene)
            }
            sceneDelegate.connect(
                windowScene: windowScene,
                launchConfiguration: launchConfiguration,
                sessionPersistence: .persistent(storage: sessionStore)
            )
            let rootViewController = try #require(sceneDelegate.rootViewController)
            let navigatedURL = try #require(URL(string: "https://example.com/navigated"))

            rootViewController.browserWindow.loadInitialRequestIfNeeded()
            rootViewController.browserWindow.load(url: navigatedURL)
            sceneDelegate.sceneWillResignActive(windowScene)

            let restoredSession = try #require(sessionStore.load())
            #expect(restoredSession.snapshot.selectedTabID == rootViewController.browserWindow.selectedTabID)
            #expect(restoredSession.snapshot.tabs.first?.url == navigatedURL)
        }
    }

    @Test
    func mainSceneDelegateForcesSaveWhenSceneDisconnects() throws {
        try withTemporarySessionStore { sessionStore, _ in
            let windowScene = try makeWindowScene()
            let launchConfiguration = BrowserLaunchConfiguration.xcodeTestOrPreview(
                initialURL: try #require(URL(string: "https://initial.example/"))
            )
            let sceneDelegate = MonoclyMainSceneDelegate()
            sceneDelegate.connect(
                windowScene: windowScene,
                launchConfiguration: launchConfiguration,
                sessionPersistence: .persistent(storage: sessionStore)
            )
            let rootViewController = try #require(sceneDelegate.rootViewController)
            let navigatedURL = try #require(URL(string: "https://example.com/disconnect"))

            rootViewController.browserWindow.loadInitialRequestIfNeeded()
            rootViewController.browserWindow.load(url: navigatedURL)
            sceneDelegate.disconnect(windowScene: windowScene)

            let restoredSession = try #require(sessionStore.load())
            #expect(restoredSession.snapshot.selectedTabID == rootViewController.browserWindow.selectedTabID)
            #expect(restoredSession.snapshot.tabs.first?.url == navigatedURL)
        }
    }

    private func withTemporarySessionStore<T>(
        _ body: (BrowserSession.FileStorage, URL) throws -> T
    ) throws -> T {
        try withTemporaryBrowserSessionDirectory { rootDirectoryURL in
            try body(BrowserSession.FileStorage(rootDirectoryURL: rootDirectoryURL), rootDirectoryURL)
        }
    }

    private func withTemporarySessionStore<T>(
        _ body: (BrowserSession.FileStorage, URL) async throws -> T
    ) async throws -> T {
        try await withTemporaryBrowserSessionDirectory { rootDirectoryURL in
            try await body(BrowserSession.FileStorage(rootDirectoryURL: rootDirectoryURL), rootDirectoryURL)
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

    private func withTemporaryBrowserSessionDirectory<T>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let rootDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoclyBrowserSession-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootDirectoryURL)
        }
        return try await body(rootDirectoryURL)
    }

    private func makeWindowScene() throws -> UIWindowScene {
        try #require(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
    }

    private func waitForSelectedTabRendering(
        in viewController: BrowserPageViewController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        guard let delivery = viewController.selectedTabObservationDeliveryForTesting else {
            return false
        }
        let values = await delivery.values(condition)
        defer { values.cancel() }
        return await withTaskCancellationHandler {
            await values.waitUntilValue(true, timeout: .seconds(1))
        } onCancel: {
            values.cancel()
        }
    }

    private func waitForInspectorPresentationRendering(
        in viewController: BrowserPageViewController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        guard let delivery = viewController.inspectorPresentationObservationDeliveryForTesting else {
            return false
        }
        let values = await delivery.values(condition)
        defer { values.cancel() }
        return await withTaskCancellationHandler {
            await values.waitUntilValue(true, timeout: .seconds(1))
        } onCancel: {
            values.cancel()
        }
    }

    private struct JavaScriptDialogFixture {
        var tab: BrowserTab
        var window: UIWindow
        var rootViewController: UINavigationController
        var inspectorViewController: UIViewController

        func cleanup() {
            rootViewController.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    private func makeJavaScriptDialogFixture(
        dialogPresenter: any BrowserJavaScriptDialogPresenting = BrowserJavaScriptDialogPresenter()
    ) throws -> JavaScriptDialogFixture {
        let tab = BrowserTab(
            url: try #require(URL(string: "about:blank")),
            automaticallyLoadsInitialRequest: false,
            javaScriptDialogPresenter: dialogPresenter
        )
        let pageViewController = UIViewController()
        pageViewController.view.addSubview(tab.webView)
        tab.webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tab.webView.leadingAnchor.constraint(equalTo: pageViewController.view.leadingAnchor),
            tab.webView.trailingAnchor.constraint(equalTo: pageViewController.view.trailingAnchor),
            tab.webView.topAnchor.constraint(equalTo: pageViewController.view.topAnchor),
            tab.webView.bottomAnchor.constraint(equalTo: pageViewController.view.bottomAnchor),
        ])

        let rootViewController = UINavigationController(rootViewController: pageViewController)
        let window = UIWindow(windowScene: try makeWindowScene())
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        rootViewController.loadViewIfNeeded()
        window.layoutIfNeeded()

        let inspectorViewController = UIViewController()
        rootViewController.present(inspectorViewController, animated: false)
        #expect(inspectorViewController.presentingViewController != nil)

        return JavaScriptDialogFixture(
            tab: tab,
            window: window,
            rootViewController: rootViewController,
            inspectorViewController: inspectorViewController
        )
    }

    private struct AttachmentLifecycleFixture {
        var secondTabID: UUID
        var browserWindow: BrowserWindow
        var firstWebView: WKWebView
        var secondWebView: WKWebView
    }

    private func makeAttachmentLifecycleFixture() throws -> AttachmentLifecycleFixture {
        let firstID = UUID()
        let secondID = UUID()
        let restoredSession = BrowserSession.RestoredState(
            snapshot: BrowserSession.Snapshot(
                selectedTabID: firstID,
                tabs: [
                    BrowserSession.TabSnapshot(
                        id: firstID,
                        url: try #require(URL(string: "about:blank#first")),
                        title: "First",
                        createdAt: Date(timeIntervalSince1970: 100),
                        lastUsedAt: Date(timeIntervalSince1970: 100)
                    ),
                    BrowserSession.TabSnapshot(
                        id: secondID,
                        url: try #require(URL(string: "about:blank#second")),
                        title: "Second",
                        createdAt: Date(timeIntervalSince1970: 200),
                        lastUsedAt: Date(timeIntervalSince1970: 200)
                    )
                ]
            ),
            tabStateDataByID: [:]
        )
        let store = BrowserWindow(
            initialState: .restored(
                restoredSession,
                fallbackURL: try #require(URL(string: "about:blank"))
            ),
            sessionPersistence: .ephemeral
        )
        return AttachmentLifecycleFixture(
            secondTabID: secondID,
            browserWindow: store,
            firstWebView: store.tabs[0].webView,
            secondWebView: store.tabs[1].webView
        )
    }

    @MainActor
    private final class ManualDelayScheduler: MainActorDelayScheduling {
        private var operation: (@Sendable @MainActor () -> Void)?
        private let scheduled = TestEventSignal()

        var hasScheduledDelay: Bool {
            operation != nil
        }

        func cancel() {
            operation = nil
        }

        func schedule(after duration: Duration, operation: @escaping @Sendable @MainActor () -> Void) {
            self.operation = operation
            scheduled.record()
        }

        func schedule(nanoseconds: UInt64, operation: @escaping @Sendable @MainActor () -> Void) {
            self.operation = operation
            scheduled.record()
        }

        func waitUntilScheduled() async throws {
            guard hasScheduledDelay == false else {
                return
            }
            try await scheduled.wait(for: scheduled.count + 1)
        }

        func fire() {
            let operation = operation
            self.operation = nil
            operation?()
        }
    }

    @MainActor
    @Observable
    fileprivate final class TestEventSignal {
        private(set) var count = 0

        func record() {
            count += 1
        }

        func wait(for expectedCount: Int) async throws {
            try await requireTestEvent { self.count >= expectedCount }
        }
    }

    @MainActor
    @Observable
    fileprivate final class WebViewIdentitySignal {
        private var seenWebViewIDs: Set<ObjectIdentifier> = []

        func record(_ webView: WKWebView) {
            seenWebViewIDs.insert(ObjectIdentifier(webView))
        }

        func wait(for webView: WKWebView) async throws {
            let webViewID = ObjectIdentifier(webView)
            try await requireTestEvent { self.seenWebViewIDs.contains(webViewID) }
        }
    }

    @MainActor
    private final class JavaScriptDialogPresenterSpy: BrowserJavaScriptDialogPresenting {
        private let confirmResult: Bool
        private let promptResult: String?

        private(set) weak var presenter: UIViewController?
        private(set) var alertMessage: String?
        private(set) var confirmMessage: String?
        private(set) var prompt: String?
        private(set) var defaultText: String?
        private(set) var alertPresentationCount = 0
        private(set) var confirmPresentationCount = 0
        private(set) var promptPresentationCount = 0

        init(confirmResult: Bool = true, promptResult: String? = nil) {
            self.confirmResult = confirmResult
            self.promptResult = promptResult
        }

        func presentAlert(
            message: String,
            from presenter: UIViewController,
            completion: @escaping () -> Void
        ) {
            self.presenter = presenter
            alertMessage = message
            alertPresentationCount += 1
            completion()
        }

        func presentConfirm(
            message: String,
            from presenter: UIViewController,
            completion: @escaping (Bool) -> Void
        ) {
            self.presenter = presenter
            confirmMessage = message
            confirmPresentationCount += 1
            completion(confirmResult)
        }

        func presentPrompt(
            prompt: String,
            defaultText: String?,
            from presenter: UIViewController,
            completion: @escaping (String?) -> Void
        ) {
            self.presenter = presenter
            self.prompt = prompt
            self.defaultText = defaultText
            promptPresentationCount += 1
            completion(promptResult)
        }
    }

    @MainActor
    @Observable
    fileprivate final class ControlledInspectorAttachmentActions {
        enum Event: Equatable {
            case attach(ObjectIdentifier)
            case detach
        }

        private(set) var attachedWebViews: [WKWebView] = []
        private(set) var attachCompletionCount = 0
        private(set) var detachCount = 0
        private(set) var events: [Event] = []
        private var attachContinuation: CheckedContinuation<Void, Never>?
        private var attachResult: Result<Void, any Error> = .success(())

        func attach(_ webView: WKWebView) async throws {
            try Task.checkCancellation()
            attachedWebViews.append(webView)
            events.append(.attach(ObjectIdentifier(webView)))
            await withCheckedContinuation { continuation in
                attachContinuation = continuation
            }
            attachCompletionCount += 1
            let result = attachResult
            attachResult = .success(())
            try result.get()
        }

        func detach() async {
            detachCount += 1
            events.append(.detach)
        }

        func waitUntilAttachStarted(count: Int) async throws {
            try await requireTestEvent { self.attachedWebViews.count >= count }
        }

        func waitUntilAttachCompleted(count: Int) async throws {
            try await requireTestEvent { self.attachCompletionCount >= count }
        }

        func waitUntilDetachCount(_ count: Int) async throws {
            try await requireTestEvent { self.detachCount >= count }
        }

        func releaseAttach(result: Result<Void, any Error> = .success(())) {
            attachResult = result
            let continuation = attachContinuation
            attachContinuation = nil
            continuation?.resume()
        }
    }
}

@MainActor
private func requireTestEvent(
    _ condition: @escaping @MainActor @Sendable () -> Bool
) async throws {
    try Task.checkCancellation()
    let observation = withPortableContinuousObservation { _ in
        _ = condition()
    }
    defer { observation.cancel() }
    let values = await observation.values(condition)
    defer { values.cancel() }
    try await withTaskCancellationHandler {
        let didObserveEvent = await values.waitUntilValue(true, timeout: .seconds(1))
        try Task.checkCancellation()
        if !didObserveEvent, let error = observation.error {
            throw error
        }
        try #require(didObserveEvent)
    } onCancel: {
        values.cancel()
    }
}
#endif
