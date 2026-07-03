#if canImport(UIKit)
import WebInspectorUIBase
import SwiftUI

@MainActor
package struct NetworkListFilterMenuView: View {
    package var model: NetworkPanelModel

    package var body: some View {
        Toggle(
            NetworkDisplay.ResourceFilter.all.localizedTitle,
            isOn: allFiltersBinding
        )

        Divider()

        ForEach(NetworkDisplay.ResourceFilter.pickerCases, id: \.self) { filter in
            Toggle(
                filter.localizedTitle,
                isOn: binding(for: filter)
            )
        }
        .menuActionDismissBehavior(.disabled)
    }

    private var allFiltersBinding: Binding<Bool> {
        Binding {
            model.effectiveResourceFilters.isEmpty
        } set: { isOn in
            if isOn {
                model.clearResourceFilters()
            }
        }
    }

    private func binding(for filter: NetworkDisplay.ResourceFilter) -> Binding<Bool> {
        Binding {
            model.activeResourceFilters.contains(filter)
        } set: { isOn in
            model.setResourceFilter(filter, enabled: isOn)
        }
    }
}
#endif
