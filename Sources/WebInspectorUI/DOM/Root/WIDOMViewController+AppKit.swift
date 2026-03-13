#if canImport(AppKit)
import AppKit
import WebInspectorCore

@MainActor
public final class WIDOMViewController: NSSplitViewController {
    private static let splitViewAutosaveName = NSSplitView.AutosaveName("WebInspectorKit.DOMSplitView")

    private let store: WIDOMStore
    private let domTreeViewController: WIDOMTreeViewController
    private let elementDetailsViewController: WIDOMDetailViewController

    public init(store: WIDOMStore) {
        self.store = store
        store.setUIBridge(WIDOMPlatformBridge.shared)
        self.domTreeViewController = WIDOMTreeViewController(store: store)
        self.elementDetailsViewController = WIDOMDetailViewController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = Self.splitViewAutosaveName

        let domTreeItem = NSSplitViewItem(viewController: domTreeViewController)
        domTreeItem.minimumThickness = 320
        domTreeItem.maximumThickness = 760
        domTreeItem.preferredThicknessFraction = 0.48
        domTreeItem.canCollapse = false

        let elementItem = NSSplitViewItem(viewController: elementDetailsViewController)
        elementItem.minimumThickness = 300

        splitViewItems = [domTreeItem, elementItem]
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("DOM Root (AppKit)") {
    WIAppKitPreviewContainer {
        WIDOMViewController(store: WIDOMPreviewFixtures.makeStore(mode: .selected))
    }
}
#endif

#endif
