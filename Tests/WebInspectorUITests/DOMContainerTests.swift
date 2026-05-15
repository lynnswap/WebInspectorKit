#if canImport(UIKit)
import Testing
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct DOMContainerTests {
    @Test
    func elementPlaceholderTracksCoreSelection() async throws {
        let dom = makeDOMSession()
        let viewController = DOMElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(contentUnavailableText(in: viewController) == "Select an element")

        let selectedNode = try #require(firstElement(named: "input", in: dom))
        dom.selectNode(selectedNode.id)

        let didRenderSelection = await waitUntil {
            contentUnavailableText(in: viewController) == "Element details"
                && contentUnavailableSecondaryText(in: viewController) == "<input>"
        }
        #expect(didRenderSelection)

        dom.selectNode(nil)
        let didClearSelection = await waitUntil {
            contentUnavailableText(in: viewController) == "Select an element"
        }
        #expect(didClearSelection)
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
    func overflowMenuDisablesActionsWhenSessionIsDetached() throws {
        let dom = makeDOMSession()
        let session = InspectorSession(dom: dom)
        let navigationItems = DOMNavigationItems(session: session)

        let emptyMenu = navigationItems.overflowMenuForTesting()
        #expect(action(titled: "HTML", in: emptyMenu)?.attributes.contains(.disabled) == true)

        let selectedNode = try #require(firstElement(named: "input", in: dom))
        dom.selectNode(selectedNode.id)

        let selectedMenu = navigationItems.overflowMenuForTesting()
        #expect(action(titled: "HTML", in: selectedMenu)?.attributes.contains(.disabled) == true)
        #expect(destructiveAction(in: selectedMenu)?.attributes.contains(.disabled) == true)
    }

    private func makeDOMSession() -> DOMSession {
        let targetID = ProtocolTargetIdentifier("page-main")
        let session = DOMSession()
        session.applyTargetCreated(
            ProtocolTargetRecord(
                id: targetID,
                kind: .page,
                frameID: DOMFrameIdentifier("main-frame")
            ),
            makeCurrentMainPage: true
        )
        _ = session.replaceDocumentRoot(documentNode(), targetID: targetID)
        return session
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

    private func contentUnavailableText(in viewController: UIViewController) -> String? {
        (viewController.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?.text
    }

    private func contentUnavailableSecondaryText(in viewController: UIViewController) -> String? {
        (viewController.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?.secondaryText
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

    private func waitUntil(
        maxTicks: Int = 256,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<maxTicks {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }
}
#endif
