import WebInspectorRuntime

@MainActor
extension WISession {
    package func configureTabs(_ descriptors: [WITabDescriptor]) {
        configureTabs(descriptors.map(\.sessionTabDefinition))
    }
}
