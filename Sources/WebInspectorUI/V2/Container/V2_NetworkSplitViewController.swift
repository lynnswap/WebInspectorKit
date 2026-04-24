#if canImport(UIKit)
import UIKit

@MainActor
final class V2_NetworkSplitViewController: UISplitViewController {
    private let primaryViewController = V2_NetworkSplitViewController.makeEmptyViewController()
    private let secondaryViewController = V2_NetworkSplitViewController.makeEmptyViewController()
    private let compactViewController = V2_NetworkSplitViewController.makeEmptyViewController()

    init() {
        super.init(style: .doubleColumn)
        configureSplitViewLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    private func configureSplitViewLayout() {
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never
        preferredDisplayMode = .oneBesideSecondary

        setViewController(compactViewController, for: .compact)
        setViewController(primaryViewController, for: .primary)
        setViewController(secondaryViewController, for: .secondary)
    }

    private static func makeEmptyViewController() -> UIViewController {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .clear
        return viewController
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2 Network Split") {
    V2_NetworkSplitViewController()
}
#endif
#endif
