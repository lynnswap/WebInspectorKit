#if canImport(UIKit)
import UIKit

@MainActor
struct V2_DOMTabController: V2_BuiltInTabController {
    let tabID = V2_WITab.dom.id
    let descriptor = V2_TabDisplayDescriptor(
        title: V2_WITab.dom.title,
        image: V2_WITab.dom.image
    )

    private let elementDescriptor = V2_TabDisplayDescriptor(
        title: "Element",
        image: UIImage(systemName: "info.circle")
    )

    private enum ContentID {
        static let tree = "tree"
        static let element = "element"
    }

    func displayItems(for layout: V2_WITabHostLayout) -> [V2_TabDisplayItem] {
        switch layout {
        case .compact:
            [.tab(tabID), .domElement(parent: tabID)]
        case .regular:
            [.tab(tabID)]
        }
    }

    func descriptor(for displayItem: V2_TabDisplayItem) -> V2_TabDisplayDescriptor? {
        switch displayItem {
        case let .tab(tabID):
            tabID == self.tabID ? descriptor : nil
        case let .domElement(parent):
            parent == tabID ? elementDescriptor : nil
        }
    }

    func contentKeys(
        for layout: V2_WITabHostLayout,
        displayItem: V2_TabDisplayItem
    ) -> [V2_TabContentKey] {
        switch (layout, displayItem) {
        case (.compact, .tab):
            [contentKey(ContentID.tree)]
        case (.compact, .domElement):
            [contentKey(ContentID.element)]
        case (.regular, _):
            [
                contentKey(ContentID.tree),
                contentKey(ContentID.element),
            ]
        }
    }

    func makeViewController(
        for displayItem: V2_TabDisplayItem,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController {
        switch (layout, displayItem) {
        case (.compact, .tab):
            V2_DOMCompactTabNavigationController(
                rootViewController: cachedDOMTreeViewController(session: session),
                dom: session.runtime.dom
            )
        case (.compact, .domElement):
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
        session.interface.viewController(for: contentKey(ContentID.tree)) {
            V2_DOMTreeViewController(dom: session.runtime.dom)
        }
    }

    private func cachedDOMElementViewController(session: V2_WISession) -> V2_DOMElementViewController {
        session.interface.viewController(for: contentKey(ContentID.element)) {
            V2_DOMElementViewController(dom: session.runtime.dom)
        }
    }

    private func contentKey(_ contentID: String) -> V2_TabContentKey {
        V2_TabContentKey(tabID: tabID, contentID: contentID)
    }
}
#endif
