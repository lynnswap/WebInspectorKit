import { beforeEach, describe, expect, it } from "vitest";

import {
    processPendingNodeRenders,
    scheduleNodeRender
} from "../../Sources/WebInspectorScripts/TypeScript/UI/DOMTree/dom-tree-view-support";
import { renderState, treeState } from "../../Sources/WebInspectorScripts/TypeScript/UI/DOMTree/dom-tree-state";
import { TEXT_CONTENT_ATTRIBUTE } from "../../Sources/WebInspectorScripts/TypeScript/UI/DOMTree/dom-tree-types";
import type { DOMNode } from "../../Sources/WebInspectorScripts/TypeScript/UI/DOMTree/dom-tree-types";

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
        placeholderParentId: null,
        depth: 1,
        parentId: 1,
        childIndex: 0
    };
}

function resetRenderState() {
    if (renderState.frameId !== null) {
        cancelAnimationFrame(renderState.frameId);
    }
    renderState.frameId = null;
    renderState.pendingNodes.clear();

    treeState.nodes.clear();
    treeState.elements.clear();
    treeState.openState.clear();
    treeState.deferredChildRenders.clear();
    treeState.snapshot = null;
}

describe("dom-tree-view-support", () => {
    beforeEach(() => {
        resetRenderState();
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
});
