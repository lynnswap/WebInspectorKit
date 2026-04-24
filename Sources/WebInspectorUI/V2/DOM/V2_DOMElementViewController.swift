#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
final class V2_DOMElementViewController: UIViewController {
    private let dom: V2_WIDOMRuntime

    init(dom: V2_WIDOMRuntime) {
        self.dom = dom
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}
#endif
