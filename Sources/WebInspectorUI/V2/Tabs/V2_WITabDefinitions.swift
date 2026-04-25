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

    private enum ContentID {
        static let tree = "tree"
        static let element = "element"
    }

    func displayTabs(for layout: V2_WITabHostLayout, tab: V2_WITab) -> [V2_WIDisplayTab] {
        switch layout {
        case .compact:
            [.content(sourceTab: tab), .compactElement(sourceTab: tab)]
        case .regular:
            [.content(sourceTab: tab)]
        }
    }

    func contentKeys(
        for layout: V2_WITabHostLayout,
        displayTab: V2_WIDisplayTab
    ) -> [V2_WIDisplayContentKey] {
        switch (layout, displayTab.kind) {
        case (.compact, .content):
            [contentKey(ContentID.tree)]
        case (.compact, .compactElement):
            [contentKey(ContentID.element)]
        case (.regular, _):
            [
                contentKey(ContentID.tree),
                contentKey(ContentID.element),
            ]
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
                rootViewController: cachedDOMTreeViewController(session: session),
                dom: session.runtime.dom
            )
        case (.compact, .compactElement):
            V2_DOMCompactTabNavigationController(
                rootViewController: cachedDOMElementViewController(session: session),
                dom: session.runtime.dom
            )
        case (.regular, _):
            V2_WIRegularSplitRootViewController(
                contentViewController: V2_DOMSplitViewController(
                    dom: session.runtime.dom,
                    treeViewController: cachedDOMTreeViewController(session: session),
                    elementViewController: cachedDOMElementViewController(session: session)
                )
            )
        }
    }

    private func cachedDOMTreeViewController(session: V2_WISession) -> V2_DOMTreeViewController {
        session.interface.viewController(for: contentKey(ContentID.tree), session: session) {
            V2_DOMTreeViewController(dom: session.runtime.dom)
        }
    }

    private func cachedDOMElementViewController(session: V2_WISession) -> V2_DOMElementViewController {
        session.interface.viewController(for: contentKey(ContentID.element), session: session) {
            V2_DOMElementViewController(dom: session.runtime.dom)
        }
    }

    private func contentKey(_ contentID: String) -> V2_WIDisplayContentKey {
        V2_WIDisplayContentKey(definitionID: id, contentID: contentID)
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
        let listViewController = session.interface.viewController(
            for: V2_WIDisplayContentKey(definitionID: id, contentID: "root"),
            session: session
        ) {
            V2_NetworkListViewController(inspector: session.runtime.network.model)
        }

        switch layout {
        case .compact:
            listViewController.installNavigationItems(on: listViewController.navigationItem)
            return V2_WICompactTabNavigationController(
                rootViewController: listViewController
            )
        case .regular:
            return V2_WIRegularSplitRootViewController(
                contentViewController: V2_NetworkSplitViewController(
                    listViewController: listViewController
                )
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
