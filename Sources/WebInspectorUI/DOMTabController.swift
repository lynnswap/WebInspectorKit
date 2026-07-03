#if canImport(UIKit)
import UIKit
import WebInspectorUIBase
import WebInspectorUIDOM

@MainActor
package struct DOMTabController: WebInspectorTab.BuiltInController {
    package let tabID = WebInspectorTab.dom.id
    package let descriptor = WebInspectorTab.DisplayDescriptor(
        title: WebInspectorTab.dom.title,
        image: WebInspectorTab.dom.image
    )

    private let elementDescriptor = WebInspectorTab.DisplayDescriptor(
        title: "Element",
        image: UIImage(systemName: "info.circle")
    )

    private enum ContentID {
        static let tree = "tree"
        static let element = "element"
    }

    package func displayItems(for layout: WebInspectorTab.HostLayout) -> [WebInspectorTab.DisplayItem] {
        switch layout {
        case .compact:
            [.tab(tabID), .domElement(parent: tabID)]
        case .regular:
            [.tab(tabID)]
        }
    }

    package func descriptor(for displayItem: WebInspectorTab.DisplayItem) -> WebInspectorTab.DisplayDescriptor? {
        switch displayItem {
        case let .tab(tabID):
            tabID == self.tabID ? descriptor : nil
        case .customTab:
            nil
        case let .domElement(parent):
            parent == tabID ? elementDescriptor : nil
        }
    }

    package func contentKeys(
        for layout: WebInspectorTab.HostLayout,
        displayItem: WebInspectorTab.DisplayItem
    ) -> [WebInspectorTab.ContentKey] {
        switch (layout, displayItem) {
        case (.compact, .tab):
            [contentKey(ContentID.tree)]
        case (.compact, .domElement):
            [contentKey(ContentID.element)]
        case (_, .customTab):
            []
        case (.regular, _):
            [
                contentKey(ContentID.tree),
                contentKey(ContentID.element),
            ]
        }
    }

    package func makeViewController(
        for displayItem: WebInspectorTab.DisplayItem,
        session: WebInspectorSession,
        layout: WebInspectorTab.HostLayout
    ) -> UIViewController {
        switch (layout, displayItem) {
        case (.compact, .tab):
            DOMCompactNavigationController(
                rootViewController: cachedTreeViewController(session: session),
                context: session.context
            )
        case (.compact, .domElement):
            DOMCompactNavigationController(rootViewController: cachedElementViewController(session: session))
        case (_, .customTab):
            UIViewController()
        case (.regular, _):
            RegularSplitRootViewController(
                contentViewController: DOMSplitViewController(
                    treeViewController: cachedTreeViewController(session: session),
                    elementViewController: cachedElementViewController(session: session),
                    context: session.context
                )
            )
        }
    }

    private func cachedTreeViewController(session: WebInspectorSession) -> DOMTreeViewController {
        session.interface.viewController(for: contentKey(ContentID.tree)) {
            DOMTreeViewController(context: session.context)
        }
    }

    private func cachedElementViewController(session: WebInspectorSession) -> DOMElementViewController {
        session.interface.viewController(for: contentKey(ContentID.element)) {
            DOMElementViewController(context: session.context)
        }
    }

    private func contentKey(_ contentID: String) -> WebInspectorTab.ContentKey {
        WebInspectorTab.ContentKey(tabID: tabID, contentID: contentID)
    }
}
#endif
