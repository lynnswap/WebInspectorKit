#if canImport(UIKit)
import WebInspectorUIBase
import SwiftUI

@MainActor
package struct NetworkListOverflowMenuView: View {
    package var model: NetworkPanelModel

    package var body: some View {
        Button(role: .destructive) {
            model.clearRequests()
        } label: {
            Label(String(localized: "network.controls.clear", bundle: WebInspectorUILocalization.bundle), systemImage: "trash")
        }
        .disabled(model.hasClearableRequests == false)
    }
}
#endif
