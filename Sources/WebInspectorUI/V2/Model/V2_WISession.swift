#if canImport(UIKit)
import Observation
import WebKit
import WebInspectorRuntime

@MainActor
@Observable
public final class V2_WISession {
    public let runtime: V2_WIRuntimeSession
    public let interface: V2_WIInterfaceModel

    public init(
        runtime: V2_WIRuntimeSession = V2_WIRuntimeSession(),
        interface: V2_WIInterfaceModel = V2_WIInterfaceModel()
    ) {
        self.runtime = runtime
        self.interface = interface
    }

    public convenience init(tabs: [V2_WITab]) {
        self.init(interface: V2_WIInterfaceModel(tabs: tabs))
    }

    public func attach(to webView: WKWebView) async {
        await runtime.attach(to: webView)
    }

    public func detach() async {
        await runtime.detach()
    }
}

@MainActor
@Observable
public final class V2_WIInterfaceModel {
    private(set) var tabs: [V2_WITab]
    private(set) var selectedTab: V2_WITab.ID?
    public let dom: V2_DOMInterfaceModel

    public init(
        tabs: [V2_WITab] = V2_WITab.defaults,
        dom: V2_DOMInterfaceModel = V2_DOMInterfaceModel()
    ) {
        self.tabs = tabs
        self.selectedTab = tabs.first?.id
        self.dom = dom
    }

    func selectTab(_ tabID: V2_WITab.ID) {
        guard containsTab(withID: tabID) else {
            return
        }
        selectedTab = tabID
    }

    var selectedTabModel: V2_WITab? {
        guard let selectedTab else {
            return nil
        }
        return tabs.first { $0.id == selectedTab }
    }

    func containsTab(withID tabID: V2_WITab.ID) -> Bool {
        tabs.contains { $0.id == tabID }
    }
}

@MainActor
@Observable
public final class V2_DOMInterfaceModel {
    private(set) var selectedCompactContent: V2_DOMCompactContent = .tree

    public init() {}

    func selectCompactContent(_ content: V2_DOMCompactContent) {
        selectedCompactContent = content
    }
}
#endif
