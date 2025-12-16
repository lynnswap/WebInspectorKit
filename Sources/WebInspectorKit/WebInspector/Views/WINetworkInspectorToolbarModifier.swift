import SwiftUI

struct WINetworkInspectorToolbarModifier: ViewModifier {
    private let model: WebInspectorModel
    private let identifier: String
    
    init(model: WebInspectorModel, identifier: String) {
        self.model = model
        self.identifier = identifier
    }
    
    private var viewModel:WINetworkViewModel{
        model.network
    }
#if os(macOS)
    private var isShowingToolbar: Bool{
        model.selectedTab?.id == identifier
    }
#endif
    
    func body(content: Content) -> some View {
        content
            .toolbar {
#if os(macOS)
                if isShowingToolbar{
                    toolbarContent
                }
#else
                toolbarContent
#endif
            }
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .secondaryAction) {
            Section {
                clearItem
            }
        }
    }
    @ViewBuilder
    private var clearItem: some View{
        Button(role: .destructive) {
            viewModel.clearNetworkLogs()
        } label: {
            Label {
                Text("network.controls.clear")
            } icon: {
                Image(systemName: "trash")
            }
        }
        .disabled(viewModel.store.entries.isEmpty)
    }
}

public extension View {
    func networkInspectorToolbar(_ model: WebInspectorModel, identifier: String) -> some View {
        modifier(WINetworkInspectorToolbarModifier(model: model, identifier: identifier))
    }
}
