#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
@Suite(.serialized)
struct DOMContainerTests {
    @Test
    func elementViewControllerLoadsEmptyContent() {
        let dom = makeDOMSession()
        let viewController = DOMElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(viewController.view.backgroundColor == .clear)
        let contentUnavailableConfiguration = viewController.contentUnavailableConfiguration as? UIContentUnavailableConfiguration
        #expect(contentUnavailableConfiguration?.text == "Select an element")
        #expect(viewController.collectionViewForTesting.isHidden)
    }

    @Test
    func elementViewControllerRendersLoadedStyleSections() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = CSSSession()
        _ = try applyBodyStyles(to: css, in: dom)

        let viewController = DOMElementViewController(dom: dom, css: css)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderRows = await waitUntil {
            viewController.collectionViewForTesting.numberOfSections == 1
                && viewController.collectionViewForTesting.numberOfItems(inSection: 0) == 3
        }
        window.layoutIfNeeded()

        #expect(didRenderRows)
        #expect(viewController.contentUnavailableConfiguration == nil)
        #expect(viewController.collectionViewForTesting.isHidden == false)

        let headers = viewController.collectionViewForTesting
            .visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
            .compactMap(\.accessibilityLabel)
        let declarations = stylePropertyViews(in: viewController)
            .map(\.declarationTextForTesting)

