import { beforeEach, describe, expect, it, vi } from "vitest";

import {
    DOMTreeUpdater,
    setReloadHandler
} from "../../Sources/WebInspectorKitCore/WebInspector/Views/DOMTreeView/dom-tree-updates";
import { renderState, treeState } from "../../Sources/WebInspectorKitCore/WebInspector/Views/DOMTreeView/dom-tree-state";
import type { DOMEventEntry, DOMNode } from "../../Sources/WebInspectorKitCore/WebInspector/Views/DOMTreeView/dom-tree-types";

function makeNode(id: number, children: DOMNode[] = []): DOMNode {
    return {
        id,
        nodeName: id === 1 ? "HTML" : "DIV",
        displayName: id === 1 ? "html" : "div",
        nodeType: 1,
        attributes: [],
        textContent: null,
        layoutFlags: ["rendered"],
        renderedSelf: true,
        isRendered: true,
        children,
        childCount: children.length,
        placeholderParentId: null,
        depth: 0,
        parentId: null,
        childIndex: 0
    };
}

function resetTreeState() {
    treeState.snapshot = null;
    treeState.nodes.clear();
    treeState.elements.clear();
    treeState.openState.clear();
    treeState.selectedNodeId = null;
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

describe("dom-tree-updates", () => {
    beforeEach(() => {
        resetTreeState();
        setReloadHandler(null);
    });

    it("triggers reload when DOM updates arrive before a snapshot exists", () => {
        const updater = new DOMTreeUpdater();
        const reloadSpy = vi.fn();
        setReloadHandler(reloadSpy);

        updater.enqueueEvents([{
            method: "DOM.attributeModified",
            params: { nodeId: 1, name: "class", value: "ready" }
        }]);

        expect(reloadSpy).toHaveBeenCalledTimes(1);
        expect(reloadSpy).toHaveBeenCalledWith("missing-snapshot");
        expect((updater as any).pendingEvents.length).toBe(0);
    });

    it("splits DOM update processing when event batch limit is exceeded", () => {
        const root = makeNode(1);
        treeState.snapshot = { root };
        treeState.nodes.set(root.id, root);

        const updater = new DOMTreeUpdater();
        const events: DOMEventEntry[] = Array.from({ length: 125 }, (_, index) => ({
            method: `DOM.customEvent.${index}`,
            params: {}
        }));

        updater.enqueueEvents(events);

        vi.advanceTimersByTime(16);
        expect((updater as any).pendingEvents.length).toBe(5);

        vi.advanceTimersByTime(16);
        expect((updater as any).pendingEvents.length).toBe(0);
    });

    it("clears selected node when a selected child is removed", () => {
        const child = makeNode(2);
        const root = makeNode(1, [child]);
        child.parentId = 1;
        child.depth = 1;
        child.childIndex = 0;

        treeState.snapshot = { root };
        treeState.nodes.set(1, root);
        treeState.nodes.set(2, child);
        treeState.selectedNodeId = 2;

        const updater = new DOMTreeUpdater();
        updater.enqueueEvents([{
            method: "DOM.childNodeRemoved",
            params: {
                parentNodeId: 1,
                nodeId: 2
            }
        }]);

        vi.advanceTimersByTime(16);
        expect(treeState.selectedNodeId).toBeNull();
        expect(treeState.nodes.has(2)).toBe(false);
    });
});
