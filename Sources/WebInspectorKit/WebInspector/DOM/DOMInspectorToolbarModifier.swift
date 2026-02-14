import SwiftUI
import WebInspectorKitCore

private struct DOMInspectorToolbarModifier: ViewModifier {
    let inspector: WebInspector.DOMInspector

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        inspector.toggleSelectionMode()
                    } label: {
                        Image(systemName: "viewfinder.circle")
                            .symbolVariant(inspector.isSelectingElement ? .fill : .none)
                    }
                    .disabled(!inspector.hasPageWebView)
                }
                ToolbarItemGroup(placement: .secondaryAction) {
                    copyItem
                    reloadItem
                    Section {
                        deleteItem
                    }
                }
            }
    }

    @ViewBuilder
    private var copyItem: some View {
        Menu {
            Button {
                inspector.copySelection(.html)
            } label: {
                Text("HTML" as String)
            }
            Button {
                inspector.copySelection(.selectorPath)
            } label: {
                Text(LocalizedStringResource("dom.element.copy.selector_path", bundle: .module))
            }
            Button {
                inspector.copySelection(.xpath)
            } label: {
                Text("XPath" as String)
            }
        } label: {
            Label {
                Text(LocalizedStringResource("Copy", bundle: .module))
            } icon: {
                Image(systemName: "document.on.document")
            }
        }
        .disabled(inspector.selection.nodeId == nil)
    }

    @ViewBuilder
    private var reloadItem: some View {
        Menu {
            Button {
                Task {
                    await inspector.reloadInspector()
                }
            } label: {
                Text(LocalizedStringResource("reload.target.inspector", bundle: .module))
            }
            Button {
                inspector.session.reloadPage()
            } label: {
                Text(LocalizedStringResource("reload.target.page", bundle: .module))
            }
        } label: {
            Label {
                Text(LocalizedStringResource("reload", bundle: .module))
            } icon: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(!inspector.hasPageWebView)
    }

    @ViewBuilder
    private var deleteItem: some View {
        Button(role: .destructive) {
            inspector.deleteSelectedNode()
        } label: {
            Label {
                Text(LocalizedStringResource("inspector.delete_node", bundle: .module))
            } icon: {
                Image(systemName: "trash")
            }
        }
        .disabled(inspector.selection.nodeId == nil)
    }
}

extension View {
    func domInspectorToolbar(_ inspector: WebInspector.DOMInspector) -> some View {
        modifier(DOMInspectorToolbarModifier(inspector: inspector))
    }
}

