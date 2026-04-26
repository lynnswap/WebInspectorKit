#if canImport(UIKit)
import UIKit

@MainActor
final class V2_CustomTabDefinition: V2_WITabDefinition {
    let id: V2_WITab.ID
    let title: String
    let image: UIImage?
    private let viewControllerProvider: V2_WITab.ViewControllerProvider?

    init(
        id: V2_WITab.ID,
        title: String,
        image: UIImage?,
        viewControllerProvider: V2_WITab.ViewControllerProvider?
    ) {
        self.id = id
        self.title = title
        self.image = image
        self.viewControllerProvider = viewControllerProvider
    }

    func makeViewController(
        for displayTab: V2_WIDisplayTab,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController {
        let viewController = session.interface.viewController(
            for: V2_WIDisplayContentKey(definitionID: id, contentID: "root"),
            session: session
        ) {
            viewControllerProvider?(displayTab.sourceTab, session) ?? UIViewController()
        }
        guard layout == .regular,
              viewController is UISplitViewController else {
            viewController.wiDetachFromV2ContainerForReuse()
            return viewController
        }
        return V2_WIRegularSplitRootViewController(contentViewController: viewController)
    }
}
#endif
