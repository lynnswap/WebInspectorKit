#if canImport(AppKit)
import AppKit

@MainActor
final class DOMInspectorTabViewController: NSSplitViewController {
    private let inspector: WIDOMPaneViewModel
    private let domTreeViewController: DOMTreeTabViewController
    private let elementDetailsViewController: ElementDetailsTabViewController

    init(inspector: WIDOMPaneViewModel) {
        self.inspector = inspector
        self.domTreeViewController = DOMTreeTabViewController(inspector: inspector)
        self.elementDetailsViewController = ElementDetailsTabViewController(inspector: inspector)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
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
#endif
