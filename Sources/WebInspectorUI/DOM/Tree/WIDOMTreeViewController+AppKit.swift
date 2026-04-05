import WebKit
import WebInspectorEngine
import WebInspectorRuntime
import ObservationBridge

#if canImport(AppKit)
import AppKit

@MainActor
public final class WIDOMTreeViewController: NSViewController {
    private let inspector: WIDOMInspector
    private var contextMenuNodeID: Int?
    private var contextMenuNodeIdentity: DOMNodeModel.ID?
    private var observationHandles: Set<ObservationHandle> = []
    private var documentStoreObservationHandles: Set<ObservationHandle> = []

    private let errorLabel = NSTextField(labelWithString: "")

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
            self.contextMenuNodeIdentity = nodeID.flatMap {
                $0 >= 0
                    ? self.inspector.document.node(localID: UInt64($0))?.id
                    : nil
            } ?? nodeID.flatMap { self.inspector.document.node(backendNodeID: $0)?.id }
            return self.makeTreeContextMenu()
        }

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.maximumNumberOfLines = 3

        view.addSubview(inspectorWebView)
        view.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            inspectorWebView.topAnchor.constraint(equalTo: view.topAnchor),
            inspectorWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inspectorWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        observeState()
        updateErrorLabel(errorMessage: inspector.document.errorMessage)
    }

    private func observeState() {
        inspector.observe(
            \.document
        ) { [weak self] document in
            guard let self else {
                return
            }
            self.documentStoreObservationHandles.removeAll()
            document.observe(
                \.errorMessage,
                options: [.removeDuplicates]
            ) { [weak self] newErrorMessage in
                self?.updateErrorLabel(errorMessage: newErrorMessage)
            }
            .store(in: &self.documentStoreObservationHandles)
            self.updateErrorLabel(errorMessage: document.errorMessage)
        }
        .store(in: &observationHandles)
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

    private func updateErrorLabel(errorMessage: String?) {
        if let errorMessage, !errorMessage.isEmpty {
            errorLabel.stringValue = errorMessage
            errorLabel.isHidden = false
        } else {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        }
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
        contextMenuNodeID = nil
        contextMenuNodeIdentity = nil
        guard nodeID != nil || nodeIdentity != nil else {
            return
        }
        let undoManager = undoManager
        Task {
            _ = await deleteContextMenuNode(
                nodeID: nodeID,
                nodeIdentity: nodeIdentity,
                undoManager: undoManager
            )
        }
    }

    func invokeContextMenuDeleteForTesting(
        nodeID: Int?,
        nodeIdentity: DOMNodeModel.ID?,
        undoManager: UndoManager? = nil
    ) async -> DOMMutationResult {
        await deleteContextMenuNode(
            nodeID: nodeID,
            nodeIdentity: nodeIdentity,
            undoManager: undoManager
        )
    }

    private func deleteContextMenuNode(
        nodeID: Int?,
        nodeIdentity: DOMNodeModel.ID?,
        undoManager: UndoManager?
    ) async -> DOMMutationResult {
        if let nodeIdentity {
            return await inspector.deleteNode(nodeID: nodeIdentity, undoManager: undoManager)
        }
        if let nodeID,
           let resolvedIdentity = nodeID >= 0
                ? inspector.document.node(localID: UInt64(nodeID))?.id
                : nil
        {
            return await inspector.deleteNode(nodeID: resolvedIdentity, undoManager: undoManager)
        }
        if let nodeID,
           let resolvedIdentity = inspector.document.node(backendNodeID: nodeID)?.id
        {
            return await inspector.deleteNode(nodeID: resolvedIdentity, undoManager: undoManager)
        }
        return await inspector.deleteNode(nodeId: nodeID, undoManager: undoManager)
    }

    private var contextActionNodeID: Int? {
        contextMenuNodeID
    }

    private var contextActionNodeIdentity: DOMNodeModel.ID? {
        contextMenuNodeIdentity
    }

    private func copyNodeForContextMenu(kind: DOMSelectionCopyKind) {
        let nodeID = contextActionNodeID
        let nodeIdentity = contextActionNodeIdentity
        contextMenuNodeID = nil
        contextMenuNodeIdentity = nil
        guard nodeID != nil || nodeIdentity != nil else {
            return
        }
        Task {
            do {
                let text: String
                if let nodeIdentity {
                    text = try await inspector.copyNode(nodeID: nodeIdentity, kind: kind)
                } else if let nodeID {
                    text = try await inspector.copyNode(nodeId: nodeID, kind: kind)
                } else {
                    return
                }
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
