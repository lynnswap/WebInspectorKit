import { beforeEach, describe, expect, it } from "vitest";

import {
    createPlaceholderNode,
    indexNode,
    mergeNodeWithSource,
} from "@wi-ts/UI/DOMTree/dom-tree-model";
import { renderState, treeState } from "@wi-ts/UI/DOMTree/dom-tree-state";
import type { DOMNode } from "@wi-ts/UI/DOMTree/dom-tree-types";

function makeNode(id: number, children: DOMNode[] = [], childCount = children.length): DOMNode {
    return {
        id,
        nodeName: "DIV",
        displayName: "div",
        nodeType: 1,
        attributes: [],
        textContent: null,
        layoutFlags: ["rendered"],
        renderedSelf: true,
        isRendered: true,
        children,
        childCount,
        placeholderParentId: null,
        depth: 0,
        parentId: null,
        childIndex: 0,
    };
}

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

    if (renderState.frameId !== null) {
        cancelAnimationFrame(renderState.frameId);
    }
    renderState.frameId = null;
    renderState.pendingNodes.clear();
}

describe("dom-tree-model mergeNodeWithSource", () => {
    beforeEach(() => {
        resetTreeState();
    });

    it("preserves known descendants when a partial subtree payload only carries placeholders", () => {
        const leaf = makeNode(4);
        const expandedChild = makeNode(3, [leaf], 1);
        const target = makeNode(2, [expandedChild], 1);

        indexNode(target, 1, 1, 0);
        treeState.openState.set(3, true);
        treeState.openState.set(4, true);

        const partialSourceChild = makeNode(3, [createPlaceholderNode(3, 1, true)], 1);
        const partialSource = makeNode(2, [partialSourceChild], 1);

        mergeNodeWithSource(target, partialSource, 1);

        expect(target.children.map((child) => child.id)).toEqual([3]);
        expect(target.children[0].children.map((child) => child.id)).toEqual([4]);
        expect(treeState.openState.get(3)).toBe(true);
        expect(treeState.openState.get(4)).toBe(true);
    });

    it("keeps known descendants and appends a placeholder when the new payload is shallower", () => {
        const firstKnownLeaf = makeNode(4);
        const secondKnownLeaf = makeNode(5);
        const target = makeNode(2, [firstKnownLeaf, secondKnownLeaf], 4);

        indexNode(target, 1, 1, 0);

        const partialSource = makeNode(2, [createPlaceholderNode(2, 4, true)], 4);

        mergeNodeWithSource(target, partialSource, 1);

        expect(target.children.map((child) => child.id)).toEqual([4, 5, -2]);
        expect(target.children[2].placeholderParentId).toBe(2);
        expect(target.children[2].childCount).toBe(2);
    });
});
