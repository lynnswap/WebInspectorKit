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
    func elementStylesListRendersLoadedSectionsAndProperties() async throws {
        let dom = makeDOMSession(capabilities: [.dom, .css])
        let selectedNode = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(selectedNode.id)
        let identity = try #require(dom.selectedCSSNodeStyleIdentity().successValue)
        let css = try loadedCSSSession(
            identity: identity,
            ruleProperties: [
                CSSProperty(name: "margin", value: "0", text: "margin: 0;", status: .active),
                CSSProperty(name: "box-sizing", value: "border-box", text: "box-sizing: border-box;"),
            ]
        )
        let viewController = DOMElementViewController(
            dom: dom,
            css: css,
            canRefreshStyles: { false },
            refreshStylesAction: nil,
            setCSSPropertyAction: { _, _ in }
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderStyles = await waitUntil {
            viewController.contentUnavailableConfiguration == nil
                && viewController.collectionViewForTesting.isHidden == false
                && visibleStyleSectionTitles(in: viewController.collectionViewForTesting).contains("body")
                && stylePropertyCell(named: "margin", in: viewController.collectionViewForTesting) != nil
                && stylePropertyCell(named: "box-sizing", in: viewController.collectionViewForTesting) != nil
        }

        #expect(didRenderStyles)
    }

    @Test
    func elementStylesListRendersPropertyToggleStates() async throws {
        let dom = makeDOMSession(capabilities: [.dom, .css])
        let selectedNode = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(selectedNode.id)
        let identity = try #require(dom.selectedCSSNodeStyleIdentity().successValue)
        let css = try loadedCSSSession(
            identity: identity,
            ruleProperties: [
                CSSProperty(name: "margin", value: "0", text: "margin: 0;", status: .active),
                CSSProperty(name: "color", value: "red", text: "color: red;", status: .inactive),
                CSSProperty(name: "display", value: "block", text: "/* display: block; */", status: .disabled),
                CSSProperty(name: "bad-value", value: "???", text: "bad-value: ???;", parsedOk: false),
            ],
            attributesProperties: [
                CSSProperty(name: "width", value: "100", text: "width: 100;"),
            ]
        )
        let viewController = DOMElementViewController(
            dom: dom,
            css: css,
            canRefreshStyles: { false },
            refreshStylesAction: nil,
            setCSSPropertyAction: { _, _ in }
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderStyles = await waitUntil {
            stylePropertyCell(named: "width", in: viewController.collectionViewForTesting) != nil
        }
        #expect(didRenderStyles)

        let marginCell = try #require(stylePropertyCell(named: "margin", in: viewController.collectionViewForTesting))
        #expect(marginCell.toggleButtonForTesting.isEnabled)
        #expect(marginCell.toggleButtonForTesting.accessibilityValue == "Enabled")

        let colorCell = try #require(stylePropertyCell(named: "color", in: viewController.collectionViewForTesting))
        #expect(colorCell.toggleButtonForTesting.isEnabled)
        #expect(colorCell.accessibilityValue?.contains("Overridden") == true)

        let displayCell = try #require(stylePropertyCell(named: "display", in: viewController.collectionViewForTesting))
        #expect(displayCell.toggleButtonForTesting.isEnabled)
        #expect(displayCell.toggleButtonForTesting.accessibilityValue == "Disabled")

        let invalidCell = try #require(stylePropertyCell(named: "bad-value", in: viewController.collectionViewForTesting))
        #expect(invalidCell.accessibilityValue?.contains("Invalid") == true)

        let widthCell = try #require(stylePropertyCell(named: "width", in: viewController.collectionViewForTesting))
        #expect(widthCell.toggleButtonForTesting.isEnabled == false)
        #expect(widthCell.accessibilityValue?.contains("Not editable") == true)
    }

    @Test
    func elementStylesToggleInvokesActionOnceWhilePending() async throws {
        let dom = makeDOMSession(capabilities: [.dom, .css])
        let selectedNode = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(selectedNode.id)
        let identity = try #require(dom.selectedCSSNodeStyleIdentity().successValue)
        let css = try loadedCSSSession(
            identity: identity,
            ruleProperties: [
                CSSProperty(name: "margin", value: "0", text: "margin: 0;", status: .active),
            ]
        )
        let probe = CSSStyleToggleProbe()
        let viewController = DOMElementViewController(
            dom: dom,
            css: css,
            canRefreshStyles: { false },
            refreshStylesAction: nil,
            setCSSPropertyAction: { propertyID, enabled in
                try await probe.action(propertyID: propertyID, enabled: enabled)
            }
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let marginCell = try await waitForStylePropertyCell(named: "margin", in: viewController.collectionViewForTesting)
        marginCell.performToggleForTesting()
        marginCell.performToggleForTesting()

        let didStartToggle = await waitUntil {
            probe.calls.count == 1
                && stylePropertyCell(named: "margin", in: viewController.collectionViewForTesting)?
                    .toggleButtonForTesting.isEnabled == false
        }
        #expect(didStartToggle)
        #expect(probe.calls.first?.enabled == false)

        probe.resume()
        let didFinishToggle = await waitUntil {
            stylePropertyCell(named: "margin", in: viewController.collectionViewForTesting)?
                .toggleButtonForTesting.isEnabled == true
        }
        #expect(didFinishToggle)
    }

    @Test
    func elementStylesNeedsRefreshTriggersRefreshOnceForUnchangedState() async throws {
        let dom = makeDOMSession(capabilities: [.dom, .css])
        let selectedNode = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(selectedNode.id)
        let identity = try #require(dom.selectedCSSNodeStyleIdentity().successValue)
        let css = try loadedCSSSession(
            identity: identity,
            ruleProperties: [
                CSSProperty(name: "margin", value: "0", text: "margin: 0;", status: .active),
            ]
        )
        var refreshCount = 0
        let viewController = DOMElementViewController(
            dom: dom,
            css: css,
            canRefreshStyles: { true },
            refreshStylesAction: {
                refreshCount += 1
            },
            setCSSPropertyAction: nil
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        css.markNeedsRefresh(targetID: identity.targetID)

        let didRefresh = await waitUntil {
            refreshCount == 1
        }
        #expect(didRefresh)

        for _ in 0..<8 {
            viewController.view.setNeedsLayout()
            viewController.view.layoutIfNeeded()
            await Task.yield()
        }
        #expect(refreshCount == 1)
    }

    @Test
    func elementStylesNoOpRefreshCanRetryOnNextRender() async throws {
        let dom = makeDOMSession(capabilities: [.dom, .css])
        let selectedNode = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(selectedNode.id)
        let css = CSSSession()
        var refreshCount = 0
        let viewController = DOMElementViewController(
            dom: dom,
            css: css,
            canRefreshStyles: { true },
            refreshStylesAction: {
                refreshCount += 1
            },
            setCSSPropertyAction: nil
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didTryInitialRefresh = await waitUntil {
            refreshCount == 1
        }
        #expect(didTryInitialRefresh)

        viewController.viewDidAppear(false)

        let didRetryRefresh = await waitUntil {
            refreshCount == 2
        }
        #expect(didRetryRefresh)
    }

    @Test
    func elementStylesReloadsSectionHeadersWhenRulesChange() async throws {
        let dom = makeDOMSession(capabilities: [.dom, .css])
        let selectedNode = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(selectedNode.id)
        let identity = try #require(dom.selectedCSSNodeStyleIdentity().successValue)
        let css = try loadedCSSSession(
            identity: identity,
            ruleProperties: [
                CSSProperty(name: "margin", value: "0", text: "margin: 0;", status: .active),
            ]
        )
        let viewController = DOMElementViewController(
            dom: dom,
            css: css,
            canRefreshStyles: { false },
            refreshStylesAction: nil,
            setCSSPropertyAction: nil
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderInitialHeader = await waitUntil {
            visibleStyleSectionTitles(in: viewController.collectionViewForTesting).contains("body")
        }
        #expect(didRenderInitialHeader)

        let token = try #require(css.beginRefresh(identity: identity))
        css.applyRefresh(
            token: token,
            matched: CSSMatchedStylesPayload(
                matchedRules: [
                    CSSRuleMatch(
                        rule: cssRule(selector: ".updated", properties: [
                            CSSProperty(name: "padding", value: "4px", text: "padding: 4px;", status: .active),
                        ]),
                        matchingSelectors: [0]
                    ),
                ]
            ),
            inline: .init(),
            computed: []
        )

        let didReloadHeader = await waitUntil {
            visibleStyleSectionTitles(in: viewController.collectionViewForTesting).contains(".updated")
        }
        #expect(didReloadHeader)
    }

    @Test
    func elementStylesFailedStateUsesUnavailableConfiguration() async throws {
        let dom = makeDOMSession(capabilities: [.dom, .css])
        let selectedNode = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(selectedNode.id)
        let identity = try #require(dom.selectedCSSNodeStyleIdentity().successValue)
        let css = CSSSession()
        let token = try #require(css.beginRefresh(identity: identity))
        css.markRefreshFailed(token, message: "CSS failed")
        let viewController = DOMElementViewController(
            dom: dom,
            css: css,
            canRefreshStyles: { false },
            refreshStylesAction: nil,
            setCSSPropertyAction: nil
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(contentUnavailableText(in: viewController) == "Couldn’t load styles")
        #expect(contentUnavailableSecondaryText(in: viewController) == "CSS failed")
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

    private func loadedCSSSession(
        identity: CSSNodeStyleIdentity,
        ruleProperties: [CSSProperty],
        attributesProperties: [CSSProperty] = []
    ) throws -> CSSSession {
        let css = CSSSession()
        let token = try #require(css.beginRefresh(identity: identity))
        css.applyRefresh(
            token: token,
            matched: CSSMatchedStylesPayload(
                matchedRules: [
                    CSSRuleMatch(
                        rule: cssRule(selector: "body", properties: ruleProperties),
                        matchingSelectors: [0]
                    ),
                ]
            ),
            inline: CSSInlineStylesPayload(
                attributesStyle: attributesProperties.isEmpty
                    ? nil
                    : CSSStyle(cssProperties: attributesProperties)
            ),
            computed: []
        )
        return css
    }

    private func cssRule(selector: String, properties: [CSSProperty]) -> CSSRule {
        let styleID = CSSStyleIdentifier(styleSheetID: .init("sheet"), ordinal: 0)
        return CSSRule(
            id: CSSRuleIdentifier(styleSheetID: styleID.styleSheetID, ordinal: styleID.ordinal),
            selectorList: CSSSelectorList(selectors: [CSSSelector(text: selector)], text: selector),
            sourceURL: "common.css",
            sourceLine: 1,
            origin: .author,
            style: CSSStyle(id: styleID, cssProperties: properties)
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

    private func visibleStyleSectionTitles(in collectionView: UICollectionView) -> [String] {
        collectionView.layoutIfNeeded()
        return collectionView
            .visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader)
            .compactMap(\.accessibilityLabel)
    }

    private func stylePropertyCell(
        named name: String,
        in collectionView: UICollectionView
    ) -> DOMElementStylePropertyCell? {
        collectionView.layoutIfNeeded()
        return collectionView.visibleCells
            .compactMap { $0 as? DOMElementStylePropertyCell }
            .first { $0.propertyNameForTesting == name }
    }

    private func waitForStylePropertyCell(
        named name: String,
        in collectionView: UICollectionView
    ) async throws -> DOMElementStylePropertyCell {
        var foundCell: DOMElementStylePropertyCell?
        let didFindCell = await waitUntil {
            foundCell = stylePropertyCell(named: name, in: collectionView)
            return foundCell != nil
        }
        #expect(didFindCell)
        return try #require(foundCell)
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

private final class UndoTarget {}

@MainActor
private final class CSSStyleToggleProbe {
    private(set) var calls: [(propertyID: CSSPropertyIdentifier, enabled: Bool)] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func action(propertyID: CSSPropertyIdentifier, enabled: Bool) async throws {
        calls.append((propertyID, enabled))
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private extension Result {
    var successValue: Success? {
        if case let .success(value) = self {
            return value
        }
        return nil
    }
}
#endif
