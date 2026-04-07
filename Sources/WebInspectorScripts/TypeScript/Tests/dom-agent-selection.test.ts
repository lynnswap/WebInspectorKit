import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { rememberNode } from "../Runtime/DOMAgent/dom-agent-dom-core";
import { cancelElementSelection, startElementSelection } from "../Runtime/DOMAgent/dom-agent-selection";
import { outerHTMLForNode, removeNode, selectorPathForNode } from "../Runtime/DOMAgent/dom-agent-dom-utils";
import { inspector } from "../Runtime/DOMAgent/dom-agent-state";

function resetInspectorSelectionState() {
    inspector.map = new Map();
    inspector.nodeMap = new WeakMap();
    inspector.nextId = 1;
    inspector.selectionState = null;
    inspector.pendingSelectionPath = null;
    inspector.cursorBackup = null;
    inspector.windowClickBlockerHandler = null;
    inspector.windowClickBlockerPendingRelease = false;
    inspector.windowClickBlockerRemovalTimer = null;
    inspector.snapshotAutoUpdateEnabled = false;
    inspector.snapshotAutoUpdatePending = false;
    inspector.snapshotAutoUpdateTimer = null;
    inspector.snapshotAutoUpdateFrame = null;
    inspector.snapshotAutoUpdateSuppressedCount = 0;
    inspector.snapshotAutoUpdatePendingWhileSuppressed = false;
    inspector.snapshotAutoUpdatePendingReason = null;
}

