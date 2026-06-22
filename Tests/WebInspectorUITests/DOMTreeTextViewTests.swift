#if canImport(UIKit)
import ObservationBridge
import Testing
import WebInspectorTransport
import UIKit
@testable import WebInspectorCore
@testable import WebInspectorCoreConsoleNetwork
@testable import WebInspectorCoreDOMCSS
@testable import WebInspectorCoreRuntime
@testable import WebInspectorCoreSupport
@testable import WebInspectorUI
@testable import WebInspectorUISyntaxBody
@testable import WebInspectorUINetwork
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

@MainActor
@Suite(.serialized)
struct DOMTreeTextViewTests {
    @Test
    func rendersDOMMarkupFromDOMSession() async throws {
        let view = await makeTreeView()
        let text = view.documentTextForTesting

        #expect(!text.contains("#document"))
        #expect(text.contains("<!DOCTYPE html>"))
        #expect(text.contains("<html lang=\"en\">"))
        #expect(text.contains("<head>…</head>"))
        #expect(text.contains("<body class=\"logged-in env-production\">"))
        #expect(text.contains("<div id=\"start-of-content\" data-testid=\"cellInnerDiv\"></div>"))
        #expect(text.contains("<input disabled>"))
        #expect(text.contains("<article>…</article>"))
        #expect(text.contains("\"Introducing luma for iOS 26\""))
        #expect(text.contains("<!-- comment text -->"))
    }

    @Test
    func rowRenderBuildDoesNotSnapshotDOMSession() async throws {
        let session = makeDOMSession()
        let baserowSnapshotBuildCount = session.snapshotBuildCountForTesting

        let view = await makeTreeView(session: session)
        #expect(view.documentTextForTesting.contains("<html lang=\"en\">"))
        #expect(session.snapshotBuildCountForTesting == baserowSnapshotBuildCount)

        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowDocumentForTesting()

        #expect(view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))
        #expect(session.snapshotBuildCountForTesting == baserowSnapshotBuildCount)
    }

