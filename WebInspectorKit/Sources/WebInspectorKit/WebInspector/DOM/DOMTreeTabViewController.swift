import WebKit
import WebInspectorKitCore
import ObservationsCompat

@MainActor
private struct DOMTreeObservedState: Sendable, Equatable {
    let errorMessage: String?
    let hasPageWebView: Bool
    let isSelectingElement: Bool
    let selectionNodeID: Int?
}

@MainActor
private func domTreeObservedState(from inspector: WIDOMPaneViewModel) -> DOMTreeObservedState {
    DOMTreeObservedState(
        errorMessage: inspector.errorMessage,
        hasPageWebView: inspector.hasPageWebView,
        isSelectingElement: inspector.isSelectingElement,
        selectionNodeID: inspector.selection.nodeId
    )
}

#if canImport(UIKit)
import UIKit

@MainActor
final class DOMTreeTabViewController: UIViewController {
    private let inspector: WIDOMPaneViewModel
    private var observationTask: Task<Void, Never>?

    private lazy var pickItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: pickSymbolName),
            style: .plain,
            target: self,
            action: #selector(toggleSelectionMode)
        )
    }()
    private lazy var secondaryActionsItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: wiSecondaryActionSymbolName()),
            menu: makeSecondaryMenu()
        )
    }()

    init(inspector: WIDOMPaneViewModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        navigationItem.title = ""

        let inspectorWebView = inspector.frontendStore.makeInspectorWebView()
        inspectorWebView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inspectorWebView)

        setupNavigationItems()

        NSLayoutConstraint.activate([
            inspectorWebView.topAnchor.constraint(equalTo: view.topAnchor),
            inspectorWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inspectorWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.updateUI()
        }

        observeState()
        updateUI()
    }

    private var pickSymbolName: String {
        traitCollection.horizontalSizeClass == .compact ? "viewfinder.circle" : "scope"
    }

    private func setupNavigationItems() {
        navigationItem.rightBarButtonItems = [secondaryActionsItem, pickItem]
    }

    private func makeSecondaryMenu() -> UIMenu {
        let hasSelection = inspector.selection.nodeId != nil
        let hasPageWebView = inspector.hasPageWebView

        return DOMSecondaryMenuBuilder.makeMenu(
            hasSelection: hasSelection,
            hasPageWebView: hasPageWebView,
            onCopyHTML: { [weak self] in
                self?.inspector.copySelection(.html)
            },
            onCopySelectorPath: { [weak self] in
                self?.inspector.copySelection(.selectorPath)
            },
            onCopyXPath: { [weak self] in
                self?.inspector.copySelection(.xpath)
            },
            onReloadInspector: { [weak self] in
                guard let self else { return }
                Task {
                    await self.inspector.reloadInspector()
                }
            },
            onReloadPage: { [weak self] in
                self?.inspector.session.reloadPage()
            },
            onDeleteNode: { [weak self] in
                self?.deleteNode()
            }
        )
    }

    private func observeState() {
        guard observationTask == nil else {
            return
        }
        let inspector = self.inspector
        observationTask = Task { @MainActor [weak self] in
            let stream = makeObservationsCompatStream {
                domTreeObservedState(from: inspector)
            }
            for await _ in stream {
                guard !Task.isCancelled else {
                    break
                }
                self?.updateUI()
            }
        }
    }

    private func updateUI() {
        if let errorMessage = inspector.errorMessage, !errorMessage.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = errorMessage
            configuration.image = UIImage(systemName: "exclamationmark.triangle")
            contentUnavailableConfiguration = configuration
        } else {
            contentUnavailableConfiguration = nil
        }

        let hasSelection = inspector.selection.nodeId != nil
        let hasPageWebView = inspector.hasPageWebView

        secondaryActionsItem.menu = makeSecondaryMenu()
        secondaryActionsItem.isEnabled = hasSelection || hasPageWebView
        pickItem.isEnabled = inspector.hasPageWebView
        pickItem.image = UIImage(systemName: pickSymbolName)
        pickItem.tintColor = inspector.isSelectingElement ? .systemBlue : .label
    }

    @objc
    private func toggleSelectionMode() {
        inspector.toggleSelectionMode()
    }

    @objc
    private func deleteNode() {
        inspector.deleteSelectedNode()
    }
}

#elseif canImport(AppKit)
import AppKit

@MainActor
final class DOMTreeTabViewController: NSViewController {
    private let inspector: WIDOMPaneViewModel
    private var observationTask: Task<Void, Never>?
    private var contextMenuNodeID: Int?

    private let errorLabel = NSTextField(labelWithString: "")

    init(inspector: WIDOMPaneViewModel) {
        self.inspector = inspector
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationTask?.cancel()
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let inspectorWebView = inspector.frontendStore.makeInspectorWebView()
        inspectorWebView.translatesAutoresizingMaskIntoConstraints = false
        inspectorWebView.domContextMenuProvider = { [weak self] nodeID in
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
        updateUI()
    }

    private func observeState() {
        guard observationTask == nil else {
            return
        }
        let inspector = self.inspector
        observationTask = Task { @MainActor [weak self] in
            let stream = makeObservationsCompatStream {
                domTreeObservedState(from: inspector)
            }
            for await _ in stream {
                guard !Task.isCancelled else {
                    break
                }
                self?.updateUI()
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

    private func updateUI() {
        if let errorMessage = inspector.errorMessage, !errorMessage.isEmpty {
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
        Task {
            await inspector.session.removeNode(nodeId: nodeID)
        }
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

#endif
