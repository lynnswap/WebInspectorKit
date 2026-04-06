import { beforeEach, describe, expect, it, vi } from "vitest";

import "../UI/DOMTree/dom-tree-view";
import { adoptDocumentContext, updateConfig } from "../UI/DOMTree/dom-tree-protocol";
import { dom, protocolState, renderState, treeState } from "../UI/DOMTree/dom-tree-state";

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
}

describe("dom-tree-view", () => {
    beforeEach(() => {
        document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";
        window.webkit = {
            messageHandlers: {
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
});
