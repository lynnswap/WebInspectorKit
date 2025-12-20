import SwiftUI

extension EnvironmentValues {
    @Entry var wiNetworkFilters: Set<WINetworkResourceFilter>? = nil
    @Entry var wiNetworkFiltersBinding: Binding<Set<WINetworkResourceFilter>>? = nil
}

public extension View {
    func wiNetworkFilters(
        _ filters: Set<WINetworkResourceFilter>?
    ) -> some View {
        environment(\.wiNetworkFilters, filters)
    }

    func wiNetworkFilters(
        _ filters: Binding<Set<WINetworkResourceFilter>>
    ) -> some View {
        environment(\.wiNetworkFiltersBinding, filters)
    }
}
