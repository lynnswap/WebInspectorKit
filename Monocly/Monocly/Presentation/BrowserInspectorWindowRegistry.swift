import Foundation
import WebInspectorKit

#if canImport(UIKit)
import UIKit

@MainActor
final class BrowserInspectorWindowRegistry {
    private enum PresentationPhase {
        case idle
        case ready(BrowserInspectorWindowContext)
        case pending(BrowserInspectorWindowContext)
        case active(BrowserInspectorWindowContext)

        var context: BrowserInspectorWindowContext? {
            switch self {
            case .idle:
                nil
            case let .ready(context), let .pending(context), let .active(context):
                context
            }
        }

        var isPendingPresentation: Bool {
            guard case .pending = self else {
                return false
            }
            return true
        }

        func replacingContext(
            _ context: BrowserInspectorWindowContext?,
            hasAttachedSceneSession: Bool
        ) -> PresentationPhase {
            guard let context else {
                return .idle
            }
            if isPendingPresentation {
                return .pending(context)
            }
            return hasAttachedSceneSession ? .active(context) : .ready(context)
        }

        func beginPendingPresentation() -> PresentationPhase {
            guard let context else {
                return self
            }
            return .pending(context)
        }

        func attachSceneSession() -> PresentationPhase {
            guard let context else {
                return .idle
            }
            return .active(context)
        }

        func sceneSessionsChanged(
            hasAttachedSceneSession: Bool,
            shouldReleaseContext: Bool
        ) -> PresentationPhase {
            guard shouldReleaseContext == false,
                  let context else {
                return .idle
            }
            if isPendingPresentation {
                return .pending(context)
            }
            return hasAttachedSceneSession ? .active(context) : .ready(context)
        }

        func isPresented(attachedSceneCount: Int) -> Bool {
            context != nil && (isPendingPresentation || attachedSceneCount > 0)
        }
    }

    private enum RegistryEvent {
        case setContext(BrowserInspectorWindowContext?)
        case beginPendingPresentation
        case attachSceneSession(UISceneSession)
        case sceneDidDisconnect(UISceneSession)
        case discardSceneSessions([UISceneSession])
        case clear
    }

    private struct RegistryUpdate {
        var previousPresentationState: Bool
        var releaseInspectorSessionID: ObjectIdentifier?
    }

    private var phase: PresentationPhase = .idle
    private let sceneRegistry = BrowserInspectorWindowSceneRegistry()
    private var observers: [UUID: (Bool) -> Void] = [:]
    private var releaseHandlersByInspectorSessionID: [ObjectIdentifier: () -> Void] = [:]

    var currentContext: BrowserInspectorWindowContext? {
        phase.context
    }

    var currentSceneSessions: [UISceneSession] {
        sceneRegistry.currentSceneSessions
    }

    var preferredActivationSceneSession: UISceneSession? {
        sceneRegistry.preferredActivationSceneSession
    }

    var hasAttachedSceneSession: Bool {
        sceneRegistry.hasAttachedSceneSession
    }

    var presentationState: Bool {
        phase.isPresented(attachedSceneCount: sceneRegistry.attachedSceneCount)
    }

    func setContext(_ context: BrowserInspectorWindowContext?) {
        publish(apply(.setContext(context)))
    }

    func beginPendingPresentation() {
        publish(apply(.beginPendingPresentation))
    }

    func attachSceneSession(_ sceneSession: UISceneSession) {
        publish(apply(.attachSceneSession(sceneSession)))
    }

    func sceneDidDisconnect(_ sceneSession: UISceneSession) {
        publish(apply(.sceneDidDisconnect(sceneSession)))
    }

    func discardSceneSessions(_ sceneSessions: some Sequence<UISceneSession>) {
        publish(apply(.discardSceneSessions(Array(sceneSessions))))
    }

    func hasWindow(for inspectorSession: WebInspectorSession) -> Bool {
        phase.context?.inspectorSession === inspectorSession && presentationState
    }

    func setReleaseHandler(
        for inspectorSession: WebInspectorSession,
        _ handler: (() -> Void)?
    ) {
        let inspectorSessionID = ObjectIdentifier(inspectorSession)
        releaseHandlersByInspectorSessionID[inspectorSessionID] = handler
    }

