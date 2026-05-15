#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorCore
import WebInspectorRuntime

@MainActor
package final class DOMNavigationItems: NSObject {
    private let session: InspectorSession
    private let observationScope = ObservationScope()
    private var undoManagerProvider: (@MainActor () -> UndoManager?)?

    private lazy var pickItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "scope"),
            style: .plain,
            target: self,
            action: #selector(toggleElementPicker)
        )
        item.accessibilityIdentifier = "WebInspector.DOM.PickButton"
        return item
    }()

    package init(session: InspectorSession) {
        self.session = session
        super.init()
        startObservingSession()
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    package func install(
        on navigationItem: UINavigationItem,
        undoManager: @escaping @MainActor () -> UndoManager?
    ) {
        undoManagerProvider = undoManager
        updatePickItemAppearance()
        navigationItem.trailingItemGroups = [
            UIBarButtonItemGroup(
                barButtonItems: [pickItem],
                representativeItem: nil
            ),
        ]
        navigationItem.additionalOverflowItems = makeDeferredOverflowItems()
    }

    private func startObservingSession() {
        session.observe([\.isAttached, \.isSelectingElement]) { [weak self] in
            self?.updatePickItemAppearance()
        }
        .store(in: observationScope)
        session.dom.observe([\.treeRevision, \.selectionRevision]) { [weak self] in
            self?.updatePickItemAppearance()
        }
        .store(in: observationScope)
    }

    private func makeDeferredOverflowItems() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else {
                completion([])
                return
            }
            completion(makeOverflowMenu(undoManager: undoManagerProvider?()).children)
        }
    }

    private func makeOverflowMenu(undoManager: UndoManager?) -> UIMenu {
        UIMenu(children: [
            makeCopyMenu(),
            makeReloadMenu(),
            makeDeleteAction(undoManager: undoManager),
        ])
    }

    private func makeCopyMenu() -> UIMenu {
        UIMenu(
            title: webInspectorLocalized("Copy", default: "Copy"),
            image: UIImage(systemName: "document.on.document"),
            children: [
                copyAction(title: "HTML", kind: .html),
                copyAction(
                    title: webInspectorLocalized("dom.element.copy.selector_path", default: "Selector Path"),
                    kind: .selectorPath
                ),
                copyAction(title: "XPath", kind: .xPath),
            ]
        )
    }

    private func makeReloadMenu() -> UIMenu {
        UIMenu(
            title: webInspectorLocalized("reload", default: "Reload"),
            image: UIImage(systemName: "arrow.clockwise"),
            children: [
                UIAction(
                    title: webInspectorLocalized("reload.target.inspector", default: "Reload Inspector"),
                    image: UIImage(systemName: "arrow.clockwise"),
                    attributes: session.canReloadDOMDocument ? [] : [.disabled]
                ) { [weak session] _ in
                    Task { @MainActor in
                        try? await session?.reloadDOMDocument()
                    }
                },
                UIAction(
                    title: webInspectorLocalized("reload.target.page", default: "Reload Page"),
                    image: UIImage(systemName: "arrow.clockwise"),
                    attributes: session.hasInspectablePageWebView ? [] : [.disabled]
                ) { [weak session] _ in
                    Task { @MainActor in
                        try? await session?.reloadPage()
                    }
                },
            ]
        )
    }

    private func makeDeleteAction(undoManager: UndoManager?) -> UIAction {
        UIAction(
            title: webInspectorLocalized("inspector.delete_node", default: "Delete Node"),
            image: UIImage(systemName: "trash"),
            attributes: session.canDeleteSelectedDOMNode ? [.destructive] : [.disabled, .destructive]
        ) { [weak session] _ in
            Task { @MainActor in
                try? await session?.deleteSelectedDOMNode(undoManager: undoManager)
            }
        }
    }

    private func copyAction(title: String, kind: DOMNodeCopyTextKind) -> UIAction {
        UIAction(
            title: title,
            attributes: session.canCopySelectedDOMNodeText ? [] : [.disabled]
        ) { [weak session] _ in
            Task { @MainActor in
                guard let text = try? await session?.copySelectedDOMNodeText(kind),
                      text.isEmpty == false else {
                    return
                }
                UIPasteboard.general.string = text
            }
        }
    }

    @objc
    private func toggleElementPicker() {
        Task { @MainActor [weak session] in
            await session?.toggleElementPicker()
        }
    }

    private func updatePickItemAppearance() {
        pickItem.isEnabled = session.canSelectElement
        pickItem.tintColor = session.isSelectingElement ? .tintColor : .label
    }
}

#if DEBUG
extension DOMNavigationItems {
    package var pickItemForTesting: UIBarButtonItem {
        pickItem
    }

    package func overflowMenuForTesting(undoManager: UndoManager? = nil) -> UIMenu {
        makeOverflowMenu(undoManager: undoManager)
    }
}
#endif
#endif
