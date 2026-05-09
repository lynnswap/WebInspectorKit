#if canImport(UIKit)
import UIKit

@MainActor
struct DOMTabController: BuiltInTabController {
    let tabID = WITab.dom.id
    let descriptor = TabDisplayDescriptor(
        title: WITab.dom.title,
        image: WITab.dom.image
    )

    private let elementDescriptor = TabDisplayDescriptor(
        title: "Element",
        image: UIImage(systemName: "info.circle")
    )

    private enum ContentID {
        static let tree = "tree"
        static let element = "element"
    }

    func displayItems(for layout: WITabHostLayout) -> [TabDisplayItem] {
        switch layout {
        case .compact:
            [.tab(tabID), .domElement(parent: tabID)]
        case .regular:
            [.tab(tabID)]
        }
    }

    func descriptor(for displayItem: TabDisplayItem) -> TabDisplayDescriptor? {
        switch displayItem {
        case let .tab(tabID):
            tabID == self.tabID ? descriptor : nil
        case let .domElement(parent):
            parent == tabID ? elementDescriptor : nil
        }
    }

    func contentKeys(
        for layout: WITabHostLayout,
        displayItem: TabDisplayItem
    ) -> [TabContentKey] {
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
        for displayItem: TabDisplayItem,
        session: WISession,
        layout: WITabHostLayout
    ) -> UIViewController {
        switch (layout, displayItem) {
        case (.compact, .tab):
            DOMCompactTabNavigationController(
                rootViewController: cachedDOMTreeViewController(session: session),
                dom: session.runtime.dom
            )
        case (.compact, .domElement):
            DOMCompactTabNavigationController(
                rootViewController: cachedDOMElementViewController(session: session),
                dom: session.runtime.dom
            )
        case (.regular, _):
            WIRegularSplitRootViewController(
                contentViewController: DOMSplitViewController(
                    dom: session.runtime.dom,
                    treeViewController: cachedDOMTreeViewController(session: session),
                    elementViewController: cachedDOMElementViewController(session: session)
                )
            )
        }
    }

    private func cachedDOMTreeViewController(session: WISession) -> DOMTreeViewController {
        session.interface.viewController(for: contentKey(ContentID.tree)) {
            DOMTreeViewController(dom: session.runtime.dom)
        }
    }

    private func cachedDOMElementViewController(session: WISession) -> DOMElementViewController {
        session.interface.viewController(for: contentKey(ContentID.element)) {
            DOMElementViewController(dom: session.runtime.dom)
        }
    }

    private func contentKey(_ contentID: String) -> TabContentKey {
        TabContentKey(tabID: tabID, contentID: contentID)
    }
}
#endif
