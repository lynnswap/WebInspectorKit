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
    private(set) var selection: V2_WIDisplayTab.ID?

    public init(tabs: [V2_WITab] = V2_WITab.defaults) {
        self.tabs = Self.uniqueTabs(tabs)
        self.selection = self.tabs.first?.id
    }

    func selectTab(_ tab: V2_WITab) {
        guard tabs.contains(tab) else {
            return
        }
        selectDisplayTab(withID: tab.id)
    }

    func selectTab(withID tabID: V2_WITab.ID) {
        guard tabs.contains(where: { $0.id == tabID }) else {
            return
        }
        selectDisplayTab(withID: tabID)
    }

    func selectDisplayTab(withID displayTabID: V2_WIDisplayTab.ID) {
        guard isValidDisplayTabID(displayTabID),
              selection != displayTabID else {
            return
        }
        selection = displayTabID
    }

    var selectedTab: V2_WITab? {
        guard let selection else {
            return nil
        }
        return tabs.first { $0.id == selection }
    }

    private func isValidDisplayTabID(_ displayTabID: V2_WIDisplayTab.ID) -> Bool {
        if tabs.contains(where: { $0.id == displayTabID }) {
            return true
        }
        return displayTabID == V2_WIDisplayTab.compactElementID && tabs.contains(where: { $0.definition is V2_DOMTabDefinition })
    }

    private static func uniqueTabs(_ tabs: [V2_WITab]) -> [V2_WITab] {
        tabs.reduce(into: []) { result, tab in
            guard result.contains(where: { $0.id == tab.id }) == false else {
                return
            }
            result.append(tab)
        }
    }
}
#endif