    @Test
    func collapsedDescendantMutationDoesNotRouteCollapsedSubtreeBuild() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)
        let documentID = try #require(session.currentPageRootNode?.id.documentID)
        let articleID = DOMNode.ID(documentID: documentID, nodeID: .init(8))
        let nestedChildID = DOMNode.ID(documentID: documentID, nodeID: .init(9))
        let observedTreeRenderRevisions = await view.documentObservationDeliveryForTesting.values {
            session.treeRenderInvalidation.revision
        }
        defer {
            observedTreeRenderRevisions.cancel()
        }
        let baserowSnapshotBuildCount = session.snapshotBuildCountForTesting
        let baselineAppliedTreeRevision = view.rowDocumentAppliedTreeRevisionForTesting
        let baselineBuildCount = view.buildRowRenderPlanCallCountForTesting

        #expect(view.documentTextForTesting.contains("<article>…</article>"))
        #expect(!view.documentTextForTesting.contains("data-state=\"ready\""))

        session.applyAttributeModified(nestedChildID, name: "data-state", value: "ready")
        let expectedTreeRevision = session.treeRevision
        let didObserveTreeRevision = await observedTreeRenderRevisions.waitUntil {
            $0 >= expectedTreeRevision
        } != nil
        await view.waitForRowDocumentForTesting()

        #expect(didObserveTreeRevision)
        #expect(view.buildRowRenderPlanCallCountForTesting == baselineBuildCount)
        #expect(DOMTreeTextView.RowRenderBuilder.lastCollectedNodeIDsForTesting.contains(articleID))
        #expect(!DOMTreeTextView.RowRenderBuilder.lastCollectedNodeIDsForTesting.contains(nestedChildID))
        #expect(session.snapshotBuildCountForTesting == baserowSnapshotBuildCount)
        #expect(view.rowDocumentAppliedTreeRevisionForTesting == baselineAppliedTreeRevision)
        #expect(!view.documentTextForTesting.contains("data-state=\"ready\""))
    }

    @Test
    func coalescedVisibleThenCollapsedMutationStillRoutesVisibleUpdate() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)
        let documentID = try #require(session.currentPageRootNode?.id.documentID)
        let visibleDivID = DOMNode.ID(documentID: documentID, nodeID: .init(7))
        let nestedChildID = DOMNode.ID(documentID: documentID, nodeID: .init(9))

        #expect(view.documentTextForTesting.contains("<div id=\"start-of-content\" data-testid=\"cellInnerDiv\"></div>"))
        #expect(view.documentTextForTesting.contains("<article>…</article>"))
        #expect(!view.documentTextForTesting.contains("data-hidden=\"ready\""))

        let didRenderVisibleAttribute = await waitForRenderedDocumentTreeUpdate(
            in: view,
            session: session,
            update: {
                session.applyAttributeModified(visibleDivID, name: "data-visible", value: "ready")
                session.applyAttributeModified(nestedChildID, name: "data-hidden", value: "ready")
            },
            until: {
                view.documentTextForTesting.contains("data-visible=\"ready\"")
            }
        )

        #expect(didRenderVisibleAttribute)
        #expect(view.documentTextForTesting.contains("data-visible=\"ready\""))
        #expect(!view.documentTextForTesting.contains("data-hidden=\"ready\""))
    }

    @Test
    func documentRootStructureMutationRoutesHiddenRenderRoot() async throws {
        let session = makeDOMSession(
            root: DOMNode.Payload(
                nodeID: .init(1),
                nodeType: .document,
                nodeName: "#document",
                regularChildren: .unrequested(count: 1)
            )
        )
        let view = await makeTreeView(session: session)
        let rootID = try #require(session.currentPageRootNode?.id)

        #expect(view.documentTextForTesting.isEmpty)

        let didRenderDocumentElement = await waitForRenderedDocumentTreeUpdate(
            in: view,
            session: session,
            update: {
                session.applySetChildNodes(
                    parent: rootID,
                    children: [
                        DOMNode.Payload(
                            nodeID: .init(2),
                            nodeType: .element,
                            nodeName: "HTML",
                            localName: "html"
                        ),
                    ],
                    eventSequence: 1
                )
            },
            until: {
                view.documentTextForTesting.contains("<html")
            }
        )

        #expect(didRenderDocumentElement)
        #expect(view.documentTextForTesting.contains("<html"))
    }

    @Test
    func rowDocumentStoresTokenForegroundAttributes() async throws {
        let view = await makeTreeView()

        let baseForeground = try #require(view.rowDocumentBaseForegroundColorForTesting)
        let tagNameStorageForeground = try #require(view.rowDocumentForegroundColorForTesting(containing: "input"))
        let attributeNameStorageForeground = try #require(view.rowDocumentForegroundColorForTesting(containing: "disabled"))
        let tagNameTokenForeground = try #require(view.tokenForegroundColorForTesting(kind: "tagName"))
        let attributeNameTokenForeground = try #require(view.tokenForegroundColorForTesting(kind: "attributeName"))

        #expect(!colorsEqual(tagNameStorageForeground, baseForeground))
        #expect(!colorsEqual(attributeNameStorageForeground, baseForeground))
        #expect(colorsEqual(tagNameStorageForeground, tagNameTokenForeground))
        #expect(colorsEqual(attributeNameStorageForeground, attributeNameTokenForeground))
        #expect(view.disclosureAttachmentSnapshotsForTesting.contains { $0.hasAttachment })
    }

    @Test
    func textDocumentVendsRowParagraphsWithStableIdentity() throws {
        let document = DOMTreeTextDocument()
        let rows = makeRowDocumentRows(["alpha", "beta"])
        document.replaceDocument(with: attributedRowDocument(rows: rows), rows: rows)

        let firstParagraph = try #require(document.textContentStorage(
            document.textContentStorage,
            textParagraphWith: rows[0].documentRange
        ) as? DOMTreeRowParagraph)
        let secondParagraph = try #require(document.textContentStorage(
            document.textContentStorage,
            textParagraphWith: rows[1].documentRange
        ) as? DOMTreeRowParagraph)

        #expect(firstParagraph.identity == rows[0].identity)
        #expect(secondParagraph.identity == rows[1].identity)
    }

    @Test
    func textDocumentLayoutFragmentsExposeRowIdentity() throws {
        let document = DOMTreeTextDocument()
        let rows = makeRowDocumentRows(["alpha", "beta"])
        document.replaceDocument(with: attributedRowDocument(rows: rows), rows: rows)
        document.textContainer.size = CGSize(width: 1_000, height: 1_000)

        let fullRange = try #require(document.textRange(for: NSRange(location: 0, length: document.utf16Length)))
        document.layoutManager.ensureLayout(for: fullRange)
        var fragments: [NSTextLayoutFragment] = []
        document.layoutManager.enumerateTextLayoutFragments(
            from: fullRange.location,
            options: []
        ) { fragment in
            fragments.append(fragment)
            return true
        }

        let firstFragment = try #require(fragments.first)
        #expect(document.rowIdentity(for: firstFragment) == rows[0].identity)
        #expect(document.row(for: firstFragment) == rows[0])
    }

    @Test
    func textDocumentSingleRowReplacementPreservesSurroundingRowIdentities() throws {
        let document = DOMTreeTextDocument()
        let initialRows = makeRowDocumentRows(["first", "middle", "third"])
        document.replaceDocument(with: attributedRowDocument(rows: initialRows), rows: initialRows)

        let nextRows = makeRowDocumentRows(["first", "second", "third"])
        document.replaceCharacters(
            in: initialRows[1].documentRange,
            with: attributedRowDocument(rows: [nextRows[1]]),
            rows: nextRows
        )

        let firstParagraph = try #require(document.textContentStorage(
            document.textContentStorage,
            textParagraphWith: nextRows[0].documentRange
        ) as? DOMTreeRowParagraph)
        let middleParagraph = try #require(document.textContentStorage(
            document.textContentStorage,
            textParagraphWith: nextRows[1].documentRange
        ) as? DOMTreeRowParagraph)
        let lastParagraph = try #require(document.textContentStorage(
            document.textContentStorage,
            textParagraphWith: nextRows[2].documentRange
        ) as? DOMTreeRowParagraph)

        #expect(document.string == "first\nsecond\nthird")
        #expect(firstParagraph.identity == nextRows[0].identity)
        #expect(middleParagraph.identity == nextRows[1].identity)
        #expect(lastParagraph.identity == nextRows[2].identity)
    }

    @Test
    func findWordMatchMethodsRespectIdentifierBoundaries() {
        let source = "foo fooBar barfoo _foo foo_bar foo2 foo-bar"

        let containsRanges = DOMTreeTextView.FindCoordinator.searchRanges(
            in: source,
            queryString: "foo",
            wordMatchMethod: .contains
        )
        let startsWithRanges = DOMTreeTextView.FindCoordinator.searchRanges(
            in: source,
            queryString: "foo",
            wordMatchMethod: .startsWith
        )
        let fullWordRanges = DOMTreeTextView.FindCoordinator.searchRanges(
            in: source,
            queryString: "foo",
            wordMatchMethod: .fullWord
        )

        #expect(containsRanges.map(\.location) == [0, 4, 14, 19, 23, 31, 36])
        #expect(startsWithRanges.map(\.location) == [0, 4, 23, 31, 36])
        #expect(fullWordRanges.map(\.location) == [0, 36])
    }

    @Test
    func findWordBoundaryChecksUseComposedCharacters() {
        let source = "e\u{301} e\u{301}x xe\u{301} e\u{301}-x"

        let containsRanges = DOMTreeTextView.FindCoordinator.searchRanges(
            in: source,
            queryString: "\u{301}",
            wordMatchMethod: .contains
        )
        let startsWithRanges = DOMTreeTextView.FindCoordinator.searchRanges(
            in: source,
            queryString: "\u{301}",
            wordMatchMethod: .startsWith
        )
        let fullWordRanges = DOMTreeTextView.FindCoordinator.searchRanges(
            in: source,
            queryString: "\u{301}",
            wordMatchMethod: .fullWord
        )

        #expect(containsRanges == [
            NSRange(location: 0, length: 2),
            NSRange(location: 3, length: 2),
            NSRange(location: 8, length: 2),
            NSRange(location: 11, length: 2),
        ])
        #expect(startsWithRanges.map(\.location) == [0, 3, 11])
        #expect(fullWordRanges.map(\.location) == [0, 11])
    }

    @Test
    func selectingNodeUpdatesCoreSelectionAndRowDecoration() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)

        view.selectRowForTesting(containing: "<input disabled>")
        view.layoutIfNeeded()

        #expect(session.selectedNode?.localName == "input")
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func primaryClickingRowUpdatesCoreSelection() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)

        view.primaryClickRowForTesting(containing: "<input disabled>")
        view.layoutIfNeeded()

        #expect(session.selectedNode?.localName == "input")
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func hitTestingVisibleRowCentersReturnsTheMatchingRow() async throws {
        let view = await makeTreeView()
        view.layoutIfNeeded()
        let visibleFragments = view.rowFragmentSnapshotsForTesting.prefix(16)

        for fragment in visibleFragments {
            let point = CGPoint(
                x: max(4, fragment.frame.minX + 4),
                y: fragment.frame.midY
            )
            #expect(view.hitTestedLineTextForTesting(atContentPoint: point) == fragment.text)
        }
    }

    @Test
    func primaryClickingDisclosurePointTogglesRowExpansion() async throws {
        let view = await makeTreeView()
        view.layoutIfNeeded()
        let point = try #require(view.disclosureHitPointForTesting(containing: "<article"))

        #expect(view.disclosureHitTestedLineTextForTesting(atContentPoint: point)?.contains("<article") == true)
        view.primaryClickContentPointForTesting(point)
        await view.waitForRowDocumentForTesting()

        #expect(view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))
    }

    @Test
    func primaryClickingRowHighlightsSelectedPageNode() async throws {
        let session = makeDOMSession()
        let recorder = NodeActionRecorder()
        let view = DOMTreeTextView(
            dom: session,
            highlightNodeAction: { nodeID, owner in
                recorder.record(nodeID, owner: owner)
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()

        view.primaryClickRowForTesting(containing: "<input disabled>")
        let highlightedNodeID = await recorder.nextNodeID()

        #expect(session.selectedNode?.id == highlightedNodeID)
        #expect(session.node(for: highlightedNodeID)?.localName == "input")
        #expect(recorder.recordedOwners == [.selection])
    }

    @Test
    func hoverEndRestoresSelectedPageHighlight() async throws {
        let session = makeDOMSession()
        let restoreRecorder = VoidActionRecorder()
        let view = DOMTreeTextView(
            dom: session,
            highlightNodeAction: { _, _ in },
            restoreHighlightAction: {
                restoreRecorder.record()
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()

        view.primaryClickRowForTesting(containing: "<input disabled>")
        view.hoverRowForTesting(containing: "<article")
        view.endHoverForTesting()
        await restoreRecorder.next()

        #expect(session.selectedNode?.localName == "input")
    }

    @Test
    func repeatedHoverEndCancelsPendingRestoreHighlight() async throws {
        let session = makeDOMSession()
        let restoreRecorder = VoidActionRecorder()
        let view = DOMTreeTextView(
            dom: session,
            highlightNodeAction: { _, _ in },
            restoreHighlightAction: {
                restoreRecorder.record()
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()

        view.primaryClickRowForTesting(containing: "<input disabled>")
        view.hoverRowForTesting(containing: "<article")
        view.endHoverForTesting()
        view.endHoverForTesting()
        await restoreRecorder.next()
        await view.waitForPageHighlightTaskForTesting()

        #expect(session.selectedNode?.localName == "input")
        #expect(restoreRecorder.recordCount == 1)
    }

    @Test
    func hidingWithHoveredPageHighlightRestoresHighlightWhileRenderingInactive() async throws {
        let session = makeDOMSession()
        let highlightRecorder = NodeActionRecorder()
        let restoreRecorder = VoidActionRecorder()
        let view = DOMTreeTextView(
            dom: session,
            highlightNodeAction: { nodeID, owner in
                highlightRecorder.record(nodeID, owner: owner)
            },
            restoreHighlightAction: {
                restoreRecorder.record()
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()

        view.hoverRowForTesting(containing: "<article")
        _ = await highlightRecorder.nextNodeID()

        view.setRenderingActive(false)
        await restoreRecorder.next()

        #expect(highlightRecorder.recordedOwners == [.transient])
        #expect(restoreRecorder.recordCount == 1)
    }

    @Test
    func hidingWithQueuedHoverRestorePreservesHighlightRestoreTask() async throws {
        let session = makeDOMSession()
        let restoreRecorder = VoidActionRecorder()
        let view = DOMTreeTextView(
            dom: session,
            highlightNodeAction: { _, _ in },
            restoreHighlightAction: {
                restoreRecorder.record()
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()

        view.primaryClickRowForTesting(containing: "<input disabled>")
        view.hoverRowForTesting(containing: "<article")
        view.endHoverForTesting()
        view.setRenderingActive(false)
        await restoreRecorder.next()

        #expect(session.selectedNode?.localName == "input")
        #expect(restoreRecorder.recordCount == 1)
    }

    @Test
    func hidingWithQueuedSelectionHighlightRequeuesHighlightOnResume() async throws {
        let session = makeDOMSession()
        let highlightRecorder = NodeActionRecorder()
        let view = DOMTreeTextView(
            dom: session,
            highlightNodeAction: { nodeID, owner in
                highlightRecorder.record(nodeID, owner: owner)
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()

        view.primaryClickRowForTesting(containing: "<input disabled>")
        view.setRenderingActive(false)
        await view.waitForPageHighlightTaskForTesting()

        #expect(highlightRecorder.recordedNodeIDs.isEmpty)

        view.setRenderingActive(true)
        let highlightedNodeID = await highlightRecorder.nextNodeID()

        #expect(session.selectedNode?.id == highlightedNodeID)
        #expect(session.node(for: highlightedNodeID)?.localName == "input")
        #expect(highlightRecorder.recordedOwners == [.selection])
    }

    @Test
    func hoverHighlightCancelsPendingRestoreHighlight() async throws {
        let session = makeDOMSession()
        let highlightRecorder = NodeActionRecorder()
        let restoreRecorder = CancellableVoidActionRecorder()
        let view = DOMTreeTextView(
            dom: session,
            highlightNodeAction: { nodeID, owner in
                highlightRecorder.record(nodeID, owner: owner)
            },
            restoreHighlightAction: {
                await restoreRecorder.run()
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()

        view.primaryClickRowForTesting(containing: "<input disabled>")
        view.hoverRowForTesting(containing: "<article")
        view.endHoverForTesting()
        await restoreRecorder.nextStart()
        highlightRecorder.removeAll()

        view.hoverRowForTesting(containing: "<input disabled>")
        await restoreRecorder.nextCancellation()
        let highlightedNodeID = await highlightRecorder.nextNodeID()

        #expect(session.node(for: highlightedNodeID)?.localName == "input")
        #expect(highlightRecorder.recordedOwners == [.transient])
    }

    @Test
    func pageHighlightActionsAreSuppressedWhileElementPickerIsActive() async throws {
        let session = makeDOMSession()
        session.isSelectingElement = true
        let highlightRecorder = NodeActionRecorder()
        let restoreRecorder = VoidActionRecorder()
        let view = DOMTreeTextView(
            dom: session,
            highlightNodeAction: { nodeID, owner in
                highlightRecorder.record(nodeID, owner: owner)
            },
            restoreHighlightAction: {
                restoreRecorder.record()
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()

        view.primaryClickRowForTesting(containing: "<input disabled>")
        view.hoverRowForTesting(containing: "<article")
        view.endHoverForTesting()
        await view.waitForPageHighlightTaskForTesting()

        #expect(session.selectedNode?.localName == "input")
        #expect(highlightRecorder.recordedNodeIDs.isEmpty)
        #expect(restoreRecorder.recordCount == 0)
    }

    @Test
    func expandedElementRendersChildrenAndClosingTag() async throws {
        let view = await makeTreeView()

        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowDocumentForTesting()

        let text = view.documentTextForTesting
        #expect(text.contains("<article>"))
        #expect(text.contains("<span id=\"nested-child\"></span>"))
        #expect(text.contains("</article>"))
        #expect(!text.contains("<article>…</article>"))
    }

    @Test
    func localMarkupLookupUsesIndexedOpeningRow() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)

        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowDocumentForTesting()

        let articleID = try #require(
            session.snapshot().nodesByID.first { entry in
                entry.value.localName == "article"
            }?.key
        )

        let markupByNodeID = view.localMarkupTextByNodeIDForTesting([articleID])
        #expect(markupByNodeID[articleID] == "      <article>")
        #expect(view.documentTextForTesting.contains("</article>"))

        view.removeRowIndexForTesting(containing: "<article>")
        #expect(view.localMarkupTextByNodeIDForTesting([articleID]).isEmpty)
    }

    @Test
    func markupCacheSeparatesOpeningAndClosingRowsForSameNode() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)

        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowDocumentForTesting()

        let articleID = try #require(
            session.snapshot().nodesByID.first { entry in
                entry.value.localName == "article"
            }?.key
        )
        let cachedKeys = view.cachedMarkupKeysForTesting

        #expect(cachedKeys.contains(DOMTreeTextView.MarkupCacheKey(nodeID: articleID, isClosingTag: false)))
        #expect(cachedKeys.contains(DOMTreeTextView.MarkupCacheKey(nodeID: articleID, isClosingTag: true)))
    }

    @Test
    func multiSelectionDisplayOrderUsesRenderedRowIndexes() async throws {
        let view = await makeTreeView()

        view.primaryClickRowForTesting(containing: "<article", modifiers: .command)
        view.primaryClickRowForTesting(containing: "<div id=\"start-of-content\"", modifiers: .command)
        view.primaryClickRowForTesting(containing: "<input disabled>", modifiers: .command)

        let selectedRows = view.multiSelectedRowSnapshotsInDisplayOrderForTesting
        #expect(selectedRows.map(\.text) == [
            "      <div id=\"start-of-content\" data-testid=\"cellInnerDiv\"></div>",
            "      <input disabled>",
            "      <article>…</article>",
        ])
        #expect(selectedRows.map(\.rowIndex) == selectedRows.map(\.rowIndex).sorted())
    }

    @Test
    func expandedDescendantMutationRerendersAfterExpansionDependencyRefresh() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)

        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowDocumentForTesting()
        #expect(view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))

        let nestedChildID = try #require(
            session.snapshot().nodesByID.first { entry in
                entry.value.attributes.contains { attribute in
                    attribute.name == "id" && attribute.value == "nested-child"
                }
            }?.key
        )

        let didRenderAttribute = await waitForRenderedDocumentTreeUpdate(
            in: view,
            session: session,
            update: {
                session.applyAttributeModified(nestedChildID, name: "data-state", value: "ready")
            },
            until: {
                view.documentTextForTesting.contains("<span id=\"nested-child\" data-state=\"ready\"></span>")
            }
        )
        #expect(didRenderAttribute)
        #expect(view.documentTextForTesting.contains("<span id=\"nested-child\" data-state=\"ready\"></span>"))
    }

    @Test
    func visibleContentMutationUsesIncrementalTextStorageUpdate() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)

        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowDocumentForTesting()
        view.resetPerformanceCountersForTesting()

        let nestedChildID = try #require(
            session.snapshot().nodesByID.first { entry in
                entry.value.attributes.contains { attribute in
                    attribute.name == "id" && attribute.value == "nested-child"
                }
            }?.key
        )

        let didRenderAttribute = await waitForRenderedDocumentTreeUpdate(
            in: view,
            session: session,
            update: {
                session.applyAttributeModified(nestedChildID, name: "data-state", value: "ready")
            },
            until: {
                view.documentTextForTesting.contains("<span id=\"nested-child\" data-state=\"ready\"></span>")
            }
        )

        #expect(didRenderAttribute)
        #expect(view.incrementalRowDocumentEditCallCountForTesting == 1)
        #expect(view.replaceRowDocumentCallCountForTesting == 0)
        #expect(view.resetTextFragmentViewsCallCountForTesting == 0)
        #expect(view.rowSpanDisplayInvalidationCallCountForTesting == 1)
        #expect(view.textSegmentRectsCallCountForTesting == 0)
    }

    @Test
    func hiddenVisibleMutationDefersRenderingUntilRenderingResumes() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)
        let documentID = try #require(session.currentPageRootNode?.id.documentID)
        let visibleDivID = DOMNode.ID(documentID: documentID, nodeID: .init(7))
        let observedTreeRenderRevisions = await view.documentObservationDeliveryForTesting.values {
            session.treeRenderInvalidation.revision
        }
        defer {
            observedTreeRenderRevisions.cancel()
        }
        let baselineText = view.documentTextForTesting
        view.resetPerformanceCountersForTesting()

        view.setRenderingActive(false)
        session.applyAttributeModified(visibleDivID, name: "data-visible", value: "deferred")
        let hiddenRevision = session.treeRevision
        #expect(await observedTreeRenderRevisions.waitUntil { $0 >= hiddenRevision } != nil)
        await view.waitForRowDocumentForTesting()

        #expect(view.buildRowRenderPlanCallCountForTesting == 0)
        #expect(view.documentTextForTesting == baselineText)
        #expect(!view.documentTextForTesting.contains("data-visible=\"deferred\""))

        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()

        #expect(view.buildRowRenderPlanCallCountForTesting == 1)
        #expect(view.documentTextForTesting.contains("data-visible=\"deferred\""))
    }

    @Test
    func inFlightExpansionMutationRebuildsAgainstNewSnapshot() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)
        let nestedChildID = try #require(
            session.snapshot().nodesByID.first { entry in
                entry.value.attributes.contains { attribute in
                    attribute.name == "id" && attribute.value == "nested-child"
                }
            }?.key
        )

        view.suspendNextRowRenderBuildForTesting()
        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowRenderBuildSuspensionForTesting()

        let didRenderAttribute = await waitForRenderedDocumentTreeUpdate(
            in: view,
            session: session,
            update: {
                session.applyAttributeModified(nestedChildID, name: "data-state", value: "ready")
            },
            until: {
                view.documentTextForTesting.contains("<span id=\"nested-child\" data-state=\"ready\"></span>")
            }
        )

        #expect(didRenderAttribute)
        #expect(view.documentTextForTesting.contains("<span id=\"nested-child\" data-state=\"ready\"></span>"))
    }

    @Test
    func hidingDuringInFlightRowRenderBuildCancelsStaleApply() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)

        view.suspendNextRowRenderBuildForTesting()
        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowRenderBuildSuspensionForTesting()

        view.setRenderingActive(false)
        await view.waitForRowDocumentForTesting()

        #expect(!view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))

        view.resumeRowRenderBuildForTesting()
        await view.waitForRowDocumentForTesting()

        #expect(!view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))

        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()

        #expect(view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))
    }

    @Test
    func selectionChangeUpdatesDecorationsWithoutRebuildingRowRender() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)
        let selectedRowCounts = await view.selectionObservationDeliveryForTesting.values {
            view.selectedRowRectsForTesting().count
        }
        view.resetPerformanceCountersForTesting()

        let htmlID = try #require(
            session.snapshot().nodesByID.first { entry in
                entry.value.localName == "html"
            }?.key
        )
        session.selectNode(htmlID)

        let didRenderSelection = await selectedRowCounts.waitUntil { $0 == 1 } != nil
        #expect(didRenderSelection)
        #expect(view.buildRowRenderPlanCallCountForTesting == 0)
    }

    @Test
    func hiddenSelectionChangeDefersRevealUntilRenderingResumes() async throws {
        let session = makeDOMSession(root: selectionRevealRaceDocument())
        let view = await makeTreeView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 96)
        view.layoutIfNeeded()
        let initialSnapshot = session.snapshot()
        let bodyID = try #require(
            initialSnapshot.nodesByID.first { entry in
                entry.value.localName == "body"
            }?.key
        )
        let targetID = try #require(
            initialSnapshot.nodesByID.first { entry in
                entry.value.attributes.contains { attribute in
                    attribute.name == "id" && attribute.value == "selected-target"
                }
            }?.key
        )
        session.applySetChildNodes(
            parent: bodyID,
            children: selectionRevealRaceBodyChildren(prefixCount: 80),
            eventSequence: 10
        )
        await view.waitForRowDocumentForTesting()
        view.contentOffset = .zero
        view.clearDrawnSelectedRowRectsForTesting()
        let observedSelectionRevisions = await view.selectionObservationDeliveryForTesting.values {
            session.selectionRevision
        }
        defer {
            observedSelectionRevisions.cancel()
        }

        view.setRenderingActive(false)
        session.selectNode(targetID)
        let hiddenSelectionRevision = session.selectionRevision
        #expect(await observedSelectionRevisions.waitUntil { $0 >= hiddenSelectionRevision } != nil)
        await view.waitForRowDocumentForTesting()

        #expect(view.contentOffset.y == 0)
        #expect(view.drawnSelectedRowRectsForTesting.isEmpty)

        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()
        view.layoutIfNeeded()

        let revealState = renderedSelectionRevealState(in: view, containing: "selected-target")
        #expect(revealState.isSelectedRowRevealed)
        #expect(view.drawnSelectedRowRectsForTesting.isEmpty == false)
    }

    @Test
    func hiddenSelectionChangeClearsMultiSelectionBeforePendingDOMInvalidationFlush() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)
        let documentID = try #require(session.currentPageRootNode?.id.documentID)
        let visibleDivID = DOMNode.ID(documentID: documentID, nodeID: .init(7))
        let inputID = DOMNode.ID(documentID: documentID, nodeID: .init(12))

        view.primaryClickRowForTesting(containing: "<div id=\"start-of-content\"", modifiers: .command)
        view.primaryClickRowForTesting(containing: "<input disabled>", modifiers: .command)
        view.primaryClickRowForTesting(containing: "<article", modifiers: .command)
        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.map(\.text) == [
            "      <div id=\"start-of-content\" data-testid=\"cellInnerDiv\"></div>",
            "      <input disabled>",
            "      <article>…</article>",
        ])

        let observedTreeRenderRevisions = await view.documentObservationDeliveryForTesting.values {
            session.treeRenderInvalidation.revision
        }
        let observedSelectionRevisions = await view.selectionObservationDeliveryForTesting.values {
            session.selectionRevision
        }
        defer {
            observedTreeRenderRevisions.cancel()
            observedSelectionRevisions.cancel()
        }

        view.setRenderingActive(false)
        session.applyAttributeModified(visibleDivID, name: "data-visible", value: "while-hidden")
        session.selectNode(inputID)
        let hiddenTreeRevision = session.treeRevision
        let hiddenSelectionRevision = session.selectionRevision
        #expect(await observedTreeRenderRevisions.waitUntil { $0 >= hiddenTreeRevision } != nil)
        #expect(await observedSelectionRevisions.waitUntil { $0 >= hiddenSelectionRevision } != nil)
        await view.waitForRowDocumentForTesting()

        #expect(!view.documentTextForTesting.contains("data-visible=\"while-hidden\""))
        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.count == 3)

        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()
        view.layoutIfNeeded()

        #expect(view.documentTextForTesting.contains("data-visible=\"while-hidden\""))
        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.isEmpty)
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func hiddenSelectionChangeAwayAndBackStillClearsMultiSelectionOnResume() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)
        let snapshot = session.snapshot()
        let inputID = try #require(
            snapshot.nodesByID.first { entry in
                entry.value.localName == "input"
            }?.key
        )
        let articleID = try #require(
            snapshot.nodesByID.first { entry in
                entry.value.localName == "article"
            }?.key
        )

        view.primaryClickRowForTesting(containing: "<input disabled>")
        view.primaryClickRowForTesting(containing: "<div id=\"start-of-content\"", modifiers: .command)
        view.primaryClickRowForTesting(containing: "<article", modifiers: .command)
        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.count == 3)
        #expect(session.selectedNode?.id == inputID)
        view.routeCurrentSelectionInvalidationForTesting()
        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.count == 3)

        let observedSelectionRevisions = await view.selectionObservationDeliveryForTesting.values {
            session.selectionRevision
        }
        defer {
            observedSelectionRevisions.cancel()
        }

        view.setRenderingActive(false)
        session.selectNode(articleID)
        session.selectNode(inputID)
        let hiddenSelectionRevision = session.selectionRevision
        #expect(await observedSelectionRevisions.waitUntil { $0 >= hiddenSelectionRevision } != nil)

        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.count == 3)

        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()
        view.layoutIfNeeded()

        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.isEmpty)
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func selectionRevealWaitsForInFlightRowRenderBuild() async throws {
        let session = makeDOMSession(root: selectionRevealRaceDocument())
        let view = await makeTreeView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 96)
        view.layoutIfNeeded()

        let initialSnapshot = session.snapshot()
        let bodyID = try #require(
            initialSnapshot.nodesByID.first { entry in
                entry.value.localName == "body"
            }?.key
        )
        let targetID = try #require(
            initialSnapshot.nodesByID.first { entry in
                entry.value.attributes.contains { attribute in
                    attribute.name == "id" && attribute.value == "selected-target"
                }
            }?.key
        )

        view.suspendNextRowRenderBuildForTesting()
        session.applySetChildNodes(
            parent: bodyID,
            children: selectionRevealRaceBodyChildren(prefixCount: 80)
        )
        await view.waitForRowRenderBuildSuspensionForTesting()

        session.selectNode(targetID)
        view.routeCurrentSelectionInvalidationForTesting()

        view.resumeRowRenderBuildForTesting()
        await view.waitForRowDocumentForTesting()

        let selectedLine = try #require(
            view.rowSnapshotsForTesting.first { snapshot in
                snapshot.text.contains("id=\"selected-target\"")
            }
        )
        let selectedRowY = CGFloat(selectedLine.rowIndex) * view.rowHeightForTesting
        let visibleMinY = view.contentOffset.y
        let visibleMaxY = view.contentOffset.y + view.bounds.height

        #expect(view.contentOffset.y > view.bounds.height)
        #expect(selectedRowY >= visibleMinY - view.rowHeightForTesting)
        #expect(selectedRowY + view.rowHeightForTesting <= visibleMaxY + view.rowHeightForTesting)
    }

    @Test
    func selectionRevealSkipsStaleSelectedNodeDuringPendingInspectSelection() async throws {
        let protocolTargetID = ProtocolTarget.ID("page-main")
        let session = makeDOMSession(root: selectionRevealRaceDocument())
        let view = await makeTreeView(session: session)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 96)
        view.layoutIfNeeded()

        let initialSnapshot = session.snapshot()
        let bodyID = try #require(
            initialSnapshot.nodesByID.first { entry in
                entry.value.localName == "body"
            }?.key
        )
        let oldSelectedNodeID = try #require(
            initialSnapshot.nodesByID.first { entry in
                entry.value.attributes.contains { attribute in
                    attribute.name == "id" && attribute.value == "selected-target"
                }
            }?.key
        )

        view.suspendNextRowRenderBuildForTesting()
        session.applySetChildNodes(
            parent: bodyID,
            children: selectionRevealRaceBodyChildren(prefixCount: 80)
        )
        await view.waitForRowRenderBuildSuspensionForTesting()

        session.selectNode(oldSelectedNodeID)
        view.routeCurrentSelectionInvalidationForTesting()

        let command = session.beginInspectSelectionRequest(
            targetID: protocolTargetID,
            objectID: "next-selection"
        )
        let selectionRequestID: DOMSelection.Request.ID
        guard case let .success(.requestNode(id, _, _)) = command else {
            Issue.record("Expected pending DOM.requestNode selection")
            return
        }
        selectionRequestID = id

        view.resumeRowRenderBuildForTesting()
        await view.waitForRowDocumentForTesting()

        #expect(session.hasPendingSelectionRequest)
        #expect(view.contentOffset.y < view.bounds.height)

        var requestNodeResult: DOMNode.RequestResolution?
        let revealedSelectionState = await waitForSelectionRenderedState(
            in: view,
            update: {
                requestNodeResult = session.applyRequestNodeResult(
                    selectionRequestID: selectionRequestID,
                    targetID: protocolTargetID,
                    nodeID: .init(4)
                )
            },
            sample: {
                renderedSelectionRevealState(
                    in: view,
                    containing: "id=\"selected-target\""
                )
            },
            until: {
                $0.isSelectedRowRevealed
            }
        )
        let result = try #require(requestNodeResult)
        guard case let .resolved(resolvedNodeID) = result else {
            Issue.record("Expected pending DOM.requestNode selection to resolve")
            return
        }
        let revealState = try #require(revealedSelectionState)

        #expect(resolvedNodeID == oldSelectedNodeID)
        #expect(!session.hasPendingSelectionRequest)
        #expect(revealState.contentOffsetY > revealState.boundsHeight)
        #expect(revealState.isSelectedRowVisible)
    }

    @Test
    func documentResetClearsLocalExpansionStateEvenWhenNodeIDsRepeat() async throws {
        let session = makeDOMSession()
        let view = await makeTreeView(session: session)

        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowDocumentForTesting()
        #expect(view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))

        let targetID = ProtocolTarget.ID("page-main")
        let didRenderResetDocument = await waitForRenderedDocumentTreeUpdate(
            in: view,
            session: session,
            update: {
                session.reset()
                session.applyTargetCreated(
                    ProtocolTarget.Record(
                        id: targetID,
                        kind: .page,
                        frameID: DOMFrame.ID("main-frame")
                    ),
                    makeCurrentMainPage: true
                )
                _ = session.replaceDocumentRoot(documentNode(), targetID: targetID)
            },
            until: {
                let text = view.documentTextForTesting
                return text.contains("<article>…</article>")
                    && !text.contains("<span id=\"nested-child\"></span>")
            }
        )
        #expect(didRenderResetDocument)

        #expect(view.documentTextForTesting.contains("<article>…</article>"))
        #expect(!view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))
    }

    @Test
    func openingUnloadedRowRequestsChildrenThroughInjectedAction() async throws {
        let session = makeDOMSession(root: documentWithDeferredArticle())
        let recorder = NodeRequestRecorder()
        let view = DOMTreeTextView(
            dom: session,
            requestChildrenAction: { nodeID in
                recorder.record(nodeID)
                return true
            }
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        await view.waitForRowDocumentForTesting()

        view.toggleRowForTesting(containing: "<article")
        let requestedNodeID = await recorder.next()

        #expect(session.node(for: requestedNodeID)?.localName == "article")
    }

    @Test
    func initialSelectionOpensProjectedFrameAncestors() async throws {
        let fixture = try makeProjectedFrameSession()
        fixture.session.selectNode(fixture.selectedNodeID)

        let view = await makeTreeView(session: fixture.session)

        let projection = fixture.session.treeProjection(rootTargetID: fixture.pageTargetID)
        #expect(fixture.session.snapshot().nodesByID[fixture.frameRootID]?.parentID == nil)
        #expect(projection.ancestorNodeIDs(of: fixture.selectedNodeID).contains(fixture.frameRootID))
        #expect(view.documentTextForTesting.contains("#document"))
        #expect(view.documentTextForTesting.contains("<img id=\"ad-node\">"))
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func selectingProjectedFrameNodeOpensComposedAncestors() async throws {
        let fixture = try makeProjectedFrameSession()
        let view = await makeTreeView(session: fixture.session)

        let sampleRenderedState: @MainActor @Sendable () -> RenderedDOMTreeState = {
            view.layoutIfNeeded()
            return RenderedDOMTreeState(
                text: view.documentTextForTesting,
                selectedRowCount: view.selectedRowRectsForTesting().count
            )
        }
        let didRenderSelection = await waitForSelectionObservationRender(
            in: view,
            session: fixture.session,
            update: {
                fixture.session.selectNode(fixture.selectedNodeID)
            },
            until: {
                sampleRenderedState().hasProjectedFrameSelection
            }
        )

        let projection = fixture.session.treeProjection(rootTargetID: fixture.pageTargetID)
        #expect(fixture.session.snapshot().nodesByID[fixture.frameRootID]?.parentID == nil)
        #expect(projection.ancestorNodeIDs(of: fixture.selectedNodeID).contains(fixture.frameRootID))
        #expect(didRenderSelection)
    }
}

private struct RenderedDOMTreeState: Equatable, Sendable {
    var text: String
    var selectedRowCount: Int

    var hasProjectedFrameSelection: Bool {
        text.contains("#document")
            && text.contains("<img id=\"ad-node\">")
            && selectedRowCount == 1
    }
}

private struct RenderedSelectionRevealState: Equatable, Sendable {
    var contentOffsetY: Double
    var boundsHeight: Double
    var selectedRowY: Double?
    var rowHeight: Double

    var isSelectedRowRevealed: Bool {
        contentOffsetY > boundsHeight && isSelectedRowVisible
    }

    var isSelectedRowVisible: Bool {
        guard let selectedRowY else {
            return false
        }
        let visibleMinY = contentOffsetY
        let visibleMaxY = contentOffsetY + boundsHeight
        return selectedRowY >= visibleMinY - rowHeight
            && selectedRowY + rowHeight <= visibleMaxY + rowHeight
    }
}

private func colorsEqual(_ lhs: UIColor, _ rhs: UIColor) -> Bool {
    CFEqual(lhs.cgColor, rhs.cgColor)
}

@MainActor
private final class NodeRequestRecorder {
    private var nodeID: DOMNode.ID?
    private var continuation: CheckedContinuation<DOMNode.ID, Never>?

    func record(_ nodeID: DOMNode.ID) {
        self.nodeID = nodeID
        continuation?.resume(returning: nodeID)
        continuation = nil
    }

    func next() async -> DOMNode.ID {
        if let nodeID {
            return nodeID
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
private final class NodeActionRecorder {
    private var nodeIDs: [DOMNode.ID] = []
    private var owners: [DOMPageHighlightOwner] = []
    private var continuation: CheckedContinuation<DOMNode.ID, Never>?

    func record(_ nodeID: DOMNode.ID, owner: DOMPageHighlightOwner) {
        nodeIDs.append(nodeID)
        owners.append(owner)
        continuation?.resume(returning: nodeID)
        continuation = nil
    }

    func nextNodeID() async -> DOMNode.ID {
        if let nodeID = nodeIDs.first {
            return nodeID
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    var recordedNodeIDs: [DOMNode.ID] {
        nodeIDs
    }

    var recordedOwners: [DOMPageHighlightOwner] {
        owners
    }

    func removeAll() {
        nodeIDs.removeAll(keepingCapacity: true)
        owners.removeAll(keepingCapacity: true)
    }
}

@MainActor
private final class VoidActionRecorder {
    private(set) var recordCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func record() {
        recordCount += 1
        continuation?.resume()
        continuation = nil
    }

    func next() async {
        if recordCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
private final class CancellableVoidActionRecorder {
    private(set) var startedCount = 0
    private(set) var cancellationCount = 0
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var runContinuation: CheckedContinuation<Void, Never>?
    private var didRecordCancellation = false

    func run() async {
        startedCount += 1
        startContinuation?.resume()
        startContinuation = nil
        if Task.isCancelled {
            recordCancellation()
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if didRecordCancellation {
                    continuation.resume()
                } else {
                    runContinuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.recordCancellation()
            }
        }
    }

    private func recordCancellation() {
        guard !didRecordCancellation else {
            return
        }
        didRecordCancellation = true
        let continuation = runContinuation
        runContinuation = nil
        continuation?.resume()
        cancellationCount += 1
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    func nextStart() async {
        if startedCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            self.startContinuation = continuation
        }
    }

    func nextCancellation() async {
        if cancellationCount > 0 {
            return
        }
        await withCheckedContinuation { continuation in
            self.cancellationContinuation = continuation
        }
    }
}

@MainActor
private func makeTreeView(root: DOMNode.Payload = documentNode()) async -> DOMTreeTextView {
    await makeTreeView(session: makeDOMSession(root: root))
}

@MainActor
private func makeTreeView(session: DOMSession) async -> DOMTreeTextView {
    let view = DOMTreeTextView(dom: session)
    view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
    view.layoutIfNeeded()
    view.setRenderingActive(true)
    await view.waitForRowDocumentForTesting()
    return view
}

@MainActor
private func waitForRenderedDocumentTreeUpdate(
    in view: DOMTreeTextView,
    session: DOMSession,
    timeout: Duration = .seconds(1),
    update: @MainActor () -> Void,
    until condition: @escaping @MainActor @Sendable () -> Bool
) async -> Bool {
    update()
    let expectedTreeRevision = session.treeRevision
    let didApplyTreeRevision = await view.waitForRowDocumentAppliedTreeRevisionForTesting(
        expectedTreeRevision,
        timeout: timeout
    )
    view.layoutIfNeeded()
    return didApplyTreeRevision && condition()
}

@MainActor
private func waitForSelectionObservationRender(
    in view: DOMTreeTextView,
    session: DOMSession,
    timeout: Duration = .seconds(1),
    update: @MainActor () -> Void,
    until condition: @escaping @MainActor @Sendable () -> Bool
) async -> Bool {
    let observedSelectionRevisions = await view.selectionObservationDeliveryForTesting.values {
        session.selectionRevision
    }
    defer {
        observedSelectionRevisions.cancel()
    }

    update()
    let expectedSelectionRevision = session.selectionRevision
    let didAlreadyObserveRevision = observedSelectionRevisions.latestValue.map {
        $0 >= expectedSelectionRevision
    } ?? false
    if !didAlreadyObserveRevision {
        let didObserveSelectionRevision = await observedSelectionRevisions.waitUntil(timeout: timeout) {
            $0 >= expectedSelectionRevision
        } != nil
        guard didObserveSelectionRevision else {
            view.layoutIfNeeded()
            return condition()
        }
    }

    await view.waitForRowDocumentForTesting()
    view.layoutIfNeeded()
    return condition()
}

@MainActor
private func waitForSelectionRenderedState<State: Sendable>(
    in view: DOMTreeTextView,
    timeout: Duration = .seconds(1),
    update: @MainActor () -> Void,
    sample: @escaping @MainActor @Sendable () -> State,
    until condition: @escaping @Sendable (State) -> Bool
) async -> State? {
    let observedStates = await view.selectionObservationDeliveryForTesting.values {
        sample()
    }
    defer {
        observedStates.cancel()
    }

    update()
    if let latestState = observedStates.latestValue, condition(latestState) {
        return latestState
    }
    if let renderedState = await observedStates.waitUntil(timeout: timeout, condition) {
        return renderedState
    }
    let fallbackState = sample()
    return condition(fallbackState) ? fallbackState : nil
}

@MainActor
private func renderedSelectionRevealState(
    in view: DOMTreeTextView,
    containing selectedText: String
) -> RenderedSelectionRevealState {
    view.layoutIfNeeded()
    let selectedLine = view.rowSnapshotsForTesting.first { snapshot in
        snapshot.text.contains(selectedText)
    }
    return RenderedSelectionRevealState(
        contentOffsetY: Double(view.contentOffset.y),
        boundsHeight: Double(view.bounds.height),
        selectedRowY: selectedLine.map { Double(CGFloat($0.rowIndex) * view.rowHeightForTesting) },
        rowHeight: Double(view.rowHeightForTesting)
    )
}

@MainActor
private func makeDOMSession(root: DOMNode.Payload = documentNode()) -> DOMSession {
    let targetID = ProtocolTarget.ID("page-main")
    let session = DOMSession()
    session.applyTargetCreated(
        ProtocolTarget.Record(
            id: targetID,
            kind: .page,
            frameID: DOMFrame.ID("main-frame")
        ),
        makeCurrentMainPage: true
    )
    _ = session.replaceDocumentRoot(root, targetID: targetID)
    return session
}

@MainActor
private func makeProjectedFrameSession() throws -> (
    session: DOMSession,
    pageTargetID: ProtocolTarget.ID,
    frameRootID: DOMNode.ID,
    selectedNodeID: DOMNode.ID
) {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-ad-target")
    let frameID = DOMFrame.ID("frame-ad")
    let session = DOMSession()

    session.applyTargetCreated(
        ProtocolTarget.Record(id: pageTargetID, kind: .page, frameID: DOMFrame.ID("main-frame")),
        makeCurrentMainPage: true
    )
    session.applyTargetCreated(
        ProtocolTarget.Record(id: frameTargetID, kind: .frame, frameID: frameID)
    )
    _ = session.replaceDocumentRoot(projectedPageDocument(frameID: frameID), targetID: pageTargetID)
    let frameRootID = session.replaceDocumentRoot(projectedFrameDocument(), targetID: frameTargetID)
    let selectedNodeID = try #require(
        session.snapshot().currentNodeIDByKey[DOMNode.CurrentKey(targetID: frameTargetID, nodeID: .init(8))]
    )

    return (session, pageTargetID, frameRootID, selectedNodeID)
}

private func documentNode() -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(1),
        nodeType: .document,
        nodeName: "#document",
        regularChildren: .loaded([
            DOMNode.Payload(
                nodeID: .init(2),
                nodeType: .documentType,
                nodeName: "html"
            ),
            DOMNode.Payload(
                nodeID: .init(3),
                nodeType: .element,
                nodeName: "HTML",
                localName: "html",
                attributes: [DOMNode.Attribute(name: "lang", value: "en")],
                regularChildren: .loaded([
                    DOMNode.Payload(
                        nodeID: .init(4),
                        nodeType: .element,
                        nodeName: "HEAD",
                        localName: "head",
                        regularChildren: .loaded([
                            DOMNode.Payload(
                                nodeID: .init(5),
                                nodeType: .element,
                                nodeName: "TITLE",
                                localName: "title"
                            ),
                        ])
                    ),
                    bodyNode(article: articleNode()),
                ])
            ),
        ])
    )
}

private func documentWithDeferredArticle() -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(1),
        nodeType: .document,
        nodeName: "#document",
        regularChildren: .loaded([
            DOMNode.Payload(
                nodeID: .init(3),
                nodeType: .element,
                nodeName: "HTML",
                localName: "html",
                regularChildren: .loaded([
                    bodyNode(
                        article: DOMNode.Payload(
                            nodeID: .init(8),
                            nodeType: .element,
                            nodeName: "ARTICLE",
                            localName: "article",
                            regularChildren: .unrequested(count: 1)
                        )
                    ),
                ])
            ),
        ])
    )
}

private func selectionRevealRaceDocument() -> DOMNode.Payload {
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
                            selectionRevealRaceTargetNode(),
                        ])
                    ),
                ])
            ),
        ])
    )
}

