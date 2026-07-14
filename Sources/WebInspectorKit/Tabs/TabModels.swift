#if canImport(UIKit)
import UIKit
import WebInspectorUIBase

extension WebInspectorTab {
    package enum HostLayout: Hashable {
        case compact
        case regular
    }

    package enum DisplayItem: Hashable, Identifiable {
        package typealias ID = String

        case tab(WebInspectorTab.ID)
        case domElement(parent: WebInspectorTab.ID)

        package static let domElementID = domElementID(parent: .init(
            rawValue: "webinspector_dom"
        ))

        package static func domElementID(parent: WebInspectorTab.ID) -> ID {
            "\(parent.rawValue).element"
        }

        package var id: ID {
            switch self {
            case let .tab(tabID):
                tabID.rawValue
            case let .domElement(parent):
                Self.domElementID(parent: parent)
            }
        }

        package var sourceTabID: WebInspectorTab.ID {
            switch self {
            case let .tab(tabID), let .domElement(parent: tabID):
                tabID
            }
        }
    }

    package struct ContentKey: Hashable {
        package let tabID: WebInspectorTab.ID
        package let contentID: String

        package init(tabID: WebInspectorTab.ID, contentID: String) {
            self.tabID = tabID
            self.contentID = contentID
        }
    }

    package struct DisplayDescriptor {
        package let title: String
        package let image: UIImage?
    }

    package final class ContentCache {
        private var viewControllerByKey: [ContentKey: UIViewController] = [:]

        package func viewController<Content: UIViewController>(
            for key: ContentKey,
            make: () -> Content
        ) -> Content {
            if let cached = viewControllerByKey[key] {
                if let content = cached as? Content {
                    return content
                }
                cached.webInspectorDetachFromContainerForReuse()
            }

            let viewController = make()
            viewControllerByKey[key] = viewController
            return viewController
        }

        package func removeAll() {
            for viewController in viewControllerByKey.values {
                viewController.webInspectorDetachFromContainerForReuse()
            }
            viewControllerByKey.removeAll()
        }

        #if DEBUG
        package var countForTesting: Int { viewControllerByKey.count }
        #endif
    }

    package struct DisplayProjection {
        package init() {}

        package func displayItems(
            for hostLayout: HostLayout,
            tabs: [WebInspectorTab]
        ) -> [DisplayItem] {
            tabs.flatMap { $0.presentation.displayItems(hostLayout) }
        }

        package func resolvedSelection(
            for hostLayout: HostLayout,
            tabs: [WebInspectorTab],
            selectedItemID: DisplayItem.ID?
        ) -> DisplayItem? {
            let displayItems = displayItems(for: hostLayout, tabs: tabs)
            if let selectedItemID,
               let selected = displayItems.first(where: { $0.id == selectedItemID }) {
                return selected
            }

            if selectedItemID == DisplayItem.domElementID,
               let dom = displayItems.first(where: { $0 == .tab(.init(rawValue: "webinspector_dom")) }) {
                return dom
            }
            return displayItems.first
        }

        package func descriptor(
            for displayItem: DisplayItem,
            catalog: WebInspectorTabCatalog
        ) -> DisplayDescriptor? {
            catalog.tabByID[displayItem.sourceTabID]?.presentation.descriptor(
                displayItem
            )
        }
    }
}
#endif
