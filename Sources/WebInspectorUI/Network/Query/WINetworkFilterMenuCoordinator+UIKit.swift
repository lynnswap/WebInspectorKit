#if canImport(UIKit)
import UIKit
import WebInspectorCore
import ObservationBridge

@MainActor
final class WINetworkFilterMenuCoordinator {
    private unowned let queryModel: WINetworkQueryState
    private var observationHandles: Set<ObservationHandle> = []
    package private(set) var menuStateRevisionForTesting: UInt64 = 0
    package var onMenuStateUpdatedForTesting: (@MainActor (UInt64) -> Void)?

    private lazy var barButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: makeMenu()
        )
        item.isSelected = !queryModel.effectiveFilters.isEmpty
        return item
    }()

    init(queryModel: WINetworkQueryState) {
        self.queryModel = queryModel

        queryModel.observe(\.effectiveFilters) { [weak self] effectiveFilters in
            self?.applyMenuStateAfterMutation(effectiveFilters: effectiveFilters)
        }
        .store(in: &observationHandles)
    }

    var item: UIBarButtonItem {
        barButtonItem
    }

    private func makeMenu() -> UIMenu {
        let allAction = makeAllAction()
        let resourceActions = makeResourceActions()
        let resourceSection = UIMenu(options: [.displayInline], children: resourceActions)
        return UIMenu(children: [allAction, resourceSection])
    }

    private func makeAllAction() -> UIAction {
        UIAction(
            title: NetworkResourceFilter.all.localizedTitle,
            image: nil,
            discoverabilityTitle: nil,
            attributes: [.keepsMenuPresented],
            state: queryModel.effectiveFilters.isEmpty ? .on : .off
        ) { [weak self] _ in
            guard let self else {
                return
            }
            queryModel.clearFilters()
        }
    }

    private func makeResourceActions() -> [UIAction] {
        var actions: [UIAction] = []
        for filter in NetworkResourceFilter.pickerCases {
            actions.append(UIAction(
                title: filter.localizedTitle,
                image: nil,
                discoverabilityTitle: nil,
                attributes: [.keepsMenuPresented],
                state: queryModel.activeFilters.contains(filter) ? .on : .off
            ) { [weak self] _ in
                guard let self else {
                    return
                }
                queryModel.toggleFilter(filter)
            })
        }
        return actions
    }

    private func applyMenuStateAfterMutation(effectiveFilters: Set<NetworkResourceFilter>) {
        barButtonItem.isSelected = !effectiveFilters.isEmpty
        barButtonItem.menu = makeMenu()
        menuStateRevisionForTesting &+= 1
        if menuStateRevisionForTesting == 0 {
            menuStateRevisionForTesting = 1
        }
        onMenuStateUpdatedForTesting?(menuStateRevisionForTesting)
    }
}
#endif