private func selectionRevealRaceBodyChildren(prefixCount: Int) -> [DOMNode.Payload] {
    (0..<prefixCount).map { index in
        DOMNode.Payload(
            nodeID: .init(1_000 + index),
            nodeType: .element,
            nodeName: "DIV",
            localName: "div",
            attributes: [DOMNode.Attribute(name: "id", value: "prefix-\(index)")]
        )
    } + [selectionRevealRaceTargetNode()]
}

private func selectionRevealRaceTargetNode() -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(4),
        nodeType: .element,
        nodeName: "DIV",
        localName: "div",
        attributes: [DOMNode.Attribute(name: "id", value: "selected-target")]
    )
}

private func projectedPageDocument(frameID: DOMFrame.ID) -> DOMNode.Payload {
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
                                nodeID: .init(20),
                                nodeType: .element,
                                nodeName: "IFRAME",
                                localName: "iframe",
                                ownerFrameID: frameID,
                                attributes: [DOMNode.Attribute(name: "src", value: "https://frame.example/ad")]
                            ),
                        ])
                    ),
                ])
            ),
        ])
    )
}

private func projectedFrameDocument() -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(101),
        nodeType: .document,
        nodeName: "#document",
        documentURL: "https://frame.example/ad",
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
                                nodeID: .init(8),
                                nodeType: .element,
                                nodeName: "IMG",
                                localName: "img",
                                attributes: [DOMNode.Attribute(name: "id", value: "ad-node")]
                            ),
                        ])
                    ),
                ])
            ),
        ])
    )
}

