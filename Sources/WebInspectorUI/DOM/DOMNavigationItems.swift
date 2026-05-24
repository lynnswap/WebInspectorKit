#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorRuntime

@MainActor
package final class DOMNavigationItems: NSObject {
    private typealias UndoManagerProvider = @MainActor () -> UndoManager?

    private let session: InspectorSession
    private let observationScope = ObservationScope()
    private var undoManagerProvider: UndoManagerProvider = { nil }

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
            completion(makeOverflowMenu(undoManagerProvider: undoManagerProvider).children)
        }
    }

    private func makeOverflowMenu(undoManagerProvider: @escaping UndoManagerProvider) -> UIMenu {
        UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                makeUndoAction(undoManagerProvider: undoManagerProvider),
                makeRedoAction(undoManagerProvider: undoManagerProvider),
            ]),
            UIMenu(options: .displayInline, children: [
                makeReloadAction(),
            ]),
            UIMenu(options: .displayInline, children: [
                makeDeleteAction(undoManagerProvider: undoManagerProvider),
            ]),
        ])
    }

    private func makeUndoAction(undoManagerProvider: @escaping UndoManagerProvider) -> UIAction {
        let undoManager = undoManagerProvider()
        return UIAction(
            title: webInspectorLocalized("undo", default: "Undo"),
            image: UIImage(systemName: "arrow.uturn.backward"),
            attributes: undoManager?.canUndo == true ? [] : [.disabled]
        ) { _ in
            Task { @MainActor in
                guard let undoManager = undoManagerProvider(), undoManager.canUndo else {
                    return
                }
                undoManager.undo()
            }
        }
    }

    private func makeRedoAction(undoManagerProvider: @escaping UndoManagerProvider) -> UIAction {
        let undoManager = undoManagerProvider()
        return UIAction(
            title: webInspectorLocalized("redo", default: "Redo"),
            image: UIImage(systemName: "arrow.uturn.forward"),
            attributes: undoManager?.canRedo == true ? [] : [.disabled]
        ) { _ in
            Task { @MainActor in
                guard let undoManager = undoManagerProvider(), undoManager.canRedo else {
                    return
                }
                undoManager.redo()
            }
        }
    }

    private func makeReloadAction() -> UIAction {
        UIAction(
            title: webInspectorLocalized("reload", default: "Reload"),
            image: UIImage(systemName: "arrow.clockwise"),
            attributes: (session.hasInspectablePageWebView || session.canReloadDOMDocument) ? [] : [.disabled]
        ) { [weak session] _ in
            Task { @MainActor in
                guard let session else {
                    return
                }
                if session.hasInspectablePageWebView {
                    try? await session.reloadPage()
                } else {
                    try? await session.reloadDOMDocument()
                }
            }
        }
    }

    private func makeDeleteAction(undoManagerProvider: @escaping UndoManagerProvider) -> UIAction {
        UIAction(
            title: webInspectorLocalized("inspector.delete_node", default: "Delete Node"),
            image: UIImage(systemName: "trash"),
            attributes: session.canDeleteSelectedDOMNode ? [.destructive] : [.disabled, .destructive]
        ) { [weak session] _ in
            Task { @MainActor in
                try? await session?.deleteSelectedDOMNode(undoManager: undoManagerProvider())
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
        makeOverflowMenu(undoManagerProvider: { undoManager })
    }
}
#endif
#endif
