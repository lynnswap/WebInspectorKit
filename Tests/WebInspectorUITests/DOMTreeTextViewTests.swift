#if canImport(UIKit)
import Testing
import UIKit
import WebInspectorTestSupport
@testable import WebInspectorDataKit
@testable import WebInspectorProxyKit
@testable import WebInspectorUI
@testable import WebInspectorUISyntaxBody
@testable import WebInspectorUINetwork
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

@MainActor
@Suite(.serialized)
struct DOMTreeTextViewTests {
    @Test
    func rendersDOMMarkupFromDataKitContext() async throws {
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
    func collapsedDescendantMutationDoesNotRouteCollapsedSubtreeBuild() async throws {
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)
        let articleID = nodeID(8)
        let nestedChildID = nodeID(9)
        let baselineAppliedTreeRevision = view.rowDocumentAppliedTreeRevisionForTesting
        let baselineBuildCount = view.buildRowRenderPlanCallCountForTesting

        #expect(view.documentTextForTesting.contains("<article>…</article>"))
        #expect(!view.documentTextForTesting.contains("data-state=\"ready\""))

        session.applyAttributeModified(nestedChildID, name: "data-state", value: "ready")
        let expectedTreeRevision = session.treeRevision
        let didObserveTreeRevision = await view.waitForObservedTreeRevisionForTesting(expectedTreeRevision)

        #expect(didObserveTreeRevision)
        #expect(view.buildRowRenderPlanCallCountForTesting == baselineBuildCount)
        #expect(DOMTreeTextView.RowRenderBuilder.lastCollectedNodeIDsForTesting.contains(articleID))
        #expect(!DOMTreeTextView.RowRenderBuilder.lastCollectedNodeIDsForTesting.contains(nestedChildID))
        #expect(view.rowDocumentAppliedTreeRevisionForTesting == baselineAppliedTreeRevision)
        #expect(!view.documentTextForTesting.contains("data-state=\"ready\""))
    }

    @Test
    func coalescedVisibleThenCollapsedMutationStillRoutesVisibleUpdate() async throws {
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)
        let visibleDivID = nodeID(7)
        let nestedChildID = nodeID(9)

        #expect(view.documentTextForTesting.contains("<div id=\"start-of-content\" data-testid=\"cellInnerDiv\"></div>"))
        #expect(view.documentTextForTesting.contains("<article>…</article>"))
        #expect(!view.documentTextForTesting.contains("data-hidden=\"ready\""))

