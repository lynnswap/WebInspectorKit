import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
    captureTreeScrollPosition,
    processPendingNodeRenders,
    restoreTreeScrollPosition,
    scheduleNodeRender
} from "../UI/DOMTree/dom-tree-view-support";
import { dom, renderState, treeState } from "../UI/DOMTree/dom-tree-state";
import { TEXT_CONTENT_ATTRIBUTE } from "../UI/DOMTree/dom-tree-types";
import type { DOMNode } from "../UI/DOMTree/dom-tree-types";

function makeNode(id: number): DOMNode {
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
        children: [],
        childCount: 0,
        depth: 1,
        parentId: 1,
        childIndex: 0
    };
}

function resetRenderState() {
    document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";
    dom.tree = null;
    dom.empty = null;
    if (renderState.frameId !== null) {
        cancelAnimationFrame(renderState.frameId);
    }
    renderState.frameId = null;
    renderState.pendingNodes.clear();
    renderState.isProcessing = false;

    treeState.nodes.clear();
    treeState.elements.clear();
    treeState.openState.clear();
    treeState.deferredChildRenders.clear();
    treeState.selectionRecoveryRequestKeys.clear();
    treeState.snapshot = null;
}

function ensureDomFixture(): {tree: HTMLDivElement} {
    const tree = document.getElementById("dom-tree") as HTMLDivElement;
    dom.tree = tree;
    return {tree};
}

describe("dom-tree-view-support", () => {
    beforeEach(() => {
        resetRenderState();
    });

    afterEach(() => {
        vi.restoreAllMocks();
    });

    it("merges render queue entries for the same node", () => {
        const node = makeNode(10);

        scheduleNodeRender(node, {
            updateChildren: false,
            modifiedAttributes: new Set(["class"])
        });
        scheduleNodeRender(node, {
            updateChildren: true,
            modifiedAttributes: new Set([TEXT_CONTENT_ATTRIBUTE])
        });

        expect(renderState.pendingNodes.size).toBe(1);
        const merged = renderState.pendingNodes.get(node.id);
        expect(merged).toBeDefined();
        expect(merged?.updateChildren).toBe(true);
        expect(merged?.modifiedAttributes?.has("class")).toBe(true);
        expect(merged?.modifiedAttributes?.has(TEXT_CONTENT_ATTRIBUTE)).toBe(true);
    });

    it("reschedules remaining node renders when render batch limit is exceeded", () => {
        for (let index = 0; index < 220; index += 1) {
            scheduleNodeRender(makeNode(index + 1));
        }

        processPendingNodeRenders();
        expect(renderState.pendingNodes.size).toBeGreaterThan(0);
        expect(renderState.pendingNodes.size).toBeLessThan(220);

        processPendingNodeRenders();
        expect(renderState.pendingNodes.size).toBe(0);
    });

    it("captures and restores scroll position from the scroll viewport", () => {
        ensureDomFixture();
        document.documentElement.scrollTop = 120;
        document.documentElement.scrollLeft = 48;

        const position = captureTreeScrollPosition();
        expect(position).toEqual({ top: 120, left: 48 });

        document.documentElement.scrollTop = 0;
        document.documentElement.scrollLeft = 0;
        restoreTreeScrollPosition(position);

        expect(document.documentElement.scrollTop).toBe(120);
        expect(document.documentElement.scrollLeft).toBe(48);
    });

    it("keeps horizontal scroll position when restoring selection visibility", async () => {
        const module = await import("../UI/DOMTree/dom-tree-view-support");
        const { tree } = ensureDomFixture();
        const row = document.createElement("div");
        row.className = "tree-node__row";
        const element = document.createElement("div");
        element.appendChild(row);

        tree.appendChild(element);
        treeState.elements.set(10, element);
        treeState.selectedNodeId = 10;

        document.documentElement.scrollTop = 10;
        document.documentElement.scrollLeft = 42;
        row.getBoundingClientRect = () => ({
            top: 880,
            bottom: 920,
            left: 0,
            right: 200,
            width: 200,
            height: 40,
            x: 0,
            y: 880,
            toJSON: () => ({}),
        }) as DOMRect;

        const scrollTo = vi.fn(({ top }: { top: number }) => {
            document.documentElement.scrollTop = top;
        });
        window.scrollTo = scrollTo as unknown as typeof window.scrollTo;

        expect(module.scrollSelectionIntoView(10)).toBe(false);
        expect(scrollTo).toHaveBeenCalledTimes(1);
        expect(document.documentElement.scrollLeft).toBe(42);
    });
});
