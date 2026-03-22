import WebKit
import WebInspectorEngine
import WebInspectorTransport

public enum WIHostVisibility: Sendable {
    case visible
    case hidden
    case finalizing
}

@MainActor
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

    public let model: WIModel
    public let dom: WIDOMModel
    public let network: WINetworkModel

    public private(set) var lifecycle: WISessionLifecycle = .disconnected

    private var connectedPageWebView: WKWebView?

    public init(
        model: WIModel = WIModel(),
        configuration: WIModelConfiguration = .init()
    ) {
        self.model = model

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

        dom.setRecoverableErrorHandler { [weak model] message in
            model?.setRecoverableError(message)
        }
    }

    public func applyHostState(
        pageWebView: WKWebView?,
        visibility: WIHostVisibility
    ) async {
        if case .finalizing = visibility {
            connectedPageWebView = nil
        } else {
            connectedPageWebView = pageWebView
        }

        let plan = runtimePlan(pageWebView: pageWebView, visibility: visibility)
        await apply(plan)
        lifecycle = lifecycleForVisibility(visibility, pageWebView: pageWebView)
    }

    public func connect(to webView: WKWebView?) async {
        if let webView {
            await applyHostState(pageWebView: webView, visibility: .visible)
            return
        }
        await applyHostState(pageWebView: currentKnownPageWebView(), visibility: .hidden)
    }

    public func suspend() async {
        await applyHostState(pageWebView: currentKnownPageWebView(), visibility: .hidden)
    }

    public func disconnect() async {
        await finalize()
    }

    public func finalize() async {
        await applyHostState(pageWebView: nil, visibility: .finalizing)
    }

    package func reapplyCurrentHostState() async {
        switch lifecycle {
        case .active:
            await applyHostState(pageWebView: currentKnownPageWebView(), visibility: .visible)
        case .suspended:
            await applyHostState(pageWebView: currentKnownPageWebView(), visibility: .hidden)
        case .disconnected:
            await finalize()
        }
    }

    package func activateFromUIIfPossible() async {
        guard let webView = currentKnownPageWebView() else {
            await applyHostState(pageWebView: nil, visibility: .hidden)
            return
        }
        await applyHostState(pageWebView: webView, visibility: .visible)
    }

    @_spi(Monocly) public func tearDownForDeinit() {
        connectedPageWebView = nil
        dom.tearDownForDeinit()
        network.tearDownForDeinit()
        model.setRecoverableError(nil)
        lifecycle = .disconnected
    }
}

private extension WIInspectorController {
    private func runtimePlan(
        pageWebView: WKWebView?,
        visibility: WIHostVisibility
    ) -> WIRuntimePlan {
        switch visibility {
        case .finalizing:
            return .init(dom: .detach, network: .detach)
        case .hidden:
            return .init(dom: .suspend, network: .suspend)
        case .visible:
            guard pageWebView != nil else {
                return .init(dom: .suspend, network: .suspend)
            }
            let tabState = resolvedTabState()
            let domPlan: DOMPlan = tabState.domEnabled
                ? .attach(autoSnapshot: tabState.domAutoSnapshotEnabled)
                : .suspend
            let networkPlan: NetworkPlan = tabState.networkEnabled
                ? .attach(mode: tabState.networkMode)
                : .suspend
            return .init(dom: domPlan, network: networkPlan)
        }
    }

    private func apply(_ plan: WIRuntimePlan) async {
        switch plan.dom {
        case let .attach(autoSnapshot):
            if let connectedPageWebView {
                await dom.attach(to: connectedPageWebView)
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
            if let connectedPageWebView {
                await network.attach(to: connectedPageWebView)
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

    func lifecycleForVisibility(
        _ visibility: WIHostVisibility,
        pageWebView: WKWebView?
    ) -> WISessionLifecycle {
        switch visibility {
        case .visible:
            return pageWebView == nil ? .suspended : .active
        case .hidden:
            return .suspended
        case .finalizing:
            return .disconnected
        }
    }

    func resolvedTabState() -> (
        domEnabled: Bool,
        networkEnabled: Bool,
        domAutoSnapshotEnabled: Bool,
        networkMode: NetworkLoggingMode
    ) {
        let tabs = model.tabs
        let selectedTab = model.selectedTab
        if tabs.isEmpty {
            guard model.hasExplicitTabsConfiguration == false else {
                return (false, false, false, .stopped)
            }
            return (true, true, true, .active)
        }
        let domEnabled = tabs.contains { $0.identifier == WITab.domTabID || $0.identifier == WITab.elementTabID }
        let networkEnabled = tabs.contains { $0.identifier == WITab.networkTabID }
        let domAutoSnapshotEnabled = selectedTab?.identifier == WITab.domTabID
            || selectedTab?.identifier == WITab.elementTabID
        let networkMode: NetworkLoggingMode = selectedTab?.identifier == WITab.networkTabID ? .active : .buffering
        return (domEnabled, networkEnabled, domAutoSnapshotEnabled, networkMode)
    }

    func currentKnownPageWebView() -> WKWebView? {
        connectedPageWebView ?? dom.session.lastPageWebView ?? network.session.lastPageWebView
    }
}
