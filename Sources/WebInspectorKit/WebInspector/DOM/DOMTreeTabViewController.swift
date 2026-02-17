import WebKit
import WebInspectorKitCore

#if canImport(UIKit)
import UIKit

@MainActor
final class DOMTreeTabViewController: UIViewController {
    private let inspector: WebInspector.DOMInspector
    private let observationToken = WIObservationToken()

    private let errorContainer = UIView()
    private let errorLabel = UILabel()
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

    init(inspector: WebInspector.DOMInspector) {
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
        view.backgroundColor = .systemBackground

        let inspectorWebView = inspector.frontendStore.makeInspectorWebView()
        inspectorWebView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inspectorWebView)

        setupErrorOverlay()
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

    private func setupErrorOverlay() {
        errorContainer.translatesAutoresizingMaskIntoConstraints = false
        errorContainer.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.92)
        errorContainer.layer.cornerRadius = 12
        errorContainer.isHidden = true

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.textColor = .secondaryLabel
        errorLabel.font = .preferredFont(forTextStyle: .footnote)

        errorContainer.addSubview(errorLabel)
        view.addSubview(errorContainer)

        NSLayoutConstraint.activate([
            errorLabel.topAnchor.constraint(equalTo: errorContainer.topAnchor, constant: 12),
            errorLabel.leadingAnchor.constraint(equalTo: errorContainer.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: errorContainer.trailingAnchor, constant: -12),
            errorLabel.bottomAnchor.constraint(equalTo: errorContainer.bottomAnchor, constant: -12),

            errorContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            errorContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
    }

    private func setupNavigationItems() {
        navigationItem.rightBarButtonItems = [secondaryActionsItem, pickItem]
    }

    private func makeSecondaryMenu() -> UIMenu {
        let hasSelection = inspector.selection.nodeId != nil
        let hasPageWebView = inspector.hasPageWebView

        let copySection = UIMenu(
            title: wiLocalized("Copy"),
            options: .displayInline,
            children: [
                UIAction(title: "HTML", attributes: hasSelection ? [] : [.disabled]) { [weak self] _ in
                    self?.inspector.copySelection(.html)
                },
                UIAction(title: wiLocalized("dom.element.copy.selector_path"), attributes: hasSelection ? [] : [.disabled]) { [weak self] _ in
                    self?.inspector.copySelection(.selectorPath)
                },
                UIAction(title: "XPath", attributes: hasSelection ? [] : [.disabled]) { [weak self] _ in
                    self?.inspector.copySelection(.xpath)
                }
            ]
        )

        let reloadSection = UIMenu(
            title: wiLocalized("reload"),
            options: .displayInline,
            children: [
                UIAction(title: wiLocalized("reload.target.inspector"), attributes: hasPageWebView ? [] : [.disabled]) { [weak self] _ in
                    guard let self else { return }
                    Task {
                        await self.inspector.reloadInspector()
                    }
                },
                UIAction(title: wiLocalized("reload.target.page"), attributes: hasPageWebView ? [] : [.disabled]) { [weak self] _ in
                    self?.inspector.session.reloadPage()
                }
            ]
        )

        let deleteAction = UIAction(
            title: wiLocalized("inspector.delete_node"),
            image: UIImage(systemName: "trash"),
            attributes: hasSelection ? [.destructive] : [.destructive, .disabled]
        ) { [weak self] _ in
            self?.deleteNode()
        }

        return UIMenu(children: [copySection, reloadSection, deleteAction])
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
            errorLabel.text = errorMessage
            errorContainer.isHidden = false
        } else {
            errorLabel.text = nil
            errorContainer.isHidden = true
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
    private let inspector: WebInspector.DOMInspector
    private let observationToken = WIObservationToken()

    private let errorLabel = NSTextField(labelWithString: "")
    private var inspectorWebView: InspectorWebView?

    private lazy var pickButton: NSButton = {
        let button = NSButton(title: wiLocalized("dom.controls.pick"), target: self, action: #selector(toggleSelectionMode))
        button.bezelStyle = .rounded
        return button
    }()

    private lazy var copyButton: NSButton = {
        let button = NSButton(title: wiLocalized("Copy"), target: self, action: #selector(showCopyMenu(_:)))
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

    init(inspector: WebInspector.DOMInspector) {
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
    private func showCopyMenu(_ sender: NSButton) {
        guard let menu = sender.menu else {
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
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
