import Foundation
import Observation
import WebKit
import WebInspectorEngine
import WebInspectorTransport

public enum WIHostVisibility: Sendable {
    case visible
    case hidden
    case finalizing
}

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

    private struct WIRuntimeSnapshot {
        let revision: Int
        let tabs: [WITab]
        let selectedTab: WITab?
        let preferredCompactSelectedTabIdentifier: String?
        let hasExplicitTabsConfiguration: Bool
        let primaryHostVisibility: WIHostVisibility
        let primaryHostPageWebViewIdentity: ObjectIdentifier?
        let primaryHostPageWebView: WKWebView?
        let lifecycle: WISessionLifecycle
    }

    private final class WIHostRecord {
        let id: WIInspectorHostID
        let preferredRole: WIInspectorHostRole
        let registrationOrder: Int
        weak var pageWebView: WKWebView?
        var visibility: WIHostVisibility = .hidden
        var isAttached = false

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

    public let dom: WIDOMModel
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
    @ObservationIgnored private var pendingRuntimeSnapshot: WIRuntimeSnapshot?
    @ObservationIgnored private var runtimeApplyTask: Task<Void, Never>?
    @ObservationIgnored private var latestScheduledRevision = 0
    @ObservationIgnored private var isTearingDown = false

    public init(configuration: WIModelConfiguration = .init()) {
        let domSession = DOMSession(configuration: configuration.dom)
        let networkBackend = WIBackendFactory.makeNetworkBackend(
            configuration: configuration.network
        )
        let networkSession = NetworkSession(
            configuration: configuration.network,
            backend: networkBackend
        )

        dom = WIDOMModel(session: domSession)
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
        state.setTabs(tabs, marksExplicitConfiguration: marksExplicitConfiguration)
        syncObservedState()
        scheduleRuntimeApply()
    }

    @discardableResult
    package func projectSelectedTabFromUI(_ tab: WITab?) -> Bool {
        let wasAccepted = state.projectSelectedTab(tab)
        syncObservedState()
        if wasAccepted {
            scheduleRuntimeApply()
        }
        return wasAccepted
    }

    package func setSelectedTabFromUI(_ tab: WITab?) {
        _ = projectSelectedTabFromUI(tab)
    }

    package func setPreferredCompactSelectedTabIdentifierFromUI(_ identifier: String?) {
        state.setPreferredCompactSelectedTabIdentifier(identifier)
        syncObservedState()
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
        scheduleRuntimeApply()
        return hostID
    }

    package func unregisterHost(_ hostID: WIInspectorHostID) {
        hostRegistry.removeValue(forKey: hostID)
        scheduleRuntimeApply()
    }

    package func finalizeForControllerSwap() {
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

    package func updateHost(
        _ hostID: WIInspectorHostID,
        pageWebView: WKWebView?,
        visibility: WIHostVisibility,
        isAttached: Bool
    ) {
        guard let host = hostRegistry[hostID] else {
            return
        }

        host.pageWebView = pageWebView
        host.visibility = visibility
        host.isAttached = isAttached
        scheduleRuntimeApply()
    }

    package func waitForRuntimeApplyForTesting() async {
        await waitForRuntimeApplyDrain()
    }

    @_spi(Monocly) public func tearDownForDeinit() {
        isTearingDown = true
        pendingRuntimeSnapshot = nil
        runtimeApplyTask?.cancel()
        runtimeApplyTask = nil
        hostRegistry.removeAll()
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
    }

    private func setRecoverableError(_ message: String?) {
        state.setRecoverableError(message)
        syncObservedState()
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

    private func scheduleRuntimeApply() {
        guard isTearingDown == false else {
            return
        }
        latestScheduledRevision += 1
        pendingRuntimeSnapshot = makeRuntimeSnapshot(revision: latestScheduledRevision)

        guard runtimeApplyTask == nil else {
            return
        }

        let applyTask = Task { [weak self] in
            guard let self else {
                return
            }

            defer {
                self.runtimeApplyTask = nil
                if self.isTearingDown == false, self.pendingRuntimeSnapshot != nil {
                    self.scheduleRuntimeApply()
                }
            }

            while let snapshot = self.pendingRuntimeSnapshot {
                guard self.isTearingDown == false else {
                    self.pendingRuntimeSnapshot = nil
                    return
                }
                self.pendingRuntimeSnapshot = nil
                guard snapshot.revision == self.latestScheduledRevision else {
                    continue
                }
                await self.applyRuntimeSnapshot(snapshot)
            }
        }
        runtimeApplyTask = applyTask
    }

    private func applyRuntimeSnapshot(_ snapshot: WIRuntimeSnapshot) async {
        guard isTearingDown == false else {
            return
        }
        let plan = runtimePlan(for: snapshot)

        switch snapshot.lifecycle {
        case .active:
            await apply(plan, pageWebView: snapshot.primaryHostPageWebView)
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

        lifecycle = snapshot.lifecycle
    }

    private func makeRuntimeSnapshot(revision: Int) -> WIRuntimeSnapshot {
        let visiblePrimaryHost = effectiveVisiblePrimaryHost()
        let retainedPrimaryHost = retainedPrimaryHostCandidate()
        let primaryHost = visiblePrimaryHost ?? retainedPrimaryHost

        let lifecycle: WISessionLifecycle
        if let visiblePrimaryHost, visiblePrimaryHost.pageWebView != nil {
            lifecycle = .active
        } else if primaryHost != nil {
            lifecycle = .suspended
        } else {
            lifecycle = .disconnected
        }

        return WIRuntimeSnapshot(
            revision: revision,
            tabs: state.tabs,
            selectedTab: state.selectedTab,
            preferredCompactSelectedTabIdentifier: state.preferredCompactSelectedTabIdentifier,
            hasExplicitTabsConfiguration: state.hasExplicitTabsConfiguration,
            primaryHostVisibility: visiblePrimaryHost == nil ? .hidden : .visible,
            primaryHostPageWebViewIdentity: primaryHost?.pageWebView.map(ObjectIdentifier.init),
            primaryHostPageWebView: primaryHost?.pageWebView,
            lifecycle: lifecycle
        )
    }

    private func effectiveVisiblePrimaryHost() -> WIHostRecord? {
        let visibleHosts = hostRegistry.values
            .filter { $0.isAttached && $0.visibility == .visible }
            .sorted { $0.registrationOrder < $1.registrationOrder }

        let visibleUIHosts = visibleHosts.filter { $0.id != directHostID }
        let visibleDirectHosts = visibleHosts.filter { $0.id == directHostID }

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

    private func runtimePlan(for snapshot: WIRuntimeSnapshot) -> WIRuntimePlan {
        switch snapshot.lifecycle {
        case .disconnected:
            return .init(dom: .detach, network: .detach)
        case .suspended:
            return .init(dom: .suspend, network: .suspend)
        case .active:
            guard snapshot.primaryHostPageWebView != nil else {
                return .init(dom: .suspend, network: .suspend)
            }
            let tabState = resolvedTabState(for: snapshot)
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

    private func resolvedTabState(for snapshot: WIRuntimeSnapshot) -> (
        domEnabled: Bool,
        networkEnabled: Bool,
        domAutoSnapshotEnabled: Bool,
        networkMode: NetworkLoggingMode
    ) {
        if snapshot.tabs.isEmpty {
            guard snapshot.hasExplicitTabsConfiguration == false else {
                return (false, false, false, .stopped)
            }
            return (true, true, true, .active)
        }

        let domEnabled = snapshot.tabs.contains {
            $0.identifier == WITab.domTabID || $0.identifier == WITab.elementTabID
        }
        let networkEnabled = snapshot.tabs.contains { $0.identifier == WITab.networkTabID }
        let domAutoSnapshotEnabled = snapshot.selectedTab?.identifier == WITab.domTabID
            || snapshot.selectedTab?.identifier == WITab.elementTabID
        let networkMode: NetworkLoggingMode = snapshot.selectedTab?.identifier == WITab.networkTabID
            ? .active
            : .buffering

        return (domEnabled, networkEnabled, domAutoSnapshotEnabled, networkMode)
    }

    private func apply(
        _ plan: WIRuntimePlan,
        pageWebView: WKWebView?
    ) async {
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
        }
        scheduleRuntimeApply()
    }
}
