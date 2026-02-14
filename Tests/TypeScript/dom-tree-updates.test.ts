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

    it("increments style revision when a link rel changes to stylesheet", () => {
        const selectedNode = makeNode(2);
        const stylesheetLinkNode = makeNode(3);
        stylesheetLinkNode.nodeName = "LINK";
        stylesheetLinkNode.displayName = "link";
        stylesheetLinkNode.attributes = [
            { name: "rel", value: "preload" },
            { name: "href", value: "/assets/app.css" }
        ];
        selectedNode.parentId = 1;
        selectedNode.depth = 1;
        selectedNode.childIndex = 0;
        stylesheetLinkNode.parentId = 1;
        stylesheetLinkNode.depth = 1;
        stylesheetLinkNode.childIndex = 1;
        const root = makeNode(1, [selectedNode, stylesheetLinkNode]);

        treeState.snapshot = { root };
        treeState.nodes.set(1, root);
        treeState.nodes.set(2, selectedNode);
        treeState.nodes.set(3, stylesheetLinkNode);
        treeState.selectedNodeId = 2;

        const updater = new DOMTreeUpdater();
        updater.enqueueEvents([{
            method: "DOM.attributeModified",
            params: {
                nodeId: 3,
                name: "rel",
                value: "stylesheet"
            }
        }]);

        vi.advanceTimersByTime(16);
        expect(treeState.styleRevision).toBe(1);
    });

    it("increments style revision when selected node style context changes structurally", () => {
        const selectedNode = makeNode(2);
        selectedNode.parentId = 1;
        selectedNode.depth = 1;
        selectedNode.childIndex = 0;
        const root = makeNode(1, [selectedNode]);
        root.childCount = 1;

        treeState.snapshot = { root };
        treeState.nodes.set(1, root);
        treeState.nodes.set(2, selectedNode);
        treeState.selectedNodeId = 2;

        const updater = new DOMTreeUpdater();
        updater.enqueueEvents([{
            method: "DOM.childNodeInserted",
            params: {
                parentNodeId: 1,
                previousNodeId: 2,
                node: {
                    nodeId: 4,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    attributes: [],
                    childNodeCount: 0,
                    children: []
                }
            }
        }]);

        vi.advanceTimersByTime(16);
        expect(treeState.styleRevision).toBe(1);
    });

    it("increments style revision for childNodeCountUpdated when parent children are incomplete", () => {
        const knownChild = makeNode(2);
        knownChild.parentId = 1;
        knownChild.depth = 1;
        knownChild.childIndex = 0;

        const root = makeNode(1, [knownChild]);
        root.childCount = 2;

        treeState.snapshot = { root };
        treeState.nodes.set(1, root);
        treeState.nodes.set(2, knownChild);

        const updater = new DOMTreeUpdater();
        updater.enqueueEvents([{
            method: "DOM.childNodeCountUpdated",
            params: {
                nodeId: 1,
                childNodeCount: 3
            }
        }]);

        vi.advanceTimersByTime(16);
        expect(treeState.styleRevision).toBe(1);
    });

    it("increments style revision for style-relevant attribute changes on unknown nodes", () => {
        const root = makeNode(1);
        treeState.snapshot = { root };
        treeState.nodes.set(1, root);

        const updater = new DOMTreeUpdater();
        updater.enqueueEvents([{
            method: "DOM.attributeModified",
            params: {
                nodeId: 999,
                name: "href",
                value: "/assets/theme.css"
            }
        }]);

        vi.advanceTimersByTime(16);
        expect(treeState.styleRevision).toBe(1);
    });

    it("increments style revision for unknown child removals in shallow snapshots", () => {
        const root = makeNode(1);
        treeState.snapshot = { root };
        treeState.nodes.set(1, root);

        const updater = new DOMTreeUpdater();
        updater.enqueueEvents([{
            method: "DOM.childNodeRemoved",
            params: {
                parentNodeId: 999,
                nodeId: 1000
            }
        }]);

        vi.advanceTimersByTime(16);
        expect(treeState.styleRevision).toBe(1);
    });
});
