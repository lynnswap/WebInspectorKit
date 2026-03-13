import WebKit
import ObservationBridge
import WebInspectorCore
import WebInspectorResources
import WebInspectorCore

#if canImport(AppKit)
import AppKit
import WebInspectorResources

@MainActor
public final class WIDOMTreeViewController: NSViewController {
    private let store: WIDOMStore
    private var contextMenuNodeID: Int?
    private weak var inspectorWebView: WKWebView?
    private let errorLabel = NSTextField(labelWithString: "")
    private var observationHandles: Set<ObservationHandle> = []

    public init(store: WIDOMStore) {
        self.store = store
        store.setUIBridge(WIDOMPlatformBridge.shared)
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

        let inspectorWebView = store.makeFrontendWebView()
        inspectorWebView.translatesAutoresizingMaskIntoConstraints = false
        self.inspectorWebView = inspectorWebView
        store.setDOMContextMenuProvider { [weak self] nodeID in
            guard let self else {
                return nil
            }
            self.contextMenuNodeID = nodeID
            return self.makeTreeContextMenu()
        }

        view.addSubview(inspectorWebView)
        configureErrorLabel()
        view.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            inspectorWebView.topAnchor.constraint(equalTo: view.topAnchor),
            inspectorWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inspectorWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20)
        ])

        startObservingErrorState()
        updateErrorPresentation()
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
        contextMenuNodeID = nil
        guard let nodeID else {
            return
        }
        store.deleteNode(nodeId: nodeID, undoManager: undoManager)
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
                let text = try await store.session.selectionCopyText(nodeId: nodeID, kind: kind)
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

    private func configureErrorLabel() {
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.alignment = .center
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.isHidden = true
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func startObservingErrorState() {
        store.observe(
            \.errorMessage,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.updateErrorPresentation()
        }
        .store(in: &observationHandles)

        store.session.graphStore.observe(
            \.rootID,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.updateErrorPresentation()
        }
        .store(in: &observationHandles)
    }

    private func updateErrorPresentation() {
        guard let errorMessage = store.errorMessage,
              errorMessage.isEmpty == false,
              store.session.graphStore.rootID == nil else {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
            inspectorWebView?.isHidden = false
            return
        }

        errorLabel.stringValue = errorMessage
        errorLabel.isHidden = false
        inspectorWebView?.isHidden = true
    }

    var testShowsErrorLabel: Bool {
        errorLabel.isHidden == false
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("DOM Tree (AppKit)") {
    WIDOMTreeViewController(store: WIDOMPreviewFixtures.makeStore(mode: .selected))
}
#endif


#endif
