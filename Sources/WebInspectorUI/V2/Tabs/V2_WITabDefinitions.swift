#if canImport(UIKit)
import UIKit

@MainActor
enum V2_WIDisplayTabKind: Hashable {
    case content
    case compactElement
}

@MainActor
struct V2_WIDisplayTab: Hashable, Identifiable {
    typealias ID = String

    static let compactElementID = "wi_element"

    let id: ID
    let sourceTab: V2_WITab
    let title: String
    let image: UIImage?
    let kind: V2_WIDisplayTabKind

    static func content(sourceTab: V2_WITab) -> V2_WIDisplayTab {
        V2_WIDisplayTab(
            id: sourceTab.id,
            sourceTab: sourceTab,
            title: sourceTab.title,
            image: sourceTab.image,
            kind: .content
        )
    }

    static func compactElement(sourceTab: V2_WITab) -> V2_WIDisplayTab {
        V2_WIDisplayTab(
            id: compactElementID,
            sourceTab: sourceTab,
            title: "Element",
            image: UIImage(systemName: "info.circle"),
            kind: .compactElement
        )
    }
}

@MainActor
final class V2_DOMTabDefinition: V2_WITabDefinition {
    let id = V2_WIStandardTab.dom.id
    let title = V2_WIStandardTab.dom.title
    let image = V2_WIStandardTab.dom.image

    func displayTabs(for layout: V2_WITabHostLayout, tab: V2_WITab) -> [V2_WIDisplayTab] {
        switch layout {
        case .compact:
            [.content(sourceTab: tab), .compactElement(sourceTab: tab)]
        case .regular:
            [.content(sourceTab: tab)]
        }
    }

    func makeViewController(
        for displayTab: V2_WIDisplayTab,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController {
        switch (layout, displayTab.kind) {
        case (.compact, .content):
            V2_DOMCompactTabNavigationController(
                rootViewController: V2_DOMTreeViewController(dom: session.runtime.dom),
                dom: session.runtime.dom
            )
        case (.compact, .compactElement):
            V2_DOMCompactTabNavigationController(
                rootViewController: V2_DOMElementViewController(dom: session.runtime.dom),
                dom: session.runtime.dom
            )
        case (.regular, _):
            V2_WIRegularSplitRootViewController(
                contentViewController: V2_DOMSplitViewController(session: session)
            )
        }
    }
}

@MainActor
final class V2_NetworkTabDefinition: V2_WITabDefinition {
    let id = V2_WIStandardTab.network.id
    let title = V2_WIStandardTab.network.title
    let image = V2_WIStandardTab.network.image

    func makeViewController(
        for displayTab: V2_WIDisplayTab,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController {
        switch layout {
        case .compact:
            V2_WICompactTabNavigationController(
                rootViewController: V2_NetworkCompactViewController()
            )
        case .regular:
            V2_WIRegularSplitRootViewController(
                contentViewController: V2_NetworkSplitViewController()
            )
        }
    }
}

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
        let viewController = viewControllerProvider?(displayTab.sourceTab, session) ?? UIViewController()
        guard layout == .regular,
              viewController is UISplitViewController else {
            return viewController
        }
        return V2_WIRegularSplitRootViewController(contentViewController: viewController)
    }
}
#endif
