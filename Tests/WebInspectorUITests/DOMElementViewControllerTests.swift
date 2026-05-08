#if canImport(UIKit)
import SyntaxEditorUI
import Testing
import UIKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct DOMElementViewControllerTests {
    @Test
    func elementViewShowsEmptyStateWithoutSelection() async {
        let runtime = WIDOMRuntime()
        let (viewController, window) = makeHostedElementViewController(runtime: runtime)
        defer { tearDown(window: window) }

        let emptyStateReady = await waitUntil {
            viewController.isShowingEmptyStateForTesting
        }
        #expect(emptyStateReady)
        #expect(viewController.collectionView.numberOfSections == 0)
    }

    @Test
    func elementViewRendersSelectedNodeSections() async throws {
        let runtime = WIDOMRuntime()
        seedSelectedNode(
            into: runtime,
            selectorPath: "#selected",
            attributes: [
                DOMAttribute(name: "id", value: "selected"),
                DOMAttribute(name: "class", value: "hero"),
            ]
        )
        let (viewController, window) = makeHostedElementViewController(runtime: runtime)
        defer { tearDown(window: window) }

        let initialReady = await waitUntil {
            viewController.collectionView.numberOfSections == 3
                && viewController.collectionView.numberOfItems(inSection: 0) == 1
                && viewController.collectionView.numberOfItems(inSection: 1) == 1
                && viewController.collectionView.numberOfItems(inSection: 2) == 2
                && visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) == "#selected"
        }
        #expect(initialReady)
        #expect(viewController.isShowingEmptyStateForTesting == false)
        #expect(viewController.collectionView.numberOfSections == 3)
        #expect(viewController.collectionView.numberOfItems(inSection: 0) == 1)
        #expect(viewController.collectionView.numberOfItems(inSection: 1) == 1)
        #expect(viewController.collectionView.numberOfItems(inSection: 2) == 2)
        #expect(
            visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 0))
                == "<div id=\"selected\" class=\"hero\">"
        )
        let previewEditorView = visibleSyntaxEditorView(
            in: viewController.collectionView,
            at: IndexPath(item: 0, section: 0)
        )
        #expect(previewEditorView != nil)
        #expect(previewEditorView?.isSelectable == true)
        #expect(previewEditorView?.isEditable == false)
        #expect(previewEditorView?.isScrollEnabled == false)
        #expect(hasCenteredTextContainerInsets(previewEditorView))
        #expect(visibleCellHeight(in: viewController.collectionView, at: IndexPath(item: 0, section: 0)) ?? 0 >= 44)
        #expect(visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) == "#selected")
        let selectorTextView = visibleTextView(in: viewController.collectionView, at: IndexPath(item: 0, section: 1))
        #expect(hasCenteredTextContainerInsets(selectorTextView))
        #expect(visibleCellHeight(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) ?? 0 >= 44)
        #expect(visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 2)) == "id")
        let attributeTextViews = visibleTextViews(in: viewController.collectionView, at: IndexPath(item: 0, section: 2))
        #expect(attributeTextViews.map(\.text) == ["id", "selected"])
        let attributeTextsAreSelectable = attributeTextViews.allSatisfy { $0.isSelectable }
        let attributeTextsAreReadOnly = attributeTextViews.allSatisfy { $0.isEditable == false }
        #expect(attributeTextsAreSelectable)
        #expect(attributeTextsAreReadOnly)
        #expect(visibleCellHeight(in: viewController.collectionView, at: IndexPath(item: 0, section: 2)) ?? 0 >= 44)
    }

    @Test
    func elementViewExpandsPreviewCellForLongText() async throws {
        let runtime = WIDOMRuntime()
        let longAttributeValue = String(repeating: "/xjs", count: 80)
        let expectedPreview = "<div src=\"\(longAttributeValue)\">"
        seedSelectedNode(
            into: runtime,
            selectorPath: "#selected",
            attributes: [
                DOMAttribute(name: "src", value: longAttributeValue),
            ]
        )
        let (viewController, window) = makeHostedElementViewController(runtime: runtime)
        defer { tearDown(window: window) }

        let previewExpanded = await waitUntil {
            let indexPath = IndexPath(item: 0, section: 0)
            guard visibleListCellText(in: viewController.collectionView, at: indexPath) == expectedPreview,
                  let cell = viewController.collectionView.cellForItem(at: indexPath),
                  let editorView = visibleSyntaxEditorView(in: cell.contentView) else {
                return false
            }
            let lineHeight = editorView.font.lineHeight
            return cell.bounds.height > lineHeight * 2
        }
        #expect(previewExpanded)
    }

    @Test
    func elementViewReconfiguresAttributeValueChanges() async throws {
        let runtime = WIDOMRuntime()
        seedSelectedNode(
            into: runtime,
            selectorPath: "#selected",
            attributes: [
                DOMAttribute(name: "id", value: "selected"),
            ]
        )
        let (viewController, window) = makeHostedElementViewController(runtime: runtime)
        defer { tearDown(window: window) }

        let initialReady = await waitUntil {
            visibleListCellSecondaryText(in: viewController.collectionView, at: IndexPath(item: 0, section: 2))
                == "selected"
        }
        #expect(initialReady)

        runtime.document.selectedNode?.attributes = [
            DOMAttribute(name: "id", value: "updated"),
        ]

        let valueUpdated = await waitUntil {
            visibleListCellSecondaryText(in: viewController.collectionView, at: IndexPath(item: 0, section: 2))
                == "updated"
        }
        #expect(valueUpdated)

        #expect(viewController.collectionView.numberOfSections == 3)
        #expect(viewController.collectionView.numberOfItems(inSection: 2) == 1)
        #expect(
            visibleListCellSecondaryText(in: viewController.collectionView, at: IndexPath(item: 0, section: 2))
                == "updated"
        )
    }

    @Test
    func elementViewUpdatesSelectorTextChanges() async throws {
        let runtime = WIDOMRuntime()
        seedSelectedNode(
            into: runtime,
            selectorPath: "#before",
            attributes: [
                DOMAttribute(name: "id", value: "selected"),
            ]
        )
        let (viewController, window) = makeHostedElementViewController(runtime: runtime)
        defer { tearDown(window: window) }

        let initialReady = await waitUntil {
            visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) == "#before"
        }
        #expect(initialReady)
        let selectorTextView = visibleTextView(in: viewController.collectionView, at: IndexPath(item: 0, section: 1))
        #expect(selectorTextView?.isSelectable == true)
        #expect(selectorTextView?.isEditable == false)

        runtime.document.selectedNode?.selectorPath = "#after"

        let selectorUpdated = await waitUntil {
            visibleListCellText(in: viewController.collectionView, at: IndexPath(item: 0, section: 1)) == "#after"
        }
        #expect(selectorUpdated)
    }

    private func seedSelectedNode(
        into runtime: WIDOMRuntime,
        selectorPath: String,
        attributes: [DOMAttribute]
    ) {
        runtime.document.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [makeNode(localID: 42, attributes: attributes)]
                )
            )
        )
        runtime.document.applySelectionSnapshot(
            .init(
                localID: 42,
                attributes: attributes,
                path: ["html", "body", "div"],
                selectorPath: selectorPath,
                styleRevision: 0
            )
        )
    }

    private func makeNode(
        localID: UInt64,
        attributes: [DOMAttribute] = [],
        children: [DOMGraphNodeDescriptor] = []
    ) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            localID: localID,
            backendNodeID: Int(localID),
            nodeType: 1,
            nodeName: "DIV",
            localName: "div",
            nodeValue: "",
            attributes: attributes,
            childCount: children.count,
            layoutFlags: [],
            isRendered: true,
            children: children
        )
    }

    private func makeHostedElementViewController(
        runtime: WIDOMRuntime
    ) -> (DOMElementViewController, UIWindow) {
        let viewController = DOMElementViewController(dom: runtime)
        let navigationController = UINavigationController(rootViewController: viewController)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        viewController.view.frame = window.bounds
        viewController.view.layoutIfNeeded()
        viewController.collectionView.layoutIfNeeded()
        return (viewController, window)
    }

    private func tearDown(window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func visibleListCellText(in collectionView: UICollectionView, at indexPath: IndexPath) -> String? {
        collectionView.layoutIfNeeded()
        guard collectionView.numberOfSections > indexPath.section,
              collectionView.numberOfItems(inSection: indexPath.section) > indexPath.item else {
            return nil
        }
        guard let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
              let configuration = cell.contentConfiguration as? UIListContentConfiguration else {
            return visibleDisplayText(in: collectionView.cellForItem(at: indexPath)?.contentView)
        }
        return configuration.text
    }

    private func visibleSyntaxEditorView(
        in collectionView: UICollectionView,
        at indexPath: IndexPath
    ) -> SyntaxEditorView? {
        collectionView.layoutIfNeeded()
        guard collectionView.numberOfSections > indexPath.section,
              collectionView.numberOfItems(inSection: indexPath.section) > indexPath.item else {
            return nil
        }
        return visibleSyntaxEditorView(in: collectionView.cellForItem(at: indexPath)?.contentView)
    }

    private func visibleSyntaxEditorView(in view: UIView?) -> SyntaxEditorView? {
        guard let view else {
            return nil
        }
        if let editorView = view as? SyntaxEditorView {
            return editorView
        }
        for subview in view.subviews {
            if let editorView = visibleSyntaxEditorView(in: subview) {
                return editorView
            }
        }
        return nil
    }

    private func visibleTextView(in collectionView: UICollectionView, at indexPath: IndexPath) -> UITextView? {
        visibleTextViews(in: collectionView, at: indexPath).first
    }

    private func visibleTextViews(in collectionView: UICollectionView, at indexPath: IndexPath) -> [UITextView] {
        collectionView.layoutIfNeeded()
        guard collectionView.numberOfSections > indexPath.section,
              collectionView.numberOfItems(inSection: indexPath.section) > indexPath.item else {
            return []
        }
        return visibleTextViews(in: collectionView.cellForItem(at: indexPath)?.contentView)
    }

    private func visibleTextView(in view: UIView?) -> UITextView? {
        visibleTextViews(in: view).first
    }

    private func visibleTextViews(in view: UIView?) -> [UITextView] {
        guard let view else {
            return []
        }
        if let textView = view as? UITextView {
            return [textView]
        }
        var textViews: [UITextView] = []
        for subview in view.subviews {
            textViews.append(contentsOf: visibleTextViews(in: subview))
        }
        return textViews
    }

    private func visibleDisplayText(in view: UIView?) -> String? {
        guard let view else {
            return nil
        }
        if let textView = view as? UITextView {
            return textView.text
        }
        if let editorView = view as? SyntaxEditorView {
            return editorView.text
        }
        for subview in view.subviews {
            if let text = visibleDisplayText(in: subview) {
                return text
            }
        }
        return nil
    }

    private func visibleCellHeight(in collectionView: UICollectionView, at indexPath: IndexPath) -> CGFloat? {
        collectionView.layoutIfNeeded()
        guard collectionView.numberOfSections > indexPath.section,
              collectionView.numberOfItems(inSection: indexPath.section) > indexPath.item else {
            return nil
        }
        return collectionView.cellForItem(at: indexPath)?.bounds.height
    }

    private func hasCenteredTextContainerInsets(_ textView: UITextView?) -> Bool {
        guard let textView else {
            return false
        }
        textView.layoutIfNeeded()
        return textView.textContainerInset.top > 0
            && abs(textView.textContainerInset.top - textView.textContainerInset.bottom) <= 1
    }

    private func hasCenteredTextContainerInsets(_ editorView: SyntaxEditorView?) -> Bool {
        guard let editorView else {
            return false
        }
        editorView.layoutIfNeeded()
        return editorView.textContainerInset.top > 0
            && abs(editorView.textContainerInset.top - editorView.textContainerInset.bottom) <= 1
    }

    private func visibleListCellSecondaryText(in collectionView: UICollectionView, at indexPath: IndexPath) -> String? {
        collectionView.layoutIfNeeded()
        guard collectionView.numberOfSections > indexPath.section,
              collectionView.numberOfItems(inSection: indexPath.section) > indexPath.item else {
            return nil
        }
        guard let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
              let configuration = cell.contentConfiguration as? UIListContentConfiguration else {
            return visibleTextViews(in: collectionView.cellForItem(at: indexPath)?.contentView).dropFirst().first?.text
        }
        return configuration.secondaryText
    }

    private func waitUntil(maxTicks: Int = 1024, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }
}
#endif
