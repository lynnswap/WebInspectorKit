#if canImport(UIKit)
import UIKit
import WebInspectorKit

@MainActor
final class BrowserRootViewController: UINavigationController {
    let store: BrowserStore
    let sessionController: WISessionController
    let launchConfiguration: BrowserLaunchConfiguration

    init(
        store: BrowserStore? = nil,
        sessionController: WISessionController? = nil,
        launchConfiguration: BrowserLaunchConfiguration
    ) {
        let resolvedStore = store ?? BrowserStore(
            url: launchConfiguration.initialURL,
            automaticallyLoadsInitialRequest: false
        )
        let resolvedSessionController = sessionController ?? WISessionController()

        self.store = resolvedStore
        self.sessionController = resolvedSessionController
        self.launchConfiguration = launchConfiguration

        let pageViewController = BrowserPageViewController(
            store: resolvedStore,
            sessionController: resolvedSessionController,
            launchConfiguration: launchConfiguration
        )

        super.init(rootViewController: pageViewController)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        nil
    }

    isolated deinit {
        sessionController.disconnect()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = false
        setNavigationBarHidden(true, animated: false)
        setToolbarHidden(true, animated: false)
        view.backgroundColor = .systemBackground
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNavigationBarHidden(true, animated: false)
        setToolbarHidden(true, animated: false)
    }

    var pageViewControllerForTesting: BrowserPageViewController? {
        viewControllers.first as? BrowserPageViewController
    }
}
#endif
