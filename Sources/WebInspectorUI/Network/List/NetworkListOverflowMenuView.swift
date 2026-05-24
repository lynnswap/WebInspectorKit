#if canImport(UIKit)
import SwiftUI

@MainActor
package struct NetworkListOverflowMenuView: View {
    package var model: NetworkPanelModel

    package var body: some View {
        Button(role: .destructive) {
            model.clearRequests()
        } label: {
            Label(webInspectorLocalized("network.controls.clear", default: "Clear"), systemImage: "trash")
        }
        .disabled(model.isEmpty)
    }
}
#endif
