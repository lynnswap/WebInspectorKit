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
                    Text(verbatim: WINetworkResourceFilter.all.displayTitle)
                }
                Divider()
                ForEach(WINetworkResourceFilter.pickerCases) { filter in
                    Toggle(isOn: viewModel.bindingForResourceFilter(filter)) {
                        Text(verbatim: filter.displayTitle)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(viewModel.effectiveResourceFilters.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
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
    var displayTitle: String {
        switch self {
        case .all:
            return "All"
        case .document:
            return "Document"
        case .stylesheet:
            return "CSS"
        case .image:
            return "Image"
        case .font:
            return "Font"
        case .script:
            return "JS"
        case .xhrFetch:
            return "XHR / Fetch"
        case .other:
            return "Other"
        }
    }
}

public extension View {
    func networkInspectorToolbar(_ model: WebInspectorModel, identifier: String) -> some View {
        modifier(WINetworkInspectorToolbarModifier(model: model, identifier: identifier))
    }
}
