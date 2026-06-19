import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class BrowserWindowStore {
    private(set) var tabs: [BrowserTabStore]
    var selectedTabID: UUID

    @ObservationIgnored private var persistenceCoordinator: BrowserSessionPersistenceCoordinator!

    var selectedTab: BrowserTabStore? {
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    var webView: WKWebView {
        tabs.first { $0.id == selectedTabID }?.webView ?? tabs[0].webView
    }

    var canGoBack: Bool {
        selectedTab?.canGoBack ?? false
    }

    var canGoForward: Bool {
        selectedTab?.canGoForward ?? false
    }

    var estimatedProgress: Double {
        selectedTab?.estimatedProgress ?? .zero
    }

    var isLoading: Bool {
        selectedTab?.isLoading ?? false
    }

    var currentURL: URL? {
        selectedTab?.currentURL
    }

    var underPageBackgroundColor: BrowserPlatformColor? {
        selectedTab?.underPageBackgroundColor
    }

    var webContentTerminationCount: Int {
        selectedTab?.webContentTerminationCount ?? 0
    }

    var lastWebContentTerminationDate: Date? {
        selectedTab?.lastWebContentTerminationDate
    }

    var lastWebContentTerminationURL: URL? {
        selectedTab?.lastWebContentTerminationURL
    }

    var lastNavigationErrorDescription: String? {
        selectedTab?.lastNavigationErrorDescription
    }

    var didCommitNavigationCount: Int {
        selectedTab?.didCommitNavigationCount ?? 0
    }

    var didFinishNavigationCount: Int {
        selectedTab?.didFinishNavigationCount ?? 0
    }

    var isShowingProgress: Bool {
        selectedTab?.isShowingProgress ?? false
    }

    var displayTitle: String {
        selectedTab?.displayTitle ?? "Monocly"
    }

    init(
        url: URL,
        automaticallyLoadsInitialRequest: Bool = true,
        sessionStore: BrowserSessionStore? = BrowserSessionStore(),
        saveDebounceDuration: UInt64 = 500_000_000,
        saveDelayScheduler: MainActorDelayScheduling = MainActorDelayScheduler()
    ) {
        let tab = BrowserTabStore(url: url, automaticallyLoadsInitialRequest: automaticallyLoadsInitialRequest)
        tabs = [tab]
        selectedTabID = tab.id

        persistenceCoordinator = BrowserSessionPersistenceCoordinator(
            store: self,
            sessionStore: sessionStore,
            saveDebounceDuration: saveDebounceDuration,
            saveDelayScheduler: saveDelayScheduler,
            startsRestored: false
        )
    }

    init(
        restoring restoredSession: BrowserSessionStore.RestoredSession?,
        fallbackURL: URL,
        sessionStore: BrowserSessionStore? = BrowserSessionStore(),
        saveDebounceDuration: UInt64 = 500_000_000,
        saveDelayScheduler: MainActorDelayScheduling = MainActorDelayScheduler()
    ) {
        if let restoredSession,
           restoredSession.snapshot.tabs.isEmpty == false {
            let restoredTabs = restoredSession.snapshot.tabs.map { tabSnapshot in
                BrowserTabStore(
                    id: tabSnapshot.id,
                    url: tabSnapshot.url,
                    title: tabSnapshot.title,
                    createdAt: tabSnapshot.createdAt,
                    lastUsedAt: tabSnapshot.lastUsedAt,
                    restoredInteractionState: restoredSession.tabStateDataByID[tabSnapshot.id],
                    automaticallyLoadsInitialRequest: false
                )
            }
            tabs = restoredTabs
            selectedTabID = restoredTabs.contains(where: { $0.id == restoredSession.snapshot.selectedTabID })
                ? restoredSession.snapshot.selectedTabID
                : restoredTabs[0].id
        } else {
            let tab = BrowserTabStore(url: fallbackURL, automaticallyLoadsInitialRequest: false)
            tabs = [tab]
            selectedTabID = tab.id
        }

        persistenceCoordinator = BrowserSessionPersistenceCoordinator(
            store: self,
            sessionStore: sessionStore,
            saveDebounceDuration: saveDebounceDuration,
            saveDelayScheduler: saveDelayScheduler,
            startsRestored: true
        )
    }

    isolated deinit {
        persistenceCoordinator.cancel()
    }

    func selectTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return
        }
        selectedTabID = tab.id
        tab.markSelected()
    }

    func goBack() {
        selectedTab?.goBack()
    }

    func goForward() {
        selectedTab?.goForward()
    }

    func go(to item: WKBackForwardListItem) {
        selectedTab?.go(to: item)
    }

    func load(url: URL) {
        selectedTab?.load(url: url)
    }

    func backHistoryItems(limit: Int = 20) -> [BrowserTabStore.HistoryMenuItem] {
        selectedTab?.backHistoryItems(limit: limit) ?? []
    }

    func forwardHistoryItems(limit: Int = 20) -> [BrowserTabStore.HistoryMenuItem] {
        selectedTab?.forwardHistoryItems(limit: limit) ?? []
    }

    func loadInitialRequestIfNeeded() {
        selectedTab?.markSelected()
        persistenceCoordinator.markRestorationComplete()
        preserveSession(immediate: false)
    }

    func preserveSession(immediate: Bool) {
        persistenceCoordinator.preserveSession(immediate: immediate)
    }
}
