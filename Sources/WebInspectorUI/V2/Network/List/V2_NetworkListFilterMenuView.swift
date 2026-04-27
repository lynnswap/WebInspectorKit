#if canImport(UIKit)
import SwiftUI
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
struct V2_NetworkListFilterMenuView: View {
    var inspector: WINetworkModel

    var body: some View {
        Toggle(
            NetworkResourceFilter.all.localizedTitle,
            isOn: allFiltersBinding
        )

        Divider()

        ForEach(NetworkResourceFilter.pickerCases, id: \.self) { filter in
            Toggle(
                filter.localizedTitle,
                isOn: binding(for: filter)
            )
        }
        .menuActionDismissBehavior(.disabled)
    }

    private var allFiltersBinding: Binding<Bool> {
        Binding {
            inspector.effectiveResourceFilters.isEmpty
        } set: { isOn in
            if isOn {
                inspector.clearResourceFilters()
            }
        }
    }

    private func binding(for filter: NetworkResourceFilter) -> Binding<Bool> {
        Binding {
            inspector.activeResourceFilters.contains(filter)
        } set: { isOn in
            inspector.setResourceFilter(filter, enabled: isOn)
        }
    }
}
#endif
