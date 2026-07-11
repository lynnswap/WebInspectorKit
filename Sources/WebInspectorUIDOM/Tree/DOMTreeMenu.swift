#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import Observation
import SwiftUI
import UIKit

typealias DOMTreeMenuCopyNodeTextAction = @MainActor (DOMNode.ID, DOMNode.CopyTextKind) async -> String?
typealias DOMTreeMenuDeleteNodesAction = @MainActor ([DOMNode.ID], UndoManager?) async -> Bool

@MainActor
@Observable
final class DOMTreeMenuModel {
    let context: WebInspectorModelContext
    var nodeIDs: [DOMNode.ID] = []
    var selectedText: String?
    var localMarkupTextByNodeID: [DOMNode.ID: String] = [:]

    @ObservationIgnored private var undoManager: UndoManager?
    @ObservationIgnored private var clearLocalSelection: (@MainActor () -> Void) = {}

    private let copyNodeTextAction: DOMTreeMenuCopyNodeTextAction?
    private let deleteNodesAction: DOMTreeMenuDeleteNodesAction?

    init(
        context: WebInspectorModelContext,
        copyNodeTextAction: DOMTreeMenuCopyNodeTextAction?,
        deleteNodesAction: DOMTreeMenuDeleteNodesAction?
    ) {
        self.context = context
        self.copyNodeTextAction = copyNodeTextAction
        self.deleteNodesAction = deleteNodesAction
    }

    func configure(
        nodeIDs: [DOMNode.ID],
        selectedText: String?,
        undoManager: UndoManager?,
        localMarkupTextByNodeID: [DOMNode.ID: String],
        clearLocalSelection: @escaping @MainActor () -> Void
    ) {
        self.nodeIDs = uniqueNodeIDsInOrder(nodeIDs)
        self.selectedText = selectedText
        self.undoManager = undoManager
        self.localMarkupTextByNodeID = localMarkupTextByNodeID
        self.clearLocalSelection = clearLocalSelection
    }

    var isMultiNodeMenu: Bool {
        nodeIDs.count > 1
    }

    var availableNodeIDs: [DOMNode.ID] {
        nodeIDs.filter { (try? context.requiredNode(for: $0)) != nil }
    }

    var showsSelectedTextCopy: Bool {
        selectedText != nil
    }

    var canCopySelectedText: Bool {
        !(selectedText?.isEmpty ?? true)
    }

    var showsSingleNodeCopyActions: Bool {
        singleNodeID != nil
    }

    var canCopyHTML: Bool {
        copyHTMLNodeIDs.contains { canCopyText(.html, for: $0) }
    }

    var canCopySelectorPath: Bool {
        singleNodeID.map { canCopyText(.selectorPath, for: $0) } ?? false
    }

    var canCopyXPath: Bool {
        singleNodeID.map { canCopyText(.xPath, for: $0) } ?? false
    }

    var deleteTitle: String {
        isMultiNodeMenu
            ? String(localized: "inspector.delete_nodes", bundle: WebInspectorUILocalization.bundle)
            : String(localized: "inspector.delete_node", bundle: WebInspectorUILocalization.bundle)
    }

    var canDelete: Bool {
        deleteNodesAction != nil && !deleteNodeIDs.isEmpty
    }

    func copySelectedText() {
        guard let selectedText, !selectedText.isEmpty else {
            return
        }
        UIPasteboard.general.string = selectedText
    }

    func copyHTML() {
        copyHTML(copyHTMLNodeIDs)
    }

    func copySelectorPath() {
        guard let nodeID = singleNodeID else {
            return
        }
        copy(.selectorPath, for: nodeID)
    }

    func copyXPath() {
        guard let nodeID = singleNodeID else {
            return
        }
        copy(.xPath, for: nodeID)
    }

    @discardableResult
    func deleteSelection() -> Task<Void, Never>? {
        delete(deleteNodeIDs)
    }

    private var singleNodeID: DOMNode.ID? {
        guard !isMultiNodeMenu,
              let nodeID = nodeIDs.first,
              (try? context.requiredNode(for: nodeID)) != nil else {
            return nil
        }
        return nodeID
    }

