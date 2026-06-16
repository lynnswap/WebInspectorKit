#if canImport(UIKit)
import ObservationBridge
import Testing
import WebInspectorTransport
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorUI

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct DOMContainerTests {
    @Test
    func elementViewControllerShowsUnavailableStateWithoutSelectedStyles() {
        let dom = makeDOMSession()
        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(viewController.view.backgroundColor == .systemBackground)
        #expect(viewController.contentUnavailableConfiguration != nil)
        let configuration = viewController.contentUnavailableConfiguration as? UIContentUnavailableConfiguration
        #expect(configuration?.text?.isEmpty == false)
        #expect(configuration?.textProperties.color == .secondaryLabel)
        #expect(viewController.collectionView.isHidden == false)
        #expect(viewController.collectionView.numberOfSections == 0)
    }

    @Test
    func elementViewControllerCanDisableBackgroundDrawing() {
        guard #available(iOS 26.0, *) else {
            return
        }

        let dom = makeDOMSession()
        let viewController = makeElementViewController(dom: dom)
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()

        #expect(viewController.view.backgroundColor == .clear)
        #expect(viewController.collectionView.backgroundColor == .clear)
    }

    @Test
    func elementViewControllerKeepsUnavailableStateWhenDocumentRootArrivesWithoutSelection() async throws {
        let targetID = ProtocolTarget.ID("page-main")
        let dom = DOMSession()
        dom.applyTargetCreated(
            ProtocolTarget.Record(
                id: targetID,
                kind: .page,
                frameID: DOMFrame.ID("main-frame"),
                capabilities: .pageDefault
            ),
            makeCurrentMainPage: true
        )
        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(viewController.contentUnavailableConfiguration != nil)
        #expect(viewController.collectionView.isHidden == false)
        #expect(viewController.collectionView.numberOfSections == 0)

        _ = dom.replaceDocumentRoot(documentNode(), targetID: targetID)

        let didKeepUnavailableState = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 0
        }
        #expect(didKeepUnavailableState)
    }

    @Test
    func elementViewControllerRendersLoadedStyleSections() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyBodyStyles(to: css, in: dom)

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderRows = await waitUntilRendered(in: viewController) {
            viewController.collectionView.numberOfSections == 1
                && viewController.collectionView.numberOfItems(inSection: 0) == 3
        }
        window.layoutIfNeeded()

        #expect(didRenderRows)
        #expect(viewController.contentUnavailableConfiguration == nil)
        #expect(viewController.collectionView.isHidden == false)

        let propertyViews = stylePropertyViews(in: viewController)
        let declarations = propertyViews.map(\.declarationTextForTesting)

        #expect(declarations.contains("margin: 0;"))
        #expect(declarations.contains("/* box-sizing: border-box; */"))
        #expect(declarations.contains("font-size: 12px;"))
        #expect(propertyView(named: "margin", in: propertyViews)?.isToggleOnForTesting == true)
        #expect(propertyView(named: "box-sizing", in: propertyViews)?.isToggleOnForTesting == false)
        #expect(propertyView(named: "font-size", in: propertyViews)?.isToggleEnabledForTesting == false)
        #expect(propertyView(named: "margin", in: propertyViews)?.declarationFontForTesting?.pointSize == UIFont.preferredFont(forTextStyle: .body).pointSize)
    }

    @Test
    func elementStyleSectionHeaderTextFormatsRuleOriginText() {
        let stylesheetLocation = CSSRule.SourceLocation(
            sourceURL: "https://styles.example/assets/result-card.css",
            line: 27,
            column: 22164
        )
        #expect(DOMElementStyleSectionHeaderText.displayText(for: stylesheetLocation) == "result-card.css:28:22165")
        #expect(DOMElementStyleSectionHeaderText.fullDisplayText(for: stylesheetLocation) == "https://styles.example/assets/result-card.css:28:22165")

        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: CSSRule.SourceLocation(sourceURL: "styles.css", line: 1)
        ) == "styles.css:2")
        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: CSSRule.SourceLocation(sourceURL: "styles.css", line: 0, column: 80)
        ) == "styles.css:1")
        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: CSSRule.SourceLocation(sourceURL: "styles.css", line: 0, column: 81)
        ) == "styles.css:1:82")
        #expect(DOMElementStyleSectionHeaderText.displayText(for: .userAgent)?.isEmpty == false)
    }

    @Test
    func elementViewControllerKeepsVisibleRowsDuringSameNodeStyleRefresh() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyBodyStyles(to: css, in: dom)

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderRows = await waitUntilRendered(in: viewController) {
            viewController.collectionView.numberOfSections == 1
                && viewController.collectionView.numberOfItems(inSection: 0) == 3
        }
        window.layoutIfNeeded()

        #expect(didRenderRows)
        let cellIDsBeforeUpdate = visibleCellIDs(in: viewController)

        let identity = try dom.selectedCSSNodeStyleIdentity().get()
        let refreshToken = try #require(css.beginRefresh(identity: identity))
        window.layoutIfNeeded()
        #expect(viewController.collectionView.isHidden == false)
        #expect(visibleCellIDs(in: viewController) == cellIDsBeforeUpdate)

        try applyBodyStyles(
            to: css,
            in: dom,
            token: refreshToken,
            marginValue: "4px",
            marginText: "margin: 4px;"
        )

        let didUpdateVisibleRow = await waitUntilRendered(in: viewController) {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 4px;")
        }

        #expect(didUpdateVisibleRow)
        #expect(viewController.collectionView.isHidden == false)
        #expect(visibleCellIDs(in: viewController) == cellIDsBeforeUpdate)
    }

    @Test
    func elementViewControllerUpdatesVisibleSectionHeaderDuringSameNodeStyleRefresh() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyBodyStyles(to: css, in: dom)

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderHeader = await waitUntilRendered(in: viewController) {
            styleSectionHeaderViews(in: viewController).first?.titleTextForTesting == "body"
                && styleSectionHeaderViews(in: viewController).first?.originTextForTesting == "styles.css:2"
        }
        window.layoutIfNeeded()

        #expect(didRenderHeader)
        let headerBeforeUpdate = try #require(styleSectionHeaderViews(in: viewController).first)
        let headerIDBeforeUpdate = ObjectIdentifier(headerBeforeUpdate)

        let identity = try dom.selectedCSSNodeStyleIdentity().get()
        let refreshToken = try #require(css.beginRefresh(identity: identity))
        try applyBodyStyles(
            to: css,
            in: dom,
            token: refreshToken,
            selector: ".content",
            sourceURL: "updated.css",
            sourceLine: 5
        )

        let didUpdateHeader = await waitUntilRendered(in: viewController) {
            guard let header = styleSectionHeaderViews(in: viewController).first else {
                return false
            }
            return ObjectIdentifier(header) == headerIDBeforeUpdate
                && header.titleTextForTesting == ".content"
                && header.originTextForTesting == "updated.css:6"
        }

        #expect(didUpdateHeader)
    }

    @Test
    func elementViewControllerKeepsCurrentRowsWhileNewSelectionStylesAreHydrating() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyBodyStyles(to: css, in: dom)

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderBodyRows = await waitUntilRendered(in: viewController) {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 0;")
        }
        window.layoutIfNeeded()
        #expect(didRenderBodyRows)

        let input = try #require(firstElement(named: "input", in: dom))
        let bodyIdentity = try dom.selectedCSSNodeStyleIdentity().get()
        dom.selectNode(input.id)
        let inputIdentity = try dom.selectedCSSNodeStyleIdentity().get()
        let inputRefreshToken = try #require(css.beginRefresh(identity: inputIdentity))
        window.layoutIfNeeded()

        #expect(bodyIdentity != inputIdentity)
        #expect(css.selectedNodeStyles?.identity == inputIdentity)
        #expect(css.selectedState == .loading)
        #expect(css.refreshState(forSelected: inputIdentity) == .loading)
        let didKeepBodyRowsWhileInputLoads = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration == nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 1
                && stylePropertyViews(in: viewController)
                    .map(\.declarationTextForTesting)
                    .contains("margin: 0;")
        }
        #expect(didKeepBodyRowsWhileInputLoads)

        try applyBodyStyles(
            to: css,
            in: dom,
            token: inputRefreshToken,
            selector: "input",
            marginValue: "8px",
            marginText: "margin: 8px;"
        )

        let didRenderInputRows = await waitUntilRendered(in: viewController) {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 8px;")
        }

        #expect(didRenderInputRows)
        #expect(viewController.collectionView.isHidden == false)
    }

    @Test
    func elementViewControllerShowsPlaceholderForInitialElementSelectionWhileStylesHydrate() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let css = dom.elementStyles
        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)
        let identity = try dom.selectedCSSNodeStyleIdentity().get()
        #expect(css.beginRefresh(identity: identity) != nil)

        let didRenderPlaceholder = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 0
        }

        #expect(didRenderPlaceholder)
    }

    @Test
    func elementViewControllerClearsRetainedRowsWhenSelectionClears() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyBodyStyles(to: css, in: dom)

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderBodyRows = await waitUntilRendered(in: viewController) {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 0;")
        }
        #expect(didRenderBodyRows)

        let input = try #require(firstElement(named: "input", in: dom))
        dom.selectNode(input.id)
        let inputIdentity = try dom.selectedCSSNodeStyleIdentity().get()
        #expect(css.beginRefresh(identity: inputIdentity) != nil)
        #expect(stylePropertyViews(in: viewController).map(\.declarationTextForTesting).contains("margin: 0;"))

        dom.selectNode(nil)

        let didClearRows = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 0
        }

        #expect(didClearRows)
    }

    @Test
    func elementViewControllerClearsDisplayedRowsWhenSelectedNodeIsRemoved() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyBodyStyles(to: css, in: dom)

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderBodyRows = await waitUntilRendered(in: viewController) {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 0;")
        }
        #expect(didRenderBodyRows)

        dom.applyNodeRemoved(body.id)

        let didClearRows = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 0
        }

        #expect(didClearRows)
    }

    @Test
    func elementViewControllerClearsDisplayedRowsWhenSelectedStylesBecomeUnavailable() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyBodyStyles(to: css, in: dom)

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderBodyRows = await waitUntilRendered(in: viewController) {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 0;")
        }
        #expect(didRenderBodyRows)

        let identity = try dom.selectedCSSNodeStyleIdentity().get()
        css.markSelectedNodeStylesUnavailable(identity: identity, reason: .staleNode(body.id))

        let didClearRows = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 0
        }

        #expect(didClearRows)
    }

    @Test
    func elementViewControllerCollapsesUnusedInheritedCSSVariablesAndAnimatesReveal() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyInheritedVariableStyles(to: css, in: dom)

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didCollapseUnusedVariables = await waitUntilRendered(in: viewController) {
            viewController.collectionView.numberOfSections == 2
                && viewController.collectionView.numberOfItems(inSection: 1) == 3
                && hiddenVariableCells(in: viewController).count == 1
        }
        window.layoutIfNeeded()

        #expect(didCollapseUnusedVariables)
        let collapsedDeclarations = stylePropertyViews(in: viewController).map(\.declarationTextForTesting)
        let revealCell = try #require(hiddenVariableCells(in: viewController).first)

        #expect(collapsedDeclarations.contains("color: var(--foreground);"))
        #expect(collapsedDeclarations.contains("--foreground: var(--palette-primary);"))
        #expect(collapsedDeclarations.contains("--palette-primary: #111;"))
        #expect(collapsedDeclarations.contains("--unused-a: red;") == false)
        #expect(collapsedDeclarations.contains("--unused-b: blue;") == false)

        revealCell.tapRevealForTesting()

        let didRevealUnusedVariables = await waitUntilRendered(in: viewController) {
            let declarations = stylePropertyViews(in: viewController).map(\.declarationTextForTesting)
            return viewController.collectionView.numberOfItems(inSection: 1) == 4
                && hiddenVariableCells(in: viewController).isEmpty
                && declarations.contains("--unused-a: red;")
                && declarations.contains("--unused-b: blue;")
        }

        #expect(didRevealUnusedVariables)
        #expect(viewController.lastSnapshotAnimatedForTesting)
    }

    @Test
    func elementViewControllerIgnoresVariableReferencesInsideCSSStringsAndComments() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyInheritedVariableStyles(
            to: css,
            in: dom,
            additionalBodyProperties: [
                CSSProperty.Payload(
                    name: "content",
                    value: #""var(--unused-a)""#,
                    text: #"content: "var(--unused-a)";"#,
                    status: .active
                ),
                CSSProperty.Payload(
                    name: "background",
                    value: "/* var(--unused-b) */ transparent",
                    text: "background: /* var(--unused-b) */ transparent;",
                    status: .active
                ),
            ]
        )

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didCollapseUnusedVariables = await waitUntilRendered(in: viewController) {
            hiddenVariableCells(in: viewController).count == 1
        }
        window.layoutIfNeeded()

        #expect(didCollapseUnusedVariables)
        let collapsedDeclarations = stylePropertyViews(in: viewController).map(\.declarationTextForTesting)
        #expect(collapsedDeclarations.contains("--unused-a: red;") == false)
        #expect(collapsedDeclarations.contains("--unused-b: blue;") == false)
    }

    @Test
    func elementViewControllerIgnoresVariableReferencesFromInactiveDeclarations() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyInheritedVariableStyles(
            to: css,
            in: dom,
            additionalBodyProperties: [
                CSSProperty.Payload(
                    name: "border-color",
                    value: "var(--unused-a)",
                    text: "border-color: var(--unused-a);",
                    status: .inactive
                ),
            ]
        )

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didCollapseUnusedVariables = await waitUntilRendered(in: viewController) {
            hiddenVariableCells(in: viewController).count == 1
        }
        window.layoutIfNeeded()

        #expect(didCollapseUnusedVariables)
        let collapsedDeclarations = stylePropertyViews(in: viewController).map(\.declarationTextForTesting)
        #expect(collapsedDeclarations.contains("--unused-a: red;") == false)
    }

    @Test
    func elementViewControllerTreatsCSSVariableFunctionNamesCaseInsensitively() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyInheritedVariableStyles(
            to: css,
            in: dom,
            bodyColorValue: "VAR(--foreground)",
            foregroundValue: "vAr(--palette-primary)"
        )

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didCollapseOnlyUnusedVariables = await waitUntilRendered(in: viewController) {
            hiddenVariableCells(in: viewController).count == 1
        }
        window.layoutIfNeeded()

        #expect(didCollapseOnlyUnusedVariables)
        let collapsedDeclarations = stylePropertyViews(in: viewController).map(\.declarationTextForTesting)
        #expect(collapsedDeclarations.contains("color: VAR(--foreground);"))
        #expect(collapsedDeclarations.contains("--foreground: vAr(--palette-primary);"))
        #expect(collapsedDeclarations.contains("--palette-primary: #111;"))
        #expect(collapsedDeclarations.contains("--unused-a: red;") == false)
        #expect(collapsedDeclarations.contains("--unused-b: blue;") == false)
    }

    @Test
    func elementViewControllerIgnoresVarTextInsideOtherFunctionNames() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyInheritedVariableStyles(
            to: css,
            in: dom,
            additionalBodyProperties: [
                CSSProperty.Payload(
                    name: "background",
                    value: "myvar(--unused-a)",
                    text: "background: myvar(--unused-a);",
                    status: .active
                ),
            ]
        )

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didCollapseUnusedVariables = await waitUntilRendered(in: viewController) {
            hiddenVariableCells(in: viewController).count == 1
        }
        window.layoutIfNeeded()

        #expect(didCollapseUnusedVariables)
        let collapsedDeclarations = stylePropertyViews(in: viewController).map(\.declarationTextForTesting)
        #expect(collapsedDeclarations.contains("--unused-a: red;") == false)
    }

    @Test
    func elementViewControllerIgnoresReferencesFromUnusedLocalCustomProperties() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyInheritedVariableStyles(
            to: css,
            in: dom,
            additionalBodyProperties: [
                CSSProperty.Payload(
                    name: "--local-unused",
                    value: "var(--unused-a)",
                    text: "--local-unused: var(--unused-a);",
                    status: .active
                ),
            ]
        )

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didCollapseUnusedVariables = await waitUntilRendered(in: viewController) {
            hiddenVariableCells(in: viewController).count == 1
        }
        window.layoutIfNeeded()

        #expect(didCollapseUnusedVariables)
        let collapsedDeclarations = stylePropertyViews(in: viewController).map(\.declarationTextForTesting)
        #expect(collapsedDeclarations.contains("--unused-a: red;") == false)
    }

    @Test
    func elementViewControllerFollowsReferencesFromUsedLocalCustomProperties() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyInheritedVariableStyles(
            to: css,
            in: dom,
            additionalBodyProperties: [
                CSSProperty.Payload(
                    name: "--local-used",
                    value: "var(--unused-a)",
                    text: "--local-used: var(--unused-a);",
                    status: .active
                ),
                CSSProperty.Payload(
                    name: "border-color",
                    value: "var(--local-used)",
                    text: "border-color: var(--local-used);",
                    status: .active
                ),
            ]
        )

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didCollapseOnlyUnusedVariable = await waitUntilRendered(in: viewController) {
            hiddenVariableCells(in: viewController).count == 1
        }
        window.layoutIfNeeded()

        #expect(didCollapseOnlyUnusedVariable)
        let collapsedDeclarations = stylePropertyViews(in: viewController).map(\.declarationTextForTesting)
        #expect(collapsedDeclarations.contains("--unused-a: red;"))
        #expect(collapsedDeclarations.contains("--unused-b: blue;") == false)
    }

    @Test
    func elementViewControllerUpdatesCollapsedUnusedVariableCountAfterStyleRefresh() async throws {
        let dom = makeDOMSession(capabilities: .pageDefault)
        let body = try #require(firstElement(named: "body", in: dom))
        dom.selectNode(body.id)

        let css = dom.elementStyles
        try applyInheritedVariableStyles(to: css, in: dom)

        let viewController = makeElementViewController(dom: dom)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didCollapseUnusedVariables = await waitUntilRendered(in: viewController) {
            hiddenVariableCells(in: viewController).count == 1
        }
        #expect(didCollapseUnusedVariables)

        try applyInheritedVariableStyles(
            to: css,
            in: dom,
            additionalRootProperties: [
                CSSProperty.Payload(
                    name: "--unused-c",
                    value: "green",
                    text: "--unused-c: green;",
                    status: .active
                ),
            ]
        )

        let didUpdateHiddenVariableCount = await waitUntilRendered(in: viewController) {
            hiddenVariableCells(in: viewController).count == 1
                && stylePropertyViews(in: viewController)
                    .map(\.declarationTextForTesting)
                    .contains("--unused-c: green;") == false
        }
        #expect(didUpdateHiddenVariableCount)

        let revealCell = try #require(hiddenVariableCells(in: viewController).first)
        revealCell.tapRevealForTesting()

        let didRevealUpdatedHiddenVariables = await waitUntilRendered(in: viewController) {
            let declarations = stylePropertyViews(in: viewController).map(\.declarationTextForTesting)
            return hiddenVariableCells(in: viewController).isEmpty
                && declarations.contains("--unused-a: red;")
                && declarations.contains("--unused-b: blue;")
                && declarations.contains("--unused-c: green;")
        }
        #expect(didRevealUpdatedHiddenVariables)
    }

    @Test
    func elementStylePropertyViewSendsToggleActionWithImmediateControlFeedback() {
        let propertyID = CSSProperty.ID(
            styleID: CSSStyle.ID(styleSheetID: CSSStyleSheet.ID("test-sheet"), ordinal: 0),
            propertyIndex: 0
        )
        let property = CSSProperty(
            id: propertyID,
            name: "margin",
            value: "0",
            text: "margin: 0;",
            status: .active,
            isEditable: true
        )
        let propertyView = DOMElementStylePropertyView()
        var requestedPropertyID: CSSProperty.ID?
        var requestedEnabled: Bool?
        propertyView.bind(property: property) { propertyID, enabled in
            requestedPropertyID = propertyID
            requestedEnabled = enabled
            return true
        }
        let window = showViewInWindow(propertyView)
        defer { window.isHidden = true }

        propertyView.tapToggleForTesting()

        #expect(requestedPropertyID == propertyID)
        #expect(requestedEnabled == false)
        #expect(propertyView.isToggleOnForTesting == false)

        propertyView.bind(property: property) { _, _ in
            false
        }
        propertyView.tapToggleForTesting()
        #expect(propertyView.isToggleOnForTesting == true)
    }

    @Test
    func elementStylePropertyViewIgnoresNonEditableAndAnonymousProperties() {
        let styleID = CSSStyle.ID(styleSheetID: CSSStyleSheet.ID("test-sheet"), ordinal: 0)
        let nonEditableID = CSSProperty.ID(styleID: styleID, propertyIndex: 0)
        let nonEditable = CSSProperty(
            id: nonEditableID,
            name: "margin",
            value: "0",
            text: "margin: 0;",
            status: .active,
            isEditable: false
        )
        let anonymous = CSSProperty(
            name: "padding",
            value: "0",
            text: "padding: 0;",
            status: .active,
            isEditable: true
        )
        let nonEditableView = DOMElementStylePropertyView()
        let anonymousView = DOMElementStylePropertyView()
        var requestCount = 0
        nonEditableView.bind(property: nonEditable) { _, _ in
            requestCount += 1
            return true
        }
        anonymousView.bind(property: anonymous) { _, _ in
            requestCount += 1
            return true
        }
        let stackView = UIStackView(arrangedSubviews: [nonEditableView, anonymousView])
        stackView.axis = .vertical
        let window = showViewInWindow(stackView)
        defer { window.isHidden = true }

        #expect(nonEditableView.isToggleEnabledForTesting == false)
        #expect(anonymousView.isToggleEnabledForTesting == false)
        nonEditableView.tapToggleForTesting()
        anonymousView.tapToggleForTesting()
        #expect(requestCount == 0)
    }

    @Test
    func elementStylePropertyViewNormalizesMultilinePropertyText() {
        let property = CSSProperty(
            name: "background",
            value: "red",
            text: "background:\n    red;",
            status: .active,
            isEditable: true
        )
        let propertyView = DOMElementStylePropertyView()
        propertyView.bind(property: property) { _, _ in
            true
        }
        let window = showViewInWindow(propertyView)
        defer { window.isHidden = true }

        #expect(propertyView.declarationTextForTesting == "background: red;")
        #expect(propertyView.declarationTextForTesting.contains("\n") == false)
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
        let session = AttachedInspection(dom: makeDOMSession())
        let inspector = InspectorSession(attachment: session)
        let treeViewController = DOMTreeViewController(inspection: session)
        let navigationController = DOMCompactNavigationController(
            rootViewController: treeViewController,
            inspector: inspector
        )

        let pickItem = try #require(treeViewController.navigationItem.trailingItemGroups.first?.barButtonItems.first)

        #expect(navigationController.viewControllers == [treeViewController])
        #expect(pickItem.accessibilityIdentifier == "WebInspector.DOM.PickButton")
        #expect(treeViewController.navigationItem.additionalOverflowItems != nil)
    }

    @Test
    func compactNavigationPickButtonEnablesWhenDOMCommandsBecomeActive() async throws {
        let targetID = ProtocolTarget.ID("page-main")
        let backend = RecordingTransportBackend()
        let transport = TransportSession(backend: backend, responseTimeout: nil)
        await transport.receiveRootMessage(pageTargetCreatedMessage(targetID: targetID))

        let attachmentGate = CommandAttachmentGate()
        let dom = makeDOMSessionWithoutDocument(targetID: targetID)
        dom.bindProtocolChannel(
            ProtocolCommandChannel(
                transport: transport,
                isCurrent: { true },
                isAttached: { attachmentGate.isAttached },
                appliedSequence: { 0 },
                shouldEnableCompatibilityCSS: { _ in false },
                markTargetDomainEnabled: { _, _ in }
            ),
            recordError: { _ in }
        )
        defer {
            dom.unbindProtocolChannel()
        }

        let session = AttachedInspection(dom: dom)
        let inspector = InspectorSession(attachment: session)
        let treeViewController = DOMTreeViewController(inspection: session)
        let navigationController = DOMCompactNavigationController(
            rootViewController: treeViewController,
            inspector: inspector
        )
        let navigationItems = try #require(navigationController.domNavigationItemsForTesting)
        let observation = try #require(navigationItems.observationDeliveryForTesting)
        let pickItem = navigationItems.pickItemForTesting
        let pickItemIdentity = ObjectIdentifier(pickItem)

        let renderedEnabledState = await observation.values {
            pickItem.isEnabled
        }
        #expect(await renderedEnabledState.waitUntilValue(false))

        attachmentGate.isAttached = true
        dom.recordCommandAvailabilityMutation()

        #expect(await renderedEnabledState.waitUntilValue(true))
        #expect(ObjectIdentifier(navigationItems.pickItemForTesting) == pickItemIdentity)
    }

    @Test
    func treeControllerRetriesDocumentLoadWhenDOMCommandsBecomeActive() async throws {
        let targetID = ProtocolTarget.ID("page-main")
        let backend = RecordingTransportBackend()
        let transport = TransportSession(backend: backend, responseTimeout: nil)
        await transport.receiveRootMessage(pageTargetCreatedMessage(targetID: targetID))

        let attachmentGate = CommandAttachmentGate()
        let dom = makeDOMSessionWithoutDocument(targetID: targetID)
        dom.bindProtocolChannel(
            ProtocolCommandChannel(
                transport: transport,
                isCurrent: { true },
                isAttached: { attachmentGate.isAttached },
                appliedSequence: { 0 },
                shouldEnableCompatibilityCSS: { _ in false },
                markTargetDomainEnabled: { _, _ in }
            ),
            recordError: { _ in }
        )
        defer {
            dom.unbindProtocolChannel()
        }

        let session = AttachedInspection(dom: dom)
        let treeViewController = DOMTreeViewController(inspection: session)
        let window = showInWindow(treeViewController)
        defer {
            window.isHidden = true
        }

        let observation = try #require(treeViewController.domRootObservationDeliveryForTesting)
        let renderedDocumentState = await observation.values {
            dom.currentPageRootNode != nil
        }
        let treeTextView = treeViewController.displayedDOMTreeTextViewForTesting
        let renderedTreeText = await treeTextView.documentObservationDeliveryForTesting.values {
            treeTextView.renderedTextForTesting
        }
        #expect(await renderedDocumentState.waitUntilValue(false))
        #expect(await backend.sentTargetMessages().isEmpty)

        attachmentGate.isAttached = true
        dom.recordCommandAvailabilityMutation()

        let documentRequest = try await waitForTargetMessage(backend, method: "DOM.getDocument")
        await receiveTargetReply(
            transport,
            targetID: documentRequest.targetIdentifier,
            messageID: try messageID(documentRequest.message),
            result: loadedDocumentResult
        )
        await dom.waitUntilDocumentRequestsIdle(targetID: documentRequest.targetIdentifier)

        #expect(await renderedDocumentState.waitUntilValue(true))
        #expect(await renderedTreeText.waitUntil { $0.contains("<html") } != nil)
        #expect(await backend.sentTargetMessages().count == 1)
    }

    @Test
    func testBackendTargetMessageWaiterTimesOutWhenMethodIsMissing() async throws {
        let backend = RecordingTransportBackend()

        await #expect(throws: TransportSession.Error.replyTimeout(method: "DOM.getDocument", targetID: nil)) {
            try await waitForTargetMessage(backend, method: "DOM.getDocument", timeout: .milliseconds(20))
        }
    }

    @Test
    func splitContainerInstallsTreeAndElementColumns() throws {
        let dom = makeDOMSession()
        let treeViewController = DOMTreeViewController(dom: dom)
        let elementViewController = makeElementViewController(dom: dom)
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
        let session = AttachedInspection(dom: makeDOMSession())
        let splitViewController = DOMSplitViewController(inspection: session)

        splitViewController.loadViewIfNeeded()

        let pickItem = try #require(splitViewController.navigationItem.trailingItemGroups.first?.barButtonItems.first)
        #expect(pickItem.accessibilityIdentifier == "WebInspector.DOM.PickButton")
        #expect(splitViewController.navigationItem.additionalOverflowItems != nil)
    }

    private struct BodyStyleIDs {
        var margin: CSSProperty.ID
        var boxSizing: CSSProperty.ID
        var fontSize: CSSProperty.ID
    }

    private func makeDOMSession(capabilities: ProtocolTarget.Capabilities = []) -> DOMSession {
        let targetID = ProtocolTarget.ID("page-main")
        let session = DOMSession()
        session.applyTargetCreated(
            ProtocolTarget.Record(
                id: targetID,
                kind: .page,
                frameID: DOMFrame.ID("main-frame"),
                capabilities: capabilities
            ),
            makeCurrentMainPage: true
        )
        _ = session.replaceDocumentRoot(documentNode(), targetID: targetID)
        return session
    }

    private func makeDOMSessionWithoutDocument(
        targetID: ProtocolTarget.ID,
        capabilities: ProtocolTarget.Capabilities = .pageDefault
    ) -> DOMSession {
        let session = DOMSession()
        session.applyTargetCreated(
            ProtocolTarget.Record(
                id: targetID,
                kind: .page,
                frameID: DOMFrame.ID("main-frame"),
                capabilities: capabilities
            ),
            makeCurrentMainPage: true
        )
        return session
    }

    private func makeElementViewController(dom: DOMSession) -> DOMElementViewController {
        let viewController = DOMElementViewController(inspection: AttachedInspection(dom: dom))
        viewController.disablesSnapshotAnimationsForTesting = true
        return viewController
    }

    @discardableResult
    private func applyBodyStyles(
        to css: CSSSession,
        in dom: DOMSession,
        token: CSSStyle.RefreshToken? = nil,
        selector: String = "body",
        sourceURL: String = "styles.css",
        sourceLine: Int = 1,
        marginValue: String = "0",
        marginText: String = "margin: 0;"
    ) throws -> BodyStyleIDs {
        let identity = try dom.selectedCSSNodeStyleIdentity().get()
        let token = try #require(token ?? css.beginRefresh(identity: identity))
        let styleSheetID = CSSStyleSheet.ID("test-sheet")
        let styleID = CSSStyle.ID(styleSheetID: styleSheetID, ordinal: 0)
        css.applyRefresh(
            token: token,
            matched: CSSStyle.MatchedStylesPayload(
                matchedRules: [
                    CSSRule.MatchPayload(
                        rule: CSSRule.Payload(
                            id: CSSRule.ID(styleSheetID: styleSheetID, ordinal: 0),
                            selectorList: CSSRule.SelectorList(
                                selectors: [CSSRule.Selector(text: selector)],
                                text: selector
                            ),
                            sourceURL: sourceURL,
                            sourceLine: sourceLine,
                            origin: .author,
                            style: CSSStyle.Payload(
                                id: styleID,
                                cssProperties: [
                                    CSSProperty.Payload(
                                        name: "margin",
                                        value: marginValue,
                                        text: marginText,
                                        status: .active
                                    ),
                                    CSSProperty.Payload(
                                        name: "box-sizing",
                                        value: "border-box",
                                        text: "/* box-sizing: border-box; */",
                                        status: .disabled
                                    ),
                                    CSSProperty.Payload(
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
            inline: CSSStyle.InlineStylesPayload(),
            computed: []
        )
        return BodyStyleIDs(
            margin: CSSProperty.ID(styleID: styleID, propertyIndex: 0),
            boxSizing: CSSProperty.ID(styleID: styleID, propertyIndex: 1),
            fontSize: CSSProperty.ID(styleID: styleID, propertyIndex: 2)
        )
    }

    private func applyInheritedVariableStyles(
        to css: CSSSession,
        in dom: DOMSession,
        bodyColorValue: String = "var(--foreground)",
        foregroundValue: String = "var(--palette-primary)",
        additionalBodyProperties: [CSSProperty.Payload] = [],
        additionalRootProperties: [CSSProperty.Payload] = []
    ) throws {
        let identity = try dom.selectedCSSNodeStyleIdentity().get()
        let token = try #require(css.beginRefresh(identity: identity))
        let styleSheetID = CSSStyleSheet.ID("variables")
        let bodyStyleID = CSSStyle.ID(styleSheetID: styleSheetID, ordinal: 0)
        let rootStyleID = CSSStyle.ID(styleSheetID: styleSheetID, ordinal: 1)
        let bodyProperties = [
            CSSProperty.Payload(
                name: "color",
                value: bodyColorValue,
                text: "color: \(bodyColorValue);",
                status: .active
            ),
        ] + additionalBodyProperties
        let rootProperties = [
            CSSProperty.Payload(
                name: "--foreground",
                value: foregroundValue,
                text: "--foreground: \(foregroundValue);",
                status: .active
            ),
            CSSProperty.Payload(
                name: "--palette-primary",
                value: "#111",
                text: "--palette-primary: #111;",
                status: .active
            ),
            CSSProperty.Payload(
                name: "--unused-a",
                value: "red",
                text: "--unused-a: red;",
                status: .active
            ),
            CSSProperty.Payload(
                name: "--unused-b",
                value: "blue",
                text: "--unused-b: blue;",
                status: .active
            ),
        ] + additionalRootProperties

        css.applyRefresh(
            token: token,
            matched: CSSStyle.MatchedStylesPayload(
                matchedRules: [
                    CSSRule.MatchPayload(
                        rule: CSSRule.Payload(
                            id: CSSRule.ID(styleSheetID: styleSheetID, ordinal: 0),
                            selectorList: CSSRule.SelectorList(
                                selectors: [CSSRule.Selector(text: "body")],
                                text: "body"
                            ),
                            sourceURL: "variables.css",
                            sourceLine: 12,
                            origin: .author,
                            style: CSSStyle.Payload(
                                id: bodyStyleID,
                                cssProperties: bodyProperties,
                                cssText: bodyProperties.compactMap(\.text).joined(separator: "\n")
                            )
                        ),
                        matchingSelectors: [0]
                    ),
                ],
                inherited: [
                    CSSStyle.InheritedStyleEntry(
                        matchedRules: [
                            CSSRule.MatchPayload(
                                rule: CSSRule.Payload(
                                    id: CSSRule.ID(styleSheetID: styleSheetID, ordinal: 1),
                                    selectorList: CSSRule.SelectorList(
                                        selectors: [CSSRule.Selector(text: ":root")],
                                        text: ":root"
                                    ),
                                    sourceURL: "variables.css",
                                    sourceLine: 1,
                                    origin: .author,
                                    style: CSSStyle.Payload(
                                        id: rootStyleID,
                                        cssProperties: rootProperties,
                                        cssText: rootProperties.compactMap(\.text).joined(separator: "\n")
                                    )
                                ),
                                matchingSelectors: [0]
                            ),
                        ]
                    ),
                ]
            ),
            inline: CSSStyle.InlineStylesPayload(),
            computed: []
        )
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

    private func documentNode() -> DOMNode.Payload {
        DOMNode.Payload(
            nodeID: .init(1),
            nodeType: .document,
            nodeName: "#document",
            regularChildren: .loaded([
                DOMNode.Payload(
                    nodeID: .init(2),
                    nodeType: .element,
                    nodeName: "HTML",
                    localName: "html",
                    regularChildren: .loaded([
                        DOMNode.Payload(
                            nodeID: .init(3),
                            nodeType: .element,
                            nodeName: "BODY",
                            localName: "body",
                            regularChildren: .loaded([
                                DOMNode.Payload(
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

    private var loadedDocumentResult: String {
        ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","children":[{"nodeId":2,"nodeType":1,"nodeName":"HTML","localName":"html","children":[{"nodeId":3,"nodeType":1,"nodeName":"BODY","localName":"body"}]}]}}"##
    }

    private func pageTargetCreatedMessage(targetID: ProtocolTarget.ID) -> String {
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(targetID.rawValue)","type":"page","frameId":"main-frame","domains":["DOM","Runtime","Target","Inspector","Network","CSS"],"isProvisional":false}}}"#
    }

    private func receiveTargetReply(
        _ transport: TransportSession,
        targetID: ProtocolTarget.ID,
        messageID: UInt64,
        result: String
    ) async {
        await transport.receiveRootMessage(
            targetDispatchMessage(
                targetID: targetID,
                message: #"{"id":\#(messageID),"result":\#(result)}"#
            )
        )
    }

    private func targetDispatchMessage(
        targetID: ProtocolTarget.ID,
        message: String
    ) -> String {
        let escapedTargetID = jsonEscapedString(targetID.rawValue)
        let escapedMessage = jsonEscapedString(message)
        return #"{"method":"Target.dispatchMessageFromTarget","params":{"targetId":"\#(escapedTargetID)","message":"\#(escapedMessage)"}}"#
    }

    private func waitForTargetMessage(
        _ backend: RecordingTransportBackend,
        method: String,
        timeout: Duration = .seconds(5)
    ) async throws -> RecordedTargetMessage {
        try await withThrowingTaskGroup(of: RecordedTargetMessage.self) { group in
            defer {
                group.cancelAll()
            }

            group.addTask {
                try await backend.waitForTargetMessage(method: method)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransportSession.Error.replyTimeout(method: method, targetID: nil)
            }

            guard let message = try await group.next() else {
                throw TransportSession.Error.replyTimeout(method: method, targetID: nil)
            }
            return message
        }
    }

    private func messageID(_ message: String) throws -> UInt64 {
        let data = try #require(message.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let number = object["id"] as? NSNumber {
            return number.uint64Value
        }
        if let string = object["id"] as? String,
           let id = UInt64(string) {
            return id
        }
        throw TransportSession.Error.malformedMessage
    }

    private func jsonEscapedString(_ string: String) -> String {
        string
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
            .replacingOccurrences(of: "\n", with: #"\n"#)
            .replacingOccurrences(of: "\r", with: #"\r"#)
    }

    private struct RecordedTargetMessage: Sendable {
        var message: String
        var targetIdentifier: ProtocolTarget.ID
    }

    private final class CommandAttachmentGate {
        var isAttached = false
    }

    private actor RecordingTransportBackend: TransportBackend {
        private struct TargetMessageWaiter {
            var id: UInt64
            var method: String
            var continuation: CheckedContinuation<RecordedTargetMessage, Error>
        }

        private var messages: [String] = []
        private var waiters: [TargetMessageWaiter] = []
        private var nextWaiterID: UInt64 = 0
        private var cancelledWaiterIDs: Set<UInt64> = []

        func sendJSONString(_ message: String) async throws {
            messages.append(message)
            resumeWaiters()
        }

        func detach() async {}

        func sentTargetMessages() -> [RecordedTargetMessage] {
            messages.compactMap(Self.targetMessage)
        }

        func waitForTargetMessage(method: String) async throws -> RecordedTargetMessage {
            try Task.checkCancellation()
            if let message = sentTargetMessages().first(where: { messageMethod($0.message) == method }) {
                return message
            }

            nextWaiterID &+= 1
            let waiterID = nextWaiterID
            let message = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    registerWaiter(id: waiterID, method: method, continuation: continuation)
                }
            } onCancel: {
                Task {
                    await self.cancelWaiter(waiterID)
                }
            }
            try Task.checkCancellation()
            return message
        }

        private func resumeWaiters() {
            guard !waiters.isEmpty else {
                return
            }

            var remainingWaiters: [TargetMessageWaiter] = []
            for waiter in waiters {
                if cancelledWaiterIDs.remove(waiter.id) != nil {
                    waiter.continuation.resume(throwing: CancellationError())
                } else if let message = sentTargetMessages().first(where: { messageMethod($0.message) == waiter.method }) {
                    waiter.continuation.resume(returning: message)
                } else {
                    remainingWaiters.append(waiter)
                }
            }
            waiters = remainingWaiters
        }

        private func registerWaiter(
            id: UInt64,
            method: String,
            continuation: CheckedContinuation<RecordedTargetMessage, Error>
        ) {
            guard cancelledWaiterIDs.remove(id) == nil else {
                continuation.resume(throwing: CancellationError())
                return
            }
            if let message = sentTargetMessages().first(where: { messageMethod($0.message) == method }) {
                continuation.resume(returning: message)
                return
            }
            waiters.append(TargetMessageWaiter(id: id, method: method, continuation: continuation))
            resumeWaiters()
        }

        private func cancelWaiter(_ id: UInt64) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                cancelledWaiterIDs.insert(id)
                return
            }
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        }

        private static func targetMessage(_ message: String) -> RecordedTargetMessage? {
            guard let data = message.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let params = object["params"] as? [String: Any],
                  let targetID = params["targetId"] as? String,
                  let innerMessage = params["message"] as? String else {
                return nil
            }
            return RecordedTargetMessage(
                message: innerMessage,
                targetIdentifier: ProtocolTarget.ID(targetID)
            )
        }

        private func messageMethod(_ message: String) -> String? {
            guard let data = message.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object["method"] as? String
        }
    }

    private func showInWindow(_ viewController: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    private func showViewInWindow(_ view: UIView) -> UIWindow {
        let viewController = UIViewController()
        view.translatesAutoresizingMaskIntoConstraints = false
        viewController.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: viewController.view.topAnchor),
            view.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
        ])
        return showInWindow(viewController)
    }

    private func stylePropertyViews(in viewController: DOMElementViewController) -> [DOMElementStylePropertyView] {
        viewController.collectionView.visibleCells
            .compactMap { ($0 as? DOMElementStylePropertyCollectionCell)?.propertyViewForTesting }
    }

    private func hiddenVariableCells(in viewController: DOMElementViewController) -> [DOMElementStyleHiddenVariablesCollectionCell] {
        viewController.collectionView.visibleCells
            .compactMap { $0 as? DOMElementStyleHiddenVariablesCollectionCell }
    }

    private func styleSectionHeaderViews(in viewController: DOMElementViewController) -> [DOMElementStyleSectionHeaderView] {
        viewController.collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader
        )
        .compactMap { $0 as? DOMElementStyleSectionHeaderView }
    }

    private func visibleCellIDs(in viewController: DOMElementViewController) -> [ObjectIdentifier] {
        viewController.collectionView.visibleCells.map(ObjectIdentifier.init)
    }

    private func propertyView(
        named name: String,
        in propertyViews: [DOMElementStylePropertyView]
    ) -> DOMElementStylePropertyView? {
        propertyViews.first {
            $0.accessibilityIdentifier == "WebInspector.DOM.Element.StyleProperty.\(name)"
        }
    }

    private func waitUntilRendered(
        in viewController: DOMElementViewController,
        condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        let generation = viewController.styleRenderGenerationForTesting
        if sampleRenderedCondition(in: viewController, condition: condition) {
            return true
        }

        guard await viewController.waitForStyleRenderForTesting(after: generation) else {
            return sampleRenderedCondition(in: viewController, condition: condition)
        }
        return sampleRenderedCondition(in: viewController, condition: condition)
    }

    private func sampleRenderedCondition(
        in viewController: DOMElementViewController,
        condition: @MainActor @Sendable () -> Bool
    ) -> Bool {
        viewController.collectionView.layoutIfNeeded()
        viewController.view.layoutIfNeeded()
        return condition()
    }

}
}
#endif