describe("dom-agent-selection", () => {
    beforeEach(() => {
        resetInspectorSelectionState();
        document.body.innerHTML = `
            <main id="root">
                <section id="parent">
                    <div id="target">Target</div>
                </section>
            </main>
        `;
        document.elementFromPoint = vi.fn(() => document.getElementById("target"));
    });

    afterEach(() => {
        cancelElementSelection();
        vi.restoreAllMocks();
    });

    it("returns a local selected node id and ancestor chains", async () => {
        const selectionPromise = startElementSelection();
        const shield = document.querySelector("[data-web-inspector-selection-shield]");
        expect(shield).not.toBeNull();

        const move = new MouseEvent("mousemove", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const down = new MouseEvent("mousedown", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const up = new MouseEvent("mouseup", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });

        shield?.dispatchEvent(move);
        shield?.dispatchEvent(down);
        shield?.dispatchEvent(up);

        const result = await selectionPromise;

        expect(result.cancelled).toBe(false);
        expect(result.selectedLocalId).toBeTypeOf("number");
        expect(result.selectedLocalId).toBeGreaterThan(0);
        expect(result.selectedBackendNodeId).toBeUndefined();
        expect(result.selectedBackendNodeIdIsStable).toBe(false);

        const ancestorIDs = result.ancestorLocalIds ?? [];
        expect(Array.isArray(ancestorIDs)).toBe(true);
        expect(ancestorIDs.length).toBeGreaterThan(0);

        const selectedNode = inspector.map?.get(result.selectedLocalId ?? -1) as Element | undefined;
        expect(selectedNode?.id).toBe("target");

        const ancestorNodes = ancestorIDs
            .map((nodeId) => inspector.map?.get(nodeId) as Element | undefined)
            .filter((node): node is Element => !!node);

        expect(ancestorNodes.some((node) => node.id === "root")).toBe(true);
        expect(ancestorNodes.at(-1)?.id).toBe("parent");
    });

    it("promotes inline hit targets to their block ancestor", async () => {
        document.body.innerHTML = `
            <main id="root">
                <article id="target">
                    <span>
                        <a id="target-label">Target</a>
                    </span>
                </article>
            </main>
        `;
        document.elementFromPoint = vi.fn(() => document.getElementById("target-label"));

        const selectionPromise = startElementSelection();
        const shield = document.querySelector("[data-web-inspector-selection-shield]");
        expect(shield).not.toBeNull();

        const move = new MouseEvent("mousemove", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const down = new MouseEvent("mousedown", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const up = new MouseEvent("mouseup", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });

        shield?.dispatchEvent(move);
        shield?.dispatchEvent(down);
        shield?.dispatchEvent(up);

        const result = await selectionPromise;
        const selectedNode = inspector.map?.get(result.selectedLocalId ?? -1) as Element | undefined;

        expect(result.cancelled).toBe(false);
        expect(selectedNode?.id).toBe("target");
    });

    it("promotes text-only inline spans to their block ancestor", async () => {
        document.body.innerHTML = `
            <main id="root">
                <article id="target">
                    <span id="target-label">Target</span>
                </article>
            </main>
        `;
        document.elementFromPoint = vi.fn(() => document.getElementById("target-label"));

        const selectionPromise = startElementSelection();
        const shield = document.querySelector("[data-web-inspector-selection-shield]");
        expect(shield).not.toBeNull();

        const move = new MouseEvent("mousemove", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const down = new MouseEvent("mousedown", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const up = new MouseEvent("mouseup", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });

        shield?.dispatchEvent(move);
        shield?.dispatchEvent(down);
        shield?.dispatchEvent(up);

        const result = await selectionPromise;
        const selectedNode = inspector.map?.get(result.selectedLocalId ?? -1) as Element | undefined;

        expect(result.cancelled).toBe(false);
        expect(selectedNode?.id).toBe("target");
    });

    it("promotes inline hit targets to their block ancestor for touch events", async () => {
        document.body.innerHTML = `
            <main id="root">
                <article id="target">
                    <span>
                        <a id="target-label">Target</a>
                    </span>
                </article>
            </main>
        `;
        document.elementFromPoint = vi.fn(() => document.getElementById("target-label"));

        const selectionPromise = startElementSelection();
        const shield = document.querySelector("[data-web-inspector-selection-shield]");
        expect(shield).not.toBeNull();

        const touchPoint = { clientX: 10, clientY: 10 };
        const touchStart = new Event("touchstart", { bubbles: true, cancelable: true });
        Object.defineProperty(touchStart, "touches", { configurable: true, value: [touchPoint] });
        Object.defineProperty(touchStart, "target", { configurable: true, value: shield });

        const touchEnd = new Event("touchend", { bubbles: true, cancelable: true });
        Object.defineProperty(touchEnd, "changedTouches", { configurable: true, value: [touchPoint] });
        Object.defineProperty(touchEnd, "target", { configurable: true, value: shield });

        shield?.dispatchEvent(touchStart);
        shield?.dispatchEvent(touchEnd);

        const result = await selectionPromise;
        const selectedNode = inspector.map?.get(result.selectedLocalId ?? -1) as Element | undefined;

        expect(result.cancelled).toBe(false);
        expect(selectedNode?.id).toBe("target");
    });

    it("keeps top-level inline targets when no block ancestor exists", async () => {
        document.body.innerHTML = `<a id="target">Target</a>`;
        document.elementFromPoint = vi.fn(() => document.getElementById("target"));

        const selectionPromise = startElementSelection();
        const shield = document.querySelector("[data-web-inspector-selection-shield]");
        expect(shield).not.toBeNull();

        const move = new MouseEvent("mousemove", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const down = new MouseEvent("mousedown", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const up = new MouseEvent("mouseup", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });

        shield?.dispatchEvent(move);
        shield?.dispatchEvent(down);
        shield?.dispatchEvent(up);

        const result = await selectionPromise;
        const selectedNode = inspector.map?.get(result.selectedLocalId ?? -1) as Element | undefined;

        expect(result.cancelled).toBe(false);
        expect(selectedNode?.id).toBe("target");
    });

    it("keeps standalone images selectable", async () => {
        document.body.innerHTML = `
            <main id="root">
                <article id="parent">
                    <img id="target" alt="Target">
                </article>
            </main>
        `;
        document.elementFromPoint = vi.fn(() => document.getElementById("target"));

        const selectionPromise = startElementSelection();
        const shield = document.querySelector("[data-web-inspector-selection-shield]");
        expect(shield).not.toBeNull();

        const move = new MouseEvent("mousemove", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const down = new MouseEvent("mousedown", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const up = new MouseEvent("mouseup", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });

        shield?.dispatchEvent(move);
        shield?.dispatchEvent(down);
        shield?.dispatchEvent(up);

        const result = await selectionPromise;
        const selectedNode = inspector.map?.get(result.selectedLocalId ?? -1) as Element | undefined;

        expect(result.cancelled).toBe(false);
        expect(selectedNode?.id).toBe("target");
    });

    it("does not promote block-styled spans to an ancestor", async () => {
        document.body.innerHTML = `
            <main id="root">
                <article id="parent">
                    <span id="target" style="display:block"><a>Target</a></span>
                </article>
            </main>
        `;
        document.elementFromPoint = vi.fn(() => document.getElementById("target"));

        const selectionPromise = startElementSelection();
        const shield = document.querySelector("[data-web-inspector-selection-shield]");
        expect(shield).not.toBeNull();

        const move = new MouseEvent("mousemove", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const down = new MouseEvent("mousedown", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const up = new MouseEvent("mouseup", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });

        shield?.dispatchEvent(move);
        shield?.dispatchEvent(down);
        shield?.dispatchEvent(up);

        const result = await selectionPromise;
        const selectedNode = inspector.map?.get(result.selectedLocalId ?? -1) as Element | undefined;

        expect(result.cancelled).toBe(false);
        expect(selectedNode?.id).toBe("target");
    });

    it("does not promote mixed-content spans to their block ancestor", async () => {
        document.body.innerHTML = `
            <main id="root">
                <article id="parent">
                    <span id="target">prefix <a id="target-label">Target</a> suffix</span>
                </article>
            </main>
        `;
        document.elementFromPoint = vi.fn(() => document.getElementById("target-label"));

        const selectionPromise = startElementSelection();
        const shield = document.querySelector("[data-web-inspector-selection-shield]");
        expect(shield).not.toBeNull();

        const move = new MouseEvent("mousemove", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const down = new MouseEvent("mousedown", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
        const up = new MouseEvent("mouseup", { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });

        shield?.dispatchEvent(move);
        shield?.dispatchEvent(down);
        shield?.dispatchEvent(up);

        const result = await selectionPromise;
        const selectedNode = inspector.map?.get(result.selectedLocalId ?? -1) as Element | undefined;

        expect(result.cancelled).toBe(false);
        expect(selectedNode?.id).toBe("target");
    });

    it("resolves typed backend targets for selector and copy helpers", () => {
        const webkit = window.webkit as unknown as {
            serializeNode?: (node: Node) => unknown;
        };
        webkit.serializeNode = vi.fn((node: Node) => {
            const element = node as Element;
            if (element.id === "target") {
                return { nodeId: 42 };
            }
            return null;
        });

        expect(selectorPathForNode({ kind: "backend", value: 42 })).toBe("#target");
        expect(outerHTMLForNode({ kind: "backend", value: 42 })).toContain("id=\"target\"");
    });

    it("resolves typed backend targets for remove helpers", () => {
        const webkit = window.webkit as unknown as {
            serializeNode?: (node: Node) => unknown;
        };
        webkit.serializeNode = vi.fn((node: Node) => {
            const element = node as Element;
            if (element.id === "target") {
                return { nodeId: 42 };
            }
            return null;
        });

        const result = removeNode({ kind: "backend", value: 42 });

        expect(result.status).toBe("applied");
        expect(document.getElementById("target")).toBeNull();
    });

    it("clears remembered handles after a successful remove", () => {
        const target = document.getElementById("target");
        expect(target).not.toBeNull();

        const localID = rememberNode(target);
        expect(localID).toBeGreaterThan(0);
        expect(selectorPathForNode(localID)).toBe("#target");

        const result = removeNode(localID);

        expect(result.status).toBe("applied");
        expect(selectorPathForNode(localID)).toBe("");
    });

    it("does not reinterpret stale numeric local handles as backend identifiers", () => {
        const staleNode = document.getElementById("parent");
        expect(staleNode).not.toBeNull();

        inspector.nextId = 42;
        const staleLocalID = rememberNode(staleNode);
        expect(staleLocalID).toBe(42);

        inspector.map = new Map();
        inspector.nodeMap = new WeakMap();

        const webkit = window.webkit as unknown as {
            serializeNode?: (node: Node) => unknown;
        };
        webkit.serializeNode = vi.fn((node: Node) => {
            const element = node as Element;
            if (element.id === "target") {
                return { nodeId: 42 };
            }
            return null;
        });

        expect(selectorPathForNode(staleLocalID)).toBe("");

        const result = removeNode(staleLocalID);

        expect(result.status).toBe("failed");
        expect(document.getElementById("target")).not.toBeNull();
    });
});