    private var copyHTMLNodeIDs: [DOMNode.ID] {
        isMultiNodeMenu ? availableNodeIDs : singleNodeID.map { [$0] } ?? []
    }

    private var deleteNodeIDs: [DOMNode.ID] {
        copyHTMLNodeIDs
    }

    private func copy(_ kind: DOMNode.CopyTextKind, for nodeID: DOMNode.ID) {
        Task { @MainActor in
            guard let text = await copyText(kind, for: nodeID),
                  !text.isEmpty else {
                return
            }
            UIPasteboard.general.string = text
        }
    }

    private func copyHTML(_ nodeIDs: [DOMNode.ID]) {
        Task { @MainActor in
            var fragments: [String] = []
            for nodeID in nodeIDs {
                guard let text = await copyText(.html, for: nodeID),
                      !text.isEmpty else {
                    continue
                }
                fragments.append(text)
            }
            guard !fragments.isEmpty else {
                return
            }
            UIPasteboard.general.string = fragments.joined(separator: "\n")
        }
    }

    @discardableResult
    private func delete(_ nodeIDs: [DOMNode.ID]) -> Task<Void, Never>? {
        guard let deleteNodesAction else {
            return nil
        }
        let uniqueNodeIDs = uniqueNodeIDsInOrder(nodeIDs)
        guard !uniqueNodeIDs.isEmpty else {
            return nil
        }
        return Task { @MainActor in
            guard await deleteNodesAction(uniqueNodeIDs, undoManager) else {
                return
            }
            clearLocalSelection()
        }
    }

    func canCopyText(_ kind: DOMNode.CopyTextKind, for nodeID: DOMNode.ID) -> Bool {
        guard (try? context.requiredNode(for: nodeID)) != nil else {
            return false
        }
        switch kind {
        case .html:
            return copyNodeTextAction != nil || !(localMarkupTextByNodeID[nodeID]?.isEmpty ?? true)
        case .selectorPath:
            guard let path = try? context.selectorPath(for: nodeID) else {
                return false
            }
            return !path.isEmpty
        case .xPath:
            guard let path = try? context.xPath(for: nodeID) else {
                return false
            }
            return !path.isEmpty
        }
    }

    private func copyText(_ kind: DOMNode.CopyTextKind, for nodeID: DOMNode.ID) async -> String? {
        if let copyNodeTextAction {
            return await copyNodeTextAction(nodeID, kind)
        }
        switch kind {
        case .html:
            return localMarkupTextByNodeID[nodeID]
        case .selectorPath:
            return try? context.selectorPath(for: nodeID)
        case .xPath:
            return try? context.xPath(for: nodeID)
        }
    }

    private func uniqueNodeIDsInOrder(_ nodeIDs: [DOMNode.ID]) -> [DOMNode.ID] {
        var seenNodeIDs: Set<DOMNode.ID> = []
        return nodeIDs.filter { seenNodeIDs.insert($0).inserted }
    }
}

@MainActor
struct DOMTreeMenuView: View {
    var model: DOMTreeMenuModel

    var body: some View {
        Section {
            if model.showsSelectedTextCopy {
                Button {
                    model.copySelectedText()
                } label: {
                    Label(String(localized: "Copy", bundle: WebInspectorUILocalization.bundle), systemImage: "doc.on.doc")
                }
                .disabled(!model.canCopySelectedText)
            }

            Button {
                model.copyHTML()
            } label: {
                Text(verbatim: "HTML")
            }
            .disabled(!model.canCopyHTML)

            if model.showsSingleNodeCopyActions {
                Button {
                    model.copySelectorPath()
                } label: {
                    Text(verbatim: "Selector")
                }
                .disabled(!model.canCopySelectorPath)

                Button {
                    model.copyXPath()
                } label: {
                    Text(verbatim: "XPath")
                }
                .disabled(!model.canCopyXPath)
            }
        } header: {
            Text(String(localized: "Copy", bundle: WebInspectorUILocalization.bundle))
        }

        Section {
            Button(role: .destructive) {
                model.deleteSelection()
            } label: {
                Label(model.deleteTitle, systemImage: "trash")
            }
            .disabled(!model.canDelete)
        }
    }
}
#endif
