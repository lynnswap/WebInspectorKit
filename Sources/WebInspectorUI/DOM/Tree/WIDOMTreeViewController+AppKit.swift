import WebKit
import WebInspectorEngine
import WebInspectorRuntime

#if canImport(AppKit)
import AppKit

@MainActor
public final class WIDOMTreeViewController: NSViewController {
    private let inspector: WIDOMInspector
    private var contextMenuNodeID: Int?
    private var contextMenuNodeIdentity: DOMNodeModel.ID?
    private var contextMenuBackendNodeID: Int?

    public init(inspector: WIDOMInspector) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        view = NSView(frame: .zero)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        let inspectorWebView = inspector.makeInspectorWebView()
        inspectorWebView.translatesAutoresizingMaskIntoConstraints = false
        inspector.setDOMContextMenuProvider { [weak self] nodeID in
            guard let self else {
                return nil
            }
            self.contextMenuNodeID = nodeID
            if let nodeID,
               nodeID >= 0,
               let node = self.inspector.document.node(localID: UInt64(nodeID)) {
                self.contextMenuNodeIdentity = node.id
                self.contextMenuBackendNodeID = node.backendNodeIDIsStable ? node.backendNodeID : nil
            } else if let nodeID,
                      let node = self.inspector.document.node(stableBackendNodeID: nodeID) {
                self.contextMenuNodeIdentity = node.id
                self.contextMenuBackendNodeID = node.backendNodeID
            } else {
                self.contextMenuNodeIdentity = nil
                self.contextMenuBackendNodeID = nil
            }
            return self.makeTreeContextMenu()
        }

        view.addSubview(inspectorWebView)

