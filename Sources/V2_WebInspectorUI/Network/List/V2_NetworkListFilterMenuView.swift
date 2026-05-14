#if canImport(UIKit)
import SwiftUI

@MainActor
package struct V2_NetworkListFilterMenuView: View {
    package var model: V2_NetworkPanelModel

    package var body: some View {
        Toggle(
            V2_NetworkResourceFilter.all.localizedTitle,
            isOn: allFiltersBinding
        )

        Divider()

        ForEach(V2_NetworkResourceFilter.pickerCases, id: \.self) { filter in
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

    private func binding(for filter: V2_NetworkResourceFilter) -> Binding<Bool> {
        Binding {
            model.activeResourceFilters.contains(filter)
        } set: { isOn in
            model.setResourceFilter(filter, enabled: isOn)
        }
    }
}
#endif
