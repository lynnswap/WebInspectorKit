import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class BrowserStore {
    private let fallbackURL: URL
    private let sessionStore: BrowserSessionStore?
    private let saveDebounceDuration: UInt64

    private(set) var tabs: [BrowserTabStore]
    var selectedTabID: UUID
    private(set) var stateRevision = 0

    @ObservationIgnored private var restorationComplete = false
    @ObservationIgnored private let saveDelayScheduler: MainActorDelayScheduling

    var selectedTab: BrowserTabStore? {
        _ = stateRevision
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    var webView: WKWebView {
        resolvedSelectedTab.webView
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
        fallbackURL = url
        self.sessionStore = sessionStore
        self.saveDebounceDuration = saveDebounceDuration
        self.saveDelayScheduler = saveDelayScheduler

        let tab = BrowserTabStore(url: url, automaticallyLoadsInitialRequest: automaticallyLoadsInitialRequest)
        tabs = [tab]
        selectedTabID = tab.id

        configureTabCallbacks()
        restorationComplete = true
    }

    init(
        restoring restoredSession: BrowserSessionStore.RestoredSession?,
        fallbackURL: URL,
        sessionStore: BrowserSessionStore? = BrowserSessionStore(),
        saveDebounceDuration: UInt64 = 500_000_000,
        saveDelayScheduler: MainActorDelayScheduling = MainActorDelayScheduler()
    ) {
        self.fallbackURL = fallbackURL
        self.sessionStore = sessionStore
        self.saveDebounceDuration = saveDebounceDuration
        self.saveDelayScheduler = saveDelayScheduler

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

        configureTabCallbacks()
    }

    isolated deinit {
        saveDelayScheduler.cancel()
    }

    func selectTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else {
            return
        }
        selectedTabID = tab.id
        tab.markSelected()
        noteStateChanged()
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
        resolvedSelectedTab.markSelected()
        restorationComplete = true
        preserveSession(immediate: false)
    }

    func preserveSession(immediate: Bool) {
        guard restorationComplete else {
            return
        }
        guard sessionStore != nil else {
            return
        }

        saveDelayScheduler.cancel()

        if immediate {
            saveCurrentSession()
            return
        }

        saveDelayScheduler.schedule(nanoseconds: saveDebounceDuration) { [weak self] in
            self?.saveCurrentSession()
        }
    }

    private var resolvedSelectedTab: BrowserTabStore {
        if let selectedTab {
            return selectedTab
        }

        let tab = BrowserTabStore(url: fallbackURL, automaticallyLoadsInitialRequest: false)
        tabs = [tab]
        selectedTabID = tab.id
        configureTabCallbacks()
        noteStateChanged()
        return tab
    }

    private func configureTabCallbacks() {
        for tab in tabs {
            tab.onStateChanged = { [weak self] in
                self?.noteStateChanged()
            }
        }
    }

    private func noteStateChanged() {
        stateRevision += 1
        preserveSession(immediate: false)
    }

    private func saveCurrentSession() {
        guard let sessionStore else {
            return
        }
        if tabs.isEmpty {
            let tab = BrowserTabStore(url: fallbackURL, automaticallyLoadsInitialRequest: false)
            tabs = [tab]
            selectedTabID = tab.id
            configureTabCallbacks()
            stateRevision += 1
        }

        let selectedID = tabs.contains(where: { $0.id == selectedTabID }) ? selectedTabID : tabs[0].id
        selectedTabID = selectedID

        var tabStateDataByID: [UUID: Data] = [:]
        let tabSnapshots = tabs.map { tab in
            if let stateData = tab.interactionStateData {
                tabStateDataByID[tab.id] = stateData
            }
            return tab.snapshot(stateFileName: BrowserTabStore.Snapshot.stateFileName(for: tab.id))
        }

        let snapshot = BrowserSessionStore.Snapshot(selectedTabID: selectedID, tabs: tabSnapshots)
        try? sessionStore.save(snapshot: snapshot, tabStateDataByID: tabStateDataByID)
    }
}
