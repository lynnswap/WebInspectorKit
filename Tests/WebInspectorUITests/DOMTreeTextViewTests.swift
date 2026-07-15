#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
@testable import WebInspectorProxyKit
import WebInspectorTestSupport
@testable import WebInspectorUIDOM

@MainActor
@Suite(.serialized)
struct DOMTreeTextViewTests {
    @Test
    func selectionRevealStateKeepsSelectionOnlyRequestsOutOfTheScrollQueue() {
        let state = DOMTreeTextView.SelectionRevealState()
        let selectedNodeID = testDOMNodeID(1000)

        let observation = state.observe(
            selectedNodeID: selectedNodeID,
            requestRevision: 1,
            revealPolicy: .selectOnly
        )

        #expect(observation.selectedNodeID == selectedNodeID)
        #expect(observation.selectedNodeIDChanged)
        #expect(state.pendingSelectedNodeID == nil)
    }

    @Test
    func selectionRevealStateRequeuesTheSameNodeForANewerScrollRequest() {
        let state = DOMTreeTextView.SelectionRevealState()
        let selectedNodeID = testDOMNodeID(1000)

        _ = state.observe(
            selectedNodeID: selectedNodeID,
            requestRevision: 1,
            revealPolicy: .selectAndScroll
        )
        state.consumePendingSelection()
        let observation = state.observe(
            selectedNodeID: selectedNodeID,
            requestRevision: 2,
            revealPolicy: .selectAndScroll
        )

        #expect(!observation.selectedNodeIDChanged)
        #expect(state.pendingSelectedNodeID == selectedNodeID)
    }

    @Test
    func selectionRevealStatePreservesPendingScrollUntilItCanBeConsumed() {
        let state = DOMTreeTextView.SelectionRevealState()
        let selectedNodeID = testDOMNodeID(1000)

        _ = state.observe(
            selectedNodeID: selectedNodeID,
            requestRevision: 1,
            revealPolicy: .selectAndScroll
        )
        _ = state.observe(
            selectedNodeID: selectedNodeID,
            requestRevision: 1,
            revealPolicy: .none
        )

        #expect(state.pendingSelectedNodeID == selectedNodeID)
    }

    @Test
    func selectionRevealStateCancelsPendingScrollForANewerNonScrollRequest() {
        let state = DOMTreeTextView.SelectionRevealState()
        let selectedNodeID = testDOMNodeID(1000)

        _ = state.observe(
            selectedNodeID: selectedNodeID,
            requestRevision: 1,
            revealPolicy: .selectAndScroll
        )
        _ = state.observe(
            selectedNodeID: selectedNodeID,
            requestRevision: 2,
            revealPolicy: .selectOnly
        )

        #expect(state.pendingSelectedNodeID == nil)
    }