        let didRenderVisibleAttribute = await waitForRenderedDocumentTreeUpdate(
            in: view,
            fixture: session,
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
        let session = makeDOMTreeFixture(
            root: DOM.Node(
                id: proxyNodeID(1),
                nodeType: 9,
                nodeName: "#document",
                childNodeCount: 1
            )
        )
        let view = await makeTreeView(fixture: session)
        let rootID = try #require(session.currentPageRootNode?.id)

        #expect(view.documentTextForTesting.isEmpty)

        let didRenderDocumentElement = await waitForRenderedDocumentTreeUpdate(
            in: view,
            fixture: session,
            update: {
                session.applySetChildNodes(
                    parent: rootID,
                    children: [
                        DOM.Node(
                            id: proxyNodeID(2),
                            nodeType: 1,
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
    func selectingNodeUpdatesDataKitSelectionAndRowDecoration() async throws {
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)

        view.selectRowForTesting(containing: "<input disabled>")
        view.layoutIfNeeded()

        #expect(session.selectedNode?.localName == "input")
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func primaryClickingRowUpdatesDataKitSelection() async throws {
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)

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
        #expect(await view.waitForRowDocumentForTesting())

        #expect(view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))
    }

    @Test
    func primaryClickingRowHighlightsSelectedPageNode() async throws {
        let session = makeDOMTreeFixture()
        let recorder = NodeActionRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { nodeID, owner in
                recorder.record(nodeID, owner: owner)
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        view.primaryClickRowForTesting(containing: "<input disabled>")
        let highlightedNodeID = await recorder.nextNodeID()

        #expect(session.selectedNode?.id == highlightedNodeID)
        #expect(session.node(for: highlightedNodeID)?.localName == "input")
        #expect(recorder.recordedOwners == [.selection])
    }

    @Test
    func duplicateSelectionInvalidationCoalescesInFlightPageHighlight() async throws {
        let session = makeDOMTreeFixture()
        let recorder = ControlledNodeActionRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { nodeID, owner in
                try await recorder.run(nodeID, owner: owner)
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        view.primaryClickRowForTesting(containing: "<input disabled>")
        await recorder.waitForInvocationCount(1)
        #expect(await view.waitForObservedTreeRevisionForTesting(session.treeRevision))

        view.routeCurrentSelectionInvalidationForTesting()
        view.routeCurrentSelectionInvalidationForTesting()
        await Task.yield()

        #expect(recorder.invocationCount == 1)
        await recorder.resolveInvocation(at: 0, as: .success)
        await view.waitForPageHighlightTaskForTesting()
        #expect(recorder.recordedOwners == [.selection])
    }

    @Test
    func changingSelectionReplacesInFlightPageHighlight() async throws {
        let session = makeDOMTreeFixture()
        let recorder = ControlledNodeActionRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { nodeID, owner in
                try await recorder.run(nodeID, owner: owner)
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        view.primaryClickRowForTesting(containing: "<input disabled>")
        await recorder.waitForInvocationCount(1)
        let firstNodeID = try #require(session.selectedNode?.id)

        view.primaryClickRowForTesting(containing: "<article")
        await recorder.waitForInvocationCount(2)
        let secondNodeID = try #require(session.selectedNode?.id)
        #expect(firstNodeID != secondNodeID)

        // The cancelled A completion must not clear B's operation token and
        // allow a duplicate B invalidation to launch a third wire command.
        await Task.yield()
        view.routeCurrentSelectionInvalidationForTesting()
        await Task.yield()
        #expect(recorder.invocationCount == 2)
        #expect(recorder.recordedNodeIDs == [firstNodeID, secondNodeID])

        await recorder.resolveInvocation(at: 1, as: .success)
        await view.waitForPageHighlightTaskForTesting()
        #expect(recorder.recordedOwners == [.selection, .selection])
    }

    @Test
    func staleSelectionHighlightCompletionCannotClearCurrentABAIntent() async throws {
        let session = makeDOMTreeFixture()
        let recorder = ControlledNodeActionRecorder(ignoresCancellation: true)
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { nodeID, owner in
                try await recorder.run(nodeID, owner: owner)
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        view.primaryClickRowForTesting(containing: "<input disabled>")
        await recorder.waitForInvocationCount(1)
        let nodeA = try #require(session.selectedNode?.id)

        view.primaryClickRowForTesting(containing: "<article")
        await recorder.waitForInvocationCount(2)
        let nodeB = try #require(session.selectedNode?.id)

        view.primaryClickRowForTesting(containing: "<input disabled>")
        await recorder.waitForInvocationCount(3)
        #expect(session.selectedNode?.id == nodeA)

        // Complete stale A1 and B2 after A3 is current. Neither completion
        // owns A3's intent, even though A1 has the same semantic node ID.
        await recorder.resolveInvocation(at: 0, as: .success)
        await recorder.resolveInvocation(at: 1, as: .success)
        await recorder.resolveInvocation(at: 2, as: .failure)
        await view.waitForPageHighlightTaskForTesting()

        view.routeCurrentSelectionInvalidationForTesting()
        await recorder.waitForInvocationCount(4)
        #expect(recorder.recordedNodeIDs == [nodeA, nodeB, nodeA, nodeA])
        await recorder.resolveInvocation(at: 3, as: .success)
        await view.waitForPageHighlightTaskForTesting()
    }

    @Test
    func selectionHighlightFailureAllowsLaterInvalidationRetry() async throws {
        let session = makeDOMTreeFixture()
        let recorder = ControlledNodeActionRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { nodeID, owner in
                try await recorder.run(nodeID, owner: owner)
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        view.primaryClickRowForTesting(containing: "<input disabled>")
        await recorder.waitForInvocationCount(1)
        #expect(await view.waitForObservedTreeRevisionForTesting(session.treeRevision))
        await recorder.resolveInvocation(at: 0, as: .failure)
        await view.waitForPageHighlightTaskForTesting()

        view.routeCurrentSelectionInvalidationForTesting()
        await recorder.waitForInvocationCount(2)
        await recorder.resolveInvocation(at: 1, as: .success)
        await view.waitForPageHighlightTaskForTesting()

        #expect(recorder.recordedNodeIDs.count == 2)
        #expect(recorder.recordedNodeIDs[0] == recorder.recordedNodeIDs[1])
        #expect(recorder.recordedOwners == [.selection, .selection])
    }

    @Test
    func hoverEndRestoresSelectedPageHighlight() async throws {
        let session = makeDOMTreeFixture()
        let restoreRecorder = VoidActionRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { _, _ in },
            restoreHighlightAction: {
                restoreRecorder.record()
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        view.primaryClickRowForTesting(containing: "<input disabled>")
        view.hoverRowForTesting(containing: "<article")
        view.endHoverForTesting()
        await restoreRecorder.next()

        #expect(session.selectedNode?.localName == "input")
    }

    @Test
    func repeatedHoverEndCancelsPendingRestoreHighlight() async throws {
        let session = makeDOMTreeFixture()
        let restoreRecorder = VoidActionRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { _, _ in },
            restoreHighlightAction: {
                restoreRecorder.record()
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

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
        let session = makeDOMTreeFixture()
        let highlightRecorder = NodeActionRecorder()
        let restoreRecorder = VoidActionRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { nodeID, owner in
                highlightRecorder.record(nodeID, owner: owner)
            },
            restoreHighlightAction: {
                restoreRecorder.record()
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        view.hoverRowForTesting(containing: "<article")
        _ = await highlightRecorder.nextNodeID()

        view.setRenderingActive(false)
        await restoreRecorder.next()

        #expect(highlightRecorder.recordedOwners == [.transient])
        #expect(restoreRecorder.recordCount == 1)
    }

    @Test
    func hidingWithQueuedHoverRestorePreservesHighlightRestoreTask() async throws {
        let session = makeDOMTreeFixture()
        let restoreRecorder = VoidActionRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { _, _ in },
            restoreHighlightAction: {
                restoreRecorder.record()
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

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
        let session = makeDOMTreeFixture()
        let highlightRecorder = NodeActionRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { nodeID, owner in
                highlightRecorder.record(nodeID, owner: owner)
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

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
        let session = makeDOMTreeFixture()
        let highlightRecorder = NodeActionRecorder()
        let restoreRecorder = CancellableVoidActionRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { nodeID, owner in
                highlightRecorder.record(nodeID, owner: owner)
            },
            restoreHighlightAction: {
                await restoreRecorder.run()
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

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
    func pageHighlightActionsOverrideElementPickerState() async throws {
        let session = makeDOMTreeFixture()
        session.isSelectingElement = true
        let highlightRecorder = NodeActionRecorder()
        let restoreRecorder = VoidActionRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            highlightNodeAction: { nodeID, owner in
                highlightRecorder.record(nodeID, owner: owner)
            },
            restoreHighlightAction: {
                restoreRecorder.record()
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        view.primaryClickRowForTesting(containing: "<input disabled>")
        let selectionHighlightedNodeID = await highlightRecorder.nextNodeID()

        #expect(session.selectedNode?.id == selectionHighlightedNodeID)
        #expect(session.node(for: selectionHighlightedNodeID)?.localName == "input")
        #expect(highlightRecorder.recordedOwners == [.selection])
        highlightRecorder.removeAll()

        view.hoverRowForTesting(containing: "<article")
        let hoverHighlightedNodeID = await highlightRecorder.nextNodeID()

        #expect(session.node(for: hoverHighlightedNodeID)?.localName == "article")
        #expect(highlightRecorder.recordedOwners == [.transient])

        view.endHoverForTesting()
        await restoreRecorder.next()

        #expect(session.selectedNode?.localName == "input")
        #expect(restoreRecorder.recordCount == 1)
    }

    @Test
    func expandedElementRendersChildrenAndClosingTag() async throws {
        let view = await makeTreeView()

        view.toggleRowForTesting(containing: "<article")
        #expect(await view.waitForRowDocumentForTesting())

        let text = view.documentTextForTesting
        #expect(text.contains("<article>"))
        #expect(text.contains("<span id=\"nested-child\"></span>"))
        #expect(text.contains("</article>"))
        #expect(!text.contains("<article>…</article>"))
    }

    @Test
    func localMarkupLookupUsesIndexedOpeningRow() async throws {
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)

        view.toggleRowForTesting(containing: "<article")
        #expect(await view.waitForRowDocumentForTesting())

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
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)

        view.toggleRowForTesting(containing: "<article")
        #expect(await view.waitForRowDocumentForTesting())

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
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)

        view.toggleRowForTesting(containing: "<article")
        #expect(await view.waitForRowDocumentForTesting())
        #expect(view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))

        let nestedChildID = nodeID(9)

        let didRenderAttribute = await waitForRenderedDocumentTreeUpdate(
            in: view,
            fixture: session,
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
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)

        view.toggleRowForTesting(containing: "<article")
        #expect(await view.waitForRowDocumentForTesting())
        view.resetPerformanceCountersForTesting()

        let nestedChildID = nodeID(9)

        let didRenderAttribute = await waitForRenderedDocumentTreeUpdate(
            in: view,
            fixture: session,
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
    }

    @Test
    func hiddenVisibleMutationDefersRenderingUntilRenderingResumes() async throws {
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)
        let visibleDivID = nodeID(7)
        let baselineText = view.documentTextForTesting
        view.resetPerformanceCountersForTesting()

        view.setRenderingActive(false)
        session.applyAttributeModified(visibleDivID, name: "data-visible", value: "deferred")
        let hiddenRevision = session.treeRevision
        #expect(await view.waitForPendingDOMInvalidationForTesting(hiddenRevision))

        #expect(view.rowDocumentAppliedTreeRevisionForTesting < hiddenRevision)
        #expect(view.buildRowRenderPlanCallCountForTesting == 0)
        #expect(view.documentTextForTesting == baselineText)
        #expect(!view.documentTextForTesting.contains("data-visible=\"deferred\""))

        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        #expect(view.buildRowRenderPlanCallCountForTesting == 1)
        #expect(view.documentTextForTesting.contains("data-visible=\"deferred\""))
    }

    @Test
    func inFlightExpansionMutationRebuildsAgainstNewSnapshot() async throws {
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)
        let nestedChildID = nodeID(9)

        view.suspendNextRowRenderBuildForTesting()
        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowRenderBuildSuspensionForTesting()

        let didRenderAttribute = await waitForRenderedDocumentTreeUpdate(
            in: view,
            fixture: session,
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
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)

        view.suspendNextRowRenderBuildForTesting()
        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowRenderBuildSuspensionForTesting()

        view.setRenderingActive(false)
        #expect(await view.waitForRowDocumentForTesting())

        #expect(!view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))

        view.resumeRowRenderBuildForTesting()
        #expect(await view.waitForRowDocumentForTesting())

        #expect(!view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))

        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        #expect(view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))
    }

    @Test
    func selectionChangeUpdatesDecorationsWithoutRebuildingRowRender() async throws {
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)
        view.resetPerformanceCountersForTesting()

        let htmlID = try #require(
            session.snapshot().nodesByID.first { entry in
                entry.value.localName == "html"
            }?.key
        )
        session.selectNode(htmlID)
        #expect(await view.waitForObservedTreeRevisionForTesting(session.selectionRevision))
        view.routeCurrentSelectionInvalidationForTesting()
        view.layoutIfNeeded()

        #expect(view.selectedRowRectsForTesting().count == 1)
        #expect(view.buildRowRenderPlanCallCountForTesting == 0)
    }

    @Test
    func hiddenSelectionChangeDefersRevealUntilRenderingResumes() async throws {
        let session = makeDOMTreeFixture(root: selectionRevealRaceDocument())
        let view = await makeTreeView(fixture: session)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 96)
        view.layoutIfNeeded()
        let bodyID = nodeID(3)
        let targetID = nodeID(4)
        session.applySetChildNodes(
            parent: bodyID,
            children: selectionRevealRaceBodyChildren(prefixCount: 80),
            eventSequence: 10
        )
        #expect(await view.waitForRowDocumentForTesting())
        view.contentOffset = .zero
        view.clearDrawnSelectedRowRectsForTesting()

        view.setRenderingActive(false)
        session.selectNode(targetID)
        let hiddenSelectionRevision = session.selectionRevision
        #expect(await view.waitForObservedTreeRevisionForTesting(hiddenSelectionRevision))

        #expect(view.contentOffset.y == 0)
        #expect(view.drawnSelectedRowRectsForTesting.isEmpty)

        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())
        view.layoutIfNeeded()

        let revealState = renderedSelectionRevealState(in: view, containing: "selected-target")
        #expect(revealState.isSelectedRowRevealed)
        #expect(view.drawnSelectedRowRectsForTesting.isEmpty == false)
    }

    @Test
    func hiddenSelectionChangeClearsMultiSelectionBeforePendingDOMInvalidationFlush() async throws {
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)
        let visibleDivID = nodeID(7)
        let inputID = nodeID(12)

        view.primaryClickRowForTesting(containing: "<div id=\"start-of-content\"", modifiers: .command)
        view.primaryClickRowForTesting(containing: "<input disabled>", modifiers: .command)
        view.primaryClickRowForTesting(containing: "<article", modifiers: .command)
        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.map(\.text) == [
            "      <div id=\"start-of-content\" data-testid=\"cellInnerDiv\"></div>",
            "      <input disabled>",
            "      <article>…</article>",
        ])

        view.setRenderingActive(false)
        session.applyAttributeModified(visibleDivID, name: "data-visible", value: "while-hidden")
        session.selectNode(inputID)
        let hiddenTreeRevision = session.treeRevision
        let hiddenSelectionRevision = session.selectionRevision
        #expect(await view.waitForObservedTreeRevisionForTesting(hiddenSelectionRevision))
        #expect(hiddenSelectionRevision >= hiddenTreeRevision)

        #expect(view.rowDocumentAppliedTreeRevisionForTesting < hiddenTreeRevision)
        #expect(!view.documentTextForTesting.contains("data-visible=\"while-hidden\""))
        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.count == 3)

        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())
        view.layoutIfNeeded()

        #expect(view.documentTextForTesting.contains("data-visible=\"while-hidden\""))
        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.isEmpty)
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func hiddenSelectionChangeAwayAndBackStillClearsMultiSelectionOnResume() async throws {
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)
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

        view.setRenderingActive(false)
        session.selectNode(articleID)
        session.selectNode(inputID)
        let hiddenSelectionRevision = session.selectionRevision
        #expect(await view.waitForObservedTreeRevisionForTesting(hiddenSelectionRevision))

        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.count == 3)

        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())
        view.layoutIfNeeded()

        #expect(view.multiSelectedRowSnapshotsInDisplayOrderForTesting.isEmpty)
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func selectionRevealWaitsForInFlightRowRenderBuild() async throws {
        let session = makeDOMTreeFixture(root: selectionRevealRaceDocument())
        let view = await makeTreeView(fixture: session)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 96)
        view.layoutIfNeeded()

        let bodyID = nodeID(3)
        let targetID = nodeID(4)

        view.suspendNextRowRenderBuildForTesting()
        session.applySetChildNodes(
            parent: bodyID,
            children: selectionRevealRaceBodyChildren(prefixCount: 80)
        )
        await view.waitForRowRenderBuildSuspensionForTesting()

        session.selectNode(targetID)
        view.routeCurrentSelectionInvalidationForTesting()

        view.resumeRowRenderBuildForTesting()
        #expect(await view.waitForRowDocumentForTesting())

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
    func selectionRevealUsesLatestSelectionDuringInFlightRowRenderBuild() async throws {
        let session = makeDOMTreeFixture(root: selectionRevealRaceDocument())
        let view = await makeTreeView(fixture: session)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 96)
        view.layoutIfNeeded()

        let initialSnapshot = session.snapshot()
        let bodyID = try #require(
            initialSnapshot.nodesByID.first { entry in
                entry.value.localName == "body"
            }?.key
        )
        let oldSelectedNodeID = nodeID(4)
        let latestSelectedNodeID = nodeID(1_070)

        view.suspendNextRowRenderBuildForTesting()
        session.applySetChildNodes(
            parent: bodyID,
            children: selectionRevealRaceBodyChildren(prefixCount: 80)
        )
        await view.waitForRowRenderBuildSuspensionForTesting()

        session.selectNode(oldSelectedNodeID)
        #expect(await view.waitForObservedTreeRevisionForTesting(session.selectionRevision))
        view.routeCurrentSelectionInvalidationForTesting()
        session.selectNode(latestSelectedNodeID)
        #expect(await view.waitForObservedTreeRevisionForTesting(session.selectionRevision))
        view.routeCurrentSelectionInvalidationForTesting()

        view.resumeRowRenderBuildForTesting()
        #expect(await view.waitForRowDocumentForTesting())

        let revealState = renderedSelectionRevealState(
            in: view,
            containing: "id=\"prefix-70\""
        )
        #expect(session.selectedNode?.id == latestSelectedNodeID)
        #expect(revealState.contentOffsetY > revealState.boundsHeight)
        #expect(revealState.isSelectedRowVisible)
    }

    @Test
    func documentResetClearsLocalExpansionStateEvenWhenNodeIDsRepeat() async throws {
        let session = makeDOMTreeFixture()
        let view = await makeTreeView(fixture: session)

        view.toggleRowForTesting(containing: "<article")
        #expect(await view.waitForRowDocumentForTesting())
        #expect(view.documentTextForTesting.contains("<span id=\"nested-child\"></span>"))

        let didRenderResetDocument = await waitForRenderedDocumentTreeUpdate(
            in: view,
            fixture: session,
            update: {
                session.replaceDocumentRoot(documentNode())
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
        let session = makeDOMTreeFixture(root: documentWithDeferredArticle())
        let recorder = NodeRequestRecorder()
        let view = DOMTreeTextView(
            context: session.context,
            requestChildrenAction: { nodeID in
                recorder.record(nodeID)
                return true
            }
        )
        configureTreeViewForDeterministicTesting(view)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        view.toggleRowForTesting(containing: "<article")
        let requestedNodeID = await recorder.next()

        #expect(session.node(for: requestedNodeID)?.localName == "article")
    }

    @Test
    func initialSelectionOpensProjectedFrameAncestors() async throws {
        let fixture = makeProjectedFrameFixture()
        fixture.session.selectNode(fixture.selectedNodeID)

        let view = await makeTreeView(fixture: fixture.session)

        #expect(fixture.session.snapshot().ancestorNodeIDs(of: fixture.selectedNodeID).contains(fixture.frameRootID))
        #expect(view.documentTextForTesting.contains("#document"))
        #expect(view.documentTextForTesting.contains("<img id=\"ad-node\">"))
        #expect(view.selectedRowRectsForTesting().count == 1)
    }

    @Test
    func selectingProjectedFrameNodeOpensComposedAncestors() async throws {
        let fixture = makeProjectedFrameFixture()
        let view = await makeTreeView(fixture: fixture.session)

        let sampleRenderedState: @MainActor @Sendable () -> RenderedDOMTreeState = {
            view.layoutIfNeeded()
            return RenderedDOMTreeState(
                text: view.documentTextForTesting,
                selectedRowCount: view.selectedRowRectsForTesting().count
            )
        }
        let didRenderSelection = await waitForSelectionObservationRender(
            in: view,
            fixture: fixture.session,
            update: {
                fixture.session.selectNode(fixture.selectedNodeID)
            },
            until: {
                sampleRenderedState().hasProjectedFrameSelection
            }
        )

        #expect(fixture.session.snapshot().ancestorNodeIDs(of: fixture.selectedNodeID).contains(fixture.frameRootID))
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
    private var owners: [DOMTreePageHighlightOwner] = []
    private var continuation: CheckedContinuation<DOMNode.ID, Never>?

    func record(_ nodeID: DOMNode.ID, owner: DOMTreePageHighlightOwner) {
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

    var recordedOwners: [DOMTreePageHighlightOwner] {
        owners
    }

    func removeAll() {
        nodeIDs.removeAll(keepingCapacity: true)
        owners.removeAll(keepingCapacity: true)
    }
}

@MainActor
private final class ControlledNodeActionRecorder {
    enum Resolution {
        case success
        case failure
    }

    private struct IntentionalFailure: Error {}

    private enum Gate {
        case cancellationAware(WebInspectorTestGate)
        case cancellationIgnoring(CancellationIgnoringGate)

        func wait() async {
            switch self {
            case let .cancellationAware(gate):
                await gate.waiter.wait()
            case let .cancellationIgnoring(gate):
                await gate.wait()
            }
        }

        func open() async {
            switch self {
            case let .cancellationAware(gate):
                await gate.open()
            case let .cancellationIgnoring(gate):
                await gate.open()
            }
        }
    }

    private var nodeIDs: [DOMNode.ID] = []
    private var owners: [DOMTreePageHighlightOwner] = []
    private var gates: [Gate] = []
    private var failedInvocationIndexes: Set<Int> = []
    private var invocationWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private let ignoresCancellation: Bool

    init(ignoresCancellation: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
    }

    func run(_ nodeID: DOMNode.ID, owner: DOMTreePageHighlightOwner) async throws {
        let invocationIndex = nodeIDs.count
        let gate: Gate = if ignoresCancellation {
            .cancellationIgnoring(CancellationIgnoringGate())
        } else {
            .cancellationAware(WebInspectorTestGate())
        }
        nodeIDs.append(nodeID)
        owners.append(owner)
        gates.append(gate)
        resumeInvocationWaitersIfNeeded()

        await gate.wait()
        if !ignoresCancellation {
            try Task.checkCancellation()
        }
        if failedInvocationIndexes.contains(invocationIndex) {
            throw IntentionalFailure()
        }
    }

    func waitForInvocationCount(_ count: Int) async {
        guard nodeIDs.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            if nodeIDs.count >= count {
                continuation.resume()
            } else {
                invocationWaiters.append((count, continuation))
            }
        }
    }

    func resolveInvocation(at index: Int, as resolution: Resolution) async {
        precondition(gates.indices.contains(index), "The controlled highlight invocation must exist before resolution.")
        if case .failure = resolution {
            failedInvocationIndexes.insert(index)
        }
        await gates[index].open()
    }

    var invocationCount: Int {
        nodeIDs.count
    }

    var recordedNodeIDs: [DOMNode.ID] {
        nodeIDs
    }

    var recordedOwners: [DOMTreePageHighlightOwner] {
        owners
    }

    private func resumeInvocationWaitersIfNeeded() {
        var pending: [(
            count: Int,
            continuation: CheckedContinuation<Void, Never>
        )] = []
        for waiter in invocationWaiters {
            if nodeIDs.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        invocationWaiters = pending
    }
}

@MainActor
private final class CancellationIgnoringGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                precondition(self.continuation == nil, "A controlled highlight gate supports one waiter.")
                self.continuation = continuation
            }
        }
    }

    func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        continuation?.resume()
        continuation = nil
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
private final class DOMTreeTestFixture {
    let context: WebInspectorContext
    let treeController: DOMTreeController

    init(root: DOM.Node) {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)
        context.seedDOMDocument(root)
        self.context = context
        self.treeController = context.rootTreeController()
    }

    var currentPageRootNode: DOMNode? {
        context.rootNode
    }

    var selectedNode: DOMNode? {
        context.selectedNode
    }

    var treeRevision: UInt64 {
        treeController.snapshot.revision
    }

    var selectionRevision: UInt64 {
        treeController.snapshot.revision
    }

    var isSelectingElement: Bool {
        get {
            context.isElementPickerEnabled
        }
        set {
            context.seedElementPickerEnabled(newValue)
        }
    }

    func snapshot() -> DOMTreeSnapshot {
        treeController.snapshot
    }

    func node(for id: DOMNode.ID) -> DOMNode? {
        try? context.requiredNode(for: id)
    }

    func selectNode(_ id: DOMNode.ID) {
        try? context.selectNode(id)
    }

    func applyAttributeModified(_ id: DOMNode.ID, name: String, value: String) {
        context.apply(.attributeModified(id.proxyID, name: name, value: value))
    }

    func applySetChildNodes(parent: DOMNode.ID, children: [DOM.Node], eventSequence: Int = 0) {
        _ = eventSequence
        context.apply(.setChildNodes(parent: parent.proxyID, nodes: children))
    }

    func replaceDocumentRoot(_ root: DOM.Node) {
        context.seedDOMDocument(root)
    }
}

@MainActor
private func makeTreeView(root: DOM.Node = documentNode()) async -> DOMTreeTextView {
    await makeTreeView(fixture: makeDOMTreeFixture(root: root))
}

@MainActor
private func makeTreeView(fixture: DOMTreeTestFixture) async -> DOMTreeTextView {
    let view = DOMTreeTextView(context: fixture.context)
    configureTreeViewForDeterministicTesting(view)
    view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
    view.layoutIfNeeded()
    view.setRenderingActive(true)
    #expect(await view.waitForRowDocumentForTesting())
    return view
}

@MainActor
private func configureTreeViewForDeterministicTesting(_ view: DOMTreeTextView) {
    view.setUsesInlineRowRenderBuildsForTesting(true)
}

@MainActor
private func waitForRenderedDocumentTreeUpdate(
    in view: DOMTreeTextView,
    fixture: DOMTreeTestFixture,
    timeout: Duration = .seconds(1),
    update: @MainActor () -> Void,
    until condition: @escaping @MainActor @Sendable () -> Bool
) async -> Bool {
    update()
    let expectedTreeRevision = fixture.treeRevision
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
    fixture: DOMTreeTestFixture,
    timeout: Duration = .seconds(1),
    update: @MainActor () -> Void,
    until condition: @escaping @MainActor @Sendable () -> Bool
) async -> Bool {
    let baselineRevision = fixture.selectionRevision
    update()
    let expectedSelectionRevision = fixture.selectionRevision
    if expectedSelectionRevision > baselineRevision {
        _ = await view.waitForRowDocumentAppliedTreeRevisionForTesting(expectedSelectionRevision, timeout: timeout)
    }

    guard await view.waitForRowDocumentForTesting() else {
        return false
    }
    view.layoutIfNeeded()
    return condition()
}

@MainActor
private func waitForSelectionRenderedState<State: Sendable>(
    in view: DOMTreeTextView,
    fixture: DOMTreeTestFixture,
    timeout: Duration = .seconds(1),
    update: @MainActor () -> Void,
    sample: @escaping @MainActor @Sendable () -> State,
    until condition: @escaping @Sendable (State) -> Bool
) async -> State? {
    let baselineRevision = fixture.selectionRevision
    update()
    let expectedSelectionRevision = fixture.selectionRevision
    if expectedSelectionRevision > baselineRevision {
        _ = await view.waitForRowDocumentAppliedTreeRevisionForTesting(expectedSelectionRevision, timeout: timeout)
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
private func makeDOMTreeFixture(root: DOM.Node = documentNode()) -> DOMTreeTestFixture {
    DOMTreeTestFixture(root: root)
}

@MainActor
private struct ProjectedFrameFixture {
    var session: DOMTreeTestFixture
    var frameRootID: DOMNode.ID
    var selectedNodeID: DOMNode.ID
}

@MainActor
private func makeProjectedFrameFixture() -> ProjectedFrameFixture {
    ProjectedFrameFixture(
        session: makeDOMTreeFixture(root: projectedPageDocument()),
        frameRootID: nodeID(101),
        selectedNodeID: nodeID(108)
    )
}

private func proxyNodeID(_ value: Int) -> DOM.Node.ID {
    DOM.Node.ID(String(value))
}

private func proxyNodeID(_ value: String) -> DOM.Node.ID {
    DOM.Node.ID(value)
}

private func nodeID(_ value: Int) -> DOMNode.ID {
    DOMNode.ID(proxyNodeID(value))
}

private func attributesDictionary(_ attributes: [DOM.Attribute]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: attributes.map { ($0.name, $0.value) })
}

private func documentNode() -> DOM.Node {
    DOM.Node(
        id: proxyNodeID(1),
        nodeType: 9,
        nodeName: "#document",
        childNodeCount: 2,
        children: [
            DOM.Node(id: proxyNodeID(2), nodeType: 10, nodeName: "html"),
            DOM.Node(
                id: proxyNodeID(3),
                nodeType: 1,
                nodeName: "HTML",
                localName: "html",
                attributes: ["lang": "en"],
                attributeList: [DOM.Attribute(name: "lang", value: "en")],
                childNodeCount: 2,
                children: [
                    DOM.Node(
                        id: proxyNodeID(4),
                        nodeType: 1,
                        nodeName: "HEAD",
                        localName: "head",
                        childNodeCount: 1,
                        children: [
                            DOM.Node(id: proxyNodeID(5), nodeType: 1, nodeName: "TITLE", localName: "title"),
                        ]
                    ),
                    bodyNode(article: articleNode()),
                ]
            ),
        ]
    )
}

private func documentWithDeferredArticle() -> DOM.Node {
    DOM.Node(
        id: proxyNodeID(1),
        nodeType: 9,
        nodeName: "#document",
        childNodeCount: 1,
        children: [
            DOM.Node(
                id: proxyNodeID(3),
                nodeType: 1,
                nodeName: "HTML",
                localName: "html",
                childNodeCount: 1,
                children: [
                    bodyNode(
                        article: DOM.Node(
                            id: proxyNodeID(8),
                            nodeType: 1,
                            nodeName: "ARTICLE",
                            localName: "article",
                            childNodeCount: 1
                        )
                    ),
                ]
            ),
        ]
    )
}

private func selectionRevealRaceDocument() -> DOM.Node {
    DOM.Node(
        id: proxyNodeID(1),
        nodeType: 9,
        nodeName: "#document",
        childNodeCount: 1,
        children: [
            DOM.Node(
                id: proxyNodeID(2),
                nodeType: 1,
                nodeName: "HTML",
                localName: "html",
                childNodeCount: 1,
                children: [
                    DOM.Node(
                        id: proxyNodeID(3),
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body",
                        childNodeCount: 1,
                        children: [
                            selectionRevealRaceTargetNode(),
                        ]
                    ),
                ]
            ),
        ]
    )
}

private func selectionRevealRaceBodyChildren(prefixCount: Int) -> [DOM.Node] {
    (0..<prefixCount).map { index in
        let attributes = [DOM.Attribute(name: "id", value: "prefix-\(index)")]
        return DOM.Node(
            id: proxyNodeID(1_000 + index),
            nodeType: 1,
            nodeName: "DIV",
            localName: "div",
            attributes: attributesDictionary(attributes),
            attributeList: attributes
        )
    } + [selectionRevealRaceTargetNode()]
}

private func selectionRevealRaceTargetNode() -> DOM.Node {
    let attributes = [DOM.Attribute(name: "id", value: "selected-target")]
    return DOM.Node(
        id: proxyNodeID(4),
        nodeType: 1,
        nodeName: "DIV",
        localName: "div",
        attributes: attributesDictionary(attributes),
        attributeList: attributes
    )
}

private func projectedPageDocument() -> DOM.Node {
    let iframeAttributes = [DOM.Attribute(name: "src", value: "https://frame.example/ad")]
    return DOM.Node(
        id: proxyNodeID(1),
        nodeType: 9,
        nodeName: "#document",
        childNodeCount: 1,
        children: [
            DOM.Node(
                id: proxyNodeID(2),
                nodeType: 1,
                nodeName: "HTML",
                localName: "html",
                childNodeCount: 1,
                children: [
                    DOM.Node(
                        id: proxyNodeID(3),
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body",
                        childNodeCount: 1,
                        children: [
                            DOM.Node(
                                id: proxyNodeID(20),
                                nodeType: 1,
                                nodeName: "IFRAME",
                                localName: "iframe",
                                attributes: attributesDictionary(iframeAttributes),
                                attributeList: iframeAttributes,
                                childNodeCount: 1,
                                contentDocument: projectedFrameDocument()
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )
}

private func projectedFrameDocument() -> DOM.Node {
    DOM.Node(
        id: proxyNodeID(101),
        nodeType: 9,
        nodeName: "#document",
        documentURL: "https://frame.example/ad",
        childNodeCount: 1,
        children: [
            DOM.Node(
                id: proxyNodeID(102),
                nodeType: 1,
                nodeName: "HTML",
                localName: "html",
                childNodeCount: 1,
                children: [
                    DOM.Node(
                        id: proxyNodeID(103),
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body",
                        childNodeCount: 1,
                        children: [
                            frameImageNode(),
                        ]
                    ),
                ]
            ),
        ]
    )
}

private func frameImageNode() -> DOM.Node {
    let attributes = [DOM.Attribute(name: "id", value: "ad-node")]
    return DOM.Node(
        id: proxyNodeID(108),
        nodeType: 1,
        nodeName: "IMG",
        localName: "img",
        attributes: attributesDictionary(attributes),
        attributeList: attributes
    )
}

private func bodyNode(article: DOM.Node) -> DOM.Node {
    let bodyAttributes = [DOM.Attribute(name: "class", value: "logged-in env-production")]
    let divAttributes = [
        DOM.Attribute(name: "id", value: "start-of-content"),
        DOM.Attribute(name: "data-testid", value: "cellInnerDiv"),
    ]
    let inputAttributes = [DOM.Attribute(name: "disabled", value: "")]
    return DOM.Node(
        id: proxyNodeID(6),
        nodeType: 1,
        nodeName: "BODY",
        localName: "body",
        attributes: attributesDictionary(bodyAttributes),
        attributeList: bodyAttributes,
        childNodeCount: 5,
        children: [
            DOM.Node(
                id: proxyNodeID(7),
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: attributesDictionary(divAttributes),
                attributeList: divAttributes
            ),
            DOM.Node(
                id: proxyNodeID(12),
                nodeType: 1,
                nodeName: "INPUT",
                localName: "input",
                attributes: attributesDictionary(inputAttributes),
                attributeList: inputAttributes
            ),
            article,
            DOM.Node(
                id: proxyNodeID(10),
                nodeType: 3,
                nodeName: "#text",
                nodeValue: "Introducing luma for iOS 26"
            ),
            DOM.Node(
                id: proxyNodeID(11),
                nodeType: 8,
                nodeName: "#comment",
                nodeValue: "comment text"
            ),
        ]
    )
}

private func articleNode() -> DOM.Node {
    let nestedAttributes = [DOM.Attribute(name: "id", value: "nested-child")]
    return DOM.Node(
        id: proxyNodeID(8),
        nodeType: 1,
        nodeName: "ARTICLE",
        localName: "article",
        childNodeCount: 1,
        children: [
            DOM.Node(
                id: proxyNodeID(9),
                nodeType: 1,
                nodeName: "SPAN",
                localName: "span",
                attributes: attributesDictionary(nestedAttributes),
                attributeList: nestedAttributes
            ),
        ]
    )
}

private func makeRowDocumentRows(_ texts: [String]) -> [DOMTreeRowRenderPlan] {
    var utf16Location = 0
    return texts.enumerated().map { index, text in
        let utf16Length = (text as NSString).length
        defer {
            utf16Location += utf16Length + (index + 1 < texts.count ? 1 : 0)
        }
        return DOMTreeRowRenderPlan(
            identity: DOMTreeRowIdentity(
                nodeID: nodeID(index + 1),
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
