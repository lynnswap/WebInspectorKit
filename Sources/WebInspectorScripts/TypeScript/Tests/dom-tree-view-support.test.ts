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
    document.documentElement.removeAttribute("style");
    Object.defineProperty(window, "visualViewport", {
        configurable: true,
        value: undefined,
    });
    Object.defineProperty(window, "innerWidth", {
        configurable: true,
        value: 1024,
    });
    Object.defineProperty(window, "innerHeight", {
        configurable: true,
        value: 768,
    });
}

function ensureDomFixture(): {tree: HTMLDivElement} {
    const tree = document.getElementById("dom-tree") as HTMLDivElement;
    dom.tree = tree;
    return {tree};
}

function setVisualViewport(options: {
    pageTop?: number;
    pageLeft?: number;
    width: number;
    height: number;
}) {
    Object.defineProperty(window, "visualViewport", {
        configurable: true,
        value: {
            pageTop: options.pageTop ?? 0,
            pageLeft: options.pageLeft ?? 0,
            width: options.width,
            height: options.height,
        },
    });
}

function setDocumentExtent({
    width,
    height,
}: {
    width: number;
    height: number;
}) {
    Object.defineProperty(document.documentElement, "scrollWidth", {
        configurable: true,
        value: width,
    });
    Object.defineProperty(document.documentElement, "scrollHeight", {
        configurable: true,
        value: height,
    });
    Object.defineProperty(document.body, "scrollWidth", {
        configurable: true,
        value: width,
    });
    Object.defineProperty(document.body, "scrollHeight", {
        configurable: true,
        value: height,
    });
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

    it("reveals the selected row leading edge with a 12px margin", async () => {
        const module = await import("../UI/DOMTree/dom-tree-view-support");
        const { tree } = ensureDomFixture();
        const row = document.createElement("div");
        row.className = "tree-node__row";
        const element = document.createElement("div");
        element.appendChild(row);

        tree.appendChild(element);
        treeState.elements.set(10, element);
        treeState.selectedNodeId = 10;

        document.documentElement.scrollTop = 24;
        document.documentElement.scrollLeft = 80;
        setVisualViewport({ pageTop: 24, pageLeft: 80, width: 320, height: 640 });
        setDocumentExtent({ width: 1600, height: 2000 });
        row.getBoundingClientRect = () => ({
            top: 120,
            bottom: 160,
            left: -32,
            right: 208,
            width: 200,
            height: 40,
            x: -32,
            y: 120,
            toJSON: () => ({}),
        }) as DOMRect;

        const scrollTo = vi.fn(({ top, left }: { top?: number; left?: number }) => {
            if (typeof top === "number") {
                document.documentElement.scrollTop = top;
            }
            if (typeof left === "number") {
                document.documentElement.scrollLeft = left;
            }
        });
        window.scrollTo = scrollTo as unknown as typeof window.scrollTo;

        expect(module.scrollSelectionIntoView(10)).toBe(false);
        expect(scrollTo).toHaveBeenCalledTimes(1);
        expect(scrollTo).toHaveBeenLastCalledWith({ top: 24, left: 36, behavior: "auto" });
    });

    it("does not scroll horizontally when the selected row leading edge is already visible", async () => {
        const module = await import("../UI/DOMTree/dom-tree-view-support");
        const { tree } = ensureDomFixture();
        const row = document.createElement("div");
        row.className = "tree-node__row";
        const element = document.createElement("div");
        element.appendChild(row);

        tree.appendChild(element);
        treeState.elements.set(11, element);
        treeState.selectedNodeId = 11;

        document.documentElement.scrollTop = 24;
        document.documentElement.scrollLeft = 80;
        setVisualViewport({ pageTop: 24, pageLeft: 80, width: 320, height: 640 });
        row.getBoundingClientRect = () => ({
            top: 160,
            bottom: 200,
            left: 20,
            right: 720,
            width: 700,
            height: 40,
            x: 20,
            y: 160,
            toJSON: () => ({}),
        }) as DOMRect;

        const scrollTo = vi.fn();
        window.scrollTo = scrollTo as unknown as typeof window.scrollTo;

        expect(module.scrollSelectionIntoView(11)).toBe(true);
        expect(scrollTo).not.toHaveBeenCalled();
    });

    it("reveals rows hidden above the safe area inset", async () => {
        const module = await import("../UI/DOMTree/dom-tree-view-support");
        const { tree } = ensureDomFixture();
        const row = document.createElement("div");
        row.className = "tree-node__row";
        const element = document.createElement("div");
        element.appendChild(row);

        tree.appendChild(element);
        treeState.elements.set(12, element);
        treeState.selectedNodeId = 12;

        document.documentElement.style.setProperty("--wi-safe-area-top", "44px");
        document.documentElement.scrollTop = 100;
        document.documentElement.scrollLeft = 18;
        setVisualViewport({ pageTop: 100, pageLeft: 18, width: 320, height: 640 });
        setDocumentExtent({ width: 1200, height: 2400 });
        row.getBoundingClientRect = () => ({
            top: 20,
            bottom: 60,
            left: 24,
            right: 240,
            width: 216,
            height: 40,
            x: 24,
            y: 20,
            toJSON: () => ({}),
        }) as DOMRect;

        const scrollTo = vi.fn(({ top, left }: { top?: number; left?: number }) => {
            if (typeof top === "number") {
                document.documentElement.scrollTop = top;
            }
            if (typeof left === "number") {
                document.documentElement.scrollLeft = left;
            }
        });
        window.scrollTo = scrollTo as unknown as typeof window.scrollTo;

        expect(module.scrollSelectionIntoView(12)).toBe(false);
        expect(scrollTo).toHaveBeenLastCalledWith({ top: 68, left: 18, behavior: "auto" });
    });

    it("preserves horizontal scroll while revealing rows hidden below the safe area inset", async () => {
        const module = await import("../UI/DOMTree/dom-tree-view-support");
        const { tree } = ensureDomFixture();
        const row = document.createElement("div");
        row.className = "tree-node__row";
        const element = document.createElement("div");
        element.appendChild(row);

        tree.appendChild(element);
        treeState.elements.set(13, element);
        treeState.selectedNodeId = 13;

        document.documentElement.style.setProperty("--wi-safe-area-bottom", "34px");
        document.documentElement.scrollTop = 10;
        document.documentElement.scrollLeft = 55;
        setVisualViewport({ pageTop: 10, pageLeft: 55, width: 320, height: 640 });
        setDocumentExtent({ width: 1600, height: 2400 });
        row.getBoundingClientRect = () => ({
            top: 620,
            bottom: 660,
            left: 40,
            right: 240,
            width: 200,
            height: 40,
            x: 40,
            y: 620,
            toJSON: () => ({}),
        }) as DOMRect;

        const scrollTo = vi.fn(({ top, left }: { top?: number; left?: number }) => {
            if (typeof top === "number") {
                document.documentElement.scrollTop = top;
            }
            if (typeof left === "number") {
                document.documentElement.scrollLeft = left;
            }
        });
        window.scrollTo = scrollTo as unknown as typeof window.scrollTo;

        expect(module.scrollSelectionIntoView(13)).toBe(false);
        expect(scrollTo).toHaveBeenLastCalledWith({ top: 72, left: 55, behavior: "auto" });
        expect(document.documentElement.scrollLeft).toBe(55);
    });
});