    @Test
    func rendersAndSelectsDOMThroughContainerOwnedPanelModel() async throws {
        let runtime = try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(enabledFeatures: [.dom]),
                document: .init(children: [
                    .element(
                        id: "html",
                        name: "html",
                        attributes: ["lang": "en"],
                        children: [
                            .element(
                                id: "body",
                                name: "body",
                                children: [
                                    .element(
                                        id: "input",
                                        name: "input",
                                        attributes: ["disabled": ""]
                                    )
                                ]
                            )
                        ]
                    )
                ])
            )
        )
        let context = runtime.container.mainContext
        let panelModel = try await DOMPanelModel.make(context: context)
        let initialRevision = try #require(panelModel.nodes.revision).rawValue
        let view = DOMTreeTextView(model: panelModel)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.setRenderingActive(true)

        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(
                initialRevision,
                timeout: .seconds(5)
            )
        )
        #expect(view.documentTextForTesting.contains("<html lang=\"en\">"))
        #expect(view.documentTextForTesting.contains("<input disabled>"))

        let inputID = try #require(panelModel.nodes.snapshot?.itemIDs.first { id in
            context.model(for: id)?.localName == "input"
        })
        panelModel.selectNode(inputID, reveal: .selectOnly)
        #expect(await view.waitForRowDocumentForTesting())
        #expect(panelModel.selectedNodeID == inputID)

        view.setRenderingActive(false)
        await panelModel.retire()
        await runtime.close()
    }

    @Test
    func textDocumentVendsRowParagraphsWithStableIdentity() throws {
        let document = DOMTreeTextDocument()
        let rows = makeRowDocumentRows(["alpha", "beta"])
        document.replaceDocument(
            with: attributedRowDocument(rows: rows),
            rowIndex: DOMTreeRowIndex(rows: rows)
        )

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
    func textDocumentSingleRowReplacementPreservesSurroundingRowIdentities() throws {
        let document = DOMTreeTextDocument()
        let initialRows = makeRowDocumentRows(["first", "middle", "third"])
        document.replaceDocument(
            with: attributedRowDocument(rows: initialRows),
            rowIndex: DOMTreeRowIndex(rows: initialRows)
        )
        let nextRows = makeRowDocumentRows(["first", "second", "third"])

        document.replaceCharacters(
            in: initialRows[1].documentRange,
            with: attributedRowDocument(rows: [nextRows[1]]),
            rowIndex: DOMTreeRowIndex(rows: nextRows)
        )

        #expect(document.string == "first\nsecond\nthird")
        #expect(document.rowIndex.rows.map(\.identity) == nextRows.map(\.identity))
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
    func textDocumentLayoutFragmentsExposeRowIdentity() throws {
        let document = DOMTreeTextDocument()
        let rows = makeRowDocumentRows(["alpha", "beta"])
        document.replaceDocument(
            with: attributedRowDocument(rows: rows),
            rowIndex: DOMTreeRowIndex(rows: rows)
        )
        document.textContainer.size = CGSize(width: 1_000, height: 1_000)

        let fullRange = try #require(document.textRange(for: NSRange(
            location: 0,
            length: document.utf16Length
        )))
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
    func rowRenderDifferenceRecognizesEquivalentRows() throws {
        let previousRows = makeRowDocumentRows(
            ["alpha", "beta"],
            nodeIDs: [1, 2]
        )
        let nextRows = makeRowDocumentRows(
            ["alpha", "beta"],
            nodeIDs: [1, 2]
        )

        let difference = try rowRenderDifference(
            previousRows: previousRows,
            nextRows: nextRows
        )

        #expect(difference == .noChange)
    }

    @Test
    func rowRenderDifferenceReplacesChangedMiddleRow() throws {
        let previousRows = makeRowDocumentRows(
            ["a", "b", "c"],
            nodeIDs: [1, 2, 3]
        )
        let nextRows = makeRowDocumentRows(
            ["a", "x", "c"],
            nodeIDs: [1, 2, 3]
        )

        let difference = try rowRenderDifference(
            previousRows: previousRows,
            nextRows: nextRows
        )

        #expect(difference == .replaceCharacters(.init(
            previousRange: NSRange(location: 1, length: 3),
            nextRowsRange: 1..<2
        )))
    }

    @Test
    func rowRenderDifferenceInsertsMiddleRow() throws {
        let previousRows = makeRowDocumentRows(
            ["a", "c"],
            nodeIDs: [1, 3]
        )
        let nextRows = makeRowDocumentRows(
            ["a", "b", "c"],
            nodeIDs: [1, 2, 3]
        )

        let difference = try rowRenderDifference(
            previousRows: previousRows,
            nextRows: nextRows
        )

        #expect(difference == .replaceCharacters(.init(
            previousRange: NSRange(location: 1, length: 1),
            nextRowsRange: 1..<2
        )))
    }

    @Test
    func rowRenderDifferenceDeletesMiddleRow() throws {
        let previousRows = makeRowDocumentRows(
            ["a", "b", "c"],
            nodeIDs: [1, 2, 3]
        )
        let nextRows = makeRowDocumentRows(
            ["a", "c"],
            nodeIDs: [1, 3]
        )

        let difference = try rowRenderDifference(
            previousRows: previousRows,
            nextRows: nextRows
        )

        #expect(difference == .replaceCharacters(.init(
            previousRange: NSRange(location: 1, length: 3),
            nextRowsRange: 1..<1
        )))
    }

    @Test
    func rowRenderDifferenceHandlesEmptyTransitions() throws {
        let row = makeRowDocumentRows(["a"], nodeIDs: [1])

        let bothEmpty = try rowRenderDifference(
            previousRows: [],
            nextRows: []
        )
        let insertion = try rowRenderDifference(
            previousRows: [],
            nextRows: row
        )
        let deletion = try rowRenderDifference(
            previousRows: row,
            nextRows: []
        )

        #expect(bothEmpty == .noChange)
        #expect(insertion == .replaceDocument(resetTextFragments: false))
        #expect(deletion == .replaceDocument(resetTextFragments: false))
    }

    @Test
    func rowRenderDifferenceUsesExactUTF16Boundaries() throws {
        let previousRows = makeRowDocumentRows(
            ["😀", "tail"],
            nodeIDs: [1, 2]
        )
        let nextRows = makeRowDocumentRows(
            ["🙂", "tail"],
            nodeIDs: [1, 2]
        )

        let difference = try rowRenderDifference(
            previousRows: previousRows,
            nextRows: nextRows
        )

        #expect(difference == .replaceCharacters(.init(
            previousRange: NSRange(location: 0, length: 3),
            nextRowsRange: 0..<1
        )))
    }

    @Test
    func rowRenderEquivalenceIncludesMarkupRange() throws {
        let previousRows = makeRowDocumentRows(
            [" <a>"],
            nodeIDs: [1],
            markupRanges: [NSRange(location: 1, length: 3)]
        )
        let nextRows = makeRowDocumentRows(
            [" <a>"],
            nodeIDs: [1],
            markupRanges: [NSRange(location: 0, length: 4)]
        )

        let difference = try rowRenderDifference(
            previousRows: previousRows,
            nextRows: nextRows
        )

        #expect(difference == .replaceCharacters(.init(
            previousRange: NSRange(location: 0, length: 4),
            nextRowsRange: 0..<1
        )))
    }

    @Test
    func canonicalDeltaSkipsCollapsedDescendantRendering() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        let baselineRevision = view.rowDocumentAppliedTreeRevisionForTesting
        let baselineBuildCount = view.buildRowRenderPlanCallCountForTesting

        #expect(view.documentTextForTesting.contains("<article>…</article>"))
        #expect(!view.documentTextForTesting.contains("data-state=\"ready\""))

        let revision = try await fixture.modifyAttribute(
            nodeID: "span",
            name: "data-state",
            value: "ready"
        )
        #expect(await view.waitForObservedTreeRevisionForTesting(revision))

        #expect(view.buildRowRenderPlanCallCountForTesting == baselineBuildCount)
        #expect(view.rowDocumentAppliedTreeRevisionForTesting == baselineRevision)
        #expect(!view.documentTextForTesting.contains("data-state=\"ready\""))
        await fixture.close(view: view)
    }

    @Test
    func canonicalVisibleDeltaUsesIncrementalTextStorageUpdate() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.resetPerformanceCountersForTesting()

        let revision = try await fixture.modifyAttribute(
            nodeID: "visible-div",
            name: "data-state",
            value: "ready"
        )
        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(revision)
        )

        #expect(view.documentTextForTesting.contains("data-state=\"ready\""))
        #expect(view.incrementalRowDocumentEditCallCountForTesting > 0)
        #expect(view.replaceRowDocumentCallCountForTesting == 0)
        await fixture.close(view: view)
    }

    @Test
    func unchangedProjectionAcknowledgesWithoutMutatingTextStorage()
        async throws
    {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        let baselineDocumentRevision = view.rowDocumentRevisionForTesting
        view.resetPerformanceCountersForTesting()

        view.rebuildRowsWithoutFragmentResetForTesting()
        #expect(await view.waitForRowDocumentForTesting())

        #expect(view.rowDocumentRevisionForTesting == baselineDocumentRevision)
        #expect(view.replaceRowDocumentCallCountForTesting == 0)
        #expect(view.incrementalRowDocumentEditCallCountForTesting == 0)
        await fixture.close(view: view)
    }

    @Test
    func scrollingUsesTheViewportSurfacePassWithoutRebuildingAllDecorations()
        async throws
    {
        let children = (0..<200).map { index in
            WebInspectorDataKitTestRuntime.Node.element(
                id: "row-\(index)",
                name: "div",
                attributes: ["data-row": "\(index)"]
            )
        }
        let fixture = try await DOMTreeRuntimeFixture.start(
            document: .init(children: [
                .element(
                    id: "html",
                    name: "html",
                    children: [
                        .element(
                            id: "body",
                            name: "body",
                            children: children
                        )
                    ]
                )
            ])
        )
        let view = await fixture.makeView()
        let maximumOffset = view.contentSize.height - view.bounds.height
        #expect(maximumOffset > view.rowHeightForTesting)
        view.resetPerformanceCountersForTesting()

        view.setContentOffset(
            CGPoint(
                x: 0,
                y: min(maximumOffset, view.rowHeightForTesting * 20)
            ),
            animated: false
        )
        view.layoutSubviews()

        #expect(view.fragmentSubviewCountForTesting > 0)
        #expect(view.updateContentDecorationsCallCountForTesting == 0)
        await fixture.close(view: view)
    }

    @Test
    func hiddenCanonicalDeltaRendersOnlyAfterRenderingResumes() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.setRenderingActive(false)

        let revision = try await fixture.modifyAttribute(
            nodeID: "visible-div",
            name: "data-hidden-update",
            value: "ready"
        )
        #expect(await view.waitForObservedTreeRevisionForTesting(revision))
        #expect(
            !view.documentTextForTesting.contains(
                "data-hidden-update=\"ready\""
            )
        )

        view.setRenderingActive(true)
        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(revision)
        )
        #expect(
            view.documentTextForTesting.contains(
                "data-hidden-update=\"ready\""
            )
        )
        await fixture.close(view: view)
    }

    @Test
    func hiddenSelectOnlyDoesNotExpandOrReloadRows() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.setRenderingActive(false)
        view.resetPerformanceCountersForTesting()
        let nestedChildID = try fixture.nodeID("span")

        fixture.model.selectNode(nestedChildID, reveal: .selectOnly)
        #expect(await waitForObservedCondition(
            deliveries: {
                [view.selectionObservationDeliveryForTesting].compactMap { $0 }
            },
            sample: {
                fixture.model.selectedNodeID == nestedChildID
            }
        ))

        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())

        #expect(view.documentTextForTesting.contains("<article>…</article>"))
        #expect(!view.documentTextForTesting.contains("nested-child"))
        #expect(view.buildRowRenderPlanCallCountForTesting == 0)
        await fixture.close(view: view)
    }

    @Test
    func rowSelectionAndDisclosureUseTheSharedPanelModel() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.layoutIfNeeded()

        #expect(view.primaryClickRowForTesting(containing: "<input disabled>"))
        let inputID = try fixture.nodeID("input")
        #expect(fixture.model.selectedNodeID == inputID)
        #expect(view.selectedRowRectsForTesting().count == 1)

        let disclosurePoint = try #require(
            view.disclosureHitPointForTesting(containing: "<article")
        )
        view.primaryClickContentPointForTesting(disclosurePoint)
        #expect(await view.waitForRowDocumentForTesting())
        #expect(
            view.documentTextForTesting.contains(
                "<span id=\"nested-child\"></span>"
            )
        )
        await fixture.close(view: view)
    }

    @Test
    func rowDocumentStoresTokenForegroundAttributes() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()

        let baseForeground = try #require(
            view.rowDocumentBaseForegroundColorForTesting
        )
        let tagNameStorageForeground = try #require(
            view.rowDocumentForegroundColorForTesting(containing: "input")
        )
        let attributeNameStorageForeground = try #require(
            view.rowDocumentForegroundColorForTesting(containing: "disabled")
        )
        let tagNameTokenForeground = try #require(
            view.tokenForegroundColorForTesting(kind: "tagName")
        )
        let attributeNameTokenForeground = try #require(
            view.tokenForegroundColorForTesting(kind: "attributeName")
        )

        #expect(tagNameStorageForeground != baseForeground)
        #expect(attributeNameStorageForeground != baseForeground)
        #expect(tagNameStorageForeground == tagNameTokenForeground)
        #expect(attributeNameStorageForeground == attributeNameTokenForeground)
        #expect(
            view.disclosureAttachmentSnapshotsForTesting.contains {
                $0.hasAttachment
            }
        )
        await fixture.close(view: view)
    }

    @Test
    func visibleRowCentersHitTestTheirRenderedRows() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.layoutIfNeeded()

        for fragment in view.rowFragmentSnapshotsForTesting.prefix(16) {
            let point = CGPoint(
                x: max(4, fragment.frame.minX + 4),
                y: fragment.frame.midY
            )
            #expect(
                view.hitTestedLineTextForTesting(atContentPoint: point)
                    == fragment.text
            )
        }
        await fixture.close(view: view)
    }

    @Test
    func selectionAndHoverRouteTheirPageHighlightOwners() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let highlights = DOMTreeNodeActionRecorder()
        let restores = DOMTreeVoidActionRecorder()
        let view = await fixture.makeView(
            highlightNodeAction: { nodeID, owner in
                highlights.record(nodeID, owner: owner)
            },
            restoreHighlightAction: {
                restores.record()
            }
        )

        #expect(view.primaryClickRowForTesting(containing: "<input disabled>"))
        let selectedID = await highlights.nextNodeID()
        #expect(fixture.model.selectedNodeID == selectedID)
        #expect(highlights.recordedOwners == [.selection])

        view.hoverRowForTesting(containing: "<article")
        let hoveredID = await highlights.nextNodeID(after: selectedID)
        #expect(try fixture.nodeID("article") == hoveredID)
        #expect(highlights.recordedOwners == [.selection, .transient])

        view.endHoverForTesting()
        await restores.next()
        #expect(restores.recordCount == 1)
        await fixture.close(view: view)
    }

    @Test
    func selectionChangeDuringHoverRestoresTheLatestModelSelection()
        async throws
    {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let highlights = DOMTreeNodeActionRecorder()
        let restores = DOMTreeSelectionRestoreRecorder()
        let view = await fixture.makeView(
            highlightNodeAction: { nodeID, owner in
                highlights.record(nodeID, owner: owner)
            },
            restoreHighlightAction: {
                restores.record(fixture.model.selectedNodeID)
            }
        )

        #expect(view.primaryClickRowForTesting(containing: "<input disabled>"))
        let selectedID = await highlights.nextNodeID()
        view.hoverRowForTesting(containing: "<article")
        _ = await highlights.nextNodeID(after: selectedID)

        let nestedID = try fixture.nodeID("span")
        fixture.model.selectNode(nestedID, reveal: .selectAndScroll)
        #expect(await waitForObservedCondition(
            deliveries: {
                [view.selectionObservationDeliveryForTesting].compactMap { $0 }
            },
            sample: {
                view.routedSelectedNodeIDForTesting == nestedID
            }
        ))
        #expect(await view.waitForRowDocumentForTesting())
        await view.waitForPageHighlightTaskForTesting()

        #expect(highlights.recordedOwners == [.selection, .transient])
        view.endHoverForTesting()
        #expect(await restores.next() == nestedID)
        await fixture.close(view: view)
    }

    @Test
    func duplicateSelectionInvalidationCoalescesInFlightPageHighlight()
        async throws
    {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let highlights = DOMTreeControlledNodeActionRecorder()
        let view = await fixture.makeView(
            highlightNodeAction: { nodeID, owner in
                try await highlights.run(nodeID, owner: owner)
            }
        )

        #expect(view.primaryClickRowForTesting(containing: "<input disabled>"))
        await highlights.waitForInvocationCount(1)
        view.routeCurrentSelectionInvalidationForTesting()
        view.routeCurrentSelectionInvalidationForTesting()
        await Task.yield()

        #expect(highlights.invocationCount == 1)
        highlights.resolveInvocation(at: 0, as: .success)
        await view.waitForPageHighlightTaskForTesting()
        #expect(highlights.recordedOwners == [.selection])
        await fixture.close(view: view)
    }

    @Test
    func changingSelectionReplacesInFlightPageHighlight() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let highlights = DOMTreeControlledNodeActionRecorder()
        let view = await fixture.makeView(
            highlightNodeAction: { nodeID, owner in
                try await highlights.run(nodeID, owner: owner)
            }
        )

        #expect(view.primaryClickRowForTesting(containing: "<input disabled>"))
        await highlights.waitForInvocationCount(1)
        #expect(view.primaryClickRowForTesting(containing: "<article"))
        await highlights.waitForInvocationCount(2)

        #expect(highlights.recordedNodeIDs == [
            try fixture.nodeID("input"),
            try fixture.nodeID("article"),
        ])
        view.routeCurrentSelectionInvalidationForTesting()
        await Task.yield()
        #expect(highlights.invocationCount == 2)

        highlights.resolveInvocation(at: 1, as: .success)
        await view.waitForPageHighlightTaskForTesting()
        await fixture.close(view: view)
    }

    @Test
    func selectionHighlightFailureAllowsLaterInvalidationRetry() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let highlights = DOMTreeControlledNodeActionRecorder()
        let view = await fixture.makeView(
            highlightNodeAction: { nodeID, owner in
                try await highlights.run(nodeID, owner: owner)
            }
        )

        #expect(view.primaryClickRowForTesting(containing: "<input disabled>"))
        await highlights.waitForInvocationCount(1)
        highlights.resolveInvocation(at: 0, as: .failure)
        await view.waitForPageHighlightTaskForTesting()

        view.routeCurrentSelectionInvalidationForTesting()
        await highlights.waitForInvocationCount(2)
        highlights.resolveInvocation(at: 1, as: .success)
        await view.waitForPageHighlightTaskForTesting()

        #expect(highlights.recordedNodeIDs.count == 2)
        #expect(highlights.recordedNodeIDs[0] == highlights.recordedNodeIDs[1])
        await fixture.close(view: view)
    }

    @Test
    func expandedElementRendersChildrenAndClosingTag() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()

        view.toggleRowForTesting(containing: "<article")
        #expect(await view.waitForRowDocumentForTesting())

        #expect(view.documentTextForTesting.contains("<article>"))
        #expect(
            view.documentTextForTesting.contains(
                "<span id=\"nested-child\"></span>"
            )
        )
        #expect(view.documentTextForTesting.contains("</article>"))
        #expect(!view.documentTextForTesting.contains("<article>…</article>"))
        await fixture.close(view: view)
    }

    @Test
    func localMarkupLookupDistinguishesOpeningAndClosingRows()
        async throws
    {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.toggleRowForTesting(containing: "<article")
        #expect(await view.waitForRowDocumentForTesting())
        let articleID = try fixture.nodeID("article")

        #expect(
            view.localMarkupTextByNodeIDForTesting([articleID])[articleID]
                == "      <article>"
        )
        view.removeRowIndexForTesting(containing: "<article>")
        #expect(view.localMarkupTextByNodeIDForTesting([articleID]).isEmpty)
        await fixture.close(view: view)
    }

    @Test
    func multiSelectionUsesRenderedDisplayOrder() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()

        #expect(view.primaryClickRowForTesting(
            containing: "<article",
            modifiers: .command
        ))
        #expect(view.primaryClickRowForTesting(
            containing: "<div data-testid=\"cellInnerDiv\"",
            modifiers: .command
        ))
        #expect(view.primaryClickRowForTesting(
            containing: "<input disabled>",
            modifiers: .command
        ))

        let rows = view.multiSelectedRowSnapshotsInDisplayOrderForTesting
        #expect(rows.map(\.text) == [
            "      <div data-testid=\"cellInnerDiv\" id=\"start-of-content\"></div>",
            "      <input disabled>",
            "      <article>…</article>",
        ])
        #expect(rows.map(\.rowIndex) == rows.map(\.rowIndex).sorted())
        await fixture.close(view: view)
    }

    @Test
    func expandedDescendantMutationRendersCanonicalDelta() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.toggleRowForTesting(containing: "<article")
        #expect(await view.waitForRowDocumentForTesting())

        let revision = try await fixture.modifyAttribute(
            nodeID: "span",
            name: "data-state",
            value: "ready"
        )
        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(revision)
        )
        #expect(
            view.documentTextForTesting.contains(
                "<span id=\"nested-child\" data-state=\"ready\"></span>"
            )
        )
        await fixture.close(view: view)
    }

    @Test
    func inFlightExpansionMutationRebuildsAgainstLatestCanonicalSnapshot()
        async throws
    {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.suspendNextRowRenderBuildForTesting()
        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowRenderBuildSuspensionForTesting()

        let revision = try await fixture.modifyAttribute(
            nodeID: "span",
            name: "data-state",
            value: "ready"
        )
        view.resumeRowRenderBuildForTesting()
        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(revision)
        )
        #expect(
            view.documentTextForTesting.contains(
                "<span id=\"nested-child\" data-state=\"ready\"></span>"
            )
        )
        await fixture.close(view: view)
    }

    @Test
    func semanticInputCancelsRowsBeforeProjectionCompletesWithoutLosingUpdate()
        async throws
    {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        let baselineCancellationCount =
            view.semanticInputCancellationCountForTesting
        view.suspendNextRowRenderBuildForTesting()
        view.rebuildRowsWithoutFragmentResetForTesting()
        await view.waitForRowRenderBuildSuspensionForTesting()
        await view.suspendNextSemanticProjectionForTesting()

        let revision = try await fixture.modifyAttribute(
            nodeID: "visible-div",
            name: "data-cancelled-build",
            value: "latest"
        )
        await view.waitForSemanticProjectionSuspensionForTesting()

        #expect(
            view.semanticInputCancellationCountForTesting
                == baselineCancellationCount + 1
        )
        #expect(view.currentRowRenderRequestIdentityForTesting == nil)
        #expect(
            !view.documentTextForTesting.contains(
                "data-cancelled-build=\"latest\""
            )
        )

        await view.resumeSemanticProjectionForTesting()
        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(revision)
        )
        #expect(
            view.documentTextForTesting.contains(
                "data-cancelled-build=\"latest\""
            )
        )
        await fixture.close(view: view)
    }

    @Test
    func supersededRequestTokenCannotCommitCompletedRows() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        let baselineDocumentRevision = view.rowDocumentRevisionForTesting
        view.suspendNextCompletedRowRenderBuildForTesting()
        view.setRowExpansionForTesting(containing: "<article", isOpen: true)
        await view.waitForCompletedRowRenderBuildSuspensionForTesting()
        let staleIdentity = try #require(
            view.currentRowRenderRequestIdentityForTesting
        )

        view.setRowExpansionForTesting(containing: "<article", isOpen: false)
        #expect(await view.waitForRowDocumentForTesting())
        let committedIdentity = try #require(
            view.lastCommittedRowRenderRequestIdentityForTesting
        )

        #expect(committedIdentity.token > staleIdentity.token)
        #expect(
            committedIdentity.expansionRevision
                > staleIdentity.expansionRevision
        )
        #expect(view.rowDocumentRevisionForTesting == baselineDocumentRevision)
        #expect(view.documentTextForTesting.contains("<article>…</article>"))
        #expect(!view.documentTextForTesting.contains("nested-child"))
        await fixture.close(view: view)
    }

    @Test
    func expansionABARejectsRowsFromTheEarlierEquivalentState() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        let baselineDocumentRevision = view.rowDocumentRevisionForTesting
        view.suspendNextCompletedRowRenderBuildForTesting()
        view.setRowExpansionForTesting(containing: "<article", isOpen: true)
        await view.waitForCompletedRowRenderBuildSuspensionForTesting()
        let staleIdentity = try #require(
            view.currentRowRenderRequestIdentityForTesting
        )

        view.setRowExpansionForTesting(containing: "<article", isOpen: false)
        view.setRowExpansionForTesting(containing: "<article", isOpen: true)
        #expect(await view.waitForRowDocumentForTesting())
        let committedIdentity = try #require(
            view.lastCommittedRowRenderRequestIdentityForTesting
        )

        #expect(committedIdentity.token > staleIdentity.token)
        #expect(
            committedIdentity.expansionRevision
                == staleIdentity.expansionRevision + 2
        )
        #expect(
            view.rowDocumentRevisionForTesting
                == baselineDocumentRevision + 1
        )
        #expect(view.documentTextForTesting.contains("nested-child"))
        await fixture.close(view: view)
    }

    @Test
    func navigationRejectsCompletedRowsFromThePreviousDocumentGeneration()
        async throws
    {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        let baselineDocumentRevision = view.rowDocumentRevisionForTesting
        view.suspendNextCompletedRowRenderBuildForTesting()
        view.setRowExpansionForTesting(containing: "<article", isOpen: true)
        await view.waitForCompletedRowRenderBuildSuspensionForTesting()
        let staleIdentity = try #require(
            view.currentRowRenderRequestIdentityForTesting
        )

        let revision = try await fixture.replacePage(
            with: DOMTreeRuntimeFixture.document()
        )
        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(revision)
        )
        let committedIdentity = try #require(
            view.lastCommittedRowRenderRequestIdentityForTesting
        )

        #expect(committedIdentity.token > staleIdentity.token)
        #expect(
            committedIdentity.documentRootNodeID
                != staleIdentity.documentRootNodeID
        )
        #expect(
            view.rowDocumentRevisionForTesting
                == baselineDocumentRevision + 2
        )
        #expect(view.documentTextForTesting.contains("<article>…</article>"))
        #expect(!view.documentTextForTesting.contains("nested-child"))
        await fixture.close(view: view)
    }

    @Test
    func hidingDuringInFlightBuildCancelsStaleApplyUntilResume() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.suspendNextRowRenderBuildForTesting()
        view.toggleRowForTesting(containing: "<article")
        await view.waitForRowRenderBuildSuspensionForTesting()

        view.setRenderingActive(false)
        view.resumeRowRenderBuildForTesting()
        #expect(await view.waitForRowDocumentForTesting())
        #expect(!view.documentTextForTesting.contains("nested-child"))

        view.setRenderingActive(true)
        #expect(await view.waitForRowDocumentForTesting())
        #expect(view.documentTextForTesting.contains("nested-child"))
        await fixture.close(view: view)
    }

    @Test
    func selectionChangeUpdatesDecorationsWithoutRebuildingRows() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.resetPerformanceCountersForTesting()

        fixture.model.selectNode(
            try fixture.nodeID("input"),
            reveal: .selectOnly
        )
        #expect(await waitForObservedCondition(
            deliveries: {
                [view.selectionObservationDeliveryForTesting].compactMap { $0 }
            },
            sample: {
                view.selectedRowRectsForTesting().count == 1
            }
        ))
        view.layoutIfNeeded()

        #expect(view.selectedRowRectsForTesting().count == 1)
        #expect(view.buildRowRenderPlanCallCountForTesting == 0)
        await fixture.close(view: view)
    }

    @Test
    func documentRootStructureMutationRendersFromCanonicalEvent() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start(document: .init())
        let view = await fixture.makeView()
        #expect(view.documentTextForTesting.isEmpty)

        let revision = try await fixture.setChildren(
            parentID: "document",
            children: [.element(id: "replacement-html", name: "html")]
        )
        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(revision)
        )
        #expect(view.documentTextForTesting.contains("<html"))
        await fixture.close(view: view)
    }

    @Test
    func childInsertionAndRemovalUpdateExpandedParentIncrementally() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.toggleRowForTesting(containing: "<article")
        #expect(await view.waitForRowDocumentForTesting())
        view.resetPerformanceCountersForTesting()

        let insertionRevision = try await fixture.insertChild(
            parentID: "article",
            previousNodeID: "span",
            node: .element(id: "emphasis", name: "em")
        )
        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(
                insertionRevision
            )
        )
        #expect(view.documentTextForTesting.contains("<em></em>"))

        let removalRevision = try await fixture.removeChild(
            parentID: "article",
            nodeID: "emphasis"
        )
        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(
                removalRevision
            )
        )
        #expect(!view.documentTextForTesting.contains("<em></em>"))
        #expect(view.incrementalRowDocumentEditCallCountForTesting > 0)
        await fixture.close(view: view)
    }

    @Test
    func pageReplacementClearsExpansionForReusedRawNodeIDs() async throws {
        let fixture = try await DOMTreeRuntimeFixture.start()
        let view = await fixture.makeView()
        view.toggleRowForTesting(containing: "<article")
        #expect(await view.waitForRowDocumentForTesting())
        #expect(view.documentTextForTesting.contains("nested-child"))

        let revision = try await fixture.replacePage(
            with: DOMTreeRuntimeFixture.document()
        )
        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(revision)
        )

        #expect(view.documentTextForTesting.contains("<article>…</article>"))
        #expect(!view.documentTextForTesting.contains("nested-child"))
        await fixture.close(view: view)
    }
}

