import { beforeEach, describe, expect, it, vi } from "vitest";

import "../UI/DOMTree/dom-tree-view";
import { adoptDocumentContext, updateConfig } from "../UI/DOMTree/dom-tree-protocol";
import { dom, protocolState, renderState, transitionState, treeState } from "../UI/DOMTree/dom-tree-state";

function resetTreeState() {
    treeState.snapshot = null;
    treeState.nodes.clear();
    treeState.elements.clear();
    treeState.openState.clear();
    treeState.selectedNodeId = null;
    treeState.styleRevision = 0;
    treeState.filter = "";
    treeState.pendingRefreshRequests.clear();
    treeState.refreshAttempts.clear();
    treeState.selectionChain = [];
    treeState.deferredChildRenders.clear();
    treeState.selectionRecoveryRequestKeys.clear();
    protocolState.snapshotDepth = 4;
    protocolState.subtreeDepth = 3;
    protocolState.pageEpoch = -1;
    protocolState.documentScopeID = 0;
    adoptDocumentContext({ pageEpoch: 0, documentScopeID: 0 });
    dom.tree = null;
    dom.empty = null;
    if (renderState.frameId !== null) {
        cancelAnimationFrame(renderState.frameId);
    }
    renderState.frameId = null;
    renderState.pendingNodes.clear();
    transitionState.pendingFreshSnapshotContext = null;
}

