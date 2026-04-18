import { beforeEach, describe, expect, it } from "vitest";

import { setSnapshot } from "../UI/DOMTree/dom-tree-snapshot";
import { protocolState, treeState } from "../UI/DOMTree/dom-tree-state";

function resetState(): void {
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
    protocolState.contextID = 1;
}

describe("dom-tree-snapshot-envelope", () => {
    beforeEach(() => {
        resetState();
    });

    it("accepts a serialized envelope with fallback identifiers", () => {
        const didApply = setSnapshot({
            type: "serialized-node-envelope",
            schemaVersion: 1,
            node: document.createElement("main"),
            fallback: {
                root: {
                    nodeId: 11,
                    nodeType: 1,
                    nodeName: "MAIN",
                    localName: "main",
                    attributes: ["id", "root"],
                    childNodeCount: 0,
                    children: [],
                },
                selectedNodeId: 11,
            },
            selectedNodeId: 11,
        });

        expect(didApply).toBe(true);
        expect(treeState.snapshot?.root?.id).toBe(11);
        expect(treeState.selectedNodeId).toBe(11);
    });

    it("rejects an invalid envelope without a resolvable root", () => {
        const didApply = setSnapshot({
            type: "serialized-node-envelope",
            schemaVersion: 1,
            node: null,
            fallback: null,
        });

        expect(didApply).toBe(false);
        expect(treeState.snapshot).toBeNull();
    });
});
