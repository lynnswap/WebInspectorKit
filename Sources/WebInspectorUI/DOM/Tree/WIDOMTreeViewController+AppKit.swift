import WebKit
import WebInspectorEngine
import WebInspectorRuntime
import ObservationBridge

#if canImport(AppKit)
import AppKit

@MainActor
public final class WIDOMTreeViewController: NSViewController {
    private let inspector: WIDOMInspector
    private let inspectorWebViewContainer = NSView()
    private weak var attachedInspectorWebView: WKWebView?
    private var inspectorWebViewConstraints: [NSLayoutConstraint] = []
    private var contextMenuNodeID: Int?
    private var contextMenuNodeIdentity: DOMNodeModel.ID?
    private var contextMenuBackendNodeID: Int?
    private var observationHandles: Set<ObservationHandle> = []
    private var documentObservationHandles: Set<ObservationHandle> = []
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

        inspectorWebViewContainer.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.maximumNumberOfLines = 3
        view.addSubview(inspectorWebViewContainer)
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            inspectorWebViewContainer.topAnchor.constraint(equalTo: view.topAnchor),
            inspectorWebViewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inspectorWebViewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorWebViewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            errorLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

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

        attachInspectorWebViewIfNeeded()
        observeState()
        updateErrorLabel(errorMessage: inspector.document.errorMessage)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        attachInspectorWebViewIfNeeded()
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        if view.window == nil {
            detachInspectorWebViewIfNeeded()
        }
    }

    private func observeState() {
        inspector.observe(\.document) { [weak self] document in
            guard let self else {
                return
            }
            self.documentObservationHandles.removeAll()
            document.observe(
                \.errorMessage,
                options: [.removeDuplicates]
            ) { [weak self] newErrorMessage in
                self?.updateErrorLabel(errorMessage: newErrorMessage)
            }
            .store(in: &self.documentObservationHandles)
            self.updateErrorLabel(errorMessage: document.errorMessage)
        }
        .store(in: &observationHandles)
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
                try await inspector.deleteNodeThrowing(nodeID: nodeIdentity, undoManager: undoManager)
                return
            } catch DOMOperationError.invalidSelection, DOMOperationError.contextInvalidated {
                guard let backendNodeID else {
                    throw DOMOperationError.invalidSelection
                }
                try await inspector.deleteNodeThrowing(nodeId: backendNodeID, undoManager: undoManager)
                return
            }
        }
        if let backendNodeID {
            try await inspector.deleteNodeThrowing(nodeId: backendNodeID, undoManager: undoManager)
            return
        }
        if let nodeID,
           let resolvedIdentity = nodeID >= 0
                ? inspector.document.node(localID: UInt64(nodeID))?.id
                : nil
        {
            try await inspector.deleteNodeThrowing(nodeID: resolvedIdentity, undoManager: undoManager)
            return
        }
        if let nodeID,
           let resolvedIdentity = inspector.document.node(stableBackendNodeID: nodeID)?.id
        {
            try await inspector.deleteNodeThrowing(nodeID: resolvedIdentity, undoManager: undoManager)
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

    private func attachInspectorWebViewIfNeeded() {
        let inspectorWebView = inspector.inspectorWebViewForPresentation()
        inspectorWebView.translatesAutoresizingMaskIntoConstraints = false
        guard inspectorWebView.superview !== inspectorWebViewContainer else {
            attachedInspectorWebView = inspectorWebView
            return
        }

        NSLayoutConstraint.deactivate(inspectorWebViewConstraints)
        inspectorWebViewConstraints.removeAll(keepingCapacity: true)
        inspectorWebView.removeFromSuperview()
        inspectorWebViewContainer.addSubview(inspectorWebView)
        let constraints = [
            inspectorWebView.topAnchor.constraint(equalTo: inspectorWebViewContainer.topAnchor),
            inspectorWebView.leadingAnchor.constraint(equalTo: inspectorWebViewContainer.leadingAnchor),
            inspectorWebView.trailingAnchor.constraint(equalTo: inspectorWebViewContainer.trailingAnchor),
            inspectorWebView.bottomAnchor.constraint(equalTo: inspectorWebViewContainer.bottomAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        inspectorWebViewConstraints = constraints
        attachedInspectorWebView = inspectorWebView
    }

    private func detachInspectorWebViewIfNeeded() {
        guard let attachedInspectorWebView,
              attachedInspectorWebView.superview === inspectorWebViewContainer else {
            self.attachedInspectorWebView = nil
            NSLayoutConstraint.deactivate(inspectorWebViewConstraints)
            inspectorWebViewConstraints.removeAll(keepingCapacity: true)
            return
        }
        NSLayoutConstraint.deactivate(inspectorWebViewConstraints)
        inspectorWebViewConstraints.removeAll(keepingCapacity: true)
        attachedInspectorWebView.removeFromSuperview()
        self.attachedInspectorWebView = nil
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

#if DEBUG
extension WIDOMTreeViewController {
    var errorLabelStringValueForTesting: String {
        errorLabel.stringValue
    }

    var isErrorLabelHiddenForTesting: Bool {
        errorLabel.isHidden
    }
}
#endif

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("DOM Tree (AppKit)") {
    WIAppKitPreviewContainer {
        WIDOMTreeViewController(inspector: WIDOMPreviewFixtures.makeInspector(mode: .selected))
    }
}
#endif


#endif
