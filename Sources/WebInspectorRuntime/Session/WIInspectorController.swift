import Foundation
import Observation
import OSLog
import WebKit
import WebInspectorEngine
import WebInspectorTransport

private let inspectorControllerLogger = Logger(subsystem: "WebInspectorKit", category: "WIInspectorController")
private let verboseConsoleDiagnosticsEnabled =
    ProcessInfo.processInfo.environment["WEBSPECTOR_VERBOSE_CONSOLE_LOGS"] == "1"

public enum WIHostVisibility: Sendable {
    case visible
    case hidden
    case finalizing
}

#if canImport(UIKit)
package typealias WIInspectorHostActivationScene = UIScene
#else
package typealias WIInspectorHostActivationScene = AnyObject
#endif

package struct WIInspectorHostID: Hashable, Sendable {
    fileprivate let rawValue = UUID()
}

package enum WIInspectorHostRole: Sendable {
    case primary
    case secondary
}

@MainActor
@Observable
public final class WIInspectorController {
    private enum DOMPlan {
        case attach(autoSnapshot: Bool)
        case suspend
        case detach
    }

    private enum NetworkPlan {
        case attach(mode: NetworkLoggingMode)
        case suspend
        case detach
    }

    private struct WIRuntimePlan {
        let dom: DOMPlan
        let network: NetworkPlan
    }

    private struct WIRuntimeTarget: Equatable {
        let tabs: [WITab]
        let selectedTab: WITab?
        let preferredCompactSelectedTabIdentifier: String?
        let hasExplicitTabsConfiguration: Bool
        let primaryHostVisibility: WIHostVisibility
        let primaryHostPageWebViewIdentity: ObjectIdentifier?
        let primaryHostPageWebView: WKWebView?
        let lifecycle: WISessionLifecycle

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.tabs == rhs.tabs
                && lhs.selectedTab == rhs.selectedTab
                && lhs.preferredCompactSelectedTabIdentifier == rhs.preferredCompactSelectedTabIdentifier
                && lhs.hasExplicitTabsConfiguration == rhs.hasExplicitTabsConfiguration
                && lhs.primaryHostVisibility == rhs.primaryHostVisibility
                && lhs.primaryHostPageWebViewIdentity == rhs.primaryHostPageWebViewIdentity
                && lhs.lifecycle == rhs.lifecycle
        }
    }

    private final class WIHostRecord {
        let id: WIInspectorHostID
        let preferredRole: WIInspectorHostRole
        let registrationOrder: Int
        weak var pageWebView: WKWebView?
        var visibility: WIHostVisibility = .hidden
        var isAttached = false
        var keepsDirectHostActiveDuringHiddenHandoff = false
        weak var sceneActivationRequestingScene: WIInspectorHostActivationScene?

        init(
            id: WIInspectorHostID,
            preferredRole: WIInspectorHostRole,
            registrationOrder: Int
        ) {
            self.id = id
            self.preferredRole = preferredRole
            self.registrationOrder = registrationOrder
        }
    }

    public let dom: WIDOMInspector
    public let network: WINetworkModel

    public private(set) var lastRecoverableError: String?
    public private(set) var tabs: [WITab] = []
    public private(set) var selectedTab: WITab?
    public private(set) var preferredCompactSelectedTabIdentifier: String?
    public private(set) var lifecycle: WISessionLifecycle = .disconnected

    @ObservationIgnored private var state = WIInspectorState()
    @ObservationIgnored private var hostRegistry: [WIInspectorHostID: WIHostRecord] = [:]
    @ObservationIgnored private var nextHostRegistrationOrder = 0
    @ObservationIgnored private let directHostID = WIInspectorHostID()
    @ObservationIgnored private var desiredRuntimeTarget: WIRuntimeTarget?
    @ObservationIgnored private var runtimeReconcileRequested = false
    @ObservationIgnored private var runtimeApplyTask: Task<Void, Never>?
    @ObservationIgnored private var isTearingDown = false
    @ObservationIgnored private var suppressesDirectHostActivation = false
    @ObservationIgnored private let sharedTransport: WISharedInspectorTransport
#if DEBUG
    @ObservationIgnored var testRuntimeLifecycleCommitHook: (@MainActor (WISessionLifecycle) async -> Void)?
