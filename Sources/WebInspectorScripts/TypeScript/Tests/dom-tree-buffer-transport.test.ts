import { beforeEach, describe, expect, it } from "vitest";
import { vi } from "vitest";

import { applyMutationBundlesFromBuffer } from "../UI/DOMTree/dom-tree-buffer-transport";
import { applyMutationBuffer, setSnapshot } from "../UI/DOMTree/dom-tree-snapshot";
import { protocolState, renderState, treeState } from "../UI/DOMTree/dom-tree-state";
import { adoptDocumentContext } from "../UI/DOMTree/dom-tree-protocol";

function resetDOMTreeState(): void {
    document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";
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
    adoptDocumentContext({ contextID: 1 });
    if (renderState.frameId !== null) {
        cancelAnimationFrame(renderState.frameId);
    }
    renderState.frameId = null;
    renderState.pendingNodes.clear();
    (window.webkit as { buffers?: Record<string, unknown> }).buffers = {};
    if (typeof globalThis.requestAnimationFrame !== "function") {
        globalThis.requestAnimationFrame = ((callback: FrameRequestCallback) => {
            return setTimeout(() => callback(0), 0) as unknown as number;
        }) as typeof requestAnimationFrame;
    }
    if (typeof globalThis.cancelAnimationFrame !== "function") {
        globalThis.cancelAnimationFrame = ((handle: number) => {
            clearTimeout(handle);
        }) as typeof cancelAnimationFrame;
    }
}

describe("dom-tree-buffer-transport", () => {
    beforeEach(() => {
        vi.useRealTimers();
        resetDOMTreeState();
    });

    it("restores mutation bundles from window.webkit.buffers", () => {
        const bundles = [{ kind: "mutation", contextID: 1, events: [{ method: "DOM.childNodeCountUpdated", params: { nodeId: 1, childNodeCount: 2 } }] }];
        const encoded = new TextEncoder().encode(JSON.stringify(bundles));
        (window.webkit as { buffers?: Record<string, unknown> }).buffers = {
            domPayload: encoded
        };

        expect(applyMutationBundlesFromBuffer("domPayload")).toEqual(bundles);
    });

    it("returns false when the named buffer is missing", () => {
        expect(applyMutationBuffer("missing")).toBe(false);
    });

    it("applies a buffered mutation when the wrapper context matches", async () => {
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

        const bundles = [{
            bundle: {
                version: 2,
                kind: "mutation",
                contextID: 999,
                events: [{
                    method: "DOM.attributeModified",
                    params: { nodeId: 1, name: "class", value: "after" }
                }]
            },
            contextID: protocolState.contextID,
        }];
        const encoded = new TextEncoder().encode(JSON.stringify(bundles));
        (window.webkit as { buffers?: Record<string, unknown> }).buffers = {
            domPayload: encoded
        };

        expect(applyMutationBuffer("domPayload", protocolState.contextID)).toBe(true);
        await new Promise((resolve) => setTimeout(resolve, 20));
        expect(treeState.snapshot?.root?.attributes?.find((attribute) => attribute.name === "class")?.value).toBe("after");
    });
});
