#if canImport(UIKit)
import Testing
import UIKit
import WebKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct DOMTreeTextViewTests {
    @Test
    func rendersWebInspectorMarkupInsteadOfBareNodeNames() throws {
        let view = makeTreeView()
        let text = view.renderedTextForTesting

        #expect(!text.contains("#document"))
        #expect(text.contains("<!DOCTYPE html>"))
        #expect(text.contains("<html lang=\"en\">"))
        #expect(text.contains("<head>...</head>"))
        #expect(text.contains("<body class=\"logged-in env-production\">"))
        #expect(text.contains("<section data-runtime=\"unknown-node-type\"></section>"))
        #expect(text.contains("<div id=\"start-of-content\" class=\"show-on-focus\" data-testid=\"cellInnerDiv\"></div>"))
        #expect(text.contains("<img src=\"/preview.webp\" alt=\"preview\">"))
        #expect(text.contains("<input disabled>"))
        #expect(text.contains("<article>...</article>"))
        #expect(!text.contains("<span id=\"nested-child\"></span>"))
        #expect(!text.contains("disabled=\"\""))
        #expect(text.contains("\"Introducing luma for iOS 26\""))
        #expect(text.contains("<!-- comment text -->"))
        #expect(!text.split(separator: "\n").contains("html"))
        #expect(!text.split(separator: "\n").contains("body"))
    }

    @Test
    func exposesTokenRangesAndKeepsDisclosureOutOfMarkup() throws {
        let view = makeTreeView()
        let lines = view.renderedLineSnapshotsForTesting
        let htmlLine = try #require(lines.first { $0.text.contains("<html") })
        let divLine = try #require(lines.first { $0.text.contains("data-testid") })

        #expect(htmlLine.depth == 0)
        #expect(htmlLine.markupRange.location == 2)
        #expect(htmlLine.disclosureRect.maxX <= htmlLine.markupStartX)
        #expect(divLine.disclosureRect.maxX <= divLine.markupStartX)
        #expect(divLine.tokenKinds.contains("punctuation"))
        #expect(divLine.tokenKinds.contains("tagName"))
        #expect(divLine.tokenKinds.contains("attributeName"))
        #expect(divLine.tokenKinds.contains("attributeValue"))
        #expect(divLine.tokenTexts.contains("div"))
        #expect(divLine.tokenTexts.contains("class"))
        #expect(divLine.tokenTexts.contains("show-on-focus"))
        #expect(divLine.tokenTexts.contains("data-testid"))
        #expect(divLine.tokenTexts.contains("cellInnerDiv"))
        let inferredElementLine = try #require(lines.first { $0.text.contains("unknown-node-type") })
        #expect(inferredElementLine.tokenKinds.contains("tagName"))
        #expect(inferredElementLine.tokenTexts.contains("section"))
    }

    @Test
    func selectedRowBackgroundSpansViewportWidth() throws {
        let view = makeTreeView(selectedLocalID: FixtureNodeID.input)
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 320)
        view.layoutIfNeeded()

        let selectedRect = try #require(view.selectedRowRectsForTesting().first)
        let inputLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("<input") })
        let textWidth = ceil((inputLine.text as NSString).size(withAttributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        ]).width)

        #expect(selectedRect.width >= 470)
        #expect(selectedRect.width > textWidth + 100)
        #expect(selectedRect.height > 0)
        #expect(selectedRect.height <= view.rowHeightForTesting)
        #expect(selectedRect.midY >= 0)
    }

    @Test
    func selectedRowBackgroundUsesTextKitHighlightVerticalGeometry() throws {
        for (localID, text) in [(FixtureNodeID.body, "<body"), (FixtureNodeID.input, "<input")] {
            let view = makeTreeView(selectedLocalID: localID)
            view.frame = CGRect(x: 0, y: 0, width: 500, height: 320)
            view.layoutIfNeeded()

            let selectedRect = try #require(view.selectedRowRectsForTesting().first)
            let textRect = try #require(view.textHighlightRectsForTesting(containing: text).first)

            #expect(abs(selectedRect.minY - textRect.minY) < 0.5)
            #expect(abs(selectedRect.midY - textRect.midY) < 0.5)
            #expect(abs(selectedRect.height - textRect.height) < 0.5)
        }
    }

    @Test
    func rowHitTestingUsesTextKitLineFragmentGeometry() throws {
        let view = makeTreeView()
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 320)
        view.layoutIfNeeded()

        let targetText = "<input disabled>"
        let targetRect = try #require(view.textHighlightRectsForTesting(containing: targetText).first)
        let hitText = try #require(
            view.hitTestedLineTextForTesting(
                atContentPoint: CGPoint(x: targetRect.midX, y: targetRect.midY)
            )
        )

        #expect(hitText.contains(targetText))
    }

    @Test
    func disclosureRowsUseTheSameLineHeightAsTextLayout() throws {
        let view = makeTreeView()
        let htmlLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("<html") })
        let bodyLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("<body") })
        let attachmentSnapshots = view.disclosureAttachmentSnapshotsForTesting

        #expect(view.paragraphLineHeightForTesting == view.rowHeightForTesting)
        #expect(htmlLine.disclosureRect.midY == CGFloat(htmlLine.rowIndex) * view.rowHeightForTesting + view.rowHeightForTesting / 2)
        #expect(bodyLine.disclosureRect.midY == CGFloat(bodyLine.rowIndex) * view.rowHeightForTesting + view.rowHeightForTesting / 2)
        #expect(attachmentSnapshots.count == view.renderedLineSnapshotsForTesting.filter(\.hasDisclosure).count)
        #expect(attachmentSnapshots.contains { $0.expectedColumn > 0 })
        #expect(attachmentSnapshots.allSatisfy { $0.column == $0.expectedColumn })
    }

    @Test
    func loadedChildrenKeepDisclosureWhenChildCountTemporarilyDrops() throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeDocumentNode()))
        let view = makeTreeView(runtime: runtime)

        runtime.document.applyMutationBundle(
            DOMGraphMutationBundle(
                events: [
                    .childNodeCountUpdated(
                        nodeLocalID: FixtureNodeID.article,
                        childCount: 0,
                        layoutFlags: nil,
                        isRendered: nil
                    ),
                ]
            )
        )
        view.synchronizeDocumentForTesting()

        let articleLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("<article") })
        #expect(articleLine.hasDisclosure)
        #expect(articleLine.text.contains("<article>...</article>"))
    }

    @Test
    func unknownChildCountElementKeepsDisclosureUntilConfirmedEmpty() throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeUnknownChildCountDocumentNode()))
        let view = makeTreeView(runtime: runtime)

        var articleLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("<article") })
        #expect(articleLine.hasDisclosure)
        #expect(articleLine.text.contains("<article>...</article>"))

        runtime.document.applyMutationBundle(
            DOMGraphMutationBundle(
                events: [
                    .setChildNodes(parentLocalID: FixtureNodeID.article, nodes: []),
                ]
            )
        )
        view.synchronizeDocumentForTesting()

        articleLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("<article") })
        #expect(!articleLine.hasDisclosure)
        #expect(articleLine.text.contains("<article></article>"))
    }

    @Test
    func dynamicReloadClearsOldFragmentSurfacesBeforeRelayout() {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeDocumentNode()))
        let view = makeTreeView(runtime: runtime)

        #expect(view.fragmentSubviewCountForTesting > 0)

        runtime.document.applyMutationBundle(
            DOMGraphMutationBundle(
                events: [
                    .attributeModified(
                        nodeLocalID: FixtureNodeID.div,
                        name: "data-dynamic",
                        value: "1",
                        layoutFlags: nil,
                        isRendered: nil
                    ),
                ]
            )
        )
        view.synchronizeDocumentForTesting()

        #expect(view.fragmentSubviewCountForTesting == 0)

        view.layoutIfNeeded()

        #expect(view.fragmentSubviewCountForTesting > 0)
    }

    @Test
    func loadingDocumentStateClearsRenderedRows() {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeDocumentNode()))
        let view = makeTreeView(runtime: runtime)

        #expect(view.renderedTextForTesting.contains("<html"))
        #expect(view.rowCountForTesting > 0)

        runtime.document.beginLoadingDocument(isFreshDocument: true)
        view.synchronizeDocumentForTesting()

        #expect(view.renderedTextForTesting.isEmpty)
        #expect(view.rowCountForTesting == 0)
    }

    @Test
    func usesWebInspectorDynamicHighlightColors() throws {
        let lightTag = try #require(DOMTreeTextView.tokenColorForTesting(kind: "tagName", style: .light))
        let darkTag = try #require(DOMTreeTextView.tokenColorForTesting(kind: "tagName", style: .dark))
        let darkAttributeName = try #require(DOMTreeTextView.tokenColorForTesting(kind: "attributeName", style: .dark))
        let darkAttributeValue = try #require(DOMTreeTextView.tokenColorForTesting(kind: "attributeValue", style: .dark))
        let darkSelectedRow = DOMTreeTextView.selectedRowBackgroundColorForTesting(style: .dark)
        let lightDisclosure = DOMTreeTextView.disclosureColorForTesting(style: .light)
        let darkDisclosure = DOMTreeTextView.disclosureColorForTesting(style: .dark)
        let expectedLightDisclosure = UIColor.systemGray.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
        let expectedDarkDisclosure = UIColor.systemGray.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark)
        )

        #expect(lightTag.wiHexRGBForTesting == "0F6BDC")
        #expect(darkTag.wiHexRGBForTesting == "32D4FF")
        #expect(darkAttributeName.wiHexRGBForTesting == "EC9EFF")
        #expect(darkAttributeValue.wiHexRGBForTesting == "FFD479")
        #expect(lightDisclosure.wiHexRGBForTesting == expectedLightDisclosure.wiHexRGBForTesting)
        #expect(darkDisclosure.wiHexRGBForTesting == expectedDarkDisclosure.wiHexRGBForTesting)
        #expect(abs(darkSelectedRow.wiAlphaForTesting - 0.35) < 0.01)
    }

    @Test
    func pickerSelectionOpensAncestorRowsToRevealSelectedNode() throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeDocumentNode()))
        let view = makeTreeView(runtime: runtime)
        let previousHorizontalOffset = max(0, view.contentSize.width - view.bounds.width)
        view.contentOffset.x = previousHorizontalOffset

        #expect(view.renderedTextForTesting.contains("<article>...</article>"))
        #expect(!view.renderedTextForTesting.contains("<span id=\"nested-child\"></span>"))
        #expect(previousHorizontalOffset > 0)

        runtime.document.applySelectionSnapshot(
            DOMSelectionSnapshotPayload(
                localID: FixtureNodeID.nestedSpan,
                backendNodeID: Int(FixtureNodeID.nestedSpan),
                attributes: [DOMAttribute(name: "id", value: "nested-child")],
                path: ["html", "body", "article", "span"],
                selectorPath: "article > span",
                styleRevision: 0
            )
        )
        view.synchronizeDocumentForTesting()
        view.layoutIfNeeded()

        let text = view.renderedTextForTesting
        let lines = view.renderedLineSnapshotsForTesting
        let articleLine = try #require(lines.first { $0.text.contains("<article>") })
        let spanLine = try #require(lines.first { $0.text.contains("<span id=\"nested-child\"") })

        #expect(text.contains("<span id=\"nested-child\"></span>"))
        #expect(!text.contains("<article>...</article>"))
        #expect(spanLine.depth == articleLine.depth + 1)
        #expect(view.selectedRowRectsForTesting().count == 1)
        #expect(view.contentOffset.x < previousHorizontalOffset)
        #expect(view.contentOffset.x <= spanLine.markupStartX)
    }

    @Test
    func findDecorationsAndContextMenuUseRenderedMarkup() {
        let view = makeTreeView()

        view.decorateFindTextForTesting(query: "data-testid")

        #expect(view.findHighlightedRangesForTesting.count == 1)
        #expect(view.findFoundRangesForTesting.count + view.findHighlightedRangesForTesting.count >= 1)
        #expect(
            view.contextMenuTitlesForTesting(containing: "data-testid") == [
                "Copy HTML",
                "Copy Selector Path",
                "Copy XPath",
                "Delete Node",
            ]
        )
    }

    @Test
    func shiftClickSelectsContiguousRowsFromTheAnchor() throws {
        let view = makeTreeView()

        view.primaryClickRowForTesting(containing: "<div id=\"start-of-content\"")
        view.primaryClickRowForTesting(containing: "<input disabled>", modifiers: .shift)

        #expect(view.multiSelectedLocalIDsForTesting == [
            FixtureNodeID.div,
            FixtureNodeID.unknownElement,
            FixtureNodeID.image,
            FixtureNodeID.input,
        ])
    }

    @Test
    func repeatedShiftClickReplacesPreviousShiftRangeButKeepsCommandSelection() throws {
        let view = makeTreeView()

        view.primaryClickRowForTesting(containing: "<!DOCTYPE", modifiers: .command)
        view.primaryClickRowForTesting(containing: "<div id=\"start-of-content\"", modifiers: .command)
        view.primaryClickRowForTesting(containing: "<input disabled>", modifiers: .shift)
        view.primaryClickRowForTesting(containing: "<article>", modifiers: .shift)

        #expect(view.multiSelectedLocalIDsForTesting == [
            FixtureNodeID.doctype,
            FixtureNodeID.div,
            FixtureNodeID.unknownElement,
            FixtureNodeID.image,
            FixtureNodeID.input,
            FixtureNodeID.article,
        ])
    }

    @Test
    func shiftClickWithoutAnAnchorSelectsFromTheFirstRenderedRow() throws {
        let view = makeTreeView()

        view.primaryClickRowForTesting(containing: "<body", modifiers: .shift)

        #expect(view.multiSelectedLocalIDsForTesting == [
            FixtureNodeID.doctype,
            FixtureNodeID.html,
            FixtureNodeID.head,
            FixtureNodeID.body,
        ])
    }

    @Test
    func commandClickBuildsNonContiguousSelectionWithoutChangingDisclosureState() throws {
        let view = makeTreeView()

        view.primaryClickRowForTesting(containing: "<body")
        view.primaryClickRowForTesting(containing: "<div id=\"start-of-content\"", modifiers: .command)
        view.primaryClickRowForTesting(containing: "<input disabled>", modifiers: .command)

        #expect(view.multiSelectedLocalIDsForTesting == [
            FixtureNodeID.body,
            FixtureNodeID.div,
            FixtureNodeID.input,
        ])
        let bodyLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("<body") })
        #expect(bodyLine.isOpen)
    }

    @Test
    func secondaryClickInsideMultipleSelectionPreservesSelectionAndShowsMultiNodeMenu() {
        let view = makeTreeView()

        view.primaryClickRowForTesting(containing: "<div id=\"start-of-content\"")
        view.primaryClickRowForTesting(containing: "<input disabled>", modifiers: .shift)
        let titles = view.secondaryClickMenuTitlesForTesting(containing: "<img src=")

        #expect(titles == ["Copy HTML", "Delete Nodes"])
        #expect(view.multiSelectedLocalIDsForTesting == [
            FixtureNodeID.div,
            FixtureNodeID.unknownElement,
            FixtureNodeID.image,
            FixtureNodeID.input,
        ])
    }

    @Test
    func secondaryClickOutsideMultipleSelectionClearsSelectionAndShowsSingleNodeMenu() {
        let view = makeTreeView()

        view.primaryClickRowForTesting(containing: "<div id=\"start-of-content\"")
        view.primaryClickRowForTesting(containing: "<input disabled>", modifiers: .shift)
        let titles = view.secondaryClickMenuTitlesForTesting(containing: "<article>")

        #expect(titles == [
            "Copy HTML",
            "Copy Selector Path",
            "Copy XPath",
            "Delete Node",
        ])
        #expect(view.multiSelectedLocalIDsForTesting.isEmpty)
    }

    @Test
    func primaryClickClearsTextSelectionWithoutPresentingDOMMenu() {
        let view = makeTreeView()

        view.selectTextForTesting("data-testid")
        view.primaryClickRowForTesting(containing: "<input disabled>")

        #expect(view.selectedTextForTesting.isEmpty)
        #expect(view.lastPresentedDOMMenuTitlesForTesting.isEmpty)
    }

    @Test
    func customTextInputExposesRenderedTextSelection() {
        let view = makeTreeView()

        view.selectTextForTesting("data-testid")

        #expect(view.selectedTextForTesting == "data-testid")
        #expect(view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
    }

    @Test
    func singleLineTextSelectionEditMenuUsesCustomCopyAndNodeActions() {
        let view = makeTreeView()

        view.selectTextForTesting("data-testid")
        let titles = view.editMenuTitlesForSelectedTextForTesting()

        #expect(titles == [
            "Copy",
            "Copy HTML",
            "Copy Selector Path",
            "Copy XPath",
            "Delete Node",
        ])
        #expect(!titles.contains("Translate"))
        #expect(!titles.contains("Share..."))
    }

    @Test
    func multiLineTextSelectionEditMenuUsesOnlyMultiNodeActions() {
        let view = makeTreeView()

        view.selectTextForTesting(from: "<div id=\"start-of-content\"", through: "<input disabled>")
        let titles = view.editMenuTitlesForSelectedTextForTesting()

        #expect(titles == ["Copy HTML", "Delete Nodes"])
        #expect(!titles.contains("Copy"))
        #expect(!titles.contains("Copy Selector Path"))
        #expect(!titles.contains("Copy XPath"))
        #expect(!titles.contains("Translate"))
        #expect(!titles.contains("Share..."))
    }

    @Test
    func treeViewControllerHostsNativeTextViewInsteadOfWebView() {
        let viewController = DOMTreeViewController(dom: WIDOMRuntime())
        viewController.loadViewIfNeeded()

        #expect(viewController.view === viewController.displayedDOMTreeTextViewForTesting)
        #expect(!containsWKWebView(in: viewController.view))
    }

    private func makeTreeView(selectedLocalID: UInt64? = nil) -> DOMTreeTextView {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(
            with: .init(root: makeDocumentNode(), selectedLocalID: selectedLocalID)
        )
        return makeTreeView(runtime: runtime)
    }

    private func makeTreeView(runtime: WIDOMRuntime) -> DOMTreeTextView {
        let view = DOMTreeTextView(dom: runtime)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        return view
    }

    private func makeDocumentNode() -> DOMGraphNodeDescriptor {
        makeNode(
            localID: FixtureNodeID.document,
            type: .document,
            nodeName: "#document",
            localName: "",
            children: [
                makeNode(
                    localID: FixtureNodeID.doctype,
                    type: .documentType,
                    nodeName: "html",
                    localName: ""
                ),
                makeNode(
                    localID: FixtureNodeID.html,
                    nodeName: "HTML",
                    localName: "html",
                    attributes: [DOMAttribute(name: "lang", value: "en")],
                    children: [
                        makeNode(
                            localID: FixtureNodeID.head,
                            nodeName: "HEAD",
                            localName: "head",
                            children: [
                                makeNode(
                                    localID: FixtureNodeID.title,
                                    nodeName: "TITLE",
                                    localName: "title"
                                ),
                            ]
                        ),
                        makeNode(
                            localID: FixtureNodeID.body,
                            nodeName: "BODY",
                            localName: "body",
                            attributes: [DOMAttribute(name: "class", value: "logged-in env-production")],
                            children: [
                                makeNode(
                                    localID: FixtureNodeID.div,
                                    nodeName: "DIV",
                                    localName: "div",
                                    attributes: [
                                        DOMAttribute(name: "id", value: "start-of-content"),
                                        DOMAttribute(name: "class", value: "show-on-focus"),
                                        DOMAttribute(name: "data-testid", value: "cellInnerDiv"),
                                    ]
                                ),
                                makeNode(
                                    localID: FixtureNodeID.unknownElement,
                                    type: .unknown,
                                    nodeName: "SECTION",
                                    localName: "section",
                                    attributes: [
                                        DOMAttribute(name: "data-runtime", value: "unknown-node-type"),
                                    ]
                                ),
                                makeNode(
                                    localID: FixtureNodeID.image,
                                    nodeName: "IMG",
                                    localName: "img",
                                    attributes: [
                                        DOMAttribute(name: "src", value: "/preview.webp"),
                                        DOMAttribute(name: "alt", value: "preview"),
                                    ]
                                ),
                                makeNode(
                                    localID: FixtureNodeID.input,
                                    nodeName: "INPUT",
                                    localName: "input",
                                    attributes: [DOMAttribute(name: "disabled", value: "")]
                                ),
                                makeNode(
                                    localID: FixtureNodeID.article,
                                    nodeName: "ARTICLE",
                                    localName: "article",
                                    children: [
                                        makeNode(
                                            localID: FixtureNodeID.nestedSpan,
                                            nodeName: "SPAN",
                                            localName: "span",
                                            attributes: [DOMAttribute(name: "id", value: "nested-child")]
                                        ),
                                    ]
                                ),
                                makeNode(
                                    localID: FixtureNodeID.text,
                                    type: .text,
                                    nodeName: "#text",
                                    localName: "",
                                    nodeValue: "\n  Introducing luma for iOS 26\t"
                                ),
                                makeNode(
                                    localID: FixtureNodeID.comment,
                                    type: .comment,
                                    nodeName: "#comment",
                                    localName: "",
                                    nodeValue: "comment text"
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }

    private func makeUnknownChildCountDocumentNode() -> DOMGraphNodeDescriptor {
        makeNode(
            localID: FixtureNodeID.document,
            type: .document,
            nodeName: "#document",
            localName: "",
            children: [
                makeNode(
                    localID: FixtureNodeID.html,
                    nodeName: "HTML",
                    localName: "html",
                    children: [
                        makeNode(
                            localID: FixtureNodeID.body,
                            nodeName: "BODY",
                            localName: "body",
                            children: [
                                makeNode(
                                    localID: FixtureNodeID.article,
                                    nodeName: "ARTICLE",
                                    localName: "article",
                                    childCount: 0,
                                    childCountIsKnown: false
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }

    private func makeNode(
        localID: UInt64,
        type: DOMNodeType = .element,
        nodeName: String = "DIV",
        localName: String = "div",
        nodeValue: String = "",
        attributes: [DOMAttribute] = [],
        children: [DOMGraphNodeDescriptor] = [],
        childCount: Int? = nil,
        childCountIsKnown: Bool = true
    ) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            localID: localID,
            backendNodeID: Int(localID),
            nodeType: type,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            attributes: attributes,
            childCount: childCount ?? children.count,
            childCountIsKnown: childCountIsKnown,
            layoutFlags: [],
            isRendered: true,
            children: children
        )
    }

    private func containsWKWebView(in view: UIView) -> Bool {
        if view is WKWebView {
            return true
        }
        return view.subviews.contains { containsWKWebView(in: $0) }
    }
}

private enum FixtureNodeID {
    static let document: UInt64 = 1
    static let doctype: UInt64 = 2
    static let html: UInt64 = 3
    static let head: UInt64 = 4
    static let title: UInt64 = 5
    static let body: UInt64 = 6
    static let div: UInt64 = 7
    static let unknownElement: UInt64 = 8
    static let image: UInt64 = 9
    static let input: UInt64 = 10
    static let article: UInt64 = 11
    static let nestedSpan: UInt64 = 12
    static let text: UInt64 = 13
    static let comment: UInt64 = 14
}

private extension UIColor {
    var wiHexRGBForTesting: String {
        let components = wiRGBAComponentsForTesting
        let value = (Int(round(components.red * 255)) << 16)
            | (Int(round(components.green * 255)) << 8)
            | Int(round(components.blue * 255))
        let hex = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 6 - hex.count)) + hex
    }

    var wiAlphaForTesting: CGFloat {
        wiRGBAComponentsForTesting.alpha
    }

    private var wiRGBAComponentsForTesting: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let color = colorSpace.flatMap {
            cgColor.converted(to: $0, intent: .defaultIntent, options: nil)
        } ?? cgColor
        let components = color.components ?? []
        if components.count >= 4 {
            return (components[0], components[1], components[2], components[3])
        }
        if components.count >= 2 {
            return (components[0], components[0], components[0], components[1])
        }
        return (0, 0, 0, color.alpha)
    }
}
#endif