#endif

    public init(configuration: WIModelConfiguration = .init()) {
        sharedTransport = WISharedInspectorTransport()
        let networkBackend = WIBackendFactory.makeNetworkBackend(
            configuration: configuration.network,
            sharedTransport: sharedTransport
        )
        let networkSession = NetworkSession(
            configuration: configuration.network,
            backend: networkBackend
        )

        dom = WIDOMInspector(configuration: configuration.dom, sharedTransport: sharedTransport)
        network = WINetworkModel(session: networkSession)

        dom.setRecoverableErrorHandler { [weak self] message in
            self?.setRecoverableError(message)
        }

        registerDirectHost()
        syncObservedState()
    }

    isolated deinit {
        runtimeApplyTask?.cancel()
    }

    public func setTabs(_ tabs: [WITab]) {
        setTabsFromUI(tabs, marksExplicitConfiguration: true)
    }

    public func setSelectedTab(_ tab: WITab?) {
        _ = projectSelectedTabFromUI(tab)
    }

    public func setPreferredCompactSelectedTabIdentifier(_ identifier: String?) {
        setPreferredCompactSelectedTabIdentifierFromUI(identifier)
    }

    public func applyHostState(
        pageWebView: WKWebView?,
        visibility: WIHostVisibility
    ) async {
        switch visibility {
        case .visible:
            updateHost(
                directHostID,
                pageWebView: pageWebView,
                visibility: .visible,
                isAttached: true
            )
        case .hidden:
            let retainedPageWebView = pageWebView ?? hostRegistry[directHostID]?.pageWebView
            updateHost(
                directHostID,
                pageWebView: retainedPageWebView,
                visibility: .hidden,
                isAttached: true
            )
        case .finalizing:
            updateHost(
                directHostID,
                pageWebView: nil,
                visibility: .finalizing,
                isAttached: false
            )
        }

        await waitForRuntimeApplyDrain()
    }

    public func connect(to webView: WKWebView?) async {
        if let webView {
            await applyHostState(pageWebView: webView, visibility: .visible)
        } else {
            suspendAllHosts()
            await waitForRuntimeApplyDrain()
        }
    }

    public func suspend() async {
        suspendAllHosts()
        await waitForRuntimeApplyDrain()
    }

    public func disconnect() async {
        await finalize()
    }

    public func finalize() async {
        finalizeAllHosts()
        await waitForRuntimeApplyDrain()
    }

    package func reapplyCurrentHostState() async {
        scheduleRuntimeApply()
        await waitForRuntimeApplyDrain()
    }

    package var hasExplicitTabsConfiguration: Bool {
        state.hasExplicitTabsConfiguration
    }

    package func setTabsFromUI(
        _ tabs: [WITab],
        marksExplicitConfiguration: Bool = true
    ) {
        let previousTabIdentifiers = state.tabs.map(\.identifier)
        state.setTabs(tabs, marksExplicitConfiguration: marksExplicitConfiguration)
        syncObservedState()
        logControllerDiagnostics(
            "setTabsFromUI previous=\(previousTabIdentifiers) next=\(tabs.map(\.identifier)) explicit=\(marksExplicitConfiguration)"
        )
        scheduleRuntimeApply()
    }

    @discardableResult
    package func projectSelectedTabFromUI(_ tab: WITab?) -> Bool {
        let previousSelectedTab = state.selectedTab
        let wasAccepted = state.projectSelectedTab(tab)
        syncObservedState()
        logControllerDiagnostics(
            "projectSelectedTabFromUI requested=\(tabIdentifierSummary(tab)) accepted=\(wasAccepted) previous=\(tabIdentifierSummary(previousSelectedTab)) next=\(tabIdentifierSummary(state.selectedTab))"
        )
        if wasAccepted {
            scheduleRuntimeApply()
        }
        return wasAccepted
    }

    package func setSelectedTabFromUI(_ tab: WITab?) {
        _ = projectSelectedTabFromUI(tab)
    }

    package func setPreferredCompactSelectedTabIdentifierFromUI(_ identifier: String?) {
        let previousIdentifier = state.preferredCompactSelectedTabIdentifier
        state.setPreferredCompactSelectedTabIdentifier(identifier)
        syncObservedState()
        logControllerDiagnostics(
            "setPreferredCompactSelectedTabIdentifierFromUI previous=\(previousIdentifier ?? "nil") next=\(identifier ?? "nil")"
        )
        scheduleRuntimeApply()
    }

    package func registerHost(
        preferredRole: WIInspectorHostRole? = nil
    ) -> WIInspectorHostID {
        let hostID = WIInspectorHostID()
        let resolvedRole = preferredRole ?? defaultRoleForNewUIHost()
        nextHostRegistrationOrder += 1
        hostRegistry[hostID] = WIHostRecord(
            id: hostID,
            preferredRole: resolvedRole,
            registrationOrder: nextHostRegistrationOrder
        )
        logControllerDiagnostics(
            "registerHost host=\(hostSummary(hostRegistry[hostID])) hosts=\(hostRegistrySummary())",
            level: .debug
        )
        updateSceneActivationRequestingSceneIfNeeded()
        scheduleRuntimeApply()
        return hostID
    }

    package func unregisterHost(_ hostID: WIInspectorHostID) {
        let previousVisibleUIHostCount = visibleUIHostCount()
        let removedHostSummary = hostSummary(hostRegistry[hostID])
        hostRegistry.removeValue(forKey: hostID)
        updateDirectHostActivationSuppression(
            afterMutatingHost: hostID,
            previousVisibleUIHostCount: previousVisibleUIHostCount,
            newVisibility: nil
        )
        logControllerDiagnostics(
            "unregisterHost removed=\(removedHostSummary) hosts=\(hostRegistrySummary())",
            level: .debug
        )
        updateSceneActivationRequestingSceneIfNeeded()
        scheduleRuntimeApply()
    }

    package func finalizeForControllerSwap() {
        logControllerDiagnostics("finalizeForControllerSwap directHost=\(hostSummary(hostRegistry[directHostID]))")
        updateHost(
            directHostID,
            pageWebView: nil,
            visibility: .finalizing,
            isAttached: false
        )
    }

    package func preferredRole(for hostID: WIInspectorHostID) -> WIInspectorHostRole? {
        hostRegistry[hostID]?.preferredRole
    }

    package func prepareHiddenHostForSameWebViewHandoff(_ hostID: WIInspectorHostID) {
        hostRegistry[hostID]?.keepsDirectHostActiveDuringHiddenHandoff = true
        logControllerDiagnostics(
            "prepareHiddenHostForSameWebViewHandoff host=\(hostSummary(hostRegistry[hostID]))"
        )
        scheduleRuntimeApply()
    }

    package var testPrimaryHostPageWebViewIdentity: ObjectIdentifier? {
        makeRuntimeTarget().primaryHostPageWebViewIdentity
    }

    package func updateHost(
        _ hostID: WIInspectorHostID,
        pageWebView: WKWebView?,
        visibility: WIHostVisibility,
        isAttached: Bool,
        sceneActivationRequestingScene: WIInspectorHostActivationScene? = nil
    ) {
        guard let host = hostRegistry[hostID] else {
            return
        }

        let previousVisibleUIHostCount = visibleUIHostCount()
        let previousHostSummary = hostSummary(hostRegistry[hostID])
        host.pageWebView = pageWebView
        host.visibility = visibility
        host.isAttached = isAttached
        if visibility == .visible {
            host.keepsDirectHostActiveDuringHiddenHandoff = false
        }
        host.sceneActivationRequestingScene = sceneActivationRequestingScene
        updateDirectHostActivationSuppression(
            afterMutatingHost: hostID,
            previousVisibleUIHostCount: previousVisibleUIHostCount,
            newVisibility: visibility
        )
        logControllerDiagnostics(
            "updateHost previous=\(previousHostSummary) next=\(hostSummary(host)) hosts=\(hostRegistrySummary())",
            level: .debug
        )
        updateSceneActivationRequestingSceneIfNeeded()
        scheduleRuntimeApply()
    }

    package func waitForRuntimeApplyForTesting() async {
        await waitForRuntimeApplyDrain()
    }

    @_spi(Monocly) public func tearDownForDeinit() {
        isTearingDown = true
        desiredRuntimeTarget = nil
        runtimeReconcileRequested = false
        runtimeApplyTask?.cancel()
        runtimeApplyTask = nil
        hostRegistry.removeAll()
        suppressesDirectHostActivation = false
        dom.tearDownForDeinit()
        network.tearDownForDeinit()
        state.setRecoverableError(nil)
        syncObservedState()
        lifecycle = .disconnected
    }
}

