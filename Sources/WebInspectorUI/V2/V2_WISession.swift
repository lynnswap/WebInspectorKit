#if canImport(UIKit)
import Observation
import UIKit
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

    isolated deinit {
        interface.removeContentCache(for: self)
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
    @ObservationIgnored private var contentViewControllerBySessionID: [
        ObjectIdentifier: [V2_WIDisplayContentKey: UIViewController]
    ] = [:]

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

    func setTabs(_ tabs: [V2_WITab]) {
        let uniqueTabs = Self.uniqueTabs(tabs)
        self.tabs = uniqueTabs
        pruneContentCache(retaining: Self.reachableContentKeys(for: self.tabs))
        guard let selection,
              isValidDisplayTabID(selection) else {
            self.selection = self.tabs.first?.id
            return
        }
    }

    func viewController<Content: UIViewController>(
        for key: V2_WIDisplayContentKey,
        session: V2_WISession,
        make: () -> Content
    ) -> Content {
        let sessionID = ObjectIdentifier(session)
        if let viewController = contentViewControllerBySessionID[sessionID]?[key] {
            if let contentViewController = viewController as? Content {
                return contentViewController
            }
            viewController.wiDetachFromV2ContainerForReuse()
        }

        let viewController = make()
        contentViewControllerBySessionID[sessionID, default: [:]][key] = viewController
        return viewController
    }

    func pruneContentCache(retaining keys: Set<V2_WIDisplayContentKey>) {
        for (sessionID, cache) in contentViewControllerBySessionID {
            var retainedCache: [V2_WIDisplayContentKey: UIViewController] = [:]
            for (key, viewController) in cache {
                guard keys.contains(key) else {
                    viewController.wiDetachFromV2ContainerForReuse()
                    continue
                }
                retainedCache[key] = viewController
            }
            contentViewControllerBySessionID[sessionID] = retainedCache
        }
    }

    func removeContentCache(for session: V2_WISession) {
        let sessionID = ObjectIdentifier(session)
        guard let cache = contentViewControllerBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        for viewController in cache.values {
            viewController.wiDetachFromV2ContainerForReuse()
        }
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

    private static func reachableContentKeys(for tabs: [V2_WITab]) -> Set<V2_WIDisplayContentKey> {
        let resolver = V2_WITabResolver()
        return resolver.contentKeys(for: .compact, tabs: tabs)
            .union(resolver.contentKeys(for: .regular, tabs: tabs))
    }
}
#endif
