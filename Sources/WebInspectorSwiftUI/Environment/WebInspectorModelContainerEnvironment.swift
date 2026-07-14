import SwiftUI
import WebInspectorDataKit

extension EnvironmentValues {
    @Entry var webInspectorModelContainer: WebInspectorModelContainer? = nil
}

extension View {
    /// Supplies the model container used by descendant `WebInspectorQuery`
    /// properties.
    @MainActor
    public func webInspectorModelContainer(
        _ container: WebInspectorModelContainer
    ) -> some View {
        environment(\.webInspectorModelContainer, container)
    }
}
