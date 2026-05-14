#if canImport(UIKit)
import SwiftUI

@MainActor
package struct V2_NetworkListOverflowMenuView: View {
    package var model: V2_NetworkListModel

    package var body: some View {
        Button(role: .destructive) {
            model.clearRequests()
        } label: {
            Label(v2WILocalized("network.controls.clear", default: "Clear"), systemImage: "trash")
        }
        .disabled(model.isEmpty)
    }
}
#endif
