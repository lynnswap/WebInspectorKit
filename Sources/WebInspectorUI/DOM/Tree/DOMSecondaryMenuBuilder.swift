import WebInspectorEngine

#if canImport(UIKit)
import UIKit

@MainActor
enum DOMSecondaryMenuBuilder {
    static func makeMenu(
        hasSelection: Bool,
        hasPageWebView: Bool,
        onCopyHTML: @escaping () -> Void,
        onCopySelectorPath: @escaping () -> Void,
        onCopyXPath: @escaping () -> Void,
        onReloadInspector: @escaping () -> Void,
        onReloadPage: @escaping () -> Void,
        onDeleteNode: @escaping () -> Void
    ) -> UIMenu {
        let copyMenu = UIMenu(
            title: wiLocalized("Copy"),
            image: UIImage(systemName: "document.on.document"),
            children: [
                UIAction(title: "HTML", attributes: hasSelection ? [] : [.disabled]) { _ in
                    onCopyHTML()
                },
                UIAction(title: wiLocalized("dom.element.copy.selector_path"), attributes: hasSelection ? [] : [.disabled]) { _ in
                    onCopySelectorPath()
                },
                UIAction(title: "XPath", attributes: hasSelection ? [] : [.disabled]) { _ in
                    onCopyXPath()
                }
            ]
        )

        let reloadMenu = UIMenu(
            title: wiLocalized("reload"),
            image: UIImage(systemName: "arrow.clockwise"),
            children: [
                UIAction(title: wiLocalized("reload.target.inspector"), attributes: hasPageWebView ? [] : [.disabled]) { _ in
                    onReloadInspector()
                },
                UIAction(title: wiLocalized("reload.target.page"), attributes: hasPageWebView ? [] : [.disabled]) { _ in
                    onReloadPage()
                }
            ]
        )

        let deleteAction = UIAction(
            title: wiLocalized("inspector.delete_node"),
            image: UIImage(systemName: "trash"),
            attributes: hasSelection ? [.destructive] : [.destructive, .disabled]
        ) { _ in
            onDeleteNode()
        }

        let destructiveSection = UIMenu(options: .displayInline, children: [deleteAction])
        return UIMenu(children: [copyMenu, reloadMenu, destructiveSection])
    }
}
#endif
