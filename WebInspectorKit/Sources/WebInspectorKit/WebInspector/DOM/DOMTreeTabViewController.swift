import WebKit
import WebInspectorKitCore

#if canImport(UIKit)
import UIKit

@MainActor
final class DOMTreeTabViewController: UIViewController {
    private let inspector: WIDOMPaneViewModel
    private let observationToken = WIObservationToken()

    private lazy var pickItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: "viewfinder.circle"),
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
        observationToken.invalidate()
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

        observeState()
        updateUI()
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
        observationToken.observe({ [weak self] in
            guard let self else { return }
            _ = self.inspector.errorMessage
            _ = self.inspector.hasPageWebView
            _ = self.inspector.isSelectingElement
            _ = self.inspector.selection.nodeId
        }, onChange: { [weak self] in
            self?.updateUI()
        })
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
    private let observationToken = WIObservationToken()

    private let errorLabel = NSTextField(labelWithString: "")
    private var inspectorWebView: InspectorWebView?

    private lazy var pickButton: NSButton = {
        let button = NSButton(title: wiLocalized("dom.controls.pick"), target: self, action: #selector(toggleSelectionMode))
        button.bezelStyle = .rounded
        return button
    }()

    private lazy var copyButton: NSPopUpButton = {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.title = wiLocalized("Copy")
        button.bezelStyle = .rounded
        button.menu = makeCopyMenu()
        return button
    }()

    private lazy var reloadButton: NSButton = {
        let button = NSButton(title: wiLocalized("reload"), target: self, action: #selector(reloadInspector))
        button.bezelStyle = .rounded
        return button
    }()

    private lazy var deleteButton: NSButton = {
        let button = NSButton(title: wiLocalized("inspector.delete_node"), target: self, action: #selector(deleteNode))
        button.bezelStyle = .rounded
        return button
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
        observationToken.invalidate()
    }

    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let toolbar = NSStackView(views: [pickButton, copyButton, reloadButton, deleteButton])
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .centerY

        let inspectorWebView = inspector.frontendStore.makeInspectorWebView()
        inspectorWebView.translatesAutoresizingMaskIntoConstraints = false
        self.inspectorWebView = inspectorWebView

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.maximumNumberOfLines = 3

        view.addSubview(toolbar)
        view.addSubview(inspectorWebView)
        view.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),

            inspectorWebView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            inspectorWebView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inspectorWebView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorWebView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorLabel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        observeState()
        updateUI()
    }

    private func observeState() {
        observationToken.observe({ [weak self] in
            guard let self else { return }
            _ = self.inspector.errorMessage
            _ = self.inspector.hasPageWebView
            _ = self.inspector.isSelectingElement
            _ = self.inspector.selection.nodeId
        }, onChange: { [weak self] in
            self?.updateUI()
        })
    }

    private func makeCopyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: wiLocalized("Copy"), action: nil, keyEquivalent: "")
        menu.addItem(.separator())

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

    private func updateUI() {
        if let errorMessage = inspector.errorMessage, !errorMessage.isEmpty {
            errorLabel.stringValue = errorMessage
            errorLabel.isHidden = false
        } else {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        }

        pickButton.state = inspector.isSelectingElement ? .on : .off
        pickButton.isEnabled = inspector.hasPageWebView
        copyButton.isEnabled = inspector.selection.nodeId != nil
        reloadButton.isEnabled = inspector.hasPageWebView
        deleteButton.isEnabled = inspector.selection.nodeId != nil
    }

    @objc
    private func toggleSelectionMode() {
        inspector.toggleSelectionMode()
    }

    @objc
    private func copyHTML(_ sender: NSMenuItem) {
        inspector.copySelection(.html)
    }

    @objc
    private func copySelectorPath(_ sender: NSMenuItem) {
        inspector.copySelection(.selectorPath)
    }

    @objc
    private func copyXPath(_ sender: NSMenuItem) {
        inspector.copySelection(.xpath)
    }

    @objc
    private func reloadInspector() {
        Task {
            await inspector.reloadInspector()
        }
    }

    @objc
    private func deleteNode() {
        inspector.deleteSelectedNode()
    }
}

#endif
