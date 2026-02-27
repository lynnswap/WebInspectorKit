import WebKit
import WebInspectorEngine
import WebInspectorRuntime
import ObservationsCompat

#if canImport(AppKit)
import AppKit

@MainActor
public final class WIDOMTreeViewController: NSViewController {
    private let inspector: WIDOMModel
    private var contextMenuNodeID: Int?
    private let errorUpdateCoalescer = UIUpdateCoalescer()

    private let errorLabel = NSTextField(labelWithString: "")

    public init(inspector: WIDOMModel) {
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
        updateErrorLabel(errorMessage: inspector.errorMessage)
    }

    private func observeState() {
        inspector.observe(
            \.errorMessage,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.errorUpdateCoalescer.schedule { [weak self] in
                guard let self else { return }
                self.updateErrorLabel(errorMessage: self.inspector.errorMessage)
            }
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
        contextMenuNodeID = nil
        guard let nodeID else {
            return
        }
        inspector.deleteNode(nodeId: nodeID, undoManager: undoManager)
    }

    private var contextActionNodeID: Int? {
        contextMenuNodeID
    }

    private func copyNodeForContextMenu(kind: DOMSelectionCopyKind) {
        let nodeID = contextActionNodeID
        contextMenuNodeID = nil
        guard let nodeID else {
            return
        }
        Task {
            do {
                let text = try await inspector.session.selectionCopyText(nodeId: nodeID, kind: kind)
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
