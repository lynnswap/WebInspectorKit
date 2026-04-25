#if canImport(UIKit)
import SwiftUI
import UIKit
import WebInspectorRuntime

@MainActor
struct V2_DOMOverflowMenuView: View {
    var dom: V2_WIDOMRuntime
    var undoManager: UndoManager?

    var body: some View {
        Menu {
            Button("HTML") {
                copySelectedHTML()
            }
            .disabled(!hasSelection)

            Button(wiLocalized("dom.element.copy.selector_path")) {
                copySelectedSelectorPath()
            }
            .disabled(!hasSelection)

            Button("XPath") {
                copySelectedXPath()
            }
            .disabled(!hasSelection)
        } label: {
            Label(wiLocalized("Copy"), systemImage: "document.on.document")
        }

        Menu {
            Button(wiLocalized("reload.target.inspector")) {
                reloadDocument()
            }
            .disabled(!dom.isPageReadyForSelection)

            Button(wiLocalized("reload.target.page")) {
                reloadPage()
            }
            .disabled(!dom.hasPageWebView)
        } label: {
            Label(wiLocalized("reload"), systemImage: "arrow.clockwise")
        }

        Divider()

        Button(role: .destructive) {
            deleteSelection()
        } label: {
            Label(wiLocalized("inspector.delete_node"), systemImage: "trash")
        }
        .disabled(!hasSelection)
    }

    private var hasSelection: Bool {
        dom.document.selectedNode != nil
    }

    private func copySelectedHTML() {
        Task { @MainActor in
            guard let text = try? await dom.copySelectedHTML(),
                  text.isEmpty == false else {
                return
            }
            UIPasteboard.general.string = text
        }
    }

    private func copySelectedSelectorPath() {
        Task { @MainActor in
            guard let text = try? await dom.copySelectedSelectorPath(),
                  text.isEmpty == false else {
                return
            }
            UIPasteboard.general.string = text
        }
    }

    private func copySelectedXPath() {
        Task { @MainActor in
            guard let text = try? await dom.copySelectedXPath(),
                  text.isEmpty == false else {
                return
            }
            UIPasteboard.general.string = text
        }
    }

    private func reloadDocument() {
        Task { @MainActor in
            try? await dom.reloadDocument()
        }
    }

    private func reloadPage() {
        Task { @MainActor in
            try? await dom.reloadPage()
        }
    }

    private func deleteSelection() {
        Task { @MainActor in
            try? await dom.deleteSelectedNode(undoManager: undoManager)
        }
    }
}
#endif
