#if canImport(UIKit)
import WebInspectorUIBase
import SwiftUI

@MainActor
package struct NetworkListOverflowMenuView: View {
    package var model: NetworkPanelModel

    package var body: some View {
        Toggle(isOn: Binding(
            get: { model.groupMediaRequestsByDOMNode },
            set: { model.groupMediaRequestsByDOMNode = $0 }
        )) {
            Label("Group Media Requests", systemImage: "rectangle.stack")
        }

        Button(role: .destructive) {
            model.clearRequests()
        } label: {
            Label(String(localized: "network.controls.clear", bundle: WebInspectorUILocalization.bundle), systemImage: "trash")
        }
        .disabled(model.isEmpty)
    }
}
#endif
