#if canImport(UIKit)
import UIKit

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
#endif
