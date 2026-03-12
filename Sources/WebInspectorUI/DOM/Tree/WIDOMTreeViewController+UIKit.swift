import WebKit
import WebInspectorCore
import WebInspectorCore
import ObservationBridge

#if canImport(UIKit)
import UIKit

@MainActor
public final class WIDOMTreeViewController: UIViewController {
    private let inspector: WIDOMInspectorStore
    private let showsNavigationControls: Bool
    private var observationHandles: Set<ObservationHandle> = []
    // Keep coalescing here because navigation controls are driven by multiple observed states.
    private let navigationUpdateCoalescer = UIUpdateCoalescer()

    private lazy var pickItem: UIBarButtonItem = {
        UIBarButtonItem(
            image: UIImage(systemName: pickSymbolName),
            style: .plain,
            target: self,
            action: #selector(toggleSelectionMode)
        )
    }()

    public init(inspector: WIDOMInspectorStore, showsNavigationControls: Bool = true) {
        self.inspector = inspector
        self.showsNavigationControls = showsNavigationControls
        inspector.setUIBridge(WIDOMPlatformBridge.shared)
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
        updateNavigationControls()
        updateErrorPresentation()
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
        let hasSelection = inspector.selectedEntry != nil
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
            \.hasPageWebView,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        .store(in: &observationHandles)
        inspector.observe(
            \.isSelectingElement,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        .store(in: &observationHandles)
        inspector.observe(
            \.errorMessage,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.updateErrorPresentation()
        }
        .store(in: &observationHandles)
        inspector.session.graphStore.observe(
            \.selectedID,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationControlsUpdate()
        }
        .store(in: &observationHandles)
        inspector.session.graphStore.observe(
            \.rootID,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.updateErrorPresentation()
        }
        .store(in: &observationHandles)
    }

    private func scheduleNavigationControlsUpdate() {
        navigationUpdateCoalescer.schedule { [weak self] in
            self?.updateNavigationControls()
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

    private func updateErrorPresentation() {
        guard let errorMessage = inspector.errorMessage,
              errorMessage.isEmpty == false,
              inspector.session.graphStore.rootID == nil else {
            contentUnavailableConfiguration = nil
            navigationItem.prompt = nil
            return
        }

        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.text = String(localized: "Unable to Load DOM")
        configuration.secondaryText = errorMessage
        contentUnavailableConfiguration = configuration
        navigationItem.prompt = errorMessage
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
