#if canImport(UIKit)
import Testing
import WebInspectorTestSupport
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import UIKit
@testable import WebInspectorDataKit
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct DOMContainerTests {
    @Test
    func elementViewControllerShowsUnavailableStateWithoutSelectedStyles() {
        let context = makeElementContext()
        let viewController = makeElementViewController(context: context)
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

        let context = makeElementContext()
        let viewController = makeElementViewController(context: context)
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()

        #expect(viewController.view.backgroundColor == .clear)
        #expect(viewController.collectionView.backgroundColor == .clear)
    }

    @Test
    func elementViewControllerKeepsUnavailableStateWhenDocumentRootArrivesWithoutSelection() async throws {
        let context = makeWebInspectorContext()
        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(viewController.contentUnavailableConfiguration != nil)
        #expect(viewController.collectionView.isHidden == false)
        #expect(viewController.collectionView.numberOfSections == 0)

        context.seedDOMDocument(documentNode())

        let didKeepUnavailableState = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 0
        }
        #expect(didKeepUnavailableState)
    }

    @Test
    func elementViewControllerRendersLoadedStyleSections() async throws {
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyBodyStyles(to: context)

        let viewController = makeElementViewController(context: context)
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
        let stylesheetLocation = DOMElementStyleSectionHeaderText.SourceLocation(
            sourceURL: "https://styles.example/assets/result-card.css",
            line: 27,
            column: 22164
        )
        #expect(DOMElementStyleSectionHeaderText.displayText(for: stylesheetLocation) == "result-card.css:28:22165")
        #expect(DOMElementStyleSectionHeaderText.fullDisplayText(for: stylesheetLocation) == "https://styles.example/assets/result-card.css:28:22165")

        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: DOMElementStyleSectionHeaderText.SourceLocation(sourceURL: "styles.css", line: 1)
        ) == "styles.css:2")
        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: DOMElementStyleSectionHeaderText.SourceLocation(sourceURL: "styles.css", line: 0, column: 80)
        ) == "styles.css:1")
        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: DOMElementStyleSectionHeaderText.SourceLocation(sourceURL: "styles.css", line: 0, column: 81)
        ) == "styles.css:1:82")
        #expect(DOMElementStyleSectionHeaderText.displayText(for: CSSStyleRule.Origin(rawValue: "user-agent"))?.isEmpty == false)
    }

    @Test
    func elementViewControllerKeepsVisibleRowsDuringSameNodeStyleRefresh() async throws {
        let context = makeElementContext()
        let body = try selectElement(named: "body", in: context)
        applyBodyStyles(to: context)

        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderRows = await waitUntilRendered(in: viewController) {
            viewController.collectionView.numberOfSections == 1
                && viewController.collectionView.numberOfItems(inSection: 0) == 3
        }
        window.layoutIfNeeded()

        #expect(didRenderRows)
        let cellIDsBeforeUpdate = visibleCellIDs(in: viewController)
        let applyCountBeforeUpdate = viewController.styleSnapshotApplyCountForTesting

        let styles = try #require(body.elementStyles)
        styles.markLoading()
        window.layoutIfNeeded()
        #expect(viewController.collectionView.isHidden == false)
        #expect(visibleCellIDs(in: viewController) == cellIDsBeforeUpdate)

        applyBodyStyles(
            to: context,
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
        // Value-type rows cannot self-observe: the same-identity content
        // change surfaces as exactly one reconfigure apply that keeps the
        // existing cells (the legacy build re-rendered in place with no
        // snapshot apply at all).
        #expect(viewController.styleSnapshotApplyCountForTesting == applyCountBeforeUpdate + 1)
        #expect(viewController.lastSnapshotApplyModeForTesting == .diff(animated: false))
    }

    @Test
    func elementViewControllerCompletesCleanStyleRenderWithoutApplyingSnapshot() async throws {
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyBodyStyles(to: context)

        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderRows = await waitUntilRendered(in: viewController) {
            viewController.collectionView.numberOfSections == 1
                && viewController.collectionView.numberOfItems(inSection: 0) == 3
        }
        #expect(didRenderRows)

        let applyCount = viewController.styleSnapshotApplyCountForTesting
        let generation = viewController.styleRenderGenerationForTesting

        viewController.renderCurrentStylesForTesting()

        #expect(await viewController.waitForStyleRenderForTesting(after: generation))
        #expect(viewController.styleSnapshotApplyCountForTesting == applyCount)
    }

    @Test
    func elementViewControllerUpdatesVisibleSectionHeaderDuringSameNodeStyleRefresh() async throws {
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyBodyStyles(to: context)

        let viewController = makeElementViewController(context: context)
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

        applyBodyStyles(
            to: context,
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
    func elementViewControllerRequestsAnimatedDifferencesForSameSelectionStructuralStyleChange() async throws {
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyBodyStyles(to: context)

        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderBodyRows = await waitUntilRendered(in: viewController) {
            viewController.collectionView.numberOfSections == 1
                && stylePropertyViews(in: viewController)
                    .map(\.declarationTextForTesting)
                    .contains("margin: 0;")
        }
        #expect(didRenderBodyRows)

        applyInheritedVariableStyles(to: context)

        let didRenderUpdatedSections = await waitUntilRendered(in: viewController) {
            viewController.collectionView.numberOfSections == 2
                && stylePropertyViews(in: viewController)
                    .map(\.declarationTextForTesting)
                    .contains("color: var(--foreground);")
        }

        #expect(didRenderUpdatedSections)
        #expect(viewController.lastSnapshotApplyModeForTesting == .diff(animated: true))
    }

    @Test
    func elementViewControllerDoesNotRequestAnimatedDifferencesWhenSwitchingToCachedSelectionStyles() async throws {
        let context = makeElementContext()
        let input = try selectElement(named: "input", in: context)
        applyBodyStyles(
            to: context,
            selector: "input",
            marginValue: "8px",
            marginText: "margin: 8px;"
        )

        _ = try selectElement(named: "body", in: context)
        applyBodyStyles(to: context)

        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderBodyRows = await waitUntilRendered(in: viewController) {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 0;")
        }
        #expect(didRenderBodyRows)

        context.select(input)
        applyBodyStyles(
            to: context,
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
        #expect(viewController.lastSnapshotApplyModeForTesting == .reloadData)
    }

    @Test
    func elementViewControllerKeepsCurrentRowsWhileNewSelectionStylesAreHydrating() async throws {
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyBodyStyles(to: context)

        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderBodyRows = await waitUntilRendered(in: viewController) {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 0;")
        }
        window.layoutIfNeeded()
        #expect(didRenderBodyRows)

        let body = try #require(context.selectedNode)
        let input = try selectElement(named: "input", in: context)
        // Seed once to cancel the preview context's backend-less refresh
        // task, then hold the fresh selection in `.loading` so the pending
        // policy is observable while the run loop settles.
        applyBodyStyles(
            to: context,
            selector: "input",
            marginValue: "8px",
            marginText: "margin: 8px;"
        )
        let inputStyles = try #require(input.elementStyles)
        inputStyles.markLoading()
        window.layoutIfNeeded()

        #expect(body !== input)
        #expect(inputStyles.phase == .loading)
        let didKeepBodyRowsWhileInputLoads = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration == nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 1
                && stylePropertyViews(in: viewController)
                    .map(\.declarationTextForTesting)
                    .contains("margin: 0;")
        }
        #expect(didKeepBodyRowsWhileInputLoads)

        applyBodyStyles(
            to: context,
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
        #expect(viewController.lastSnapshotApplyModeForTesting == .reloadData)
    }

    @Test
    func elementViewControllerShowsPlaceholderForInitialElementSelectionWhileStylesHydrate() async throws {
        let context = makeElementContext()
        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let body = try selectElement(named: "body", in: context)
        #expect(body.elementStyles?.phase == .loading)

        let didRenderPlaceholder = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 0
        }

        #expect(didRenderPlaceholder)
    }

    @Test
    func elementViewControllerClearsRetainedRowsWhenSelectionClears() async throws {
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyBodyStyles(to: context)

        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderBodyRows = await waitUntilRendered(in: viewController) {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 0;")
        }
        #expect(didRenderBodyRows)

        let input = try selectElement(named: "input", in: context)
        #expect(input.elementStyles?.phase == .loading)
        #expect(stylePropertyViews(in: viewController).map(\.declarationTextForTesting).contains("margin: 0;"))

        context.select(nil)

        let didClearRows = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 0
        }

        #expect(didClearRows)
    }

    @Test
    func elementViewControllerClearsDisplayedRowsWhenSelectedNodeIsRemoved() async throws {
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyBodyStyles(to: context)

        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderBodyRows = await waitUntilRendered(in: viewController) {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 0;")
        }
        #expect(didRenderBodyRows)

        context.apply(.childNodeRemoved(parent: DOM.Node.ID("html"), node: DOM.Node.ID("body")))

        let didClearRows = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 0
        }

        #expect(didClearRows)
    }

    @Test
    func elementViewControllerClearsDisplayedRowsWhenSelectedStylesBecomeUnavailable() async throws {
        let context = makeElementContext()
        let body = try selectElement(named: "body", in: context)
        applyBodyStyles(to: context)

        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        let didRenderBodyRows = await waitUntilRendered(in: viewController) {
            stylePropertyViews(in: viewController)
                .map(\.declarationTextForTesting)
                .contains("margin: 0;")
        }
        #expect(didRenderBodyRows)

        let styles = try #require(body.elementStyles)
        styles.markUnavailable()

        let didClearRows = await waitUntilRendered(in: viewController) {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.isHidden == false
                && viewController.collectionView.numberOfSections == 0
        }

        #expect(didClearRows)
    }

    @Test
    func elementViewControllerCollapsesUnusedInheritedCSSVariablesAndAnimatesReveal() async throws {
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyInheritedVariableStyles(to: context)

        let viewController = makeElementViewController(context: context)
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
        #expect(revealCell.isRevealButtonEnabledForTesting)

        let applyModesBeforeReveal = viewController.styleSnapshotApplyModesForTesting
        revealCell.tapRevealForTesting()
        #expect(revealCell.isRevealButtonEnabledForTesting == false)

        let didRevealUnusedVariables = await waitUntilRendered(in: viewController) {
            let declarations = stylePropertyViews(in: viewController).map(\.declarationTextForTesting)
            return viewController.collectionView.numberOfItems(inSection: 1) == 4
                && hiddenVariableCells(in: viewController).isEmpty
                && declarations.contains("--unused-a: red;")
                && declarations.contains("--unused-b: blue;")
        }

        #expect(didRevealUnusedVariables)
        let revealApplyModes = Array(
            viewController.styleSnapshotApplyModesForTesting.dropFirst(applyModesBeforeReveal.count)
        )
        #expect(revealApplyModes == [.diff(animated: true)])
    }

    @Test
    func elementViewControllerIgnoresVariableReferencesInsideCSSStringsAndComments() async throws {
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyInheritedVariableStyles(
            to: context,
            additionalBodyProperties: [
                PropertySpec(
                    name: "content",
                    value: #""var(--unused-a)""#,
                    text: #"content: "var(--unused-a)";"#,
                    status: .active
                ),
                PropertySpec(
                    name: "background",
                    value: "/* var(--unused-b) */ transparent",
                    text: "background: /* var(--unused-b) */ transparent;",
                    status: .active
                ),
            ]
        )

        let viewController = makeElementViewController(context: context)
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
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyInheritedVariableStyles(
            to: context,
            additionalBodyProperties: [
                PropertySpec(
                    name: "border-color",
                    value: "var(--unused-a)",
                    text: "border-color: var(--unused-a);",
                    status: .inactive
                ),
            ]
        )

        let viewController = makeElementViewController(context: context)
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
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyInheritedVariableStyles(
            to: context,
            bodyColorValue: "VAR(--foreground)",
            foregroundValue: "vAr(--palette-primary)"
        )

        let viewController = makeElementViewController(context: context)
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
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyInheritedVariableStyles(
            to: context,
            additionalBodyProperties: [
                PropertySpec(
                    name: "background",
                    value: "myvar(--unused-a)",
                    text: "background: myvar(--unused-a);",
                    status: .active
                ),
            ]
        )

        let viewController = makeElementViewController(context: context)
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
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyInheritedVariableStyles(
            to: context,
            additionalBodyProperties: [
                PropertySpec(
                    name: "--local-unused",
                    value: "var(--unused-a)",
                    text: "--local-unused: var(--unused-a);",
                    status: .active
                ),
            ]
        )

        let viewController = makeElementViewController(context: context)
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
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyInheritedVariableStyles(
            to: context,
            additionalBodyProperties: [
                PropertySpec(
                    name: "--local-used",
                    value: "var(--unused-a)",
                    text: "--local-used: var(--unused-a);",
                    status: .active
                ),
                PropertySpec(
                    name: "border-color",
                    value: "var(--local-used)",
                    text: "border-color: var(--local-used);",
                    status: .active
                ),
            ]
        )

        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController, useUIKitVisibility: false)
        defer { window.isHidden = true }

        let didCollapseOnlyUnusedVariable = await waitUntilRendered(in: viewController) {
            hiddenVariableCells(in: viewController).count == 1
        }

        #expect(didCollapseOnlyUnusedVariable)
        let collapsedDeclarations = stylePropertyViews(in: viewController).map(\.declarationTextForTesting)
        #expect(collapsedDeclarations.contains("--unused-a: red;"))
        #expect(collapsedDeclarations.contains("--unused-b: blue;") == false)
    }

    @Test
    func elementViewControllerUpdatesCollapsedUnusedVariableCountAfterStyleRefresh() async throws {
        let context = makeElementContext()
        _ = try selectElement(named: "body", in: context)
        applyInheritedVariableStyles(to: context)

        let viewController = makeElementViewController(context: context)
        let window = showInWindow(viewController, useUIKitVisibility: false)
        defer { window.isHidden = true }

        let didCollapseUnusedVariables = await waitUntilRendered(in: viewController) {
            hiddenVariableCells(in: viewController).count == 1
        }
        #expect(didCollapseUnusedVariables)

        applyInheritedVariableStyles(
            to: context,
            additionalRootProperties: [
                PropertySpec(
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
        let propertyID = CSSStyleProperty.ID("test-style:0")
        let property = CSSStyleProperty(
            id: propertyID,
            name: "margin",
            value: "0",
            text: "margin: 0;",
            status: .active,
            isEditable: true
        )
        let propertyView = DOMElementStylePropertyView()
        var requestedPropertyID: CSSStyleProperty.ID?
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
    func elementStylePropertyViewIgnoresNonEditableProperties() {
        let nonEditable = CSSStyleProperty(
            id: CSSStyleProperty.ID("test-style:0"),
            name: "margin",
            value: "0",
            text: "margin: 0;",
            status: .active,
            isEditable: false
        )
        let implicit = CSSStyleProperty(
            id: CSSStyleProperty.ID("test-style:1"),
            name: "padding",
            value: "0",
            text: "padding: 0;",
            status: .active,
            implicit: true,
            isEditable: false
        )
        let nonEditableView = DOMElementStylePropertyView()
        let implicitView = DOMElementStylePropertyView()
        var requestCount = 0
        nonEditableView.bind(property: nonEditable) { _, _ in
            requestCount += 1
            return true
        }
        implicitView.bind(property: implicit) { _, _ in
            requestCount += 1
            return true
        }
        let stackView = UIStackView(arrangedSubviews: [nonEditableView, implicitView])
        stackView.axis = .vertical
        let window = showViewInWindow(stackView)
        defer { window.isHidden = true }

        #expect(nonEditableView.isToggleEnabledForTesting == false)
        #expect(implicitView.isToggleEnabledForTesting == false)
        nonEditableView.tapToggleForTesting()
        implicitView.tapToggleForTesting()
        #expect(requestCount == 0)
    }

    @Test
    func elementStylePropertyViewNormalizesMultilinePropertyText() {
        let property = CSSStyleProperty(
            id: CSSStyleProperty.ID("test-style:0"),
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
        let context = makeWebInspectorContext()
        let treeViewController = DOMTreeViewController(context: context)
        let navigationController = DOMCompactNavigationController(rootViewController: treeViewController)

        #expect(navigationController.viewControllers == [treeViewController])
        #expect(navigationController.navigationBar.prefersLargeTitles == false)
        #expect(treeViewController.navigationItem.style == UINavigationItem.ItemStyle.browser)
    }

    @Test
    func compactContainerInstallsSessionNavigationActions() throws {
        let context = makeWebInspectorContext()
        let treeViewController = DOMTreeViewController(context: context)
        let navigationController = DOMCompactNavigationController(
            rootViewController: treeViewController,
            context: context
        )

        let pickItem = try #require(treeViewController.navigationItem.trailingItemGroups.first?.barButtonItems.first)

        #expect(navigationController.viewControllers == [treeViewController])
        #expect(pickItem.accessibilityIdentifier == "WebInspector.DOM.PickButton")
        #expect(treeViewController.navigationItem.additionalOverflowItems != nil)
        #expect(navigationController.canBecomeFirstResponder)
        #expect(domNavigationKeyCommandSpecs(navigationController.keyCommands) == expectedDOMNavigationKeyCommandSpecs)
    }

    @Test
    func navigationDeleteRegistersDOMUndoRedoAfterSuccessfulBackendDelete() async throws {
        let fixture = try await makeLiveDOMContext()
        let input = try #require(fixture.context.node(for: DOMNode.ID(DOM.Node.ID("input"))))
        fixture.context.select(input)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let navigationItems = DOMNavigationItems(context: fixture.context)

        await enqueueDOMRemoveNodeWithUndoMark(on: fixture.runtime.backend)
        await navigationItems.deleteSelectedNodeForTesting(undoManager: undoManager)

        #expect(undoManager.canUndo)

        await fixture.runtime.backend.enqueue((), for: "DOM", method: "undo")
        undoManager.undo()
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "undo", count: 1)

        let didEnableRedo = await waitForDOMRedoAvailability(true, undoManager: undoManager)
        #expect(didEnableRedo)

        await fixture.runtime.backend.enqueue((), for: "DOM", method: "redo")
        navigationItems.redoForTesting(undoManager: undoManager)
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "redo", count: 1)

        let commands = await fixture.runtime.backend.recordedCommands()
        #expect(commands.domMutationUndoMethods == ["removeNode", "undo", "redo"])
    }

    @Test
    func navigationDeleteDoesNotRegisterUndoWhenBackendDeleteFails() async throws {
        let fixture = try await makeLiveDOMContext()
        let input = try #require(fixture.context.node(for: DOMNode.ID(DOM.Node.ID("input"))))
        fixture.context.select(input)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let navigationItems = DOMNavigationItems(context: fixture.context)

        await navigationItems.deleteSelectedNodeForTesting(undoManager: undoManager)

        let commands = await fixture.runtime.backend.recordedCommands()
        #expect(commands.domMutationUndoMethods == ["removeNode"])
        #expect(!undoManager.canUndo)
    }

    @Test
    func navigationUndoDoesNotRegisterRedoWhenBackendUndoFails() async throws {
        let fixture = try await makeLiveDOMContext()
        let input = try #require(fixture.context.node(for: DOMNode.ID(DOM.Node.ID("input"))))
        fixture.context.select(input)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let navigationItems = DOMNavigationItems(context: fixture.context)

        await enqueueDOMRemoveNodeWithUndoMark(on: fixture.runtime.backend)
        await navigationItems.deleteSelectedNodeForTesting(undoManager: undoManager)

        undoManager.undo()
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "undo", count: 1)

        let commands = await fixture.runtime.backend.recordedCommands()
        #expect(commands.domMutationUndoMethods == ["removeNode", "undo"])
        #expect(!navigationItems.canRedoForTesting(undoManager: undoManager))
    }

    @Test
    func navigationDOMRedoClearsWhenUndoManagerRegistersAnotherAction() async throws {
        let fixture = try await makeLiveDOMContext()
        let input = try #require(fixture.context.node(for: DOMNode.ID(DOM.Node.ID("input"))))
        fixture.context.select(input)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let navigationItems = DOMNavigationItems(context: fixture.context)

        await enqueueDOMRemoveNodeWithUndoMark(on: fixture.runtime.backend)
        await navigationItems.deleteSelectedNodeForTesting(undoManager: undoManager)

        await fixture.runtime.backend.enqueue((), for: "DOM", method: "undo")
        undoManager.undo()
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "undo", count: 1)
        let didEnableRedo = await waitForDOMRedoAvailability(true, undoManager: undoManager)
        #expect(didEnableRedo)

        let marker = UndoRegistrationMarker()
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: marker) { _ in }
        undoManager.endUndoGrouping()
        let didClearRedo = await waitForDOMRedoAvailability(false, undoManager: undoManager)
        #expect(didClearRedo)

        navigationItems.redoForTesting(undoManager: undoManager)

        let commands = await fixture.runtime.backend.recordedCommands()
        #expect(commands.domMutationUndoMethods == ["removeNode", "undo"])
    }

    @Test
    func navigationPendingDOMRedoClearsWhenUndoManagerRegistersAnotherActionBeforeUndoCompletes() async throws {
        let fixture = try await makeLiveDOMContext()
        let input = try #require(fixture.context.node(for: DOMNode.ID(DOM.Node.ID("input"))))
        fixture.context.select(input)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let navigationItems = DOMNavigationItems(context: fixture.context)

        await enqueueDOMRemoveNodeWithUndoMark(on: fixture.runtime.backend)
        await navigationItems.deleteSelectedNodeForTesting(undoManager: undoManager)

        let undoGate = WebInspectorTestGate()
        await fixture.runtime.backend.hold(domain: "DOM", method: "undo", gate: undoGate)
        await fixture.runtime.backend.enqueue((), for: "DOM", method: "undo")
        let operationBaseline = DOMDeletionUndoRegistration.operationCompletionCountForTesting(on: undoManager)
        undoManager.undo()
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "undo", count: 1)

        let marker = UndoRegistrationMarker()
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: marker) { _ in }
        undoManager.endUndoGrouping()

        await undoGate.open()
        let didFinishUndo = await DOMDeletionUndoRegistration.waitForOperationCompletionForTesting(
            after: operationBaseline,
            on: undoManager
        )
        #expect(didFinishUndo)
        #expect(!navigationItems.canRedoForTesting(undoManager: undoManager))

        navigationItems.redoForTesting(undoManager: undoManager)

        let commands = await fixture.runtime.backend.recordedCommands()
        #expect(commands.domMutationUndoMethods == ["removeNode", "undo"])
    }

    @Test
    func navigationRedoDoesNotRegisterUndoWhenBackendRedoFails() async throws {
        let fixture = try await makeLiveDOMContext()
        let input = try #require(fixture.context.node(for: DOMNode.ID(DOM.Node.ID("input"))))
        fixture.context.select(input)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let navigationItems = DOMNavigationItems(context: fixture.context)

        await enqueueDOMRemoveNodeWithUndoMark(on: fixture.runtime.backend)
        await navigationItems.deleteSelectedNodeForTesting(undoManager: undoManager)

        await fixture.runtime.backend.enqueue((), for: "DOM", method: "undo")
        undoManager.undo()
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "undo", count: 1)
        let didEnableRedo = await waitForDOMRedoAvailability(true, undoManager: undoManager)
        #expect(didEnableRedo)

        navigationItems.redoForTesting(undoManager: undoManager)
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "redo", count: 1)

        let commands = await fixture.runtime.backend.recordedCommands()
        #expect(commands.domMutationUndoMethods == ["removeNode", "undo", "redo"])
        #expect(!undoManager.canUndo)
    }

    @Test
    func treeMenuDeleteUsesControllerUndoManagerWiring() async throws {
        let fixture = try await makeLiveDOMContext()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let navigationItems = DOMNavigationItems(context: fixture.context)
        let viewController = DOMTreeViewController(context: fixture.context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        let treeView = viewController.displayedDOMTreeTextViewForTesting
        #expect(await treeView.waitForRowDocumentForTesting())

        await enqueueDOMRemoveNodeWithUndoMark(on: fixture.runtime.backend)
        await treeView.deleteRowFromMenuForTesting(containing: "<input", undoManager: undoManager)

        #expect(undoManager.canUndo)

        await fixture.runtime.backend.enqueue((), for: "DOM", method: "undo")
        undoManager.undo()
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "undo", count: 1)
        let didEnableRedo = await waitForDOMRedoAvailability(true, undoManager: undoManager)
        #expect(didEnableRedo)

        await fixture.runtime.backend.enqueue((), for: "DOM", method: "redo")
        navigationItems.redoForTesting(undoManager: undoManager)
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "redo", count: 1)

        let commands = await fixture.runtime.backend.recordedCommands()
        #expect(commands.domMutationUndoMethods == ["removeNode", "undo", "redo"])
    }

    @Test
    func treeMenuMultiDeleteUndoRedoCoversEveryRemovedNode() async throws {
        let fixture = try await makeLiveDOMContext(document: multiDeleteDocumentNode())
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let navigationItems = DOMNavigationItems(context: fixture.context)
        let viewController = DOMTreeViewController(context: fixture.context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        let treeView = viewController.displayedDOMTreeTextViewForTesting
        #expect(await treeView.waitForRowDocumentForTesting())

        treeView.primaryClickRowForTesting(containing: "<input")
        treeView.primaryClickRowForTesting(containing: "<button", modifiers: .command)

        await enqueueDOMRemoveNodeWithUndoMark(on: fixture.runtime.backend)
        await enqueueDOMRemoveNodeWithUndoMark(on: fixture.runtime.backend)
        await treeView.deleteMultiSelectionFromMenuForTesting(undoManager: undoManager)

        #expect(undoManager.canUndo)

        await fixture.runtime.backend.enqueue((), for: "DOM", method: "undo")
        await fixture.runtime.backend.enqueue((), for: "DOM", method: "undo")
        undoManager.undo()
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "undo", count: 2)
        let didEnableRedo = await waitForDOMRedoAvailability(true, undoManager: undoManager)
        #expect(didEnableRedo)

        await fixture.runtime.backend.enqueue((), for: "DOM", method: "redo")
        await fixture.runtime.backend.enqueue((), for: "DOM", method: "redo")
        navigationItems.redoForTesting(undoManager: undoManager)
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "redo", count: 2)

        let commands = await fixture.runtime.backend.recordedCommands()
        #expect(commands.domMutationUndoMethods == [
            "removeNode",
            "removeNode",
            "undo",
            "undo",
            "redo",
            "redo",
        ])
    }

    @Test
    func treeMenuMultiDeleteRegistersUndoForSuccessfulRemovalsWhenLaterDeleteFails() async throws {
        let fixture = try await makeLiveDOMContext(document: multiDeleteDocumentNode())
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let viewController = DOMTreeViewController(context: fixture.context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        let treeView = viewController.displayedDOMTreeTextViewForTesting
        #expect(await treeView.waitForRowDocumentForTesting())

        treeView.primaryClickRowForTesting(containing: "<input")
        treeView.primaryClickRowForTesting(containing: "<button", modifiers: .command)

        await enqueueDOMRemoveNodeWithUndoMark(on: fixture.runtime.backend)
        await treeView.deleteMultiSelectionFromMenuForTesting(undoManager: undoManager)

        #expect(undoManager.canUndo)

        await fixture.runtime.backend.enqueue((), for: "DOM", method: "undo")
        undoManager.undo()
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "undo", count: 1)
        let didEnableRedo = await waitForDOMRedoAvailability(true, undoManager: undoManager)
        #expect(didEnableRedo)

        let commands = await fixture.runtime.backend.recordedCommands()
        #expect(commands.domMutationUndoMethods == [
            "removeNode",
            "removeNode",
            "undo",
        ])
    }

    @Test
    func treeControllerPageHighlightCommandsFollowSelectionAndHoverPolicy() async throws {
        let selectionFixture = try await makeLiveDOMContext()
        let selectionViewController = DOMTreeViewController(context: selectionFixture.context)
        let selectionWindow = showInWindow(selectionViewController, useUIKitVisibility: false)
        defer { selectionWindow.isHidden = true }
        let selectionTreeView = selectionViewController.displayedDOMTreeTextViewForTesting
        #expect(await selectionTreeView.waitForRowDocumentForTesting())

        await selectionFixture.runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
        selectionTreeView.primaryClickRowForTesting(containing: "<input")
        _ = await recordedDOMCommands(on: selectionFixture.runtime.backend, method: "highlightNode", count: 1)
        let selectionHighlightNodeIDs = await selectionFixture.runtime.backend.recordedCommands()
            .filter { $0.domain == "DOM" && $0.method == "highlightNode" }
            .compactMap { $0.payload.cast(as: DOM.HighlightNodePayload.self)?.id }
        #expect(selectionHighlightNodeIDs.contains(DOM.Node.ID("input")))
        #expect(selectionHighlightNodeIDs.last == DOM.Node.ID("input"))

        let hoverFixture = try await makeLiveDOMContext()
        let input = try #require(hoverFixture.context.node(for: DOMNode.ID(DOM.Node.ID("input"))))
        hoverFixture.context.select(input)
        await hoverFixture.runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
        let hoverViewController = DOMTreeViewController(context: hoverFixture.context)
        let hoverWindow = showInWindow(hoverViewController, useUIKitVisibility: false)
        defer { hoverWindow.isHidden = true }
        let hoverTreeView = hoverViewController.displayedDOMTreeTextViewForTesting
        #expect(await hoverTreeView.waitForRowDocumentForTesting())
        _ = await recordedDOMCommands(
            on: hoverFixture.runtime.backend,
            method: "highlightNode",
            count: 1
        )
        let hoverBaselineCount = await hoverFixture.runtime.backend.recordedCommands()
            .filter { $0.domain == "DOM" && $0.method == "highlightNode" }
            .count

        await hoverFixture.runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
        hoverTreeView.hoverRowForTesting(containing: "<body")
        _ = await recordedDOMCommands(
            on: hoverFixture.runtime.backend,
            method: "highlightNode",
            count: hoverBaselineCount + 1
        )

        await hoverFixture.runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
        hoverTreeView.endHoverForTesting()
        _ = await recordedDOMCommands(
            on: hoverFixture.runtime.backend,
            method: "highlightNode",
            count: hoverBaselineCount + 2
        )

        let highlightNodeIDs = await hoverFixture.runtime.backend.recordedCommands()
            .filter { $0.domain == "DOM" && $0.method == "highlightNode" }
            .compactMap { $0.payload.cast(as: DOM.HighlightNodePayload.self)?.id }
        let hoverHighlightNodeIDs = Array(highlightNodeIDs.dropFirst(hoverBaselineCount))
        #expect(hoverHighlightNodeIDs.contains(DOM.Node.ID("body")))
        #expect(hoverHighlightNodeIDs.last == DOM.Node.ID("input"))

        let hideFixture = try await makeLiveDOMContext()
        let hideViewController = DOMTreeViewController(context: hideFixture.context)
        let hideWindow = showInWindow(hideViewController, useUIKitVisibility: false)
        defer { hideWindow.isHidden = true }
        let hideTreeView = hideViewController.displayedDOMTreeTextViewForTesting
        #expect(await hideTreeView.waitForRowDocumentForTesting())

        await hideFixture.runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
        hideTreeView.hoverRowForTesting(containing: "<body")
        _ = await recordedDOMCommands(on: hideFixture.runtime.backend, method: "highlightNode", count: 1)

        await hideFixture.runtime.backend.enqueue((), for: "DOM", method: "hideHighlight")
        hideTreeView.endHoverForTesting()
        _ = await recordedDOMCommands(on: hideFixture.runtime.backend, method: "hideHighlight", count: 1)
    }

    @Test
    func inspectedNodeHighlightHasOneSelectionPresentationOwner() async throws {
        let fixture = try await makeLiveDOMContext()
        let target = try await fixture.runtime.proxy.waitForCurrentPage()
        let viewController = DOMTreeViewController(context: fixture.context)
        let window = showInWindow(viewController, useUIKitVisibility: false)
        defer { window.isHidden = true }
        let treeView = viewController.displayedDOMTreeTextViewForTesting
        #expect(await treeView.waitForRowDocumentForTesting())

        await fixture.runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
        await fixture.runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
        await fixture.runtime.backend.emit(.inspect(DOM.Node.ID("input")), target: target)
        _ = await recordedDOMCommands(
            on: fixture.runtime.backend,
            method: "highlightNode",
            count: 1
        )
        #expect(await treeView.waitForObservedTreeRevisionForTesting(fixture.context.rootTreeController().revision))
        treeView.routeCurrentSelectionInvalidationForTesting()
        await treeView.waitForPageHighlightTaskForTesting()

        let highlightedNodeIDs = await fixture.runtime.backend.recordedCommands()
            .filter { $0.domain == "DOM" && $0.method == "highlightNode" }
            .compactMap { $0.payload.cast(as: DOM.HighlightNodePayload.self)?.id }
        #expect(highlightedNodeIDs == [DOM.Node.ID("input")])
    }

    @Test
    func treeControllerRetriesSelectionHighlightAfterBackendFailure() async throws {
        let fixture = try await makeLiveDOMContext()
        let viewController = DOMTreeViewController(context: fixture.context)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        let treeView = viewController.displayedDOMTreeTextViewForTesting
        #expect(await treeView.waitForRowDocumentForTesting())

        treeView.primaryClickRowForTesting(containing: "<input")
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "highlightNode", count: 1)
        await treeView.waitForPageHighlightTaskForTesting()

        await fixture.runtime.backend.enqueue((), for: "DOM", method: "highlightNode")
        treeView.routeCurrentSelectionInvalidationForTesting()
        _ = await recordedDOMCommands(on: fixture.runtime.backend, method: "highlightNode", count: 2)

        let highlightNodeIDs = await fixture.runtime.backend.recordedCommands()
            .filter { $0.domain == "DOM" && $0.method == "highlightNode" }
            .compactMap { $0.payload.cast(as: DOM.HighlightNodePayload.self)?.id }
        #expect(highlightNodeIDs == [DOM.Node.ID("input"), DOM.Node.ID("input")])
    }

    @Test
    func testBackendTargetMessageWaiterTimesOutWhenMethodIsMissing() async throws {
        let backend = RecordingTransportBackend()
        let timeout = ManualResponseTimeout()

        let waitTask = Task {
            try await waitForTargetMessage(
                backend,
                method: "DOM.getDocument",
                timeout: .milliseconds(20),
                timeoutSleep: { duration in
                    try await timeout.sleep(for: duration)
                }
            )
        }
        await timeout.waitUntilSuspended()
        await timeout.fireNext()
        await #expect(throws: TransportSession.Error.replyTimeout(method: "DOM.getDocument", targetID: nil)) {
            try await waitTask.value
        }
    }

    @Test
    func splitContainerInstallsTreeAndElementColumns() throws {
        let context = makeWebInspectorContext()
        let treeViewController = DOMTreeViewController(context: context)
        let elementViewController = makeElementViewController(context: context)
        let splitViewController = DOMSplitViewController(
            treeViewController: treeViewController,
            elementViewController: elementViewController,
            context: context
        )

        splitViewController.loadViewIfNeeded()

        if #available(iOS 26.0, *) {
            let treeNavigationController = try #require(
                splitViewController.viewController(for: UISplitViewController.Column.secondary) as? UINavigationController
            )
            let elementNavigationController = try #require(
                splitViewController.viewController(for: UISplitViewController.Column.inspector) as? UINavigationController
            )
            #expect(treeNavigationController.viewControllers.first === treeViewController)
            #expect(elementNavigationController.viewControllers.first === elementViewController)
            #expect(splitViewController.preferredDisplayMode == UISplitViewController.DisplayMode.secondaryOnly)
        } else {
            let treeNavigationController = try #require(
                splitViewController.viewController(for: UISplitViewController.Column.primary) as? UINavigationController
            )
            let elementNavigationController = try #require(
                splitViewController.viewController(for: UISplitViewController.Column.secondary) as? UINavigationController
            )
            #expect(treeNavigationController.viewControllers.first === treeViewController)
            #expect(elementNavigationController.viewControllers.first === elementViewController)
            #expect(splitViewController.preferredDisplayMode == UISplitViewController.DisplayMode.oneBesideSecondary)
        }
    }

    @Test
    func splitContainerInstallsSessionNavigationActions() throws {
        let splitViewController = DOMSplitViewController(context: makeWebInspectorContext())

        splitViewController.loadViewIfNeeded()

        let pickItem = try #require(splitViewController.navigationItem.trailingItemGroups.first?.barButtonItems.first)
        #expect(pickItem.accessibilityIdentifier == "WebInspector.DOM.PickButton")
        #expect(splitViewController.navigationItem.additionalOverflowItems != nil)
        #expect(splitViewController.canBecomeFirstResponder)
        #expect(domNavigationKeyCommandSpecs(splitViewController.keyCommands) == expectedDOMNavigationKeyCommandSpecs)
    }

    private struct PropertySpec {
        var name: String
        var value: String
        var text: String
        var status: CSS.Status
    }

    private struct BodyStyleIDs {
        var margin: CSSStyleProperty.ID
        var boxSizing: CSSStyleProperty.ID
        var fontSize: CSSStyleProperty.ID
    }

    private struct DOMNavigationKeyCommandSpec: Hashable {
        var input: String?
        var modifierFlags: UIKeyModifierFlags.RawValue
    }

    private var expectedDOMNavigationKeyCommandSpecs: Set<DOMNavigationKeyCommandSpec> {
        [
            DOMNavigationKeyCommandSpec(input: "z", modifierFlags: UIKeyModifierFlags.command.rawValue),
            DOMNavigationKeyCommandSpec(input: "z", modifierFlags: UIKeyModifierFlags([.command, .shift]).rawValue),
            DOMNavigationKeyCommandSpec(input: "r", modifierFlags: UIKeyModifierFlags.command.rawValue),
            DOMNavigationKeyCommandSpec(input: UIKeyCommand.inputDelete, modifierFlags: UIKeyModifierFlags().rawValue),
            DOMNavigationKeyCommandSpec(input: "c", modifierFlags: UIKeyModifierFlags([.command, .shift]).rawValue),
        ]
    }

    private func domNavigationKeyCommandSpecs(_ commands: [UIKeyCommand]?) -> Set<DOMNavigationKeyCommandSpec> {
        Set((commands ?? []).map { command in
            DOMNavigationKeyCommandSpec(
                input: command.input,
                modifierFlags: command.modifierFlags.rawValue
            )
        })
    }

    private func makeWebInspectorContext() -> WebInspectorContext {
        WebInspectorContext.preview(isolation: MainActor.shared)
    }

    private struct LiveDOMContextFixture {
        var runtime: WebInspectorProxyTestRuntime
        var context: WebInspectorContext
    }

    private func makeLiveDOMContext(document: DOM.Node? = nil) async throws -> LiveDOMContextFixture {
        let runtime = try await WebInspectorProxyTestRuntime.start()
        let target = try await runtime.proxy.waitForCurrentPage()
        await enqueueLiveStartupReplies(on: runtime.backend, document: document ?? documentNode())
        let container = WebInspectorContainer(proxy: runtime.proxy)
        let context = container.mainContext
        try await waitForLiveStartupSubscribers(runtime: runtime, target: target)
        let didAttach = await waitForAttachedState(in: context)
        try #require(didAttach)
        return LiveDOMContextFixture(runtime: runtime, context: context)
    }

    private func enqueueLiveStartupReplies(on backend: WebInspectorTestBackend, document: DOM.Node) async {
        await backend.enqueue((), for: "Inspector", method: "enable")
        await backend.enqueue((), for: "Inspector", method: "initialized")
        await backend.enqueue((), for: "Page", method: "enable")
        await backend.enqueue((), for: "Runtime", method: "enable")
        await backend.enqueue((), for: "Network", method: "enable")
        await backend.enqueue(document, for: "DOM", method: "getDocument")
        await backend.enqueue((), for: "Console", method: "enable")
    }

    private func waitForLiveStartupSubscribers(
        runtime: WebInspectorProxyTestRuntime,
        target: WebInspectorTarget
    ) async throws {
        try await runtime.backend.waitForSubscribers(domain: "DOM", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Inspector", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "CSS", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Network", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Console", target: target, count: 1)
        try await runtime.backend.waitForSubscribers(domain: "Runtime", target: target, count: 1)
    }

    private func waitForAttachedState(in context: WebInspectorContext) async -> Bool {
        if context.state == .attached {
            return true
        }
        for await status in context.statusUpdates {
            if status.state == .attached {
                return true
            }
            if status.state != .attaching {
                return false
            }
        }
        return context.state == .attached
    }

    private func waitForDOMRedoAvailability(_ isAvailable: Bool, undoManager: UndoManager?) async -> Bool {
        await DOMDeletionUndoRegistration.waitForRedoAvailabilityForTesting(isAvailable, on: undoManager)
    }

    private func recordedDOMCommands(
        on backend: WebInspectorTestBackend,
        method: String,
        count: Int
    ) async -> [RecordedCommand] {
        await backend.waitForRecordedCommands(domain: "DOM", method: method, count: count)
    }

    private func enqueueDOMRemoveNodeWithUndoMark(on backend: WebInspectorTestBackend) async {
        await backend.enqueue((), for: "DOM", method: "removeNode")
        await backend.enqueue((), for: "DOM", method: "markUndoableState")
    }

    private func makeElementContext() -> WebInspectorContext {
        let context = makeWebInspectorContext()
        context.seedDOMDocument(documentNode())
        return context
    }

    private func makeElementViewController(context: WebInspectorContext) -> DOMElementViewController {
        let viewController = DOMElementViewController(context: context)
        viewController.disablesSnapshotAnimationsForTesting = true
        return viewController
    }

    private func selectElement(named localName: String, in context: WebInspectorContext) throws -> DOMNode {
        let node = try #require(DOMPreviewFixtures.firstElement(named: localName, in: context))
        context.select(node)
        return node
    }

    @discardableResult
    private func applyBodyStyles(
        to context: WebInspectorContext,
        selector: String = "body",
        sourceURL: String = "styles.css",
        sourceLine: Int = 1,
        marginValue: String = "0",
        marginText: String = "margin: 0;"
    ) -> BodyStyleIDs {
        let styleID = "test-style"
        let cssText = "\(marginText)\n/* box-sizing: border-box; */\nfont-size: 12px;"
        let style = CSS.Style(
            id: CSS.Style.ID(styleID),
            properties: [
                CSS.Property(
                    id: CSS.Property.ID("\(styleID):0"),
                    name: "margin",
                    value: marginValue,
                    text: marginText,
                    status: .active
                ),
                CSS.Property(
                    id: CSS.Property.ID("\(styleID):1"),
                    name: "box-sizing",
                    value: "border-box",
                    text: "/* box-sizing: border-box; */",
                    status: .disabled
                ),
                CSS.Property(
                    id: CSS.Property.ID("\(styleID):2"),
                    name: "font-size",
                    value: "12px",
                    text: "font-size: 12px;",
                    status: .inactive
                ),
            ],
            cssText: cssText,
            isEditable: true
        )
        context.seedSelectedNodeStyles(
            matchedStyles: CSS.MatchedStyles(matchedRules: [
                CSS.Rule(
                    id: CSS.Rule.ID("test-rule"),
                    selectorList: CSS.Rule.SelectorList(
                        selectors: [selector],
                        text: selector
                    ),
                    sourceURL: sourceURL,
                    sourceLine: sourceLine,
                    origin: CSS.Origin(rawValue: "author"),
                    style: style
                ),
            ])
        )
        return BodyStyleIDs(
            margin: CSSStyleProperty.ID("\(styleID):0"),
            boxSizing: CSSStyleProperty.ID("\(styleID):1"),
            fontSize: CSSStyleProperty.ID("\(styleID):2")
        )
    }

    private func applyInheritedVariableStyles(
        to context: WebInspectorContext,
        bodyColorValue: String = "var(--foreground)",
        foregroundValue: String = "var(--palette-primary)",
        additionalBodyProperties: [PropertySpec] = [],
        additionalRootProperties: [PropertySpec] = []
    ) {
        let bodyProperties = [
            PropertySpec(
                name: "color",
                value: bodyColorValue,
                text: "color: \(bodyColorValue);",
                status: .active
            ),
        ] + additionalBodyProperties
        let rootProperties = [
            PropertySpec(
                name: "--foreground",
                value: foregroundValue,
                text: "--foreground: \(foregroundValue);",
                status: .active
            ),
            PropertySpec(
                name: "--palette-primary",
                value: "#111",
                text: "--palette-primary: #111;",
                status: .active
            ),
            PropertySpec(
                name: "--unused-a",
                value: "red",
                text: "--unused-a: red;",
                status: .active
            ),
            PropertySpec(
                name: "--unused-b",
                value: "blue",
                text: "--unused-b: blue;",
                status: .active
            ),
        ] + additionalRootProperties

        context.seedSelectedNodeStyles(
            matchedStyles: CSS.MatchedStyles(
                matchedRules: [
                    CSS.Rule(
                        id: CSS.Rule.ID("variables-rule-body"),
                        selectorList: CSS.Rule.SelectorList(
                            selectors: ["body"],
                            text: "body"
                        ),
                        sourceURL: "variables.css",
                        sourceLine: 12,
                        origin: CSS.Origin(rawValue: "author"),
                        style: makeStyle(id: "variables-body", properties: bodyProperties)
                    ),
                ],
                inherited: [
                    CSS.MatchedStyles.InheritedEntry(matchedRules: [
                        CSS.Rule(
                            id: CSS.Rule.ID("variables-rule-root"),
                            selectorList: CSS.Rule.SelectorList(
                                selectors: [":root"],
                                text: ":root"
                            ),
                            sourceURL: "variables.css",
                            sourceLine: 1,
                            origin: CSS.Origin(rawValue: "author"),
                            style: makeStyle(id: "variables-root", properties: rootProperties)
                        ),
                    ]),
                ]
            )
        )
    }

    private func makeStyle(id: String, properties: [PropertySpec]) -> CSS.Style {
        CSS.Style(
            id: CSS.Style.ID(id),
            properties: properties.enumerated().map { index, spec in
                CSS.Property(
                    id: CSS.Property.ID("\(id):\(index)"),
                    name: spec.name,
                    value: spec.value,
                    text: spec.text,
                    status: spec.status
                )
            },
            cssText: properties.map(\.text).joined(separator: "\n"),
            isEditable: true
        )
    }

    private func documentNode() -> DOM.Node {
        DOM.Node(
            id: DOM.Node.ID("document"),
            nodeType: 9,
            nodeName: "#document",
            childNodeCount: 1,
            children: [
                DOM.Node(
                    id: DOM.Node.ID("html"),
                    nodeType: 1,
                    nodeName: "HTML",
                    localName: "html",
                    childNodeCount: 1,
                    children: [
                        DOM.Node(
                            id: DOM.Node.ID("body"),
                            nodeType: 1,
                            nodeName: "BODY",
                            localName: "body",
                            childNodeCount: 1,
                            children: [
                                DOM.Node(
                                    id: DOM.Node.ID("input"),
                                    nodeType: 1,
                                    nodeName: "INPUT",
                                    localName: "input"
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }

    private func multiDeleteDocumentNode() -> DOM.Node {
        DOM.Node(
            id: DOM.Node.ID("document"),
            nodeType: 9,
            nodeName: "#document",
            childNodeCount: 1,
            children: [
                DOM.Node(
                    id: DOM.Node.ID("html"),
                    nodeType: 1,
                    nodeName: "HTML",
                    localName: "html",
                    childNodeCount: 1,
                    children: [
                        DOM.Node(
                            id: DOM.Node.ID("body"),
                            nodeType: 1,
                            nodeName: "BODY",
                            localName: "body",
                            childNodeCount: 2,
                            children: [
                                DOM.Node(
                                    id: DOM.Node.ID("input"),
                                    nodeType: 1,
                                    nodeName: "INPUT",
                                    localName: "input"
                                ),
                                DOM.Node(
                                    id: DOM.Node.ID("button"),
                                    nodeType: 1,
                                    nodeName: "BUTTON",
                                    localName: "button",
                                    childNodeCount: 1,
                                    children: [
                                        DOM.Node(
                                            id: DOM.Node.ID("button-text"),
                                            nodeType: 3,
                                            nodeName: "#text",
                                            nodeValue: "Save"
                                        ),
                                    ]
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }

    private func waitForTargetMessage(
        _ backend: RecordingTransportBackend,
        method: String,
        timeout: Duration = .seconds(5),
        timeoutSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) async throws -> RecordedTargetMessage {
        try await withThrowingTaskGroup(of: RecordedTargetMessage.self) { group in
            defer {
                group.cancelAll()
            }

            group.addTask {
                try await backend.waitForTargetMessage(method: method)
            }
            group.addTask {
                try await timeoutSleep(timeout)
                throw TransportSession.Error.replyTimeout(method: method, targetID: nil)
            }

            guard let message = try await group.next() else {
                throw TransportSession.Error.replyTimeout(method: method, targetID: nil)
            }
            return message
        }
    }

    private struct RecordedTargetMessage: Sendable {
        var message: String
        var targetIdentifier: ProtocolTarget.ID
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

    private func showInWindow(
        _ viewController: UIViewController,
        useUIKitVisibility: Bool = true
    ) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        viewController.loadViewIfNeeded()
        if useUIKitVisibility {
            window.makeKeyAndVisible()
        } else {
            viewController.view.frame = window.bounds
            activateDOMRenderingForTesting(in: viewController)
        }
        window.layoutIfNeeded()
        return window
    }

    private func activateDOMRenderingForTesting(in viewController: UIViewController) {
        if let navigationController = viewController as? UINavigationController {
            for child in navigationController.viewControllers {
                activateDOMRenderingForTesting(in: child)
            }
            return
        }

        if let treeViewController = viewController as? DOMTreeViewController {
            treeViewController.displayedDOMTreeTextViewForTesting.setRenderingActive(true)
        }
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
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var generation = viewController.styleRenderGenerationForTesting
        while clock.now < deadline {
            if sampleRenderedCondition(in: viewController, condition: condition) {
                return true
            }

            let remainingTimeout = clock.now.duration(to: deadline)
            guard await viewController.waitForStyleRenderForTesting(
                after: generation,
                timeout: remainingTimeout
            ) else {
                return sampleRenderedCondition(in: viewController, condition: condition)
            }
            generation = viewController.styleRenderGenerationForTesting
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

private extension Array where Element == RecordedCommand {
    var domMutationUndoMethods: [String] {
        filter { command in
            command.domain == "DOM" && ["removeNode", "undo", "redo"].contains(command.method)
        }
        .map(\.method)
    }
}

private final class UndoRegistrationMarker: NSObject {}
#endif
