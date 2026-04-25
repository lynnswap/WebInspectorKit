#if canImport(UIKit)
import ObservationBridge
import UIKit

@MainActor
protocol V2_WITabHostRendering: AnyObject {
    func renderTabs(_ displayTabs: [V2_WIDisplayTab], animated: Bool)
    func renderSelection(_ selectedDisplayTab: V2_WIDisplayTab?, animated: Bool)
}

@MainActor
final class V2_WITabHostCoordinator {
    private let interface: V2_WIInterfaceModel
    private let hostLayout: V2_WITabHostLayout
    private let resolver = V2_WITabResolver()
    private weak var renderer: (any V2_WITabHostRendering)?
    private var observationHandles: Set<ObservationHandle> = []

    init(
        interface: V2_WIInterfaceModel,
        hostLayout: V2_WITabHostLayout,
        renderer: any V2_WITabHostRendering
    ) {
        self.interface = interface
        self.hostLayout = hostLayout
        self.renderer = renderer

        renderTabsAndSelection(animated: false)
        bindInterface()
    }

    deinit {
        observationHandles.removeAll()
    }

    func selectDisplayTab(withID displayTabID: V2_WIDisplayTab.ID) {
        guard let displayTab = displayTabs().first(where: { $0.id == displayTabID }) else {
            return
        }
        interface.selectDisplayTab(withID: displayTab.id)
    }

    private func bindInterface() {
        interface.observe(\.tabs) { [weak self] _ in
            self?.renderTabsAndSelection(animated: true)
        }
        .store(in: &observationHandles)

        interface.observe(\.selection) { [weak self] _ in
            self?.renderSelection(animated: false)
        }
        .store(in: &observationHandles)
    }

    private func renderTabsAndSelection(animated: Bool) {
        renderer?.renderTabs(displayTabs(), animated: animated)
        renderSelection(animated: false)
    }

    private func renderSelection(animated: Bool) {
        renderer?.renderSelection(selectedDisplayTab(), animated: animated)
    }

    private func displayTabs() -> [V2_WIDisplayTab] {
        resolver.displayTabs(for: hostLayout, tabs: interface.tabs)
    }

    private func selectedDisplayTab() -> V2_WIDisplayTab? {
        resolver.selectedDisplayTab(
            for: hostLayout,
            tabs: interface.tabs,
            selection: interface.selection
        )
    }
}
#endif