private extension WIInspectorController {
    private func registerDirectHost() {
        hostRegistry[directHostID] = WIHostRecord(
            id: directHostID,
            preferredRole: .primary,
            registrationOrder: 0
        )
        updateSceneActivationRequestingSceneIfNeeded()
    }

    private func setRecoverableError(_ message: String?) {
        state.setRecoverableError(message)
        syncObservedState()
    }

    private func visibleUIHostCount() -> Int {
        hostRegistry.values.reduce(into: 0) { count, host in
            guard host.id != directHostID,
                  host.isAttached,
                  host.visibility == .visible else {
                return
            }
            count += 1
        }
    }

    private func updateDirectHostActivationSuppression(
        afterMutatingHost hostID: WIInspectorHostID,
        previousVisibleUIHostCount: Int,
        newVisibility: WIHostVisibility?
    ) {
        if hostID == directHostID {
            let currentVisibleUIHostCount = visibleUIHostCount()
            if newVisibility == .visible,
               currentVisibleUIHostCount == 0 {
                // Treat an explicit visible direct-host update as a reconnect signal
                // once every UI host has gone away.
                suppressesDirectHostActivation = false
            }
            return
        }

        let currentVisibleUIHostCount = visibleUIHostCount()
        if currentVisibleUIHostCount > 0 {
            suppressesDirectHostActivation = false
            return
        }

        if previousVisibleUIHostCount > 0 {
            suppressesDirectHostActivation = true
        }
    }

