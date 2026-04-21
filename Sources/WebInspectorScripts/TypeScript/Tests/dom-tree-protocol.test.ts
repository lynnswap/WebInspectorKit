import { beforeEach, describe, expect, it, vi } from "vitest";

import {
    adoptDocumentContext,
    finishChildNodeRequest,
    onContextDidChange,
    requestChildNodes,
} from "../UI/DOMTree/dom-tree-protocol";
import { applyMutationBundle, setSnapshot } from "../UI/DOMTree/dom-tree-snapshot";
import { dom, protocolState, renderState, treeState } from "../UI/DOMTree/dom-tree-state";

let nextContextID = 1;

function resetState(): void {
    document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";
    dom.tree = null;
    dom.empty = null;
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
    protocolState.contextID = 0;
    adoptDocumentContext({ contextID: nextContextID });
    nextContextID += 1;
    if (renderState.frameId !== null) {
        cancelAnimationFrame(renderState.frameId);
    }
    renderState.frameId = null;
    renderState.pendingNodes.clear();
    window.webkit = {
        messageHandlers: {
            webInspectorDomRequestChildren: { postMessage: vi.fn() },
            webInspectorDomHighlight: { postMessage: vi.fn() },
            webInspectorDomHideHighlight: { postMessage: vi.fn() },
            webInspectorLog: { postMessage: vi.fn() },
        },
    } as never;
}

describe("dom-tree-protocol", () => {
    beforeEach(() => {
        resetState();
    });

    it("adopts a new contextID and notifies listeners", () => {
        const handler = vi.fn();
        const dispose = onContextDidChange(handler);

        expect(adoptDocumentContext({ contextID: 2 })).toBe(true);
        expect(protocolState.contextID).toBe(2);
        expect(handler).toHaveBeenCalledTimes(1);

        dispose();
    });

    it("posts child requests with the current contextID", async () => {
        await requestChildNodes(11, 3);

        const handler = window.webkit?.messageHandlers?.webInspectorDomRequestChildren?.postMessage as ReturnType<typeof vi.fn>;
        expect(handler).toHaveBeenCalledWith({
            nodeId: 11,
            depth: 3,
            contextID: protocolState.contextID,
        });
    });

    it("allows a child request to be re-issued after finish", async () => {
        const handler = window.webkit?.messageHandlers?.webInspectorDomRequestChildren?.postMessage as ReturnType<typeof vi.fn>;

        await requestChildNodes(11, 3);
        await requestChildNodes(11, 3);
        expect(handler).toHaveBeenCalledTimes(1);

        finishChildNodeRequest(11, true, protocolState.contextID);
        await requestChildNodes(11, 3);
        expect(handler).toHaveBeenCalledTimes(2);
    });

    it("ignores stale mutation bundles", () => {
        setSnapshot({
            root: {
                nodeId: 1,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: ["class", "before"],
                children: [],
            }
        });

        applyMutationBundle({
            version: 2,
            kind: "mutation",
            contextID: 999,
            events: [{ method: "DOM.attributeModified", params: { nodeId: 1, name: "class", value: "after" } }],
        });

        expect(treeState.snapshot?.root?.attributes?.find((attribute) => attribute.name === "class")?.value).toBe("before");
    });

    it("clears the tree when documentUpdated arrives for the current context", () => {
        setSnapshot({
            root: {
                nodeId: 1,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: [],
                children: [],
            }
        });
        const tree = document.getElementById("dom-tree") as HTMLElement;
        document.documentElement.scrollTop = 40;
        document.documentElement.scrollLeft = 55;

        applyMutationBundle({
            version: 2,
            kind: "mutation",
            contextID: protocolState.contextID,
            events: [{ method: "DOM.documentUpdated", params: {} }],
        });

        expect(treeState.snapshot).toBeNull();
        expect(treeState.selectedNodeId).toBeNull();
        expect(tree.childElementCount).toBe(0);
        expect(document.documentElement.scrollTop).toBe(0);
        expect(document.documentElement.scrollLeft).toBe(0);
    });
});
