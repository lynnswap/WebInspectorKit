#if canImport(UIKit)
import SwiftUI
import WebInspectorRuntime

@MainActor
struct NetworkListOverflowMenuView: View {
    var inspector: WINetworkModel

    var body: some View {
        Button(role: .destructive) {
            clearEntries()
        } label: {
            Label(wiLocalized("network.controls.clear"), systemImage: "trash")
        }
        .disabled(inspector.store.entries.isEmpty)
    }

    private func clearEntries() {
        Task { @MainActor in
            await inspector.clear()
        }
    }
}
#endif