    private func syncObservedState() {
        lastRecoverableError = state.lastRecoverableError
        tabs = state.tabs
        selectedTab = state.selectedTab
        preferredCompactSelectedTabIdentifier = state.preferredCompactSelectedTabIdentifier
    }

    private func defaultRoleForNewUIHost() -> WIInspectorHostRole {
        hostRegistry.values.contains(where: { $0.id != directHostID && $0.preferredRole == .primary })
            ? .secondary
            : .primary
    }

    private func updateSceneActivationRequestingSceneIfNeeded() {
#if canImport(UIKit)
        dom.sceneActivationRequestingScene = resolvedSceneActivationRequestingScene()
#endif
    }

#if canImport(UIKit)
    private func resolvedSceneActivationRequestingScene() -> UIScene? {
        let visibleUIHosts = hostRegistry.values
            .filter { $0.id != directHostID && $0.isAttached && $0.visibility == .visible }
            .sorted { $0.registrationOrder < $1.registrationOrder }

        if let primaryScene = visibleUIHosts
            .filter({ $0.preferredRole == .primary })
            .compactMap(activeSceneActivationRequestingScene(for:))
            .first {
            return primaryScene
        }

        return visibleUIHosts
            .filter { $0.preferredRole == .secondary }
            .compactMap(activeSceneActivationRequestingScene(for:))
            .first
    }

    private func activeSceneActivationRequestingScene(for host: WIHostRecord) -> UIScene? {
        guard let scene = host.sceneActivationRequestingScene,
              scene.activationState == .foregroundActive else {
            return nil
        }
        return scene
    }
#endif

    private func scheduleRuntimeApply() {
        guard isTearingDown == false else {
            return
        }
        let nextTarget = makeRuntimeTarget()
        if desiredRuntimeTarget != nextTarget {
            logControllerDiagnostics(
                "scheduleRuntimeApply previousTarget=\(runtimeTargetSummary(desiredRuntimeTarget)) nextTarget=\(runtimeTargetSummary(nextTarget)) hosts=\(hostRegistrySummary())",
                level: .debug
            )
        }
        desiredRuntimeTarget = nextTarget
        runtimeReconcileRequested = true

        guard runtimeApplyTask == nil else {
            return
        }

        let applyTask = Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                self.runtimeApplyTask = nil
                if self.isTearingDown == false, self.runtimeReconcileRequested {
                    self.scheduleRuntimeApply()
                }
            }

