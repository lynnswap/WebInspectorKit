#if canImport(UIKit)
import UIKit

@MainActor
final class V2_DOMSplitViewController: UISplitViewController {
    private let session: V2_WISession
    private lazy var domTreeViewController = V2_DOMTreeViewController(dom: session.runtime.dom)
    private lazy var elementDetailsViewController = V2_DOMElementViewController(dom: session.runtime.dom)

    init(session: V2_WISession = V2_WISession()) {
        self.session = session
        super.init(style: .doubleColumn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureSplitViewLayout()
    }

    private func configureSplitViewLayout() {
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never

        if #available(iOS 26.0, *) {
            preferredDisplayMode = .secondaryOnly
            setViewController(domTreeViewController, for: .secondary)
            setViewController(elementDetailsViewController, for: .inspector)
            minimumInspectorColumnWidth = 320
            maximumInspectorColumnWidth = .greatestFiniteMagnitude
            preferredInspectorColumnWidthFraction = 0.3
            show(.inspector)
        } else {
            preferredDisplayMode = .oneBesideSecondary
            setViewController(domTreeViewController, for: .primary)
            setViewController(elementDetailsViewController, for: .secondary)
            minimumPrimaryColumnWidth = 320
            maximumPrimaryColumnWidth = .greatestFiniteMagnitude
            preferredPrimaryColumnWidthFraction = 0.7
        }
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2 DOM Split") {
    V2_DOMSplitViewController()
}
#endif
#endif
