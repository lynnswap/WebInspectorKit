import SwiftUI

struct WebInspectorToolbarModifier: ViewModifier {
    @Bindable var model: WIDOMViewModel
    private var isShowingToolbar: Bool

    init(model: WIDOMViewModel, isVisible: Bool = true) {
        self._model = Bindable(model)
        self.isShowingToolbar = isVisible
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                if isShowingToolbar{
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.toggleSelectionMode()
                        } label: {
                            Image(systemName: model.isSelectingElement ? "viewfinder.circle.fill" : "viewfinder.circle")
                        }
                        .disabled(!model.hasPageWebView)
                    }
                    ToolbarItemGroup(placement: .secondaryAction) {
                        Menu {
                            Button {
                                model.copySelection(.html)
                            } label: {
                                Text("HTML" as String)
                            }
                            Button {
                                model.copySelection(.selectorPath)
                            } label: {
                                Text("dom.detail.copy.selector_path")
                            }
                            Button {
                                model.copySelection(.xpath)
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
                        .disabled(model.selection.nodeId == nil)
                        
                   
                        Menu{
                            Button {
                                Task { await model.reloadInspector() }
                            } label: {
                                Text("reload.target.inspector")
                            }
                            Button {
                                model.session.domAgent.webView?.reload()
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
                        .disabled(!model.hasPageWebView)
                        Section{
                            Button(role: .destructive) {
                                model.deleteSelectedNode()
                            } label: {
                                Label {
                                    Text("inspector.delete_node")
                            } icon: {
                                Image(systemName: "trash")
                            }
                        }
                        .disabled(model.selection.nodeId == nil)
                    }
                }
            }
            }
            .animation(.default,value:isShowingToolbar)
    }
}

public extension View {
    func webInspectorToolbar(_ model: WebInspectorModel, isVisible: Bool? = nil) -> some View {
        let visible = isVisible ?? (model.selectedTab?.role == .inspector)
        return modifier(WebInspectorToolbarModifier(model: model.dom, isVisible: visible))
    }
}
