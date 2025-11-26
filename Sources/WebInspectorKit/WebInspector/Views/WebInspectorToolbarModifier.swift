import SwiftUI

struct WebInspectorToolbarModifier: ViewModifier {
    @Environment(WebInspectorModel.self) private var model

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.toggleSelectionMode()
                    } label: {
                        Image(systemName: model.isSelectingElement ? "viewfinder.circle.fill" : "viewfinder.circle")
                    }
                    .disabled(!model.hasPageWebView)
                }
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        if model.webBridge.isLoading {
                            ProgressView()
                        } else {
                            Label {
                                Text("reload")
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                    .disabled(model.webBridge.isLoading)

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
                    .disabled(model.webBridge.domSelection.nodeId == nil)

                    Button(role: .destructive) {
                        model.deleteSelectedNode()
                    } label: {
                        Label {
                            Text("inspector.delete_node")
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .disabled(model.webBridge.domSelection.nodeId == nil)
                }
            }
    }
}

public extension View {
    func webInspectorToolbar() -> some View {
        modifier(WebInspectorToolbarModifier())
    }
}
