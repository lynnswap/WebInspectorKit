#if canImport(UIKit)
import UIKit

@MainActor
package struct V2_DOMTabController: V2_BuiltInTabController {
    package let tabID = V2_WITab.dom.id
    package let descriptor = V2_TabDisplayDescriptor(
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

    package func displayItems(for layout: V2_WITabHostLayout) -> [V2_TabDisplayItem] {
        switch layout {
        case .compact:
            [.tab(tabID), .domElement(parent: tabID)]
        case .regular:
            [.tab(tabID)]
        }
    }

    package func descriptor(for displayItem: V2_TabDisplayItem) -> V2_TabDisplayDescriptor? {
        switch displayItem {
        case let .tab(tabID):
            tabID == self.tabID ? descriptor : nil
        case let .domElement(parent):
            parent == tabID ? elementDescriptor : nil
        }
    }

    package func contentKeys(
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

    package func makeViewController(
        for displayItem: V2_TabDisplayItem,
        session: V2_WISession,
        layout: V2_WITabHostLayout
    ) -> UIViewController {
        switch (layout, displayItem) {
        case (.compact, .tab):
            V2_DOMCompactNavigationController(
                rootViewController: cachedTreeViewController(session: session),
                session: session.inspector
            )
        case (.compact, .domElement):
            V2_DOMCompactNavigationController(
                rootViewController: cachedElementViewController(session: session),
                session: session.inspector
            )
        case (.regular, _):
            V2_RegularSplitRootViewController(
                contentViewController: V2_DOMSplitViewController(
                    treeViewController: cachedTreeViewController(session: session),
                    elementViewController: cachedElementViewController(session: session),
                    session: session.inspector
                )
            )
        }
    }

    private func cachedTreeViewController(session: V2_WISession) -> V2_DOMTreeViewController {
        session.interface.viewController(for: contentKey(ContentID.tree)) {
            V2_DOMTreeViewController(session: session.inspector)
        }
    }

    private func cachedElementViewController(session: V2_WISession) -> V2_DOMElementViewController {
        session.interface.viewController(for: contentKey(ContentID.element)) {
            V2_DOMElementViewController(dom: session.inspector.dom)
        }
    }

    private func contentKey(_ contentID: String) -> V2_TabContentKey {
        V2_TabContentKey(tabID: tabID, contentID: contentID)
    }
}
#endif
