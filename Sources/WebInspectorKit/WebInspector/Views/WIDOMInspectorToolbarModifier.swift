import SwiftUI

struct WIDOMInspectorToolbarModifier: ViewModifier {
    private let model: WebInspectorModel
    private let identifier: String
    
    init(model: WebInspectorModel,identifier:String) {
        self.model = model
        self.identifier = identifier
    }
    
    private var viewModel:WIDOMViewModel{
        model.dom
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
    private var toolbarContent:some ToolbarContent{
        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.toggleSelectionMode()
            } label: {
                Image(systemName: "viewfinder.circle")
                    .symbolVariant(viewModel.isSelectingElement ? .fill : .none)
            }
            .disabled(!viewModel.hasPageWebView)
        }
        ToolbarItemGroup(placement: .secondaryAction) {
            copyItem
            
            reloadItem
            
            Section{
                deleteItem
            }
        }
    }
    @ViewBuilder
    private var copyItem:some View{
        Menu {
            Button {
                viewModel.copySelection(.html)
            } label: {
                Text("HTML" as String)
            }
            Button {
                viewModel.copySelection(.selectorPath)
            } label: {
                Text("dom.element.copy.selector_path")
            }
            Button {
                viewModel.copySelection(.xpath)
            } label: {
                Text("XPath" as String)
            }
        } label: {
            Label {
                Text("Copy")
            } icon: {
                Image(systemName: "document.on.document")
            }
        }
        .disabled(viewModel.selection.nodeId == nil)
        
    }
    @ViewBuilder
    private var reloadItem:some View{
        Menu{
            Button {
                Task { await viewModel.reloadInspector() }
            } label: {
                Text("reload.target.inspector")
            }
            Button {
                viewModel.session.reloadPage()
            } label: {
                Text("reload.target.page")
            }
        }label:{
            Label {
                Text("reload")
            } icon: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(!viewModel.hasPageWebView)
    }
    @ViewBuilder
    private var deleteItem:some View{
        Button(role: .destructive) {
            viewModel.deleteSelectedNode()
        } label: {
            Label {
                Text("inspector.delete_node")
            } icon: {
                Image(systemName: "trash")
            }
        }
        .disabled(viewModel.selection.nodeId == nil)
    }
}

public extension View {
    func domInspectorToolbar(_ model: WebInspectorModel, identifier: String) -> some View {
        modifier(WIDOMInspectorToolbarModifier(model: model, identifier: identifier))
    }
}
