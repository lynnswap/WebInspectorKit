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
    func launchConfigurationUsesEphemeralSessionPersistenceForXCTestAndPreviews() throws {
        let testConfiguration = BrowserLaunchConfiguration.current(environment: [
            "XCTestConfigurationFilePath": "/tmp/Monocly.xctestconfiguration"
        ])
        let previewConfiguration = BrowserLaunchConfiguration.current(environment: [
            "XCODE_RUNNING_FOR_PREVIEWS": "1"
        ])

        #expect(testConfiguration.initialURL == URL(string: "about:blank"))
        #expect(testConfiguration.sessionPersistenceMode == .ephemeral)
        #expect(previewConfiguration.initialURL == URL(string: "about:blank"))
        #expect(previewConfiguration.sessionPersistenceMode == .ephemeral)
    }

    @Test
    func xctestLaunchConfigurationKeepsEnvironmentInitialURLButUsesEphemeralPersistence() throws {
        let diagnosticURL = try #require(URL(string: "data:text/html;charset=utf-8,%3Chtml%3Etest%3C/html%3E"))
        let configuration = BrowserLaunchConfiguration.current(environment: [
            "XCTestConfigurationFilePath": "/tmp/Monocly.xctestconfiguration",
            "WEBSPECTOR_INITIAL_URL": diagnosticURL.absoluteString
        ])

        #expect(configuration.initialURL == diagnosticURL)
        #expect(configuration.sessionPersistenceMode == .ephemeral)
    }

    @Test
    func diagnosticLaunchCanUseItsInitialURLWithoutReadingOrWritingTheSavedSession() throws {
        let diagnosticURL = try #require(URL(string: "http://127.0.0.1:8765/a"))
        let configuration = BrowserLaunchConfiguration.current(environment: [
            "WEBSPECTOR_EPHEMERAL_SESSION": "1",
            "WEBSPECTOR_INITIAL_URL": diagnosticURL.absoluteString,
        ])

        #expect(configuration.initialURL == diagnosticURL)
        #expect(configuration.sessionPersistenceMode == .ephemeral)
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

            #expect(await waitUntil { scheduler.hasScheduledDelay })
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
            #expect(await waitUntil { scheduler.hasScheduledDelay })

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

            await Task.yield()
            tab.pageTitle = "Observed Title"
            await Task.yield()

            #expect(scheduler.hasScheduledDelay)

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

        await tab.waitUntilTitleObservationApplied()

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
            launchConfiguration: BrowserLaunchConfiguration(initialURL: initialURL),
            progressHideScheduler: scheduler
        )

        pageViewController.loadViewIfNeeded()
        let tab = try #require(store.selectedTab)
        #expect(await waitUntil {
            pageViewController.selectedTabObservationIsActiveForTesting
        })

        tab.pageTitle = "Native Title"
        tab.canGoBack = true
        tab.canGoForward = true
        tab.isLoading = true
        tab.estimatedProgress = 0.42
        tab.underPageBackgroundColor = .systemPink

        #expect(await waitUntil {
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
            launchConfiguration: BrowserLaunchConfiguration(initialURL: initialURL),
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
            launchConfiguration: BrowserLaunchConfiguration(initialURL: initialURL),
            progressHideScheduler: ManualDelayScheduler()
        )

        pageViewController.loadViewIfNeeded()
        let tab = try #require(store.selectedTab)
        let backButtonItem = pageViewController.backButtonItemForTesting
        let forwardButtonItem = pageViewController.forwardButtonItemForTesting
        let inspectorButtonItem = pageViewController.inspectorButtonItemForTesting

        tab.pageTitle = "Updated Title"
        tab.isLoading = true
        tab.estimatedProgress = 0.75
        await Task.yield()

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
        let inspectorSession = WebInspectorSession()
        let pageViewController = BrowserPageViewController(
            browserWindow: store,
            inspectorSession: inspectorSession,
            launchConfiguration: BrowserLaunchConfiguration(initialURL: initialURL),
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
        #expect(await waitUntil {
            pageViewController.inspectorPresentationObservationIsActiveForTesting
        })
        let inspectorButtonItem = pageViewController.inspectorButtonItemForTesting
        #expect(inspectorButtonItem.isEnabled)

        #expect(pageViewController.openInspectorAsSheetForTesting())
        let sheetController = try #require(pageViewController.presentedInspectorSheetForTesting)
        #expect(sheetController.session === inspectorSession)
        #expect(await waitUntil {
            inspectorButtonItem.isEnabled == false
        })

        let presentationController = try #require(sheetController.presentationController)
        presentationController.delegate?.presentationControllerDidDismiss?(presentationController)

        #expect(await waitUntil {
            pageViewController.presentedInspectorSheetForTesting == nil
                && inspectorButtonItem.isEnabled
        })
        #expect(pageViewController.inspectorButtonItemForTesting === inspectorButtonItem)
    }

    @Test
    func tabSwitchInstallsSelectedWebViewOnceAndPreservesTabIdentity() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let pageViewController = BrowserPageViewController(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            launchConfiguration: BrowserLaunchConfiguration(initialURL: try #require(URL(string: "about:blank"))),
            progressHideScheduler: ManualDelayScheduler()
        )
        var installedWebViewIDs: [ObjectIdentifier] = []
        pageViewController.onSelectedWebViewInstalled = { webView in
            installedWebViewIDs.append(ObjectIdentifier(webView))
        }

        pageViewController.loadViewIfNeeded()
        await Task.yield()
        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        await Task.yield()
        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        await Task.yield()

        #expect(installedWebViewIDs == [
            ObjectIdentifier(fixture.firstWebView),
            ObjectIdentifier(fixture.secondWebView)
        ])
        #expect(pageViewController.hostedWebViewForTesting === fixture.secondWebView)
        #expect(fixture.browserWindow.tabs[0].webView === fixture.firstWebView)
        #expect(fixture.browserWindow.tabs[1].webView === fixture.secondWebView)
    }

    @Test
    func attachmentLifecycleAttachesLatestWebViewAfterInFlightSelectionChange() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )

        lifecycle.request(.attached)
        await actions.waitUntilAttachStarted(count: 1)

        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        lifecycle.selectedWebViewDidChange(to: fixture.secondWebView)
        actions.releaseAttach()
        await actions.waitUntilAttachStarted(count: 2)
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
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )
        lifecycle.setAttachedForTesting(to: fixture.firstWebView)

        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        lifecycle.selectedWebViewDidChange(to: fixture.secondWebView)
        await actions.waitUntilAttachStarted(count: 1)
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
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
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
            browserWindow: fixture.browserWindow,
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
    func inFlightAttachmentDoesNotRetainLifecycleOwner() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        var lifecycle: BrowserInspectorSessionAttachmentLifecycle? = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )
        weak var retainedLifecycle = lifecycle

        lifecycle?.request(.attached)
        await actions.waitUntilAttachStarted(count: 1)

        lifecycle = nil

        #expect(retainedLifecycle == nil)

        actions.releaseAttach()
        await actions.waitUntilAttachCompleted(count: 1)
    }

    @Test
    func lateAttachmentCompletionDoesNotStartPendingReattachmentAfterLifecycleRelease() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        var lifecycle: BrowserInspectorSessionAttachmentLifecycle? = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )
        weak var retainedLifecycle = lifecycle

        lifecycle?.request(.attached)
        await actions.waitUntilAttachStarted(count: 1)
        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        lifecycle?.selectedWebViewDidChange(to: fixture.secondWebView)

        lifecycle = nil
        #expect(retainedLifecycle == nil)

        actions.releaseAttach()
        await actions.waitUntilAttachCompleted(count: 1)

        #expect(actions.attachedWebViews == [fixture.firstWebView])
        #expect(actions.detachCount == 0)
    }

    @Test
    func cancellingInFlightAttachmentRejectsLateCompletionAndPendingReattachment() async throws {
        let fixture = try makeAttachmentLifecycleFixture()
        let actions = ControlledInspectorAttachmentActions()
        let lifecycle = BrowserInspectorSessionAttachmentLifecycle(
            browserWindow: fixture.browserWindow,
            inspectorSession: WebInspectorSession(),
            attachAction: actions.attach,
            detachAction: actions.detach
        )

        lifecycle.request(.attached)
        await actions.waitUntilAttachStarted(count: 1)
        fixture.browserWindow.selectTab(id: fixture.secondTabID)
        lifecycle.selectedWebViewDidChange(to: fixture.secondWebView)

        lifecycle.cancel()
        actions.releaseAttach()
        await actions.waitUntilAttachCompleted(count: 1)
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
            let launchConfiguration = BrowserLaunchConfiguration(
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
            let launchConfiguration = BrowserLaunchConfiguration(
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

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
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
        private var attachStartedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var attachCompletedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var detachWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func attach(_ webView: WKWebView) async throws {
            attachedWebViews.append(webView)
            events.append(.attach(ObjectIdentifier(webView)))
            resumeAttachStartedWaiters()
            await withCheckedContinuation { continuation in
                attachContinuation = continuation
            }
            attachCompletionCount += 1
            resumeAttachCompletedWaiters()
            let result = attachResult
            attachResult = .success(())
            try result.get()
        }

        func detach() async {
            detachCount += 1
            events.append(.detach)
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

        func waitUntilAttachCompleted(count: Int) async {
            guard attachCompletionCount < count else {
                return
            }
            await withCheckedContinuation { continuation in
                attachCompletedWaiters.append((count, continuation))
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

        private func resumeAttachCompletedWaiters() {
            let readyWaiters = attachCompletedWaiters.filter { attachCompletionCount >= $0.0 }
            attachCompletedWaiters.removeAll { attachCompletionCount >= $0.0 }
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
