#if canImport(UIKit)
import UIKit

@MainActor
package struct DOMTabController: BuiltInTabController {
    package let tabID = WebInspectorTab.dom.id
    package let descriptor = TabDisplayDescriptor(
        title: WebInspectorTab.dom.title,
        image: WebInspectorTab.dom.image
    )

    private let elementDescriptor = TabDisplayDescriptor(
        title: "Element",
        image: UIImage(systemName: "info.circle")
    )

    private enum ContentID {
        static let tree = "tree"
        static let element = "element"
    }

    package func displayItems(for layout: WebInspectorTabHostLayout) -> [TabDisplayItem] {
        switch layout {
        case .compact:
            [.tab(tabID), .domElement(parent: tabID)]
        case .regular:
            [.tab(tabID)]
        }
    }

    package func descriptor(for displayItem: TabDisplayItem) -> TabDisplayDescriptor? {
        switch displayItem {
        case let .tab(tabID):
            tabID == self.tabID ? descriptor : nil
        case let .domElement(parent):
            parent == tabID ? elementDescriptor : nil
        }
    }

    package func contentKeys(
        for layout: WebInspectorTabHostLayout,
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

    package func makeViewController(
        for displayItem: TabDisplayItem,
        session: WebInspectorSession,
        layout: WebInspectorTabHostLayout
    ) -> UIViewController {
        switch (layout, displayItem) {
        case (.compact, .tab):
            DOMCompactNavigationController(
                rootViewController: cachedTreeViewController(session: session),
                session: session.inspector
            )
        case (.compact, .domElement):
            DOMCompactNavigationController(
                rootViewController: cachedElementViewController(session: session),
                session: session.inspector
            )
        case (.regular, _):
            RegularSplitRootViewController(
                contentViewController: DOMSplitViewController(
                    treeViewController: cachedTreeViewController(session: session),
                    elementViewController: cachedElementViewController(session: session),
                    session: session.inspector
                )
            )
        }
    }

    private func cachedTreeViewController(session: WebInspectorSession) -> DOMTreeViewController {
        session.interface.viewController(for: contentKey(ContentID.tree)) {
            DOMTreeViewController(session: session.inspector)
        }
    }

    private func cachedElementViewController(session: WebInspectorSession) -> DOMElementViewController {
        session.interface.viewController(for: contentKey(ContentID.element)) {
            DOMElementViewController(dom: session.inspector.dom)
        }
    }

    private func contentKey(_ contentID: String) -> TabContentKey {
        TabContentKey(tabID: tabID, contentID: contentID)
    }
}
#endif
