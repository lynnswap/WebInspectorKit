#if canImport(UIKit)
import UIKit
import WebInspectorEngine
import WebInspectorBridge

@MainActor
final class NetworkFilterMenuController {
    private static let allFilterActionIdentifier = UIAction.Identifier("wi.network.filter.all")
    private static let resourceFilterActionIdentifierPrefix = "wi.network.filter.resource."

    typealias ToggleHandler = (_ filter: NetworkResourceFilter, _ isEnabled: Bool) -> Void
    typealias TitleProvider = (_ filter: NetworkResourceFilter) -> String

    private let spiRuntime: WISPIRuntime
    private let toggleHandler: ToggleHandler
    private let titleProvider: TitleProvider

    private var activeFilters: Set<NetworkResourceFilter> = []
    private var effectiveFilters: Set<NetworkResourceFilter> = []

    private lazy var allAction = makeAllAction()
    private lazy var resourceActions = makeResourceActions()
    private lazy var barButtonItem: UIBarButtonItem = {
        let button = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: makeMenu()
        )
        button.style = .plain
        return button
    }()

    init(
        spiRuntime: WISPIRuntime = .shared,
        titleProvider: @escaping TitleProvider,
        toggleHandler: @escaping ToggleHandler
    ) {
        self.spiRuntime = spiRuntime
        self.titleProvider = titleProvider
        self.toggleHandler = toggleHandler
    }

    var item: UIBarButtonItem {
        barButtonItem
    }

    func sync(
        activeFilters: Set<NetworkResourceFilter>,
        effectiveFilters: Set<NetworkResourceFilter>,
        notifyingVisibleMenu: Bool
    ) {
        self.activeFilters = activeFilters
        self.effectiveFilters = effectiveFilters
        applyActionStates()
        applySelectedIndicator()
        let nextMenu = makeMenu()

        guard notifyingVisibleMenu, spiRuntime.hasVisibleMenu(for: barButtonItem) else {
            barButtonItem.menu = nextMenu
            return
        }
        spiRuntime.updateVisibleMenu(for: barButtonItem) { _ in
            nextMenu
        }
    }

    private func makeMenu() -> UIMenu {
        let resourceSection = UIMenu(
            options: [.displayInline],
            children: NetworkResourceFilter.pickerCases.compactMap { resourceActions[$0] }
        )
        return UIMenu(children: [allAction, resourceSection])
    }

    private func applyActionStates() {
        let allState: UIMenuElement.State = effectiveFilters.isEmpty ? .on : .off
        if allAction.state != allState {
            allAction.state = allState
        }

        for filter in NetworkResourceFilter.pickerCases {
            guard let action = resourceActions[filter] else {
                continue
            }
            let desiredState: UIMenuElement.State = activeFilters.contains(filter) ? .on : .off
            if action.state != desiredState {
                action.state = desiredState
            }
        }
    }

    private func applySelectedIndicator() {
        let shouldSelect = !effectiveFilters.isEmpty
        guard barButtonItem.isSelected != shouldSelect else {
            return
        }
        barButtonItem.isSelected = shouldSelect
    }

    private func makeAllAction() -> UIAction {
        let keepsPresented: UIMenuElement.Attributes = [.keepsMenuPresented]
        return UIAction(
            title: titleProvider(.all),
            image: nil,
            identifier: Self.allFilterActionIdentifier,
            discoverabilityTitle: nil,
            attributes: keepsPresented,
            state: .on
        ) { [weak self] _ in
            self?.toggleHandler(.all, true)
        }
    }

    private func makeResourceActions() -> [NetworkResourceFilter: UIAction] {
        let keepsPresented: UIMenuElement.Attributes = [.keepsMenuPresented]
        var actions: [NetworkResourceFilter: UIAction] = [:]
        for filter in NetworkResourceFilter.pickerCases {
            actions[filter] = UIAction(
                title: titleProvider(filter),
                image: nil,
                identifier: Self.resourceFilterActionIdentifier(for: filter),
                discoverabilityTitle: nil,
                attributes: keepsPresented,
                state: .off
            ) { [weak self] _ in
                guard let self else {
                    return
                }
                let currentlyEnabled = self.activeFilters.contains(filter)
                self.toggleHandler(filter, !currentlyEnabled)
            }
        }
        return actions
    }

    private static func resourceFilterActionIdentifier(for filter: NetworkResourceFilter) -> UIAction.Identifier {
        UIAction.Identifier(resourceFilterActionIdentifierPrefix + filter.rawValue)
    }
}
#endif