describe("dom-tree-view", () => {
    beforeEach(() => {
        document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";
        window.webkit = {
            messageHandlers: {
                webInspectorDomRequestDocument: { postMessage: vi.fn() },
                webInspectorReady: { postMessage: vi.fn() },
                webInspectorLog: { postMessage: vi.fn() },
                webInspectorDomSelection: { postMessage: vi.fn() },
            }
        } as never;
        resetTreeState();
    });

    it("adopts newer transport context before applying a full snapshot", () => {
        adoptDocumentContext({ documentScopeID: 1 });

        window.webInspectorDOMFrontend?.applyFullSnapshot?.(
            {
                root: {
                    nodeId: 2,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    attributes: ["class", "after"],
                    children: [],
                },
            },
            "fresh",
            protocolState.pageEpoch,
            2
        );

        expect(protocolState.documentScopeID).toBe(2);
        expect(treeState.snapshot?.root?.id).toBe(2);
        expect(treeState.snapshot?.root?.attributes?.find((attribute) => attribute.name === "class")?.value).toBe("after");
    });

    it("does not advance protocol context when an incoming snapshot payload is rejected", () => {
        adoptDocumentContext({ documentScopeID: 1 });
        window.webInspectorDOMFrontend?.applyFullSnapshot?.(
            "{",
            "fresh",
            protocolState.pageEpoch,
            2
        );

        expect(protocolState.documentScopeID).toBe(1);
        expect(treeState.snapshot).toBeNull();
        expect(transitionState.pendingFreshSnapshotContext).toEqual({
            pageEpoch: 0,
            documentScopeID: 1,
        });
    });

    it("exposes document context adoption on the public frontend API", () => {
        const didAdopt = window.webInspectorDOMFrontend?.adoptDocumentContext?.({
            pageEpoch: 4,
            documentScopeID: 6,
        });

        expect(didAdopt).toBe(true);
        expect(protocolState.pageEpoch).toBe(4);
        expect(protocolState.documentScopeID).toBe(6);
        expect(transitionState.pendingFreshSnapshotContext).toEqual({
            pageEpoch: 4,
            documentScopeID: 6,
        });
    });

    it("forces the next same-context snapshot bundle to apply fresh after public context adoption", () => {
        window.webInspectorDOMFrontend?.applyFullSnapshot?.(
            {
                root: {
                    nodeId: 1,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    attributes: ["id", "stale-root"],
                    children: [
                        {
                            nodeId: 2,
                            nodeType: 1,
                            nodeName: "SPAN",
                            localName: "span",
                            attributes: ["id", "stale-child"],
                            children: [],
                        },
                    ],
                },
            },
            "fresh",
            protocolState.pageEpoch,
            protocolState.documentScopeID
        );
        treeState.selectedNodeId = 2;

        const didAdopt = window.webInspectorDOMFrontend?.adoptDocumentContext?.({
            pageEpoch: 4,
            documentScopeID: 6,
        });
        expect(didAdopt).toBe(true);

        window.webInspectorDOMFrontend?.applyMutationBundle?.({
            kind: "snapshot",
            pageEpoch: 4,
            documentScopeID: 6,
            snapshot: {
                root: {
                    nodeId: 10,
                    nodeType: 1,
                    nodeName: "SECTION",
                    localName: "section",
                    attributes: ["id", "fresh-root"],
                    children: [],
                },
            },
        });

        expect(treeState.snapshot?.root?.id).toBe(10);
        expect(treeState.selectedNodeId).toBeNull();
        expect(transitionState.pendingFreshSnapshotContext).toBeNull();
    });

    it("forces the next same-context direct full snapshot to apply fresh after public context adoption", () => {
        window.webInspectorDOMFrontend?.applyFullSnapshot?.(
            {
                root: {
                    nodeId: 1,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    attributes: ["id", "stale-root"],
                    children: [
                        {
                            nodeId: 2,
                            nodeType: 1,
                            nodeName: "SPAN",
                            localName: "span",
                            attributes: ["id", "stale-child"],
                            children: [],
                        },
                    ],
                },
            },
            "fresh",
            protocolState.pageEpoch,
            protocolState.documentScopeID
        );
        treeState.selectedNodeId = 2;

        const didAdopt = window.webInspectorDOMFrontend?.adoptDocumentContext?.({
            pageEpoch: 8,
            documentScopeID: 9,
        });
        expect(didAdopt).toBe(true);

        window.webInspectorDOMFrontend?.applyFullSnapshot?.(
            {
                root: {
                    nodeId: 20,
                    nodeType: 1,
                    nodeName: "ARTICLE",
                    localName: "article",
                    attributes: ["id", "fresh-root"],
                    children: [],
                },
            },
            "preserve-ui-state",
            8,
            9
        );

        expect(treeState.snapshot?.root?.id).toBe(20);
        expect(treeState.selectedNodeId).toBeNull();
        expect(transitionState.pendingFreshSnapshotContext).toBeNull();
    });

    it("applies selection directly without requiring a full snapshot", () => {
        window.webInspectorDOMFrontend?.applyFullSnapshot?.(
            {
                root: {
                    nodeId: 1,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    attributes: ["id", "root"],
                    children: [
                        {
                            nodeId: 2,
                            nodeType: 1,
                            nodeName: "SPAN",
                            localName: "span",
                            attributes: ["id", "target"],
                            children: [],
                        },
                    ],
                },
            },
            "fresh",
            protocolState.pageEpoch,
            protocolState.documentScopeID
        );

        const didSelect = window.webInspectorDOMFrontend?.applySelectionPayload?.(
            2,
            protocolState.pageEpoch,
            protocolState.documentScopeID
        );

        expect(didSelect).toBe(true);
        expect(treeState.selectedNodeId).toBe(2);
        expect(
            (
                window.webkit?.messageHandlers?.webInspectorDomSelection as {
                    postMessage: ReturnType<typeof vi.fn>;
                }
            ).postMessage
        ).toHaveBeenCalled();
    });

    it("falls back to selectedNodePath when the payload node id is not indexed", () => {
        window.webInspectorDOMFrontend?.applyFullSnapshot?.(
            {
                root: {
                    nodeId: 1,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    attributes: ["id", "root"],
                    children: [
                        {
                            nodeId: 2,
                            nodeType: 1,
                            nodeName: "SPAN",
                            localName: "span",
                            attributes: ["id", "target"],
                            children: [],
                        },
                    ],
                },
            },
            "fresh",
            protocolState.pageEpoch,
            protocolState.documentScopeID
        );

        const didSelect = window.webInspectorDOMFrontend?.applySelectionPayload?.(
            {
                selectedLocalId: 999,
                selectedNodePath: [0],
            },
            protocolState.pageEpoch,
            protocolState.documentScopeID
        );

        expect(didSelect).toBe(true);
        expect(treeState.selectedNodeId).toBe(2);
    });

    it("requests a preserve-ui-state snapshot with a selection restore target when selection is missing from the current tree", () => {
        const requestDocumentHandler = window.webkit?.messageHandlers?.webInspectorDomRequestDocument as {
            postMessage: ReturnType<typeof vi.fn>;
        };
        const rafSpy = vi.spyOn(globalThis, "requestAnimationFrame");

        window.webInspectorDOMFrontend?.applyFullSnapshot?.(
            {
                root: {
                    nodeId: 1,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    attributes: ["id", "root"],
                    children: [
                        {
                            nodeId: 2,
                            nodeType: 1,
                            nodeName: "SECTION",
                            localName: "section",
                            attributes: ["id", "branch"],
                            children: [],
                        },
                    ],
                },
            },
            "fresh",
            protocolState.pageEpoch,
            protocolState.documentScopeID
        );

        const firstAttempt = window.webInspectorDOMFrontend?.applySelectionPayload?.(
            {
                selectedLocalId: 99,
                backendNodeId: 9001,
                selectedNodePath: [0, 0],
            },
            protocolState.pageEpoch,
            protocolState.documentScopeID
        );
        const duplicateAttempt = window.webInspectorDOMFrontend?.applySelectionPayload?.(
            {
                selectedLocalId: 99,
                backendNodeId: 9001,
                selectedNodePath: [0, 0],
            },
            protocolState.pageEpoch,
            protocolState.documentScopeID
        );

        expect(firstAttempt).toBe(false);
        expect(duplicateAttempt).toBe(false);
        expect(requestDocumentHandler.postMessage).toHaveBeenCalledTimes(1);
        expect(requestDocumentHandler.postMessage.mock.calls[0]?.[0]).toMatchObject({
            depth: protocolState.snapshotDepth,
            mode: "preserve-ui-state",
            pageEpoch: protocolState.pageEpoch,
            documentScopeID: protocolState.documentScopeID,
            selectionRestoreTarget: {
                selectedLocalId: 99,
                selectedBackendNodeId: 9001,
                selectedNodePath: [0, 0],
            },
        });

        rafSpy.mockClear();

        window.webInspectorDOMFrontend?.applyFullSnapshot?.(
            {
                root: {
                    nodeId: 1,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    attributes: ["id", "root"],
                    children: [
                        {
                            nodeId: 2,
                            nodeType: 1,
                            nodeName: "SECTION",
                            localName: "section",
                            attributes: ["id", "branch"],
                            children: [
                                {
                                    nodeId: 99,
                                    nodeType: 1,
                                    nodeName: "SPAN",
                                    localName: "span",
                                    attributes: ["id", "target"],
                                    children: [],
                                },
                            ],
                        },
                    ],
                    selectedLocalId: 99,
                    selectedNodePath: [0, 0],
                },
                selectedLocalId: 99,
                selectedNodePath: [0, 0],
            },
            "fresh",
            protocolState.pageEpoch,
            protocolState.documentScopeID
        );

        expect(treeState.selectedNodeId).toBe(99);
        expect(treeState.openState.get(1)).toBe(true);
        expect(treeState.openState.get(2)).toBe(true);
        expect(rafSpy).toHaveBeenCalled();
        rafSpy.mockRestore();
    });
});