private func bodyNode(article: DOMNode.Payload) -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(6),
        nodeType: .element,
        nodeName: "BODY",
        localName: "body",
        attributes: [DOMNode.Attribute(name: "class", value: "logged-in env-production")],
        regularChildren: .loaded([
            DOMNode.Payload(
                nodeID: .init(7),
                nodeType: .element,
                nodeName: "DIV",
                localName: "div",
                attributes: [
                    DOMNode.Attribute(name: "id", value: "start-of-content"),
                    DOMNode.Attribute(name: "data-testid", value: "cellInnerDiv"),
                ]
            ),
            DOMNode.Payload(
                nodeID: .init(12),
                nodeType: .element,
                nodeName: "INPUT",
                localName: "input",
                attributes: [DOMNode.Attribute(name: "disabled", value: "")]
            ),
            article,
            DOMNode.Payload(
                nodeID: .init(10),
                nodeType: .text,
                nodeName: "#text",
                nodeValue: "Introducing luma for iOS 26"
            ),
            DOMNode.Payload(
                nodeID: .init(11),
                nodeType: .comment,
                nodeName: "#comment",
                nodeValue: "comment text"
            ),
        ])
    )
}

private func articleNode() -> DOMNode.Payload {
    DOMNode.Payload(
        nodeID: .init(8),
        nodeType: .element,
        nodeName: "ARTICLE",
        localName: "article",
        regularChildren: .loaded([
            DOMNode.Payload(
                nodeID: .init(9),
                nodeType: .element,
                nodeName: "SPAN",
                localName: "span",
                attributes: [DOMNode.Attribute(name: "id", value: "nested-child")]
            ),
        ])
    )
}