    func canRestoreSceneSession(_ sceneSession: UISceneSession) -> Bool {
        phase.context != nil && sceneRegistry.canRestoreSceneSession(sceneSession)
    }

    func canConnectSceneSession(_ sceneSession: UISceneSession) -> Bool {
        phase.context != nil
            && (
                phase.isPendingPresentation
                    || sceneRegistry.canRestoreSceneSession(sceneSession)
            )
    }

    func clear() {
        publish(apply(.clear))
    }

    func addObserver(_ observer: @escaping (Bool) -> Void) -> UUID {
        let observerID = UUID()
        observers[observerID] = observer
        observer(presentationState)
        return observerID
    }

    func removeObserver(_ observerID: UUID) {
        observers[observerID] = nil
    }

    private func apply(_ event: RegistryEvent) -> RegistryUpdate {
        let previousState = presentationState
        let previousInspectorSessionID = phase.context.map { ObjectIdentifier($0.inspectorSession) }
        var releaseInspectorSessionID: ObjectIdentifier?

        switch event {
        case let .setContext(context):
            let nextInspectorSessionID = context.map { ObjectIdentifier($0.inspectorSession) }
            phase = phase.replacingContext(
                context,
                hasAttachedSceneSession: sceneRegistry.hasAttachedSceneSession
            )
            if previousInspectorSessionID != nextInspectorSessionID {
                releaseInspectorSessionID = previousInspectorSessionID
            }

        case .beginPendingPresentation:
            sceneRegistry.prepareForPendingPresentation()
            phase = phase.beginPendingPresentation()

        case let .attachSceneSession(sceneSession):
            sceneRegistry.attachSceneSession(sceneSession)
            phase = phase.attachSceneSession()

        case let .sceneDidDisconnect(sceneSession):
            sceneRegistry.sceneDidDisconnect(sceneSession)
            let shouldReleaseContext = sceneRegistry.shouldReleaseContextAfterDisconnect
                && phase.isPendingPresentation == false
            phase = phase.sceneSessionsChanged(
                hasAttachedSceneSession: sceneRegistry.hasAttachedSceneSession,
                shouldReleaseContext: shouldReleaseContext
            )
            if shouldReleaseContext {
                releaseInspectorSessionID = previousInspectorSessionID
            }

        case let .discardSceneSessions(sceneSessions):
            sceneRegistry.discardSceneSessions(sceneSessions)
            let shouldReleaseContext = sceneRegistry.shouldReleaseContextAfterDiscard
                && phase.isPendingPresentation == false
            phase = phase.sceneSessionsChanged(
                hasAttachedSceneSession: sceneRegistry.hasAttachedSceneSession,
                shouldReleaseContext: shouldReleaseContext
            )
            if shouldReleaseContext {
                releaseInspectorSessionID = previousInspectorSessionID
            }

        case .clear:
            phase = .idle
            sceneRegistry.clear()
            releaseInspectorSessionID = previousInspectorSessionID
        }

        return RegistryUpdate(
            previousPresentationState: previousState,
            releaseInspectorSessionID: releaseInspectorSessionID
        )
    }

    private func publish(_ update: RegistryUpdate) {
        releaseContext(for: update.releaseInspectorSessionID)
        notifyObserversIfNeeded(previousState: update.previousPresentationState)
    }

    private func releaseContext(for inspectorSessionID: ObjectIdentifier?) {
        guard let inspectorSessionID,
              let releaseHandler = releaseHandlersByInspectorSessionID.removeValue(forKey: inspectorSessionID) else {
            return
        }
        releaseHandler()
    }

    private func notifyObserversIfNeeded(previousState: Bool) {
        let currentState = presentationState
        guard currentState != previousState else {
            return
        }
        observers.values.forEach { $0(currentState) }
    }
}

@MainActor
private final class BrowserInspectorWindowSceneRegistry {
    private enum SceneSessionRestorationState {
        case restorable
        case stale
    }

    private final class SceneSessionRecord {
        weak var attachedSession: UISceneSession?
        weak var reusableSession: UISceneSession?
        var restorationState: SceneSessionRestorationState?

        var isRestorable: Bool {
            restorationState == .restorable
        }

        var isStale: Bool {
            restorationState == .stale
        }

        var canRestore: Bool {
            isStale == false && isRestorable
        }

        var hasAttachedSession: Bool {
            attachedSession != nil
        }
    }