        #expect(headers.contains { $0.contains("body") })
        #expect(declarations.contains("margin: 0"))
        #expect(declarations.contains("/* box-sizing: border-box; */"))
        #expect(declarations.contains("font-size: 12px"))
    }

    @Test
    func elementViewControllerKeepsVisibleRowsDuringSameNodeStyleRefresh() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = CSSSession()
        try applyBodyStyles(to: css, in: dom)

        let viewController = DOMElementViewController(dom: dom, css: css)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderRows = await waitUntil {
            viewController.collectionViewForTesting.numberOfSections == 1
                && viewController.collectionViewForTesting.numberOfItems(inSection: 0) == 3
        }
        window.layoutIfNeeded()

        #expect(didRenderRows)
        let cellIDsBeforeUpdate = visibleCellIDs(in: viewController)

        let identity = try dom.selectedCSSNodeStyleIdentity().get()
        let refreshToken = try #require(css.beginRefresh(identity: identity))
        window.layoutIfNeeded()
        #expect(viewController.collectionViewForTesting.isHidden == false)
        #expect(visibleCellIDs(in: viewController) == cellIDsBeforeUpdate)

        try applyBodyStyles(
            to: css,
            in: dom,
            token: refreshToken,
            marginValue: "4px",
            marginText: "margin: 4px;"
        )

        let didUpdateVisibleRow = await waitUntil {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 4px")
        }

        #expect(didUpdateVisibleRow)
        #expect(viewController.collectionViewForTesting.isHidden == false)
        #expect(visibleCellIDs(in: viewController) == cellIDsBeforeUpdate)
    }

    @Test
    func compactContainerWrapsDOMRootControllerWithoutChangingIdentity() {
        let dom = makeDOMSession()
        let treeViewController = DOMTreeViewController(dom: dom)
        let navigationController = DOMCompactNavigationController(rootViewController: treeViewController)

        #expect(navigationController.viewControllers == [treeViewController])
        #expect(navigationController.navigationBar.prefersLargeTitles == false)
        #expect(treeViewController.navigationItem.style == .browser)
    }

    @Test
    func compactContainerInstallsSessionNavigationActions() throws {
        let session = InspectorSession(dom: makeDOMSession())
        let treeViewController = DOMTreeViewController(session: session)
        let navigationController = DOMCompactNavigationController(
            rootViewController: treeViewController,
            session: session
        )

        let pickItem = try #require(treeViewController.navigationItem.trailingItemGroups.first?.barButtonItems.first)

        #expect(navigationController.viewControllers == [treeViewController])
        #expect(pickItem.accessibilityIdentifier == "WebInspector.DOM.PickButton")
        #expect(treeViewController.navigationItem.additionalOverflowItems != nil)
    }

    @Test
    func splitContainerInstallsTreeAndElementColumns() throws {
        let dom = makeDOMSession()
        let treeViewController = DOMTreeViewController(dom: dom)
        let elementViewController = DOMElementViewController(dom: dom)
        let splitViewController = DOMSplitViewController(
            treeViewController: treeViewController,
            elementViewController: elementViewController
        )

        splitViewController.loadViewIfNeeded()

        if #available(iOS 26.0, *) {
            let treeNavigationController = try #require(
                splitViewController.viewController(for: .secondary) as? UINavigationController
            )
            let elementNavigationController = try #require(
                splitViewController.viewController(for: .inspector) as? UINavigationController
            )
            #expect(treeNavigationController.viewControllers.first === treeViewController)
            #expect(elementNavigationController.viewControllers.first === elementViewController)
            #expect(splitViewController.preferredDisplayMode == .secondaryOnly)
        } else {
            let treeNavigationController = try #require(
                splitViewController.viewController(for: .primary) as? UINavigationController
            )
            let elementNavigationController = try #require(
                splitViewController.viewController(for: .secondary) as? UINavigationController
            )
            #expect(treeNavigationController.viewControllers.first === treeViewController)
            #expect(elementNavigationController.viewControllers.first === elementViewController)
            #expect(splitViewController.preferredDisplayMode == .oneBesideSecondary)
        }
    }

    @Test
    func splitContainerInstallsSessionNavigationActions() throws {
        let session = InspectorSession(dom: makeDOMSession())
        let splitViewController = DOMSplitViewController(session: session)

        splitViewController.loadViewIfNeeded()

        let pickItem = try #require(splitViewController.navigationItem.trailingItemGroups.first?.barButtonItems.first)
        #expect(pickItem.accessibilityIdentifier == "WebInspector.DOM.PickButton")
        #expect(splitViewController.navigationItem.additionalOverflowItems != nil)
    }

    @Test
    func overflowMenuUsesPageReloadAndDeleteOnlyWhenSessionIsDetached() throws {
        let dom = makeDOMSession()
        let session = InspectorSession(dom: dom)
        let navigationItems = DOMNavigationItems(session: session)

        let emptyMenu = navigationItems.overflowMenuForTesting()
        #expect(inlineSectionCount(in: emptyMenu) == 3)
        #expect(action(titled: "Undo", in: emptyMenu)?.attributes.contains(.disabled) == true)
        #expect(action(titled: "Redo", in: emptyMenu)?.attributes.contains(.disabled) == true)
        #expect(action(titled: "HTML", in: emptyMenu) == nil)
        #expect(action(titled: "Selector Path", in: emptyMenu) == nil)
        #expect(action(titled: "XPath", in: emptyMenu) == nil)
        #expect(action(titled: "Reload", in: emptyMenu)?.attributes.contains(.disabled) == true)
        #expect(action(titled: "Reload Inspector", in: emptyMenu) == nil)
        #expect(action(titled: "Reload Page", in: emptyMenu) == nil)

        let selectedNode = try #require(firstElement(named: "input", in: dom))
        dom.selectNode(selectedNode.id)

        let selectedMenu = navigationItems.overflowMenuForTesting()
        #expect(inlineSectionCount(in: selectedMenu) == 3)
        #expect(action(titled: "Undo", in: selectedMenu)?.attributes.contains(.disabled) == true)
        #expect(action(titled: "Redo", in: selectedMenu)?.attributes.contains(.disabled) == true)
        #expect(action(titled: "HTML", in: selectedMenu) == nil)
        #expect(action(titled: "Selector Path", in: selectedMenu) == nil)
        #expect(action(titled: "XPath", in: selectedMenu) == nil)
        #expect(action(titled: "Reload", in: selectedMenu)?.attributes.contains(.disabled) == true)
        #expect(action(titled: "Reload Inspector", in: selectedMenu) == nil)
        #expect(action(titled: "Reload Page", in: selectedMenu) == nil)
        #expect(destructiveAction(in: selectedMenu)?.attributes.contains(.disabled) == true)

        let undoManager = UndoManager()
        undoManager.registerUndo(withTarget: UndoTarget()) { _ in }
        let undoableMenu = navigationItems.overflowMenuForTesting(undoManager: undoManager)
        #expect(action(titled: "Undo", in: undoableMenu)?.attributes.contains(.disabled) == false)
        #expect(action(titled: "Redo", in: undoableMenu)?.attributes.contains(.disabled) == true)
    }

    private func makeDOMSession(capabilities: ProtocolTargetCapabilities = []) -> DOMSession {
        let targetID = ProtocolTargetIdentifier("page-main")
        let session = DOMSession()
        session.applyTargetCreated(
            ProtocolTargetRecord(
                id: targetID,
                kind: .page,
                frameID: DOMFrameIdentifier("main-frame"),
                capabilities: capabilities
            ),
            makeCurrentMainPage: true
        )
        _ = session.replaceDocumentRoot(documentNode(), targetID: targetID)
        return session
    }

    @discardableResult
    private func applyBodyStyles(
        to css: CSSSession,
        in dom: DOMSession,
        token: CSSStyleRefreshToken? = nil,
        marginValue: String = "0",
        marginText: String = "margin: 0;"
    ) throws -> CSSPropertyIdentifier {
        let identity = try dom.selectedCSSNodeStyleIdentity().get()
        let token = try #require(token ?? css.beginRefresh(identity: identity))
        let styleSheetID = CSSStyleSheetIdentifier("test-sheet")
        let styleID = CSSStyleIdentifier(styleSheetID: styleSheetID, ordinal: 0)
        css.applyRefresh(
            token: token,
            matched: CSSMatchedStylesPayload(
                matchedRules: [
                    CSSRuleMatchPayload(
                        rule: CSSRulePayload(
                            id: CSSRuleIdentifier(styleSheetID: styleSheetID, ordinal: 0),
                            selectorList: CSSSelectorList(
                                selectors: [CSSSelector(text: "body")],
                                text: "body"
                            ),
                            sourceURL: "styles.css",
                            sourceLine: 1,
                            origin: .author,
                            style: CSSStylePayload(
                                id: styleID,
                                cssProperties: [
                                    CSSPropertyPayload(
                                        name: "margin",
                                        value: marginValue,
                                        text: marginText,
                                        status: .active
                                    ),
                                    CSSPropertyPayload(
                                        name: "box-sizing",
                                        value: "border-box",
                                        text: "/* box-sizing: border-box; */",
                                        status: .disabled
                                    ),
                                    CSSPropertyPayload(
                                        name: "font-size",
                                        value: "12px",
                                        text: "font-size: 12px;",
                                        status: .inactive
                                    ),
                                ],
                                cssText: "\(marginText)\n/* box-sizing: border-box; */\nfont-size: 12px;"
                            )
                        ),
                        matchingSelectors: [0]
                    ),
                ]
            ),
            inline: CSSInlineStylesPayload(),
            computed: []
        )
        return CSSPropertyIdentifier(styleID: styleID, propertyIndex: 0)
    }

    private func firstElement(named localName: String, in dom: DOMSession) -> DOMNode? {
        guard let rootNode = dom.currentPageRootNode else {
            return nil
        }
        var stack = [rootNode]
        while let node = stack.popLast() {
            if node.localName == localName {
                return node
            }
            stack.append(contentsOf: dom.visibleDOMTreeChildren(of: node).reversed())
        }
        return nil
    }

    private func documentNode() -> DOMNodePayload {
        DOMNodePayload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNodePayload(
                    nodeID: .init(2),
                    nodeType: .element,
                    nodeName: "HTML",
                    localName: "html",
                    regularChildren: .loaded([
                        DOMNodePayload(
                            nodeID: .init(3),
                            nodeType: .element,
                            nodeName: "BODY",
                            localName: "body",
                            regularChildren: .loaded([
                                DOMNodePayload(
                                    nodeID: .init(4),
                                    nodeType: .element,
                                    nodeName: "INPUT",
                                    localName: "input"
                                ),
                            ])
                        ),
                    ])
                ),
            ])
        )
    }

    private func showInWindow(_ viewController: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    private func stylePropertyViews(in viewController: DOMElementViewController) -> [DOMElementStylePropertyView] {
        viewController.collectionViewForTesting.visibleCells
            .compactMap { ($0 as? DOMElementStylePropertyCollectionCell)?.propertyViewForTesting }
    }

    private func visibleCellIDs(in viewController: DOMElementViewController) -> [ObjectIdentifier] {
        viewController.collectionViewForTesting.visibleCells.map(ObjectIdentifier.init)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let interval: UInt64 = 10_000_000
        let attempts = Int(timeoutNanoseconds / interval)
        for _ in 0..<attempts {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: interval)
        }
        return condition()
    }

    private func action(titled title: String, in menu: UIMenu) -> UIAction? {
        for child in menu.children {
            if let action = child as? UIAction, action.title == title {
                return action
            }
            if let childMenu = child as? UIMenu,
               let action = action(titled: title, in: childMenu) {
                return action
            }
        }
        return nil
    }

    private func inlineSectionCount(in menu: UIMenu) -> Int {
        menu.children
            .compactMap { $0 as? UIMenu }
            .filter { $0.options.contains(.displayInline) }
            .count
    }

    private func destructiveAction(in menu: UIMenu) -> UIAction? {
        for child in menu.children {
            if let action = child as? UIAction,
               action.attributes.contains(.destructive) {
                return action
            }
            if let childMenu = child as? UIMenu,
               let action = destructiveAction(in: childMenu) {
                return action
            }
        }
        return nil
    }

}

private final class UndoTarget {}
#endif
