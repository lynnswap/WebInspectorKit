import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class BrowserWindow {
    enum InitialState {
        case fresh(url: URL, automaticallyLoadsInitialRequest: Bool = true)
        case restored(BrowserSession.RestoredState?, fallbackURL: URL)
    }

    private(set) var tabs: [BrowserTab]
    var selectedTabID: UUID

    @ObservationIgnored private var persistenceCoordinator: BrowserSession.PersistenceCoordinator!

    var selectedTab: BrowserTab? {
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
        initialState: BrowserWindow.InitialState,
        sessionPersistence: BrowserSession.Persistence = .persistent(storage: BrowserSession.FileStorage()),
        saveDebounceDuration: UInt64 = 500_000_000,
        saveDelayScheduler: MainActorDelayScheduling = MainActorDelayScheduler()
    ) {
        let startsRestored: Bool
        switch initialState {
        case .fresh(let url, let automaticallyLoadsInitialRequest):
            let tab = BrowserTab(url: url, automaticallyLoadsInitialRequest: automaticallyLoadsInitialRequest)
            tabs = [tab]
            selectedTabID = tab.id
            startsRestored = false

        case .restored(let restoredState, let fallbackURL):
            if let restoredState,
               restoredState.snapshot.tabs.isEmpty == false {
                let restoredTabs = restoredState.snapshot.tabs.map { tabSnapshot in
                    BrowserTab(
                        id: tabSnapshot.id,
                        url: tabSnapshot.url,
                        title: tabSnapshot.title,
                        createdAt: tabSnapshot.createdAt,
                        lastUsedAt: tabSnapshot.lastUsedAt,
                        restoredInteractionState: restoredState.tabStateDataByID[tabSnapshot.id],
                        automaticallyLoadsInitialRequest: false
                    )
                }
                tabs = restoredTabs
                selectedTabID = restoredTabs.contains(where: { $0.id == restoredState.snapshot.selectedTabID })
                    ? restoredState.snapshot.selectedTabID
                    : restoredTabs[0].id
            } else {
                let tab = BrowserTab(url: fallbackURL, automaticallyLoadsInitialRequest: false)
                tabs = [tab]
                selectedTabID = tab.id
            }
            startsRestored = true
        }

        persistenceCoordinator = BrowserSession.PersistenceCoordinator(
            browserWindow: self,
            sessionPersistence: sessionPersistence,
            saveDebounceDuration: saveDebounceDuration,
            saveDelayScheduler: saveDelayScheduler,
            startsRestored: startsRestored
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

    func backHistoryItems(limit: Int = 20) -> [BrowserTab.HistoryMenuItem] {
        selectedTab?.backHistoryItems(limit: limit) ?? []
    }

    func forwardHistoryItems(limit: Int = 20) -> [BrowserTab.HistoryMenuItem] {
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