            while self.isTearingDown == false {
                guard self.runtimeReconcileRequested, let target = self.desiredRuntimeTarget else {
                    return
                }
                self.runtimeReconcileRequested = false
                await self.applyRuntimeTarget(target)
            }
        }
        runtimeApplyTask = applyTask
    }

    private func applyRuntimeTarget(_ target: WIRuntimeTarget) async {
        guard isTearingDown == false else {
            return
        }
        let plan = runtimePlan(for: target)
        logControllerDiagnostics(
            "applyRuntimeTarget lifecycle=\(lifecycleSummary(lifecycle))->\(lifecycleSummary(target.lifecycle)) plan=\(runtimePlanSummary(plan)) target=\(runtimeTargetSummary(target)) domSelected=\(domSelectionSummary()) hosts=\(hostRegistrySummary())"
        )

        switch target.lifecycle {
        case .active:
            await apply(plan, pageWebView: target.primaryHostPageWebView)
        case .suspended:
            if lifecycle == .active {
                await apply(
                    .init(dom: .suspend, network: .suspend),
                    pageWebView: nil
                )
            }
        case .disconnected:
            if lifecycle != .disconnected {
                await apply(
                    .init(dom: .detach, network: .detach),
                    pageWebView: nil
                )
            }
        }

#if DEBUG
        if let testRuntimeLifecycleCommitHook {
            await testRuntimeLifecycleCommitHook(target.lifecycle)
        }
#endif
        lifecycle = target.lifecycle
    }

    private func makeRuntimeTarget() -> WIRuntimeTarget {
        let visiblePrimaryHost = effectiveVisiblePrimaryHost(
            suppressingDirectHostActivation: suppressesDirectHostActivation
        )
        let hiddenPrimaryHostForWarmup = hiddenPrimaryHostDuringPreparedHandoff()
        let retainedPrimaryHost = retainedPrimaryHostCandidate()
        let activePrimaryHost = visiblePrimaryHost ?? hiddenPrimaryHostForWarmup
        let primaryHost = activePrimaryHost ?? retainedPrimaryHost

        let lifecycle: WISessionLifecycle
        if let activePrimaryHost, activePrimaryHost.pageWebView != nil {
            lifecycle = .active
        } else if primaryHost != nil {
            lifecycle = .suspended
        } else {
            lifecycle = .disconnected
        }

        return WIRuntimeTarget(
            tabs: state.tabs,
            selectedTab: state.selectedTab,
            preferredCompactSelectedTabIdentifier: state.preferredCompactSelectedTabIdentifier,
            hasExplicitTabsConfiguration: state.hasExplicitTabsConfiguration,
            primaryHostVisibility: activePrimaryHost?.visibility ?? .hidden,
            primaryHostPageWebViewIdentity: primaryHost?.pageWebView.map(ObjectIdentifier.init),
            primaryHostPageWebView: primaryHost?.pageWebView,
            lifecycle: lifecycle
        )
    }

    private func effectiveVisiblePrimaryHost(
        suppressingDirectHostActivation: Bool
    ) -> WIHostRecord? {
        let visibleHosts = hostRegistry.values
            .filter { $0.isAttached && $0.visibility == .visible }
            .sorted { $0.registrationOrder < $1.registrationOrder }

        let visibleUIHosts = visibleHosts.filter { $0.id != directHostID }
        let visibleDirectHosts = suppressingDirectHostActivation
            ? []
            : visibleHosts.filter { $0.id == directHostID }

        if let primaryHost = visibleUIHosts.first(where: {
            $0.preferredRole == .primary && $0.pageWebView != nil
        }) {
            return primaryHost
        }
        if let secondaryHost = visibleUIHosts.first(where: {
            $0.preferredRole == .secondary && $0.pageWebView != nil
        }) {
            return secondaryHost
        }
        if let directHost = visibleDirectHosts.first(where: { $0.pageWebView != nil }) {
            return directHost
        }
        if let primaryHost = visibleUIHosts.first(where: { $0.preferredRole == .primary }) {
            return primaryHost
        }
        if let secondaryHost = visibleUIHosts.first(where: { $0.preferredRole == .secondary }) {
            return secondaryHost
        }
        return visibleDirectHosts.first
    }

    private func retainedPrimaryHostCandidate() -> WIHostRecord? {
        let attachedHosts = hostRegistry.values
            .filter { $0.isAttached && $0.visibility != .finalizing }
            .sorted { $0.registrationOrder < $1.registrationOrder }

        let attachedUIHosts = attachedHosts.filter { $0.id != directHostID }
        let attachedDirectHosts = attachedHosts.filter { $0.id == directHostID }

        if let primaryHost = attachedUIHosts.first(where: { $0.preferredRole == .primary }) {
            return primaryHost
        }
        if let secondaryHost = attachedUIHosts.first(where: { $0.preferredRole == .secondary }) {
            return secondaryHost
        }
        return attachedDirectHosts.first
    }

    private func hiddenPrimaryHostDuringPreparedHandoff() -> WIHostRecord? {
        let directHost = hostRegistry[directHostID]
        guard directHost?.isAttached == true,
              directHost?.visibility == .hidden,
              let directHostPageWebViewIdentity = directHost?.pageWebView.map(ObjectIdentifier.init) else {
            return nil
        }

        let hasPreparedHiddenUIHost = hostRegistry.values.contains { host in
            host.id != directHostID
                && host.isAttached
                && host.keepsDirectHostActiveDuringHiddenHandoff
                && host.pageWebView.map(ObjectIdentifier.init) == directHostPageWebViewIdentity
        }
        guard hasPreparedHiddenUIHost else {
            return nil
        }

        return directHost
    }

    private func runtimePlan(for target: WIRuntimeTarget) -> WIRuntimePlan {
        switch target.lifecycle {
        case .disconnected:
            return .init(dom: .detach, network: .detach)
        case .suspended:
            return .init(dom: .suspend, network: .suspend)
        case .active:
            guard target.primaryHostPageWebView != nil else {
                return .init(dom: .suspend, network: .suspend)
            }
            let tabState = resolvedTabState(for: target)
            return .init(
                dom: tabState.domEnabled
                    ? .attach(autoSnapshot: tabState.domAutoSnapshotEnabled)
                    : .suspend,
                network: tabState.networkEnabled
                    ? .attach(mode: tabState.networkMode)
                    : .suspend
            )
        }
    }

    private func resolvedTabState(for target: WIRuntimeTarget) -> (
        domEnabled: Bool,
        networkEnabled: Bool,
        domAutoSnapshotEnabled: Bool,
        networkMode: NetworkLoggingMode
    ) {
        if target.tabs.isEmpty {
            guard target.hasExplicitTabsConfiguration == false else {
                return (false, false, false, .stopped)
            }
            return (true, true, true, .active)
        }

        let domEnabled = target.tabs.contains {
            $0.identifier == WITab.domTabID || $0.identifier == WITab.elementTabID
        }
        let networkEnabled = target.tabs.contains { $0.identifier == WITab.networkTabID }
        let domAutoSnapshotEnabled = target.selectedTab?.identifier == WITab.domTabID
            || target.selectedTab?.identifier == WITab.elementTabID
        let networkMode: NetworkLoggingMode = target.selectedTab?.identifier == WITab.networkTabID
            ? .active
            : .buffering

        return (domEnabled, networkEnabled, domAutoSnapshotEnabled, networkMode)
    }

    private func apply(
        _ plan: WIRuntimePlan,
        pageWebView: WKWebView?
    ) async {
        switch plan.network {
        case let .attach(mode):
            if let pageWebView {
                await network.attach(to: pageWebView)
                await network.setMode(mode)
            } else {
                await network.suspend()
            }
        case .suspend:
            await network.suspend()
        case .detach:
            await network.detach()
        }

        switch plan.dom {
        case let .attach(autoSnapshot):
            if let pageWebView {
                await dom.attach(to: pageWebView)
            } else {
                await dom.suspend()
            }
            await dom.setAutoSnapshotEnabled(autoSnapshot)
        case .suspend:
            await dom.suspend()
        case .detach:
            await dom.detach()
        }
    }

    private func waitForRuntimeApplyDrain() async {
        while let runtimeApplyTask {
            await runtimeApplyTask.value
        }
    }

    private func suspendAllHosts() {
        for host in hostRegistry.values {
            host.visibility = .hidden
            host.isAttached = true
        }
        scheduleRuntimeApply()
    }

    private func finalizeAllHosts() {
        for host in hostRegistry.values {
            host.pageWebView = nil
            host.visibility = .finalizing
            host.isAttached = false
            host.sceneActivationRequestingScene = nil
        }
        suppressesDirectHostActivation = false
        updateSceneActivationRequestingSceneIfNeeded()
        scheduleRuntimeApply()
    }

    private func logControllerDiagnostics(
        _ message: String,
        level: OSLogType = .default
    ) {
        if verboseConsoleDiagnosticsEnabled == false,
           level != .error,
           level != .fault {
            return
        }
        switch level {
        case .error, .fault:
            inspectorControllerLogger.error("\(message, privacy: .public)")
        case .debug:
            inspectorControllerLogger.debug("\(message, privacy: .public)")
        default:
            inspectorControllerLogger.notice("\(message, privacy: .public)")
        }
    }

    private func tabIdentifierSummary(_ tab: WITab?) -> String {
        tab?.identifier ?? "nil"
    }

    private func lifecycleSummary(_ lifecycle: WISessionLifecycle) -> String {
        switch lifecycle {
        case .active:
            return "active"
        case .suspended:
            return "suspended"
        case .disconnected:
            return "disconnected"
        }
    }

    private func visibilitySummary(_ visibility: WIHostVisibility) -> String {
        switch visibility {
        case .visible:
            return "visible"
        case .hidden:
            return "hidden"
        case .finalizing:
            return "finalizing"
        }
    }

    private func hostRoleSummary(_ role: WIInspectorHostRole) -> String {
        switch role {
        case .primary:
            return "primary"
        case .secondary:
            return "secondary"
        }
    }

    private func webViewSummary(_ webView: WKWebView?) -> String {
        guard let webView else {
            return "nil"
        }
        return String(describing: ObjectIdentifier(webView))
    }

    private func compactHostID(_ hostID: WIInspectorHostID?) -> String {
        guard let hostID else {
            return "nil"
        }
        return String(hostID.rawValue.uuidString.prefix(8))
    }

    private func hostSummary(_ host: WIHostRecord?) -> String {
        guard let host else {
            return "nil"
        }
        let kind = host.id == directHostID ? "direct" : "ui"
        return "id=\(compactHostID(host.id)) kind=\(kind) role=\(hostRoleSummary(host.preferredRole)) visibility=\(visibilitySummary(host.visibility)) attached=\(host.isAttached) handoff=\(host.keepsDirectHostActiveDuringHiddenHandoff) webView=\(webViewSummary(host.pageWebView))"
    }

    private func hostRegistrySummary() -> String {
        let hosts = hostRegistry.values
            .sorted { $0.registrationOrder < $1.registrationOrder }
            .map { hostSummary($0) }
        return hosts.isEmpty ? "[]" : "[\(hosts.joined(separator: ", "))]"
    }

    private func runtimeTargetSummary(_ target: WIRuntimeTarget?) -> String {
        guard let target else {
            return "nil"
        }
        return "lifecycle=\(lifecycleSummary(target.lifecycle)) selectedTab=\(tabIdentifierSummary(target.selectedTab)) preferredCompact=\(target.preferredCompactSelectedTabIdentifier ?? "nil") primaryVisibility=\(visibilitySummary(target.primaryHostVisibility)) primaryWebView=\(webViewSummary(target.primaryHostPageWebView)) tabs=\(target.tabs.map(\.identifier))"
    }

    private func runtimePlanSummary(_ plan: WIRuntimePlan) -> String {
        let domPlan: String
        switch plan.dom {
        case let .attach(autoSnapshot):
            domPlan = "attach(autoSnapshot=\(autoSnapshot))"
        case .suspend:
            domPlan = "suspend"
        case .detach:
            domPlan = "detach"
        }

        let networkPlan: String
        switch plan.network {
        case let .attach(mode):
            networkPlan = "attach(mode=\(String(describing: mode)))"
        case .suspend:
            networkPlan = "suspend"
        case .detach:
            networkPlan = "detach"
        }

        return "dom=\(domPlan) network=\(networkPlan)"
    }

    private func domSelectionSummary() -> String {
        guard let node = dom.document.selectedNode else {
            return "nil"
        }
        let nodeName = node.localName.isEmpty ? node.nodeName : node.localName
        return "\(nodeName)#local=\(node.localID)#backend=\(node.backendNodeID.map(String.init) ?? "nil")#selector=\(node.selectorPath)"
    }
}