        NSLayoutConstraint.activate([
            inspectorWebView.topAnchor.constraint(equalTo: view.topAnchor),
            inspectorWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inspectorWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func makeCopyMenu() -> NSMenu {
        let menu = NSMenu()

        let html = NSMenuItem(title: "HTML", action: #selector(copyHTML(_:)), keyEquivalent: "")
        html.target = self
        menu.addItem(html)

        let selectorPath = NSMenuItem(title: wiLocalized("dom.element.copy.selector_path"), action: #selector(copySelectorPath(_:)), keyEquivalent: "")
        selectorPath.target = self
        menu.addItem(selectorPath)

        let xpath = NSMenuItem(title: "XPath", action: #selector(copyXPath(_:)), keyEquivalent: "")
        xpath.target = self
        menu.addItem(xpath)

        return menu
    }

    private func makeTreeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let hasContextNode = contextMenuNodeID != nil

        let copyItem = NSMenuItem(title: wiLocalized("Copy"), action: nil, keyEquivalent: "")
        copyItem.submenu = makeCopyMenu()
        copyItem.isEnabled = hasContextNode
        menu.addItem(copyItem)
        menu.addItem(.separator())

        let deleteItem = NSMenuItem(
            title: wiLocalized("inspector.delete_node"),
            action: #selector(deleteNode),
            keyEquivalent: ""
        )
        deleteItem.target = self
        deleteItem.isEnabled = hasContextNode
        menu.addItem(deleteItem)

        return menu
    }

    @objc
    private func copyHTML(_ sender: NSMenuItem) {
        copyNodeForContextMenu(kind: .html)
    }

    @objc
    private func copySelectorPath(_ sender: NSMenuItem) {
        copyNodeForContextMenu(kind: .selectorPath)
    }

    @objc
    private func copyXPath(_ sender: NSMenuItem) {
        copyNodeForContextMenu(kind: .xpath)
    }

    @objc
    private func deleteNode() {
        let nodeID = contextActionNodeID
        let nodeIdentity = contextActionNodeIdentity
        let backendNodeID = contextMenuBackendNodeID
        contextMenuNodeID = nil
        contextMenuNodeIdentity = nil
        contextMenuBackendNodeID = nil
        guard nodeID != nil || nodeIdentity != nil else {
            return
        }
        let undoManager = undoManager
        Task {
            do {
                try await deleteContextMenuNode(
                    nodeID: nodeID,
                    nodeIdentity: nodeIdentity,
                    backendNodeID: backendNodeID,
                    undoManager: undoManager
                )
            } catch {
            }
        }
    }

    func invokeContextMenuDeleteForTesting(
        nodeID: Int?,
        nodeIdentity: DOMNodeModel.ID?,
        backendNodeID: Int? = nil,
        undoManager: UndoManager? = nil
    ) async throws {
        try await deleteContextMenuNode(
            nodeID: nodeID,
            nodeIdentity: nodeIdentity,
            backendNodeID: backendNodeID,
            undoManager: undoManager
        )
    }

    private func deleteContextMenuNode(
        nodeID: Int?,
        nodeIdentity: DOMNodeModel.ID?,
        backendNodeID: Int?,
        undoManager: UndoManager?
    ) async throws {
        if let nodeIdentity {
            do {
                try await inspector.deleteNode(nodeID: nodeIdentity, undoManager: undoManager)
                return
            } catch DOMOperationError.invalidSelection, DOMOperationError.contextInvalidated {
                guard let backendNodeID else {
                    throw DOMOperationError.invalidSelection
                }
                try await inspector.deleteNode(nodeId: backendNodeID, undoManager: undoManager)
                return
            }
        }
        if let backendNodeID {
            try await inspector.deleteNode(nodeId: backendNodeID, undoManager: undoManager)
            return
        }
        if let nodeID,
           let resolvedIdentity = nodeID >= 0
                ? inspector.document.node(localID: UInt64(nodeID))?.id
                : nil
        {
            try await inspector.deleteNode(nodeID: resolvedIdentity, undoManager: undoManager)
            return
        }
        if let nodeID,
           let resolvedIdentity = inspector.document.node(stableBackendNodeID: nodeID)?.id
        {
            try await inspector.deleteNode(nodeID: resolvedIdentity, undoManager: undoManager)
            return
        }
        throw DOMOperationError.invalidSelection
    }

    private var contextActionNodeID: Int? {
        contextMenuNodeID
    }

    private var contextActionNodeIdentity: DOMNodeModel.ID? {
        contextMenuNodeIdentity
    }

    func invokeContextMenuCopyForTesting(
        nodeID: Int?,
        nodeIdentity: DOMNodeModel.ID?,
        backendNodeID: Int? = nil,
        kind: DOMSelectionCopyKind = .html
    ) async throws -> String {
        try await copyContextMenuNode(
            nodeID: nodeID,
            nodeIdentity: nodeIdentity,
            backendNodeID: backendNodeID,
            kind: kind
        )
    }

    private func copyNodeForContextMenu(kind: DOMSelectionCopyKind) {
        let nodeID = contextActionNodeID
        let nodeIdentity = contextActionNodeIdentity
        let backendNodeID = contextMenuBackendNodeID
        contextMenuNodeID = nil
        contextMenuNodeIdentity = nil
        contextMenuBackendNodeID = nil
        guard nodeID != nil || nodeIdentity != nil else {
            return
        }
        Task {
            do {
                let text = try await copyContextMenuNode(
                    nodeID: nodeID,
                    nodeIdentity: nodeIdentity,
                    backendNodeID: backendNodeID,
                    kind: kind
                )
                guard !text.isEmpty else {
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            } catch {
                return
            }
        }
    }

    private func copyContextMenuNode(
        nodeID: Int?,
        nodeIdentity: DOMNodeModel.ID?,
        backendNodeID: Int?,
        kind: DOMSelectionCopyKind
    ) async throws -> String {
        if let nodeIdentity {
            let text = try await inspector.copyNode(nodeID: nodeIdentity, kind: kind)
            guard text.isEmpty, let backendNodeID else {
                return text
            }
            return try await inspector.copyNode(nodeId: backendNodeID, kind: kind)
        }
        if let backendNodeID {
            return try await inspector.copyNode(nodeId: backendNodeID, kind: kind)
        }
        if let nodeID,
           let resolvedIdentity = nodeID >= 0
                ? inspector.document.node(localID: UInt64(nodeID))?.id
                : nil {
            return try await inspector.copyNode(nodeID: resolvedIdentity, kind: kind)
        }
        if let nodeID,
           let resolvedIdentity = inspector.document.node(stableBackendNodeID: nodeID)?.id {
            return try await inspector.copyNode(nodeID: resolvedIdentity, kind: kind)
        }
        return ""
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("DOM Tree (AppKit)") {
    WIAppKitPreviewContainer {
        WIDOMTreeViewController(inspector: WIDOMPreviewFixtures.makeInspector(mode: .selected))
    }
}
#endif


#endif
