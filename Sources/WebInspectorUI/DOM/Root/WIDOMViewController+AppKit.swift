#if canImport(AppKit)
import AppKit

@MainActor
public final class WIDOMViewController: NSSplitViewController {
    private let inspector: WIDOMModel
    private let domTreeViewController: WIDOMTreeViewController
    private let elementDetailsViewController: WIDOMDetailViewController

    public init(inspector: WIDOMModel) {
        self.inspector = inspector
        self.domTreeViewController = WIDOMTreeViewController(inspector: inspector)
        self.elementDetailsViewController = WIDOMDetailViewController(inspector: inspector)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

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
        WIDOMViewController(inspector: WIDOMPreviewFixtures.makeInspector(mode: .selected))
    }
}
#endif

#endif
