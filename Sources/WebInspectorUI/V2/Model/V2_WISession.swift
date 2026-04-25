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
    private(set) var selectedTab: V2_WITab?
    public let dom: V2_DOMInterfaceModel

    public init(
        tabs: [V2_WITab] = V2_WITab.defaults,
        dom: V2_DOMInterfaceModel = V2_DOMInterfaceModel()
    ) {
        self.tabs = tabs
        self.selectedTab = tabs.first
        self.dom = dom
    }

    func selectTab(_ tab: V2_WITab) {
        guard tabs.contains(tab) else {
            return
        }
        guard selectedTab != tab else {
            return
        }
        selectedTab = tab
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else {
            return
        }
        selectTab(tabs[index])
    }

    func selectTab(withID tabID: V2_WITab.ID) {
        guard let tab = tab(withID: tabID) else {
            return
        }
        selectTab(tab)
    }

    var selectedTabIndex: Int? {
        guard let selectedTab else {
            return nil
        }
        return tabs.firstIndex(of: selectedTab)
    }

    private func tab(withID tabID: V2_WITab.ID) -> V2_WITab? {
        tabs.first { $0.id == tabID }
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

    func selectCompactContent(at index: Int) {
        guard V2_DOMCompactContent.allCases.indices.contains(index) else {
            return
        }
        selectedCompactContent = V2_DOMCompactContent.allCases[index]
    }

    var selectedCompactContentIndex: Int? {
        V2_DOMCompactContent.allCases.firstIndex(of: selectedCompactContent)
    }
}
#endif
