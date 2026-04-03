import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { cancelElementSelection, startElementSelection } from "../Runtime/DOMAgent/dom-agent-selection";
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

    it("returns a stable selected node id and ancestor chain", async () => {
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
        expect(result.selectedNodeId).toBeTypeOf("number");
        expect(result.selectedNodeId).toBeGreaterThan(0);
        expect(Array.isArray(result.ancestorNodeIds)).toBe(true);
        expect(result.ancestorNodeIds?.length).toBeGreaterThan(0);

        const selectedNode = inspector.map?.get(result.selectedNodeId ?? -1) as Element | undefined;
        expect(selectedNode?.id).toBe("target");

        const ancestorIDs = result.ancestorNodeIds ?? [];
        const ancestorNodes = ancestorIDs
            .map((nodeId) => inspector.map?.get(nodeId) as Element | undefined)
            .filter((node): node is Element => !!node);

        expect(ancestorNodes.some((node) => node.id === "root")).toBe(true);
        expect(ancestorNodes.at(-1)?.id).toBe("parent");
    });
});