    private var sceneSessionRecordsByIdentifier: [String: SceneSessionRecord] = [:]
    private var reusableSceneSessionIdentifier: String?

    var currentSceneSessions: [UISceneSession] {
        pruneDisconnectedSceneSessions()
        return sceneSessionRecordsByIdentifier.values.compactMap(\.attachedSession)
    }

    var preferredActivationSceneSession: UISceneSession? {
        pruneDisconnectedSceneSessions()
        return sceneSessionRecordsByIdentifier.values.compactMap(\.attachedSession).first
            ?? reusableSceneSessionIdentifier.flatMap {
                sceneSessionRecordsByIdentifier[$0]?.reusableSession
            }
    }

    var hasAttachedSceneSession: Bool {
        pruneDisconnectedSceneSessions()
        return sceneSessionRecordsByIdentifier.values.contains { $0.hasAttachedSession }
    }

    var attachedSceneCount: Int {
        pruneDisconnectedSceneSessions()
        return sceneSessionRecordsByIdentifier.values.filter { $0.hasAttachedSession }.count
    }

    var shouldReleaseContextAfterDisconnect: Bool {
        pruneDisconnectedSceneSessions()
        return hasRestorableSceneSession == false
    }

    var shouldReleaseContextAfterDiscard: Bool {
        pruneDisconnectedSceneSessions()
        return hasRestorableSceneSession == false && hasAttachedSceneSession == false
    }

    func prepareForPendingPresentation() {
        for record in sceneSessionRecordsByIdentifier.values where record.isRestorable {
            record.restorationState = .stale
        }
    }

    func attachSceneSession(_ sceneSession: UISceneSession) {
        let persistentIdentifier = sceneSession.persistentIdentifier
        let record = record(for: persistentIdentifier)
        record.attachedSession = sceneSession
        if reusableSceneSessionIdentifier == persistentIdentifier {
            record.reusableSession = nil
            reusableSceneSessionIdentifier = nil
        }
        record.restorationState = .restorable
    }

    func sceneDidDisconnect(_ sceneSession: UISceneSession) {
        let persistentIdentifier = sceneSession.persistentIdentifier
        clearReusableSceneSession()
        let record = record(for: persistentIdentifier)
        record.attachedSession = nil
        record.reusableSession = sceneSession
        reusableSceneSessionIdentifier = persistentIdentifier
        record.restorationState = .stale
        pruneDisconnectedSceneSessions()
    }

    func discardSceneSessions(_ sceneSessions: some Sequence<UISceneSession>) {
        for sceneSession in sceneSessions {
            let persistentIdentifier = sceneSession.persistentIdentifier
            if reusableSceneSessionIdentifier == persistentIdentifier {
                reusableSceneSessionIdentifier = nil
            }
            sceneSessionRecordsByIdentifier.removeValue(forKey: persistentIdentifier)
        }
        pruneDisconnectedSceneSessions()
    }

    func canRestoreSceneSession(_ sceneSession: UISceneSession) -> Bool {
        let record = sceneSessionRecordsByIdentifier[sceneSession.persistentIdentifier]
        return record?.canRestore == true
    }

    func clear() {
        sceneSessionRecordsByIdentifier.removeAll()
        reusableSceneSessionIdentifier = nil
    }

    private var hasRestorableSceneSession: Bool {
        sceneSessionRecordsByIdentifier.values.contains { $0.isRestorable }
    }

    private func record(for persistentIdentifier: String) -> SceneSessionRecord {
        if let record = sceneSessionRecordsByIdentifier[persistentIdentifier] {
            return record
        }
        let record = SceneSessionRecord()
        sceneSessionRecordsByIdentifier[persistentIdentifier] = record
        return record
    }

    private func clearReusableSceneSession() {
        guard let reusableSceneSessionIdentifier else {
            return
        }
        sceneSessionRecordsByIdentifier[reusableSceneSessionIdentifier]?.reusableSession = nil
        self.reusableSceneSessionIdentifier = nil
    }

    private func pruneDisconnectedSceneSessions() {
        if let currentReusableSceneSessionIdentifier = reusableSceneSessionIdentifier,
           sceneSessionRecordsByIdentifier[currentReusableSceneSessionIdentifier]?.reusableSession == nil {
            reusableSceneSessionIdentifier = nil
        }
    }
}
#endif
