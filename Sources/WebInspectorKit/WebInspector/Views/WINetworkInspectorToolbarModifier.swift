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
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle(isOn: viewModel.bindingForAllResourceFilters()) {
                    Text(WINetworkResourceFilter.all.localizedTitle)
                }
                Divider()
                ForEach(WINetworkResourceFilter.pickerCases) { filter in
                    Toggle(isOn: viewModel.bindingForResourceFilter(filter)) {
                        Text(filter.localizedTitle)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .accessibilityLabel(
                        Text(LocalizedStringResource("network.controls.filter", bundle: .module))
                    )
            }
#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst) || os(visionOS)
            .menuActionDismissBehavior(.disabled)
#endif
            .menuOrder(.fixed)
        }
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

private extension WINetworkResourceFilter {
    var localizedTitle: LocalizedStringResource {
        switch self {
        case .all:
            return LocalizedStringResource("network.filter.all", bundle: .module)
        case .document:
            return LocalizedStringResource("network.filter.document", bundle: .module)
        case .stylesheet:
            return LocalizedStringResource("network.filter.stylesheet", bundle: .module)
        case .image:
            return LocalizedStringResource("network.filter.image", bundle: .module)
        case .font:
            return LocalizedStringResource("network.filter.font", bundle: .module)
        case .script:
            return LocalizedStringResource("network.filter.script", bundle: .module)
        case .xhrFetch:
            return LocalizedStringResource("network.filter.xhr_fetch", bundle: .module)
        case .other:
            return LocalizedStringResource("network.filter.other", bundle: .module)
        }
    }
}

public extension View {
    func networkInspectorToolbar(_ model: WebInspectorModel, identifier: String) -> some View {
        modifier(WINetworkInspectorToolbarModifier(model: model, identifier: identifier))
    }
}
