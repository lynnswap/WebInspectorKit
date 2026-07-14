#if canImport(UIKit)
import UIKit

extension WebInspectorTab {
    @MainActor
    package enum ContentFactory {
        package static func makeViewController(
            for displayItem: DisplayItem,
            session: WebInspectorSession,
            interface: InterfaceModel,
            contentStore: PresentationContentStore,
            hostLayout: HostLayout
        ) -> UIViewController {
            guard let tab = interface.catalog.tabByID[displayItem.sourceTabID]
            else {
                let viewController = UIViewController()
                var configuration = UIContentUnavailableConfiguration.empty()
                configuration.text = "Tab Unavailable"
                viewController.contentUnavailableConfiguration = configuration
                return viewController
            }

            return tab.presentation.makeViewController(
                displayItem,
                Context(session: session),
                contentStore,
                hostLayout
            )
        }
    }
}
#endif
