import Foundation
import ObservationBridge

extension BrowserSession {
    @MainActor
    final class PersistenceCoordinator {
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

        private weak var browserWindow: BrowserWindow?
        private let sessionPersistence: BrowserSession.Persistence
        private let saveDebounceDuration: UInt64
        private let saveDelayScheduler: MainActorDelayScheduling
        private var observation: PortableObservationTracking.Token?
        private var isRestorationComplete: Bool
        private var lastObservedState: ObservedSessionState?

        init(
            browserWindow: BrowserWindow,
            sessionPersistence: BrowserSession.Persistence,
            saveDebounceDuration: UInt64,
            saveDelayScheduler: MainActorDelayScheduling,
            startsRestored: Bool
        ) {
            self.browserWindow = browserWindow
            self.sessionPersistence = sessionPersistence
            self.saveDebounceDuration = saveDebounceDuration
            self.saveDelayScheduler = saveDelayScheduler
            self.isRestorationComplete = startsRestored == false
            self.lastObservedState = Self.observedSessionState(from: browserWindow)

            startObservingBrowserWindow()
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
            guard isRestorationComplete, sessionPersistence.isPersistent else {
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

        private func startObservingBrowserWindow() {
            guard sessionPersistence.isPersistent else {
                return
            }

            observation = withPortableContinuousObservation { [weak self, weak browserWindow] event in
                guard let self, let browserWindow else {
                    return
                }

                let observedState = Self.observedSessionState(from: browserWindow)
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

        private static func observedSessionState(from browserWindow: BrowserWindow) -> ObservedSessionState {
            ObservedSessionState(
                selectedTabID: browserWindow.selectedTabID,
                tabs: browserWindow.tabs.map { tab in
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
            guard let browserWindow else {
                return
            }

            let tabs = browserWindow.tabs
            let selectedID = tabs.contains(where: { $0.id == browserWindow.selectedTabID })
                ? browserWindow.selectedTabID
                : tabs[0].id

            var tabStateDataByID: [UUID: Data] = [:]
            let tabSnapshots = tabs.map { tab in
                if let stateData = tab.interactionStateData {
                    tabStateDataByID[tab.id] = stateData
                }
                return tab.snapshot()
            }

            let snapshot = BrowserSession.Snapshot(
                selectedTabID: selectedID,
                tabs: tabSnapshots
            )
            try? sessionPersistence.save(snapshot: snapshot, tabStateDataByID: tabStateDataByID)
        }
    }
}