private func makeRowDocumentRows(_ texts: [String]) -> [DOMTreeRowRenderPlan] {
    let documentID = DOMDocument.ID(
        targetID: ProtocolTarget.ID("row-document-test"),
        localDocumentLifetimeID: .init(1)
    )
    var utf16Location = 0
    return texts.enumerated().map { index, text in
        let utf16Length = (text as NSString).length
        defer {
            utf16Location += utf16Length + (index + 1 < texts.count ? 1 : 0)
        }
        return DOMTreeRowRenderPlan(
            identity: DOMTreeRowIdentity(
                nodeID: DOMNode.ID(documentID: documentID, nodeID: .init(index + 1)),
                kind: .opening
            ),
            depth: 0,
            rowIndex: index,
            text: text,
            documentRange: NSRange(location: utf16Location, length: utf16Length),
            markupRange: NSRange(location: 0, length: utf16Length),
            tokens: [],
            displayColumnCount: utf16Length,
            hasDisclosure: false,
            isOpen: false
        )
    }
}

private func attributedRowDocument(rows: [DOMTreeRowRenderPlan]) -> NSAttributedString {
    let attributedString = NSMutableAttributedString()
    for (index, row) in rows.enumerated() {
        if index > 0 {
            attributedString.append(NSAttributedString(string: "\n"))
        }
        attributedString.append(NSAttributedString(
            string: row.text,
            attributes: [
                DOMTreeTextDocument.rowIdentityAttribute: row.identity,
            ]
        ))
    }
    return attributedString
}
#endif
