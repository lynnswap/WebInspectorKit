import { beforeEach, describe, expect, it } from "vitest";

import {
    ensureTreeEventHandlers,
    selectNode,
    processPendingNodeRenders,
    scheduleNodeRender
} from "../UI/DOMTree/dom-tree-view-support";
import { setSnapshot } from "../UI/DOMTree/dom-tree-snapshot";
import { protocolState, renderState, treeState } from "../UI/DOMTree/dom-tree-state";
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
    treeState.selectedNodeId = null;
    treeState.deferredChildRenders.clear();
    treeState.selectionChain = [];
    treeState.snapshot = null;
    protocolState.pending.clear();
    protocolState.lastId = 0;
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

    it("toggles subtree expansion when clicking a row", () => {
        document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";

        setSnapshot({
            root: {
                nodeId: 1,
                nodeType: 9,
                nodeName: "#document",
                localName: "",
                childNodeCount: 1,
                children: [{
                    nodeId: 2,
                    nodeType: 1,
                    nodeName: "HTML",
                    localName: "html",
                    attributes: [],
                    childNodeCount: 1,
                    children: [{
                        nodeId: 3,
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body",
                        attributes: [],
                        childNodeCount: 1,
                        children: [{
                            nodeId: 4,
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            attributes: [],
                            childNodeCount: 1,
                            children: [{
                                nodeId: 5,
                                nodeType: 1,
                                nodeName: "SPAN",
                                localName: "span",
                                attributes: [],
                                childNodeCount: 0,
                                children: []
                            }]
                        }]
                    }]
                }]
            }
        });

        ensureTreeEventHandlers();

        const targetElement = treeState.elements.get(4);
        const row = targetElement?.querySelector(".tree-node__row") as HTMLElement | null;
        const disclosure = targetElement?.querySelector(".tree-node__disclosure") as HTMLElement | null;

        expect(treeState.openState.get(4)).toBe(false);
        row?.dispatchEvent(new MouseEvent("click", { bubbles: true }));

        expect(treeState.selectedNodeId).toBe(4);
        expect(treeState.openState.get(4)).toBe(true);
        expect(targetElement?.classList.contains("is-collapsed")).toBe(false);

        row?.dispatchEvent(new MouseEvent("click", { bubbles: true }));

        expect(treeState.selectedNodeId).toBe(4);
        expect(treeState.openState.get(4)).toBe(false);
        expect(targetElement?.classList.contains("is-collapsed")).toBe(true);

        disclosure?.dispatchEvent(new MouseEvent("click", { bubbles: true }));

        expect(treeState.openState.get(4)).toBe(true);
        expect(targetElement?.classList.contains("is-collapsed")).toBe(false);
    });

    it("reveals ancestors without forcing the selected node open", () => {
        document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";

        setSnapshot({
            root: {
                nodeId: 1,
                nodeType: 9,
                nodeName: "#document",
                localName: "",
                childNodeCount: 1,
                children: [{
                    nodeId: 2,
                    nodeType: 1,
                    nodeName: "HTML",
                    localName: "html",
                    attributes: [],
                    childNodeCount: 1,
                    children: [{
                        nodeId: 3,
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body",
                        attributes: [],
                        childNodeCount: 1,
                        children: [{
                            nodeId: 4,
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            attributes: [],
                            childNodeCount: 1,
                            children: [{
                                nodeId: 5,
                                nodeType: 1,
                                nodeName: "SPAN",
                                localName: "span",
                                attributes: [],
                                childNodeCount: 1,
                                children: [{
                                    nodeId: 6,
                                    nodeType: 1,
                                    nodeName: "EM",
                                    localName: "em",
                                    attributes: [],
                                    childNodeCount: 0,
                                    children: []
                                }]
                            }]
                        }]
                    }]
                }]
            }
        });

        selectNode(5, { shouldHighlight: false });

        expect(treeState.selectedNodeId).toBe(5);
        expect(treeState.openState.get(2)).toBe(true);
        expect(treeState.openState.get(3)).toBe(true);
        expect(treeState.openState.get(4)).toBe(true);
        expect(treeState.openState.get(5)).not.toBe(true);
    });
});
