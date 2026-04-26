#if canImport(UIKit)
import UIKit

@MainActor
enum V2_WITabContentFactory {
    static func makeViewController(
        for tab: V2_WITab,
        session: V2_WISession,
        hostLayout: V2_WITabHostLayout
    ) -> UIViewController {
        makeViewController(
            for: .content(sourceTab: tab),
            session: session,
            hostLayout: hostLayout
        )
    }

    static func makeViewController(
        for displayTab: V2_WIDisplayTab,
        session: V2_WISession,
        hostLayout: V2_WITabHostLayout
    ) -> UIViewController {
        displayTab.sourceTab.definition.makeViewController(
            for: displayTab,
            session: session,
            layout: hostLayout
        )
    }
}
#endif