@MainActor
private final class DOMTreeNodeActionRecorder {
    private var nodeIDs: [DOMNode.ID] = []
    private(set) var recordedOwners: [DOMTreePageHighlightOwner] = []
    private var continuations: [CheckedContinuation<DOMNode.ID, Never>] = []

    var recordedNodeIDs: [DOMNode.ID] {
        nodeIDs
    }

    func record(_ nodeID: DOMNode.ID, owner: DOMTreePageHighlightOwner) {
        nodeIDs.append(nodeID)
        recordedOwners.append(owner)
        if let continuation = continuations.first {
            continuations.removeFirst()
            continuation.resume(returning: nodeID)
        }
    }

    func nextNodeID() async -> DOMNode.ID {
        await nextNodeID(at: 0)
    }

    func nextNodeID(after nodeID: DOMNode.ID) async -> DOMNode.ID {
        if let index = nodeIDs.firstIndex(of: nodeID),
            nodeIDs.indices.contains(index + 1)
        {
            return nodeIDs[index + 1]
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    private func nextNodeID(at index: Int) async -> DOMNode.ID {
        if nodeIDs.indices.contains(index) {
            return nodeIDs[index]
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

@MainActor
private final class DOMTreeControlledNodeActionRecorder {
    enum Resolution {
        case success
        case failure
    }

    private struct IntentionalFailure: Error {}

    private var nodeIDs: [DOMNode.ID] = []
    private(set) var recordedOwners: [DOMTreePageHighlightOwner] = []
    private var gates: [WebInspectorTestGate] = []
    private var failedInvocationIndexes: Set<Int> = []
    private var invocationWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    var invocationCount: Int {
        nodeIDs.count
    }

    var recordedNodeIDs: [DOMNode.ID] {
        nodeIDs
    }

    func run(
        _ nodeID: DOMNode.ID,
        owner: DOMTreePageHighlightOwner
    ) async throws {
        let invocationIndex = nodeIDs.count
        let gate = WebInspectorTestGate()
        nodeIDs.append(nodeID)
        recordedOwners.append(owner)
        gates.append(gate)
        resumeInvocationWaitersIfNeeded()

        await gate.waiter.wait()
        try Task.checkCancellation()
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

    func resolveInvocation(at index: Int, as resolution: Resolution) {
        precondition(gates.indices.contains(index))
        if case .failure = resolution {
            failedInvocationIndexes.insert(index)
        }
        gates[index].open()
    }

    private func resumeInvocationWaitersIfNeeded() {
        invocationWaiters.removeAll { waiter in
            guard nodeIDs.count >= waiter.count else {
                return false
            }
            waiter.continuation.resume()
            return true
        }
    }
}

@MainActor
private final class DOMTreeVoidActionRecorder {
    private(set) var recordCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func record() {
        recordCount += 1
        continuation?.resume()
        continuation = nil
    }

    func next() async {
        guard recordCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
private final class DOMTreeSelectionRestoreRecorder {
    private var nodeIDs: [DOMNode.ID?] = []
    private var continuation: CheckedContinuation<DOMNode.ID?, Never>?

    func record(_ nodeID: DOMNode.ID?) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: nodeID)
        } else {
            nodeIDs.append(nodeID)
        }
    }

    func next() async -> DOMNode.ID? {
        if nodeIDs.isEmpty == false {
            return nodeIDs.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }
}

@MainActor
private final class DOMTreeRuntimeFixture {
    let runtime: WebInspectorDataKitTestRuntime
    let model: DOMPanelModel
    private var updates:
        WebInspectorFetchedResultsUpdateSequence<DOMNode.ID>.AsyncIterator

    private init(
        runtime: WebInspectorDataKitTestRuntime,
        model: DOMPanelModel,
        updates: WebInspectorFetchedResultsUpdateSequence<DOMNode.ID>.AsyncIterator
    ) {
        self.runtime = runtime
        self.model = model
        self.updates = updates
    }

    static func start(
        document: WebInspectorDataKitTestRuntime.Document = document()
    ) async throws -> DOMTreeRuntimeFixture {
        let runtime = try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(enabledFeatures: [.dom]),
                document: document
            )
        )
        let model = try await DOMPanelModel.make(
            context: runtime.container.mainContext
        )
        var updates = model.nodes.updates.makeAsyncIterator()
        guard case .initial = await updates.next() else {
            preconditionFailure(
                "A DOM tree test fixture requires an initial canonical snapshot."
            )
        }
        return DOMTreeRuntimeFixture(
            runtime: runtime,
            model: model,
            updates: updates
        )
    }

    func makeView(
        requestChildrenAction: DOMTreeTextView.RequestChildrenAction? = nil,
        highlightNodeAction: DOMTreeTextView.HighlightNodeAction? = nil,
        restoreHighlightAction: DOMTreeTextView.RestoreHighlightAction? = nil
    ) async -> DOMTreeTextView {
        guard let initialRevision = model.nodes.revision?.rawValue else {
            preconditionFailure(
                "A DOM tree test view requires an accepted canonical snapshot."
            )
        }
        let view = DOMTreeTextView(
            model: model,
            requestChildrenAction: requestChildrenAction,
            highlightNodeAction: highlightNodeAction,
            restoreHighlightAction: restoreHighlightAction
        )
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        view.layoutIfNeeded()
        view.setRenderingActive(true)
        #expect(
            await view.waitForRowDocumentAppliedTreeRevisionForTesting(
                initialRevision,
                timeout: .seconds(5)
            )
        )
        return view
    }

    func nodeID(_ rawValue: String) throws -> DOMNode.ID {
        try #require(model.nodes.snapshot?.itemIDs.first { id in
            id.canonicalStorage.rawNodeID.rawValue == rawValue
        })
    }

    func modifyAttribute(
        nodeID: String,
        name: String,
        value: String
    ) async throws -> UInt64 {
        try await runtime.emitDOMAttributeModified(
            nodeID: nodeID,
            name: name,
            value: value
        )
        return try await nextRevision()
    }

    func setChildren(
        parentID: String,
        children: [WebInspectorDataKitTestRuntime.Node]
    ) async throws -> UInt64 {
        try await runtime.emitDOMSetChildNodes(
            parentID: parentID,
            children: children
        )
        return try await nextRevision()
    }

    func insertChild(
        parentID: String,
        previousNodeID: String? = nil,
        node: WebInspectorDataKitTestRuntime.Node
    ) async throws -> UInt64 {
        try await runtime.emitDOMChildNodeInserted(
            parentID: parentID,
            previousNodeID: previousNodeID,
            node: node
        )
        return try await nextRevision()
    }

    func removeChild(
        parentID: String,
        nodeID: String
    ) async throws -> UInt64 {
        try await runtime.emitDOMChildNodeRemoved(
            parentID: parentID,
            nodeID: nodeID
        )
        return try await nextRevision()
    }

    func replacePage(
        with document: WebInspectorDataKitTestRuntime.Document
    ) async throws -> UInt64 {
        let boundary = try await runtime.replacePage(with: document)
        guard case let .ready(pageGeneration, _) = boundary.featureState(
            for: .dom
        ) else {
            preconditionFailure(
                "A DOM page replacement requires a ready replacement generation."
            )
        }
        return try await nextRevision(in: pageGeneration)
    }

    func close(view: DOMTreeTextView) async {
        view.setRenderingActive(false)
        await model.retire()
        await runtime.close()
    }

    private func nextRevision() async throws -> UInt64 {
        while true {
            var iterator = updates
            let next = await iterator.next()
            updates = iterator
            guard let update = next else {
                break
            }
            switch update {
            case let .initial(nextRevision, _),
                let .reset(nextRevision, _):
                return nextRevision.rawValue
            case let .changes(_, toRevision, _, _):
                return toRevision.rawValue
            }
        }
        preconditionFailure(
            "A live DOM tree test fixture cannot terminate its update sequence."
        )
    }

    private func nextRevision(
        in pageGeneration: WebInspectorPageGeneration
    ) async throws -> UInt64 {
        while true {
            if let revision = revision(in: pageGeneration) {
                return revision
            }
            var iterator = updates
            let next = await iterator.next()
            updates = iterator
            guard next != nil else {
                break
            }
        }
        preconditionFailure(
            "A live DOM tree test fixture cannot terminate before applying the replacement generation."
        )
    }

    private func revision(
        in pageGeneration: WebInspectorPageGeneration
    ) -> UInt64? {
        guard let snapshot = model.nodes.snapshot,
              snapshot.itemIDs.isEmpty == false,
              snapshot.itemIDs.allSatisfy({
                  $0.canonicalStorage.documentScope.pageGeneration
                      == pageGeneration
              }),
              let revision = model.nodes.revision else {
            return nil
        }
        return revision.rawValue
    }

    static func document() -> WebInspectorDataKitTestRuntime.Document {
        .init(children: [
            .init(
                id: "doctype",
                nodeType: 10,
                nodeName: "html"
            ),
            .element(
                id: "html",
                name: "html",
                attributes: ["lang": "en"],
                children: [
                    .element(
                        id: "body",
                        name: "body",
                        attributes: [
                            "class": "logged-in env-production"
                        ],
                        children: [
                            .element(
                                id: "visible-div",
                                name: "div",
                                attributes: [
                                    "id": "start-of-content",
                                    "data-testid": "cellInnerDiv",
                                ]
                            ),
                            .element(
                                id: "input",
                                name: "input",
                                attributes: ["disabled": ""]
                            ),
                            .element(
                                id: "article",
                                name: "article",
                                children: [
                                    .element(
                                        id: "span",
                                        name: "span",
                                        attributes: [
                                            "id": "nested-child"
                                        ]
                                    )
                                ]
                            ),
                            .text(
                                id: "text",
                                value: "Introducing luma for iOS 26"
                            ),
                        ]
                    )
                ]
            ),
        ])
    }
}

private let testDOMDocumentScope = WebInspectorDOMDocumentScopeStorage(
    storeID: WebInspectorContainerStoreID(),
    attachmentGeneration: .init(rawValue: 1),
    pageGeneration: .init(rawValue: 1),
    semanticTargetID: WebInspectorTarget.ID("dom-render-test"),
    agentTargetID: WebInspectorTarget.ID("dom-render-test"),
    domBindingEpoch: .init(rawValue: 1)
)

private func testDOMNodeID(_ value: Int) -> DOMNode.ID {
    DOMNode.ID(
        canonical: WebInspectorDOMNodeIdentityStorage(
            documentScope: testDOMDocumentScope,
            rawNodeID: DOM.Node.ID(String(value))
        )
    )
}

private func makeRowDocumentRows(
    _ texts: [String],
    nodeIDs: [Int]? = nil,
    markupRanges: [NSRange]? = nil
) -> [DOMTreeRowRenderPlan] {
    let nodeIDs = nodeIDs ?? texts.indices.map { $0 + 1 }
    precondition(nodeIDs.count == texts.count)
    precondition(markupRanges == nil || markupRanges?.count == texts.count)
    var utf16Location = 0
    return texts.enumerated().map { index, text in
        let utf16Length = (text as NSString).length
        defer {
            utf16Location += utf16Length + (index + 1 < texts.count ? 1 : 0)
        }
        return DOMTreeRowRenderPlan(
            identity: DOMTreeRowIdentity(
                nodeID: testDOMNodeID(nodeIDs[index]),
                kind: .opening
            ),
            depth: 0,
            rowIndex: index,
            text: text,
            documentRange: NSRange(
                location: utf16Location,
                length: utf16Length
            ),
            markupRange: markupRanges?[index]
                ?? NSRange(location: 0, length: utf16Length),
            tokens: [],
            displayColumnCount: utf16Length,
            hasDisclosure: false,
            isOpen: false,
            hasUnloadedRegularChildren: false
        )
    }
}

private func rowRenderDifference(
    previousRows: [DOMTreeRowRenderPlan],
    nextRows: [DOMTreeRowRenderPlan]
) throws -> DOMTreeTextView.RowRenderDifference {
    try DOMTreeTextView.RowRenderDifferenceBuilder(
        previousRows: previousRows,
        previousTextUTF16Length: previousRows.last.map {
            NSMaxRange($0.documentRange)
        } ?? 0,
        nextRows: nextRows,
        resetMarkupCache: false
    ).build()
}

@MainActor
private func attributedRowDocument(
    rows: [DOMTreeRowRenderPlan]
) -> NSAttributedString {
    let attributedString = NSMutableAttributedString()
    for (index, row) in rows.enumerated() {
        if index > 0 {
            attributedString.append(NSAttributedString(string: "\n"))
        }
        attributedString.append(NSAttributedString(
            string: row.text,
            attributes: [DOMTreeTextDocument.rowIdentityAttribute: row.identity]
        ))
    }
    return attributedString
}
#endif
