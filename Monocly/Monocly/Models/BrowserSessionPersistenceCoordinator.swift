import Foundation
import ObservationBridge

@MainActor
final class BrowserSessionPersistenceCoordinator {
    private struct ObservedSessionState: Equatable, Sendable {
        struct ObservedTabState: Equatable, Sendable {
            let id: UUID
            let url: URL
            let title: String?
            let createdAt: Date
            let lastUsedAt: Date
            let persistenceRevision: Int
        }

        let selectedTabID: UUID
        let tabs: [ObservedTabState]
    }

    private weak var store: BrowserWindowStore?
    private let sessionStore: BrowserSessionStore?
    private let saveDebounceDuration: UInt64
    private let saveDelayScheduler: MainActorDelayScheduling
    private var observation: PortableObservationTracking.Token?
    private var isRestorationComplete: Bool
    private var lastObservedState: ObservedSessionState?

    init(
        store: BrowserWindowStore,
        sessionStore: BrowserSessionStore?,
        saveDebounceDuration: UInt64,
        saveDelayScheduler: MainActorDelayScheduling,
        startsRestored: Bool
    ) {
        self.store = store
        self.sessionStore = sessionStore
        self.saveDebounceDuration = saveDebounceDuration
        self.saveDelayScheduler = saveDelayScheduler
        self.isRestorationComplete = startsRestored == false
        self.lastObservedState = Self.observedSessionState(from: store)

        startObservingStore()
    }

    isolated deinit {
        observation?.cancel()
        saveDelayScheduler.cancel()
    }

    func cancel() {
        observation?.cancel()
        observation = nil
        saveDelayScheduler.cancel()
    }

    func markRestorationComplete() {
        guard isRestorationComplete == false else {
            return
        }
        isRestorationComplete = true
    }

    func preserveSession(immediate: Bool) {
        guard isRestorationComplete else {
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

    private func startObservingStore() {
        guard sessionStore != nil else {
            return
        }

        observation = withPortableContinuousObservation { [weak self, weak store] event in
            guard let self, let store else {
                return
            }

            let observedState = Self.observedSessionState(from: store)
            guard event.kind != .initial else {
                lastObservedState = observedState
                return
            }
            guard observedState != lastObservedState else {
                return
            }
            lastObservedState = observedState
            preserveSession(immediate: false)
        }
    }

    private static func observedSessionState(from store: BrowserWindowStore) -> ObservedSessionState {
        ObservedSessionState(
            selectedTabID: store.selectedTabID,
            tabs: store.tabs.map { tab in
                ObservedSessionState.ObservedTabState(
                    id: tab.id,
                    url: tab.persistedURL,
                    title: tab.pageTitle,
                    createdAt: tab.createdAt,
                    lastUsedAt: tab.lastUsedAt,
                    persistenceRevision: tab.persistenceRevision
                )
            }
        )
    }

    private func saveCurrentSession() {
        guard let sessionStore, let store else {
            return
        }

        let tabs = store.tabs
        let selectedID = tabs.contains(where: { $0.id == store.selectedTabID })
            ? store.selectedTabID
            : tabs[0].id

        var tabStateDataByID: [UUID: Data] = [:]
        let tabSnapshots = tabs.map { tab in
            if let stateData = tab.interactionStateData {
                tabStateDataByID[tab.id] = stateData
            }
            return tab.snapshot(stateFileName: BrowserTabStore.Snapshot.stateFileName(for: tab.id))
        }

        let snapshot = BrowserSessionStore.Snapshot(
            selectedTabID: selectedID,
            tabs: tabSnapshots
        )
        try? sessionStore.save(snapshot: snapshot, tabStateDataByID: tabStateDataByID)
    }
}
