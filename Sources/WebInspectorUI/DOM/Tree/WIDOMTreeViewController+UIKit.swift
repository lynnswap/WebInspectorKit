import WebKit
import WebInspectorEngine
import WebInspectorRuntime
import ObservationsCompat

#if canImport(UIKit)
import UIKit

@MainActor
public final class WIDOMTreeViewController: UIViewController {
    private let inspector: WIDOMModel
    private let showsNavigationControls: Bool
    private let errorUpdateCoalescer = UIUpdateCoalescer()
    private let navigationUpdateCoalescer = UIUpdateCoalescer()

    private lazy var pickItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: pickSymbolName),
            style: .plain,
            target: self,
            action: #selector(toggleSelectionMode)
        )
    }()

    public init(inspector: WIDOMModel, showsNavigationControls: Bool = true) {
        self.inspector = inspector
        self.showsNavigationControls = showsNavigationControls
        super.init(nibName: nil, bundle: nil)
        
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = nil

        let inspectorWebView = inspector.makeInspectorWebView()
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
            self.scheduleNavigationControlsUpdate()
        }

        observeState()
        updateErrorPresentation(errorMessage: inspector.errorMessage)
        updateNavigationControls()
    }

    private var pickSymbolName: String {
        traitCollection.horizontalSizeClass == .compact ? "viewfinder.circle" : "scope"
    }

    private func setupNavigationItems() {
        guard showsNavigationControls else {
            navigationItem.rightBarButtonItems = nil
            return
        }
        navigationItem.rightBarButtonItems = [pickItem]
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
        inspector.observe(
            \.errorMessage,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleErrorPresentationUpdate()
        }
        inspector.observe(
            \.hasPageWebView,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        inspector.observe(
            \.isSelectingElement,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        inspector.selection.observe(
            \.nodeId,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
    }

    private func scheduleErrorPresentationUpdate() {
        errorUpdateCoalescer.schedule { [weak self] in
            guard let self else { return }
            self.updateErrorPresentation(errorMessage: self.inspector.errorMessage)
        }
    }

    private func scheduleNavigationControlsUpdate() {
        navigationUpdateCoalescer.schedule { [weak self] in
            self?.updateNavigationControls()
        }
    }

    private func updateErrorPresentation(errorMessage: String?) {
        if let errorMessage, !errorMessage.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = errorMessage
            configuration.image = UIImage(systemName: "exclamationmark.triangle")
            contentUnavailableConfiguration = configuration
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func updateNavigationControls() {
        if showsNavigationControls {
            navigationItem.additionalOverflowItems = UIDeferredMenuElement.uncached { [weak self] completion in
                completion((self?.makeSecondaryMenu() ?? UIMenu()).children)
            }
            pickItem.isEnabled = inspector.hasPageWebView
            pickItem.image = UIImage(systemName: pickSymbolName)
            pickItem.tintColor = inspector.isSelectingElement ? .systemBlue : .label
        } else {
            navigationItem.additionalOverflowItems = nil
        }
    }

    @objc
    private func toggleSelectionMode() {
        inspector.toggleSelectionMode()
    }

    @objc
    private func deleteNode() {
        inspector.deleteSelectedNode(undoManager: undoManager)
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("DOM Tree (UIKit)") {
    WIUIKitPreviewContainer {
        UINavigationController(
            rootViewController: WIDOMTreeViewController(
                inspector: WIDOMPreviewFixtures.makeInspector(mode: .selected)
            )
        )
    }
}
#endif


#endif
