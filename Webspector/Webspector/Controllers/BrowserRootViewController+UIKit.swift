#if canImport(UIKit)
import UIKit
import WebInspectorKit

@MainActor
final class BrowserRootViewController: UINavigationController {
    let store: BrowserStore
    let inspectorController: WIModel
    let launchConfiguration: BrowserLaunchConfiguration

    init(
        store: BrowserStore? = nil,
        inspectorController: WIModel? = nil,
        launchConfiguration: BrowserLaunchConfiguration
    ) {
        let resolvedStore = store ?? BrowserStore(
            url: launchConfiguration.initialURL,
            automaticallyLoadsInitialRequest: false
        )
        let resolvedInspectorController = inspectorController ?? WIModel()

        self.store = resolvedStore
        self.inspectorController = resolvedInspectorController
        self.launchConfiguration = launchConfiguration

        let pageViewController = BrowserPageViewController(
            store: resolvedStore,
            inspectorController: resolvedInspectorController,
            launchConfiguration: launchConfiguration
        )

        super.init(rootViewController: pageViewController)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        nil
    }

    isolated deinit {
        inspectorController.disconnect()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = false
        setNavigationBarHidden(false, animated: false)
        view.backgroundColor = .systemBackground
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNavigationBarHidden(false, animated: false)
    }

    var pageViewControllerForTesting: BrowserPageViewController? {
        viewControllers.first as? BrowserPageViewController
    }
}
#endif
