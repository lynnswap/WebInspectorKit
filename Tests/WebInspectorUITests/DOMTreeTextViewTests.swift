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
        #expect(text.contains("<head>…</head>"))
        #expect(text.contains("<body class=\"logged-in env-production\">"))
        #expect(text.contains("<section data-runtime=\"unknown-node-type\"></section>"))
        #expect(text.contains("<div id=\"start-of-content\" class=\"show-on-focus\" data-testid=\"cellInnerDiv\"></div>"))
        #expect(text.contains("<img src=\"/preview.webp\" alt=\"preview\">"))
        #expect(text.contains("<input disabled>"))
        #expect(text.contains("<article>…</article>"))
        #expect(!text.contains("<span id=\"nested-child\"></span>"))
        #expect(!text.contains("disabled=\"\""))
        #expect(text.contains("\"Introducing luma for iOS 26\""))
        #expect(text.contains("<!-- comment text -->"))
        #expect(!text.split(separator: "\n").contains("html"))
        #expect(!text.split(separator: "\n").contains("body"))
    }

    @Test
    func exposesTokenRangesAndKeepsDisclosureAttachmentOutOfMarkup() throws {
        let view = makeTreeView()
        let lines = view.renderedLineSnapshotsForTesting
        let htmlLine = try #require(lines.first { $0.text.contains("<html") })
        let divLine = try #require(lines.first { $0.text.contains("data-testid") })
        let attachmentSnapshots = view.disclosureAttachmentSnapshotsForTesting

        #expect(htmlLine.depth == 0)
        #expect(htmlLine.markupRange.location == 2)
        #expect(attachmentSnapshots.allSatisfy { $0.hasAttachment })
        #expect(attachmentSnapshots.allSatisfy { $0.slotRect.maxX <= $0.markupStartX })
        #expect(attachmentSnapshots.contains { $0.attachmentRange.location < htmlLine.textRange.location + htmlLine.markupRange.location })
        #expect(attachmentSnapshots.contains { $0.attachmentRange.location < divLine.textRange.location + divLine.markupRange.location })
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
        let view = makeTreeView(selectedNodeID: FixtureNodeID.input)
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
        for (nodeID, text) in [(FixtureNodeID.body, "<body"), (FixtureNodeID.input, "<input")] {
            let view = makeTreeView(selectedNodeID: nodeID)
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
    func contentWidthDoesNotClipFullWidthRenderedText() throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeWideGlyphDocumentNode()))
        let view = makeTreeView(runtime: runtime)
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 320)
        view.layoutIfNeeded()

        let wideLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("data-title") })
        let renderedWidth = ceil((wideLine.text as NSString).size(withAttributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        ]).width)

        #expect(view.contentSize.width >= renderedWidth)
    }

    @Test
    func disclosureAttachmentsUseTextKitLineGeometry() throws {
        let view = makeTreeView()
        let attachmentSnapshots = view.disclosureAttachmentSnapshotsForTesting

        #expect(view.paragraphLineHeightForTesting == view.rowHeightForTesting)
        #expect(attachmentSnapshots.count == view.renderedLineSnapshotsForTesting.filter(\.hasDisclosure).count)
        #expect(attachmentSnapshots.allSatisfy { $0.hasAttachment })
        #expect(attachmentSnapshots.allSatisfy { $0.rowRect.contains(CGPoint(x: $0.slotRect.midX, y: $0.slotRect.midY)) })
        #expect(attachmentSnapshots.allSatisfy { $0.slotRect.minY >= $0.rowRect.minY })
        #expect(attachmentSnapshots.allSatisfy { $0.slotRect.maxY <= $0.rowRect.maxY })
        #expect(attachmentSnapshots.contains { $0.isOpen })
        #expect(attachmentSnapshots.contains { !$0.isOpen })
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
                        nodeKey: key(FixtureNodeID.article),
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
        #expect(articleLine.text.contains("<article>…</article>"))
    }

    @Test
    func unknownChildCountElementKeepsDisclosureUntilConfirmedEmpty() throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeUnknownChildCountDocumentNode()))
        let view = makeTreeView(runtime: runtime)

        var articleLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("<article") })
        #expect(articleLine.hasDisclosure)
        #expect(articleLine.text.contains("<article>…</article>"))

        runtime.document.applyMutationBundle(
            DOMGraphMutationBundle(
                events: [
                    .setChildNodes(parentKey: key(FixtureNodeID.article), nodes: []),
                ]
            )
        )
        view.synchronizeDocumentForTesting()

        articleLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("<article") })
        #expect(!articleLine.hasDisclosure)
        #expect(articleLine.text.contains("<article></article>"))
    }

    @Test
    func knownChildCountElementRemovesDisclosureWhenLoadedEmpty() throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeDeferredChildDocumentNode()))
        let view = makeTreeView(runtime: runtime)

        var articleLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("<article") })
        #expect(articleLine.hasDisclosure)
        #expect(articleLine.text.contains("<article>…</article>"))

        runtime.document.applyMutationBundle(
            DOMGraphMutationBundle(
                events: [
                    .setChildNodes(parentKey: key(FixtureNodeID.article), nodes: []),
                ]
            )
        )
        view.synchronizeDocumentForTesting()

        articleLine = try #require(view.renderedLineSnapshotsForTesting.first { $0.text.contains("<article") })
        #expect(!articleLine.hasDisclosure)
        #expect(articleLine.text.contains("<article></article>"))
    }

    @Test
    func expandedElementRendersClosingTagRowAndLeavesEmptyChildInline() throws {
        let view = makeTreeView()

        view.toggleRowForTesting(containing: "<article")

        let lines = view.renderedLineSnapshotsForTesting
        let articleIndex = try #require(lines.firstIndex { $0.text.contains("<article") })
        let childIndex = articleIndex + 1
        let closeIndex = articleIndex + 2
        #expect(lines.indices.contains(childIndex))
        #expect(lines.indices.contains(closeIndex))

        #expect(lines[articleIndex].hasDisclosure)
        #expect(lines[articleIndex].isOpen)
        #expect(lines[articleIndex].text.contains("<article>"))
        #expect(!lines[articleIndex].text.contains("</article>"))

        #expect(lines[childIndex].text.contains("<span id=\"nested-child\"></span>"))
        #expect(!lines[childIndex].hasDisclosure)
        #expect(!lines[childIndex].isClosingTag)

        #expect(lines[closeIndex].text.contains("</article>"))
        #expect(!lines[closeIndex].hasDisclosure)
        #expect(lines[closeIndex].isClosingTag)
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
                        nodeKey: key(FixtureNodeID.div),
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
    func selectionOnlyChangeUpdatesDecorationsWithoutRebuildingTextStorage() async throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeDocumentNode()))
        let view = makeTreeView(runtime: runtime)
        await waitForObservationDelivery()
        view.resetPerformanceCountersForTesting()

        runtime.document.applySelectionSnapshot(
            DOMSelectionSnapshotPayload(
                key: key(FixtureNodeID.html),
                attributes: [DOMAttribute(name: "lang", value: "en")],
                path: ["html"],
                selectorPath: "html",
                styleRevision: 0
            )
        )
        await waitForObservationDelivery()
        view.layoutIfNeeded()

        #expect(view.reloadTreeCallCountForTesting == 0)
        #expect(view.rebuildTextStorageCallCountForTesting == 0)
        #expect(view.selectedRowRectsForTesting().count == 1)
        #expect(view.renderedTextForTesting.contains("<html lang=\"en\">"))
    }

    @Test
    func selectionChangeReloadsWhenSelectedRowIndexIsStale() async throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeDocumentNode()))
        let view = makeTreeView(runtime: runtime)
        await waitForObservationDelivery()
        view.removeRowIndexForTesting(containing: "<input disabled>")
        view.resetPerformanceCountersForTesting()

        runtime.document.applySelectionSnapshot(
            DOMSelectionSnapshotPayload(
                key: key(FixtureNodeID.input),
                attributes: [DOMAttribute(name: "disabled", value: "")],
                path: ["html", "body", "input"],
                selectorPath: "input",
                styleRevision: 0
            )
        )

        #expect(await waitUntilReloadCount(1, in: view))
        #expect(view.reloadTreeCallCountForTesting == 1)
        #expect(view.rebuildTextStorageCallCountForTesting == 0)
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func documentSelectionClearsStaleMultiSelectionForSameSelectedNode() async throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(
            with: .init(root: makeDocumentNode(), selectedKey: key(FixtureNodeID.input))
        )
        let view = makeTreeView(runtime: runtime)
        await waitForObservationDelivery()

        view.primaryClickRowForTesting(containing: "<div id=\"start-of-content\"")
        view.primaryClickRowForTesting(containing: "<input disabled>", modifiers: .shift)

        #expect(view.multiSelectedNodeIDsForTesting == [
            FixtureNodeID.div,
            FixtureNodeID.unknownElement,
            FixtureNodeID.image,
            FixtureNodeID.input,
        ])
        #expect(view.selectedRowRectsForTesting().isEmpty)

        runtime.document.applySelectionSnapshot(
            DOMSelectionSnapshotPayload(
                key: key(FixtureNodeID.input),
                attributes: [DOMAttribute(name: "disabled", value: "")],
                path: ["html", "body", "input"],
                selectorPath: "input",
                styleRevision: 0
            )
        )
        await waitForObservationDelivery()
        view.layoutIfNeeded()

        #expect(view.multiSelectedNodeIDsForTesting.isEmpty)
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func noOpContentInvalidationRefreshesDrawnSelectionDecoration() async throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(
            with: .init(root: makeDocumentNode(), selectedKey: key(FixtureNodeID.input))
        )
        let view = makeTreeView(runtime: runtime)
        view.synchronizeDocumentForTesting()
        await waitForObservationDelivery()
        view.resetPerformanceCountersForTesting()

        #expect(view.drawnSelectedRowRectsForTesting.count == 1)
        view.clearDrawnSelectedRowRectsForTesting()
        #expect(view.drawnSelectedRowRectsForTesting.isEmpty)

        runtime.document.applyMutationBundle(
            DOMGraphMutationBundle(
                events: [
                    .attributeModified(
                        nodeKey: key(FixtureNodeID.input),
                        name: "disabled",
                        value: "",
                        layoutFlags: nil,
                        isRendered: nil
                    ),
                ]
            )
        )

        #expect(await waitUntilReloadCount(1, in: view))
        #expect(view.incrementalTextStorageEditCallCountForTesting == 0)
        #expect(view.drawnSelectedRowRectsForTesting.count == 1)
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

        #expect(view.renderedTextForTesting.contains("<article>…</article>"))
        #expect(!view.renderedTextForTesting.contains("<span id=\"nested-child\"></span>"))
        #expect(previousHorizontalOffset > 0)

        runtime.document.applySelectionSnapshot(
            DOMSelectionSnapshotPayload(
                key: key(FixtureNodeID.nestedSpan),
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
        #expect(!text.contains("<article>…</article>"))
        #expect(spanLine.depth == articleLine.depth + 1)
        #expect(view.selectedRowRectsForTesting().count == 1)
        #expect(view.contentOffset.x < previousHorizontalOffset)
        #expect(view.contentOffset.x <= spanLine.markupStartX)
    }

    @Test
    func pickerSelectionOpensEmbeddedDocumentAncestorRowsToRevealIframeNode() throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeIframeDocumentNode()))
        let view = makeTreeView(runtime: runtime)

        #expect(view.renderedTextForTesting.contains("<iframe src=\"https://cross.example/\">…</iframe>"))
        #expect(!view.renderedTextForTesting.contains("<button id=\"inside-frame\"></button>"))

        runtime.document.applySelectionSnapshot(
            DOMSelectionSnapshotPayload(
                key: key(FixtureNodeID.iframeButton),
                attributes: [DOMAttribute(name: "id", value: "inside-frame")],
                path: ["html", "body", "iframe", "#document", "html", "body", "button"],
                selectorPath: "iframe > #document > html > body > button",
                styleRevision: 0
            )
        )
        view.synchronizeDocumentForTesting()
        view.layoutIfNeeded()

        let text = view.renderedTextForTesting
        let lines = view.renderedLineSnapshotsForTesting
        let iframeLine = try #require(lines.first { $0.text.contains("<iframe src=\"https://cross.example/\">") })
        let embeddedDocumentLine = try #require(lines.first { $0.text.contains("#document") })
        let frameButtonLine = try #require(lines.first { $0.text.contains("<button id=\"inside-frame\"") })

        #expect(text.contains("<button id=\"inside-frame\"></button>"))
        #expect(!text.contains("<iframe src=\"https://cross.example/\">…</iframe>"))
        #expect(iframeLine.isOpen)
        #expect(embeddedDocumentLine.isOpen)
        #expect(embeddedDocumentLine.depth == iframeLine.depth + 1)
        #expect(frameButtonLine.depth > embeddedDocumentLine.depth)
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func rendersWebKitSpecialChildrenInCanonicalOrder() throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeSpecialChildrenDocumentNode()))
        let view = makeTreeView(runtime: runtime)

        runtime.document.applySelectionSnapshot(
            DOMSelectionSnapshotPayload(
                key: key(FixtureNodeID.regularParagraph),
                attributes: [],
                path: ["html", "body", "section", "p"],
                selectorPath: "section > p",
                styleRevision: 0
            )
        )
        view.synchronizeDocumentForTesting()
        view.layoutIfNeeded()

        let orderedTexts = view.renderedLineSnapshotsForTesting.map(\.text)
        let templateIndex = try #require(orderedTexts.firstIndex { $0.contains("Template Content") })
        let beforeIndex = try #require(orderedTexts.firstIndex { $0.contains("::before") })
        let shadowIndex = try #require(orderedTexts.firstIndex { $0.contains("Shadow Content (Open)") })
        let regularIndex = try #require(orderedTexts.firstIndex { $0.contains("<p></p>") })
        let afterIndex = try #require(orderedTexts.firstIndex { $0.contains("::after") })

        #expect(templateIndex < beforeIndex)
        #expect(beforeIndex < shadowIndex)
        #expect(shadowIndex < regularIndex)
        #expect(regularIndex < afterIndex)
    }

    @Test
    func expandedPseudoElementDoesNotRenderInvalidClosingTagRow() throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makePseudoElementChildDocumentNode()))
        let view = makeTreeView(runtime: runtime)

        view.toggleRowForTesting(containing: "<section")
        view.toggleRowForTesting(containing: "::before")

        let lines = view.renderedLineSnapshotsForTesting
        let pseudoIndex = try #require(lines.firstIndex { $0.text.contains("::before") })
        let childIndex = try #require(lines.firstIndex { $0.text.contains("<span></span>") })

        #expect(lines[pseudoIndex].hasDisclosure)
        #expect(lines[pseudoIndex].isOpen)
        #expect(childIndex > pseudoIndex)
        #expect(lines[childIndex].depth == lines[pseudoIndex].depth + 1)
        #expect(!lines.contains { $0.text.contains("</::before>") })
        #expect(!lines.contains { $0.isClosingTag && $0.text.contains("::before") })
    }

    @Test
    func pickerSelectionReloadsOnlyWhenOpeningHiddenAncestors() async throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeDocumentNode()))
        let view = makeTreeView(runtime: runtime)
        await waitForObservationDelivery()

        #expect(view.renderedTextForTesting.contains("<article>…</article>"))
        view.resetPerformanceCountersForTesting()

        runtime.document.applySelectionSnapshot(
            DOMSelectionSnapshotPayload(
                key: key(FixtureNodeID.nestedSpan),
                attributes: [DOMAttribute(name: "id", value: "nested-child")],
                path: ["html", "body", "article", "span"],
                selectorPath: "article > span",
                styleRevision: 0
            )
        )

        #expect(await waitUntilReloadCount(1, in: view))
        #expect(view.reloadTreeCallCountForTesting == 1)
        #expect(view.rebuildTextStorageCallCountForTesting == 0)
        #expect(view.incrementalTextStorageEditCallCountForTesting == 1)
        #expect(view.resetTextFragmentViewsCallCountForTesting == 0)
        #expect(view.renderedTextForTesting.contains("<span id=\"nested-child\"></span>"))
    }

    @Test
    func treeInvalidationIncrementallyEditsAttributeMutationsIntoRenderedMarkup() async throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeDocumentNode()))
        let view = makeTreeView(runtime: runtime)
        await waitForObservationDelivery()
        view.resetPerformanceCountersForTesting()

        runtime.document.applyMutationBundle(
            DOMGraphMutationBundle(
                events: [
                    .attributeModified(
                        nodeKey: key(FixtureNodeID.div),
                        name: "data-revision",
                        value: "updated",
                        layoutFlags: nil,
                        isRendered: nil
                    ),
                ]
            )
        )

        #expect(await waitUntilReloadCount(1, in: view))
        #expect(view.reloadTreeCallCountForTesting == 1)
        #expect(view.buildRenderedRowsCallCountForTesting == 0)
        #expect(view.rebuildTextStorageCallCountForTesting == 0)
        #expect(view.incrementalTextStorageEditCallCountForTesting == 1)
        #expect(view.resetTextFragmentViewsCallCountForTesting == 0)
        #expect(view.renderedTextForTesting.contains("data-revision=\"updated\""))
    }

    @Test
    func treeInvalidationSubscribersSurviveViewRecreation() async throws {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(with: .init(root: makeDocumentNode()))
        var previousView: DOMTreeTextView? = makeTreeView(runtime: runtime)
        let currentView = makeTreeView(runtime: runtime)
        await waitForObservationDelivery()
        previousView?.resetPerformanceCountersForTesting()
        currentView.resetPerformanceCountersForTesting()

        previousView = nil
        await waitForObservationDelivery()
        runtime.document.applyMutationBundle(
            DOMGraphMutationBundle(
                events: [
                    .attributeModified(
                        nodeKey: key(FixtureNodeID.div),
                        name: "data-after-recreate",
                        value: "1",
                        layoutFlags: nil,
                        isRendered: nil
                    ),
                ]
            )
        )

        #expect(await waitUntilReloadCount(1, in: currentView))
        #expect(currentView.reloadTreeCallCountForTesting == 1)
        #expect(currentView.renderedTextForTesting.contains("data-after-recreate=\"1\""))
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
    func staleFindSearchIdentifierDoesNotDecorateRanges() {
        let view = makeTreeView()

        view.decorateStaleFindTextForTesting(query: "data-testid")

        #expect(view.findFoundRangesForTesting.isEmpty)
        #expect(view.findHighlightedRangesForTesting.isEmpty)
    }

    @Test
    func shiftClickSelectsContiguousRowsFromTheAnchor() throws {
        let view = makeTreeView()

        view.primaryClickRowForTesting(containing: "<div id=\"start-of-content\"")
        view.primaryClickRowForTesting(containing: "<input disabled>", modifiers: .shift)

        #expect(view.multiSelectedNodeIDsForTesting == [
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

        #expect(view.multiSelectedNodeIDsForTesting == [
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

        #expect(view.multiSelectedNodeIDsForTesting == [
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

        #expect(view.multiSelectedNodeIDsForTesting == [
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
        #expect(view.multiSelectedNodeIDsForTesting == [
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
        #expect(view.multiSelectedNodeIDsForTesting.isEmpty)
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

    private func makeTreeView(selectedNodeID: UInt64? = nil) -> DOMTreeTextView {
        let runtime = WIDOMRuntime()
        runtime.document.replaceDocument(
            with: .init(root: makeDocumentNode(), selectedKey: selectedNodeID.map { key($0) })
        )
        return makeTreeView(runtime: runtime)
    }

    private func makeTreeView(runtime: WIDOMRuntime) -> DOMTreeTextView {
        let view = DOMTreeTextView(dom: runtime)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        return view
    }

    private func waitForObservationDelivery() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private func waitUntilReloadCount(_ count: Int, in view: DOMTreeTextView) async -> Bool {
        for _ in 0..<20 {
            if view.reloadTreeCallCountForTesting == count {
                return true
            }
            await Task.yield()
        }
        return view.reloadTreeCallCountForTesting == count
    }

    private func makeDocumentNode() -> DOMGraphNodeDescriptor {
        makeNode(
            nodeID: FixtureNodeID.document,
            type: .document,
            nodeName: "#document",
            localName: "",
            children: [
                makeNode(
                    nodeID: FixtureNodeID.doctype,
                    type: .documentType,
                    nodeName: "html",
                    localName: ""
                ),
                makeNode(
                    nodeID: FixtureNodeID.html,
                    nodeName: "HTML",
                    localName: "html",
                    attributes: [DOMAttribute(name: "lang", value: "en")],
                    children: [
                        makeNode(
                            nodeID: FixtureNodeID.head,
                            nodeName: "HEAD",
                            localName: "head",
                            children: [
                                makeNode(
                                    nodeID: FixtureNodeID.title,
                                    nodeName: "TITLE",
                                    localName: "title"
                                ),
                            ]
                        ),
                        makeNode(
                            nodeID: FixtureNodeID.body,
                            nodeName: "BODY",
                            localName: "body",
                            attributes: [DOMAttribute(name: "class", value: "logged-in env-production")],
                            children: [
                                makeNode(
                                    nodeID: FixtureNodeID.div,
                                    nodeName: "DIV",
                                    localName: "div",
                                    attributes: [
                                        DOMAttribute(name: "id", value: "start-of-content"),
                                        DOMAttribute(name: "class", value: "show-on-focus"),
                                        DOMAttribute(name: "data-testid", value: "cellInnerDiv"),
                                    ]
                                ),
                                makeNode(
                                    nodeID: FixtureNodeID.unknownElement,
                                    type: .unknown,
                                    nodeName: "SECTION",
                                    localName: "section",
                                    attributes: [
                                        DOMAttribute(name: "data-runtime", value: "unknown-node-type"),
                                    ]
                                ),
                                makeNode(
                                    nodeID: FixtureNodeID.image,
                                    nodeName: "IMG",
                                    localName: "img",
                                    attributes: [
                                        DOMAttribute(name: "src", value: "/preview.webp"),
                                        DOMAttribute(name: "alt", value: "preview"),
                                    ]
                                ),
                                makeNode(
                                    nodeID: FixtureNodeID.input,
                                    nodeName: "INPUT",
                                    localName: "input",
                                    attributes: [DOMAttribute(name: "disabled", value: "")]
                                ),
                                makeNode(
                                    nodeID: FixtureNodeID.article,
                                    nodeName: "ARTICLE",
                                    localName: "article",
                                    children: [
                                        makeNode(
                                            nodeID: FixtureNodeID.nestedSpan,
                                            nodeName: "SPAN",
                                            localName: "span",
                                            attributes: [DOMAttribute(name: "id", value: "nested-child")]
                                        ),
                                    ]
                                ),
                                makeNode(
                                    nodeID: FixtureNodeID.text,
                                    type: .text,
                                    nodeName: "#text",
                                    localName: "",
                                    nodeValue: "\n  Introducing luma for iOS 26\t"
                                ),
                                makeNode(
                                    nodeID: FixtureNodeID.comment,
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
            nodeID: FixtureNodeID.document,
            type: .document,
            nodeName: "#document",
            localName: "",
            children: [
                makeNode(
                    nodeID: FixtureNodeID.html,
                    nodeName: "HTML",
                    localName: "html",
                    children: [
                        makeNode(
                            nodeID: FixtureNodeID.body,
                            nodeName: "BODY",
                            localName: "body",
                            children: [
                                makeNode(
                                    nodeID: FixtureNodeID.article,
                                    nodeName: "ARTICLE",
                                    localName: "article",
                                    childCount: 1
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }

    private func makeDeferredChildDocumentNode() -> DOMGraphNodeDescriptor {
        makeNode(
            nodeID: FixtureNodeID.document,
            type: .document,
            nodeName: "#document",
            localName: "",
            children: [
                makeNode(
                    nodeID: FixtureNodeID.html,
                    nodeName: "HTML",
                    localName: "html",
                    children: [
                        makeNode(
                            nodeID: FixtureNodeID.body,
                            nodeName: "BODY",
                            localName: "body",
                            children: [
                                makeNode(
                                    nodeID: FixtureNodeID.article,
                                    nodeName: "ARTICLE",
                                    localName: "article",
                                    childCount: 1
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }

    private func makeWideGlyphDocumentNode() -> DOMGraphNodeDescriptor {
        makeNode(
            nodeID: FixtureNodeID.document,
            type: .document,
            nodeName: "#document",
            localName: "",
            children: [
                makeNode(
                    nodeID: FixtureNodeID.html,
                    nodeName: "HTML",
                    localName: "html",
                    children: [
                        makeNode(
                            nodeID: FixtureNodeID.body,
                            nodeName: "BODY",
                            localName: "body",
                            children: [
                                makeNode(
                                    nodeID: FixtureNodeID.div,
                                    nodeName: "DIV",
                                    localName: "div",
                                    attributes: [
                                        DOMAttribute(
                                            name: "data-title",
                                            value: String(repeating: "日本語テキスト", count: 16)
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

    private func makeSpecialChildrenDocumentNode() -> DOMGraphNodeDescriptor {
        makeNode(
            nodeID: FixtureNodeID.document,
            type: .document,
            nodeName: "#document",
            localName: "",
            children: [
                makeNode(
                    nodeID: FixtureNodeID.html,
                    nodeName: "HTML",
                    localName: "html",
                    children: [
                        makeNode(
                            nodeID: FixtureNodeID.body,
                            nodeName: "BODY",
                            localName: "body",
                            children: [
                                makeNode(
                                    nodeID: FixtureNodeID.specialHost,
                                    nodeName: "SECTION",
                                    localName: "section",
                                    children: [
                                        makeNode(
                                            nodeID: FixtureNodeID.regularParagraph,
                                            nodeName: "P",
                                            localName: "p"
                                        ),
                                    ],
                                    shadowRoots: [
                                        makeNode(
                                            nodeID: FixtureNodeID.shadowRoot,
                                            type: .documentFragment,
                                            nodeName: "#shadow-root",
                                            localName: "",
                                            shadowRootType: "open"
                                        )
                                    ],
                                    templateContent: makeNode(
                                        nodeID: FixtureNodeID.templateContent,
                                        type: .documentFragment,
                                        nodeName: "#document-fragment",
                                        localName: ""
                                    ),
                                    beforePseudoElement: makeNode(
                                        nodeID: FixtureNodeID.beforePseudoElement,
                                        nodeName: "::before",
                                        localName: "",
                                        pseudoType: "before"
                                    ),
                                    afterPseudoElement: makeNode(
                                        nodeID: FixtureNodeID.afterPseudoElement,
                                        nodeName: "::after",
                                        localName: "",
                                        pseudoType: "after"
                                    )
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }

    private func makeIframeDocumentNode() -> DOMGraphNodeDescriptor {
        makeNode(
            nodeID: FixtureNodeID.document,
            type: .document,
            nodeName: "#document",
            localName: "",
            children: [
                makeNode(
                    nodeID: FixtureNodeID.html,
                    nodeName: "HTML",
                    localName: "html",
                    children: [
                        makeNode(
                            nodeID: FixtureNodeID.body,
                            nodeName: "BODY",
                            localName: "body",
                            children: [
                                makeNode(
                                    nodeID: FixtureNodeID.iframe,
                                    nodeName: "IFRAME",
                                    localName: "iframe",
                                    attributes: [
                                        DOMAttribute(name: "src", value: "https://cross.example/"),
                                    ],
                                    contentDocument:
                                        makeNode(
                                            nodeID: FixtureNodeID.iframeDocument,
                                            type: .document,
                                            nodeName: "#document",
                                            localName: "",
                                            children: [
                                                makeNode(
                                                    nodeID: FixtureNodeID.iframeHTML,
                                                    nodeName: "HTML",
                                                    localName: "html",
                                                    children: [
                                                        makeNode(
                                                            nodeID: FixtureNodeID.iframeBody,
                                                            nodeName: "BODY",
                                                            localName: "body",
                                                            children: [
                                                                makeNode(
                                                                    nodeID: FixtureNodeID.iframeButton,
                                                                    nodeName: "BUTTON",
                                                                    localName: "button",
                                                                    attributes: [
                                                                        DOMAttribute(name: "id", value: "inside-frame"),
                                                                    ]
                                                                ),
                                                            ]
                                                        ),
                                                    ]
                                                ),
                                            ]
                                        ),
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }

    private func makePseudoElementChildDocumentNode() -> DOMGraphNodeDescriptor {
        makeNode(
            nodeID: FixtureNodeID.document,
            type: .document,
            nodeName: "#document",
            localName: "",
            children: [
                makeNode(
                    nodeID: FixtureNodeID.html,
                    nodeName: "HTML",
                    localName: "html",
                    children: [
                        makeNode(
                            nodeID: FixtureNodeID.body,
                            nodeName: "BODY",
                            localName: "body",
                            children: [
                                makeNode(
                                    nodeID: FixtureNodeID.specialHost,
                                    nodeName: "SECTION",
                                    localName: "section",
                                    beforePseudoElement: makeNode(
                                        nodeID: FixtureNodeID.beforePseudoElement,
                                        nodeName: "::before",
                                        localName: "",
                                        children: [
                                            makeNode(
                                                nodeID: FixtureNodeID.beforePseudoSpan,
                                                nodeName: "SPAN",
                                                localName: "span"
                                            ),
                                        ],
                                        pseudoType: "before"
                                    )
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
    }

    private func makeNode(
        nodeID: UInt64,
        type: DOMNodeType = .element,
        nodeName: String = "DIV",
        localName: String = "div",
        nodeValue: String = "",
        attributes: [DOMAttribute] = [],
        children: [DOMGraphNodeDescriptor] = [],
        contentDocument: DOMGraphNodeDescriptor? = nil,
        shadowRoots: [DOMGraphNodeDescriptor] = [],
        templateContent: DOMGraphNodeDescriptor? = nil,
        beforePseudoElement: DOMGraphNodeDescriptor? = nil,
        afterPseudoElement: DOMGraphNodeDescriptor? = nil,
        pseudoType: String? = nil,
        shadowRootType: String? = nil,
        childCount: Int? = nil
    ) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            targetIdentifier: testTargetIdentifier,
            nodeID: Int(nodeID),
            nodeType: type,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            pseudoType: pseudoType,
            shadowRootType: shadowRootType,
            attributes: attributes,
            regularChildCount: childCount ?? children.count,
            regularChildrenAreLoaded: childCount == nil,
            layoutFlags: [],
            isRendered: true,
            children: children,
            contentDocument: contentDocument,
            shadowRoots: shadowRoots,
            templateContent: templateContent,
            beforePseudoElement: beforePseudoElement,
            afterPseudoElement: afterPseudoElement
        )
    }

    private var testTargetIdentifier: String {
        "page"
    }

    private func key(_ nodeID: UInt64) -> DOMNodeKey {
        DOMNodeKey(targetIdentifier: testTargetIdentifier, nodeID: Int(nodeID))
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
    static let iframe: UInt64 = 15
    static let iframeDocument: UInt64 = 16
    static let iframeHTML: UInt64 = 17
    static let iframeBody: UInt64 = 18
    static let iframeButton: UInt64 = 19
    static let specialHost: UInt64 = 20
    static let templateContent: UInt64 = 21
    static let beforePseudoElement: UInt64 = 22
    static let shadowRoot: UInt64 = 23
    static let regularParagraph: UInt64 = 24
    static let afterPseudoElement: UInt64 = 25
    static let beforePseudoSpan: UInt64 = 26
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
