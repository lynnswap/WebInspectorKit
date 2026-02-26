import { beforeEach, describe, expect, it, vi } from "vitest";

import {
    disableAutoSnapshot,
    enableAutoSnapshot,
    setAutoSnapshotOptions,
    triggerSnapshotUpdate
} from "../../Sources/WebInspectorScripts/TypeScript/Runtime/DOMAgent/dom-agent-snapshot";
import { inspector } from "../../Sources/WebInspectorScripts/TypeScript/Runtime/DOMAgent/dom-agent-state";

type WebKitMockHandler = {
    postMessage: ReturnType<typeof vi.fn>;
};

function snapshotHandler(): WebKitMockHandler {
    return window.webkit?.messageHandlers?.webInspectorDOMSnapshot as WebKitMockHandler;
}

function mutationHandler(): WebKitMockHandler {
    return window.webkit?.messageHandlers?.webInspectorDOMMutations as WebKitMockHandler;
}

function parseBundleCall(
    handler: WebKitMockHandler
): Record<string, any> {
    const call = handler.postMessage.mock.calls.at(-1)?.[0] as { bundle?: unknown } | undefined;
    const rawBundle = call?.bundle;
    if (!rawBundle) {
        return {};
    }
    if (typeof rawBundle === "string") {
        return JSON.parse(rawBundle);
    }
    return rawBundle as Record<string, any>;
}

function resetInspectorState() {
    inspector.map = new Map();
    inspector.nodeMap = new WeakMap();
    inspector.nextId = 1;
    inspector.pendingMutations = [];
    inspector.snapshotAutoUpdateObserver = null;
    inspector.snapshotAutoUpdateEnabled = true;
    inspector.snapshotAutoUpdatePending = false;
    inspector.snapshotAutoUpdateTimer = null;
    inspector.snapshotAutoUpdateFrame = null;
    inspector.snapshotAutoUpdateDebounce = 600;
    inspector.snapshotAutoUpdateMaxDepth = 4;
    inspector.snapshotAutoUpdateReason = "mutation";
    inspector.snapshotAutoUpdateOverflow = false;
    inspector.snapshotAutoUpdateSuppressedCount = 0;
    inspector.snapshotAutoUpdatePendingWhileSuppressed = false;
    inspector.snapshotAutoUpdatePendingReason = null;
    inspector.documentURL = null;
}

describe("dom-agent-snapshot", () => {
    beforeEach(() => {
        resetInspectorState();
        document.body.innerHTML = "<main id=\"app\"></main>";
        snapshotHandler().postMessage.mockClear();
        mutationHandler().postMessage.mockClear();
    });

    it("debounce is clamped to the 50ms minimum", () => {
        const node = document.createElement("div");
        node.setAttribute("class", "ready");
        document.body.appendChild(node);

        inspector.map = new Map([[1, document.documentElement]]);
        inspector.snapshotAutoUpdateDebounce = 10;
        inspector.pendingMutations = [{
            type: "attributes",
            target: node,
            attributeName: "class",
            addedNodes: [] as unknown as NodeList,
            removedNodes: [] as unknown as NodeList,
            previousSibling: null
        } as unknown as MutationRecord];
        setAutoSnapshotOptions({ debounce: 10 });

        triggerSnapshotUpdate("mutation");

        vi.advanceTimersByTime(49);
        expect(mutationHandler().postMessage).not.toHaveBeenCalled();

        vi.advanceTimersByTime(1);
        expect(mutationHandler().postMessage).not.toHaveBeenCalled();

        vi.advanceTimersByTime(16);
        expect(mutationHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(parseBundleCall(mutationHandler()).reason).toBe("mutation");
    });

    it("uses compact-depth full snapshot when overflow is detected", () => {
        inspector.map = new Map([[1, document.documentElement]]);
        inspector.snapshotAutoUpdateOverflow = true;
        inspector.snapshotAutoUpdateMaxDepth = 8;
        setAutoSnapshotOptions({ debounce: 50 });

        triggerSnapshotUpdate("mutation");
        vi.advanceTimersByTime(66);

        expect(snapshotHandler().postMessage).toHaveBeenCalledTimes(1);
        const payload = parseBundleCall(snapshotHandler());
        expect(payload.kind).toBe("snapshot");
        expect(payload.reason).toBe("overflow");
        expect(payload.depth).toBe(2);
    });

    it("emits mutation bundles instead of full snapshot when events are available", () => {
        const node = document.createElement("div");
        node.setAttribute("class", "ready");
        document.body.appendChild(node);

        inspector.map = new Map([[1, node]]);
        inspector.pendingMutations = [{
            type: "attributes",
            target: node,
            attributeName: "class",
            addedNodes: [] as unknown as NodeList,
            removedNodes: [] as unknown as NodeList,
            previousSibling: null
        } as unknown as MutationRecord];
        inspector.snapshotAutoUpdateDebounce = 50;

        triggerSnapshotUpdate("mutation");
        vi.advanceTimersByTime(66);

        expect(mutationHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(snapshotHandler().postMessage).not.toHaveBeenCalled();
        const payload = parseBundleCall(mutationHandler());
        expect(payload.kind).toBe("mutation");
        expect(Array.isArray(payload.events)).toBe(true);
        expect(payload.events.length).toBeGreaterThan(0);
    });

    it("falls back to compact snapshot when mutation event volume is too large", () => {
        const parent = document.createElement("section");
        document.body.appendChild(parent);

        for (let index = 0; index < 650; index += 1) {
            const child = document.createElement("span");
            child.textContent = `item-${index}`;
            parent.appendChild(child);
        }

        inspector.map = new Map([[1, parent]]);
        inspector.pendingMutations = [{
            type: "childList",
            target: parent,
            addedNodes: parent.childNodes,
            removedNodes: [] as unknown as NodeList,
            previousSibling: null
        } as unknown as MutationRecord];
        inspector.snapshotAutoUpdateDebounce = 50;

        triggerSnapshotUpdate("mutation");
        vi.advanceTimersByTime(66);

        expect(snapshotHandler().postMessage).toHaveBeenCalledTimes(1);
        const payload = parseBundleCall(snapshotHandler());
        expect(payload.kind).toBe("snapshot");
        expect(payload.reason).toBe("compact");
        expect(payload.depth).toBe(2);
    });

    it("does not emit snapshot or mutation payload when no pending mutations exist", () => {
        inspector.map = new Map([[1, document.documentElement]]);
        inspector.snapshotAutoUpdateDebounce = 50;

        triggerSnapshotUpdate("mutation");
        vi.advanceTimersByTime(66);

        expect(snapshotHandler().postMessage).not.toHaveBeenCalled();
        expect(mutationHandler().postMessage).not.toHaveBeenCalled();
    });

    it("emits initial full snapshot when auto updates are re-enabled with no pending mutations", () => {
        inspector.map = new Map([[1, document.documentElement]]);
        inspector.snapshotAutoUpdateDebounce = 50;
        inspector.pendingMutations = [];

        disableAutoSnapshot();
        enableAutoSnapshot();
        vi.advanceTimersByTime(66);

        expect(snapshotHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(mutationHandler().postMessage).not.toHaveBeenCalled();
        const payload = parseBundleCall(snapshotHandler());
        expect(payload.kind).toBe("snapshot");
        expect(payload.reason).toBe("initial");
    });
});
