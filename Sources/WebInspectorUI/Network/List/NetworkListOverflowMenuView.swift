#if canImport(UIKit)
import SwiftUI

@MainActor
package struct NetworkListOverflowMenuView: View {
    package var model: NetworkPanelModel

    package var body: some View {
        Button(role: .destructive) {
            model.clearRequests()
        } label: {
            Label(String(localized: "network.controls.clear", bundle: .module), systemImage: "trash")
        }
        .disabled(model.isEmpty)
    }
}
#endif
