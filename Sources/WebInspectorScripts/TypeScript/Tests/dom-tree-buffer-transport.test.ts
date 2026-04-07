import { beforeEach, describe, expect, it, vi } from "vitest";

import { applyMutationBundlesFromBuffer } from "../UI/DOMTree/dom-tree-buffer-transport";
import { applyMutationBuffer, setSnapshot } from "../UI/DOMTree/dom-tree-snapshot";
import { protocolState, renderState, treeState } from "../UI/DOMTree/dom-tree-state";
import { adoptDocumentContext, updateConfig } from "../UI/DOMTree/dom-tree-protocol";

describe("dom-tree-buffer-transport", () => {
    beforeEach(() => {
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
        protocolState.snapshotDepth = 4;
        protocolState.subtreeDepth = 3;
        protocolState.pageEpoch = -1;
        protocolState.documentScopeID = 0;
        adoptDocumentContext({ pageEpoch: 0, documentScopeID: 0 });
        if (renderState.frameId !== null) {
            cancelAnimationFrame(renderState.frameId);
        }
        renderState.frameId = null;
        renderState.pendingNodes.clear();
    });

    it("restores mutation bundles from window.webkit.buffers", () => {
        const bundles = [{ kind: "mutation", events: [{ method: "DOM.childNodeCountUpdated", params: { nodeId: 1, childNodeCount: 2 } }] }];
        const encoded = new TextEncoder().encode(JSON.stringify(bundles));
        const webkit = window.webkit as unknown as { buffers?: Record<string, unknown> };
        webkit.buffers = {
            domPayload: encoded
        };

        const restored = applyMutationBundlesFromBuffer("domPayload");
        expect(restored).toEqual(bundles);
    });

    it("returns null when the named buffer is missing", () => {
        const webkit = window.webkit as unknown as { buffers?: Record<string, unknown> };
        webkit.buffers = {};

        const restored = applyMutationBundlesFromBuffer("missing");
        expect(restored).toBeNull();
    });

    it("returns application status from applyMutationBuffer", () => {
        const bundles = [{ kind: "mutation", events: [{ method: "DOM.childNodeCountUpdated", params: { nodeId: 1, childNodeCount: 2 } }] }];
        const encoded = new TextEncoder().encode(JSON.stringify(bundles));
        const webkit = window.webkit as unknown as { buffers?: Record<string, unknown> };
        webkit.buffers = {
            domPayload: encoded
        };

        expect(applyMutationBuffer("domPayload")).toBe(true);
        expect(applyMutationBuffer("missing")).toBe(false);
    });

    it("applyMutationBuffer uses wrapper context ahead of stale embedded metadata", () => {
        setSnapshot({
            root: {
                nodeId: 1,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: ["class", "before"],
                children: [],
            }
        }, { mode: "fresh" });
        adoptDocumentContext({ documentScopeID: 2 });

        const bundles = [{
            bundle: {
                version: 1,
                kind: "mutation",
                pageEpoch: protocolState.pageEpoch,
                documentScopeID: 1,
                events: [{
                    method: "DOM.attributeModified",
                    params: { nodeId: 1, name: "class", value: "after" }
                }]
            },
            mode: "preserve-ui-state",
            pageEpoch: protocolState.pageEpoch,
            documentScopeID: protocolState.documentScopeID,
        }];
        const encoded = new TextEncoder().encode(JSON.stringify(bundles));
        const webkit = window.webkit as unknown as { buffers?: Record<string, unknown> };
        webkit.buffers = {
            domPayload: encoded
        };

        expect(applyMutationBuffer("domPayload", protocolState.pageEpoch)).toBe(true);
        vi.advanceTimersByTime(16);
        expect(treeState.snapshot?.root?.attributes?.find((attribute) => attribute.name === "class")?.value).toBe("after");
    });
});
