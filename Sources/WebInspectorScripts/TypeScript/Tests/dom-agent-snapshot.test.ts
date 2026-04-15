import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
    disableAutoSnapshot,
    enableAutoSnapshot,
    setAutoSnapshotOptions,
    triggerSnapshotUpdate
} from "../Runtime/DOMAgent/dom-agent-snapshot";
import {
    captureDOMPayload,
    computeNodePath,
    INSPECTOR_INTERNAL_OVERLAY_ATTRIBUTE,
    INSPECTOR_INTERNAL_SELECTION_SHIELD_ATTRIBUTE,
    rememberNode
} from "../Runtime/DOMAgent/dom-agent-dom-core";
import { inspector } from "../Runtime/DOMAgent/dom-agent-state";

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
    inspector.nextInitialSnapshotMode = null;
    inspector.documentURL = null;
    inspector.pendingSelectionRestoreTarget = null;
}

describe("dom-agent-snapshot", () => {
    beforeEach(() => {
        resetInspectorState();
        document.body.innerHTML = "<main id=\"app\"></main>";
        snapshotHandler().postMessage.mockClear();
        mutationHandler().postMessage.mockClear();
    });

    afterEach(() => {
        disableAutoSnapshot();
        if (inspector.snapshotAutoUpdateTimer) {
            clearTimeout(inspector.snapshotAutoUpdateTimer);
            inspector.snapshotAutoUpdateTimer = null;
        }
        if (inspector.snapshotAutoUpdateFrame !== null) {
            cancelAnimationFrame(inspector.snapshotAutoUpdateFrame);
            inspector.snapshotAutoUpdateFrame = null;
        }
        inspector.snapshotAutoUpdatePending = false;
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

    it("ignores inspector internal child-list mutations", () => {
        const overlay = document.createElement("div");
        overlay.setAttribute(INSPECTOR_INTERNAL_OVERLAY_ATTRIBUTE, "true");
        document.documentElement.appendChild(overlay);

        inspector.map = new Map([[1, document.documentElement]]);
        inspector.snapshotAutoUpdateDebounce = 50;
        inspector.pendingMutations = [{
            type: "childList",
            target: document.documentElement,
            addedNodes: [overlay] as unknown as NodeList,
            removedNodes: [] as unknown as NodeList,
            previousSibling: document.body
        } as unknown as MutationRecord];

        triggerSnapshotUpdate("mutation");
        vi.advanceTimersByTime(66);

        expect(snapshotHandler().postMessage).not.toHaveBeenCalled();
        expect(mutationHandler().postMessage).not.toHaveBeenCalled();
    });

    it("omits inspector internal nodes from computed selection paths and snapshots", () => {
        const shield = document.createElement("div");
        shield.setAttribute(INSPECTOR_INTERNAL_SELECTION_SHIELD_ATTRIBUTE, "true");
        const target = document.createElement("div");
        target.id = "target";
        document.body.replaceChildren(shield, target);

        const path = computeNodePath(target);
        const payload = captureDOMPayload(4);
        const bodyDescriptor = payload.root?.children?.find((child) => child.localName === "body") ?? null;

        expect(path).toEqual([1, 0]);
        expect(bodyDescriptor?.children).toHaveLength(1);
        expect(bodyDescriptor?.children?.[0]?.attributes).toEqual(["id", "target"]);
    });

    it("manual snapshot capture clears the pending initial snapshot mode", () => {
        inspector.nextInitialSnapshotMode = "fresh";

        const payload = captureDOMPayload(4);

        expect(payload.root).not.toBeNull();
        expect(inspector.nextInitialSnapshotMode).toBeNull();
    });

    it("does not promote fragment-only URL changes to a fresh manual snapshot reset", () => {
        const currentURL = document.URL || "about:blank";
        inspector.documentURL = `${currentURL}#before`;
        window.location.hash = "#after";

        const payload = captureDOMPayload(4, { consumeInitialSnapshotMode: false });

        expect(payload.root).not.toBeNull();
        expect(inspector.nextInitialSnapshotMode).toBeNull();
    });

    it("captures stable node ids separately from local handle ids", () => {
        document.body.innerHTML = "<main id=\"root\"><section id=\"target-parent\"><div id=\"target\"></div></section></main>";
        const target = document.getElementById("target");
        expect(target).not.toBeNull();
        inspector.pendingSelectionRestoreTarget = {
            path: computeNodePath(target),
            localId: rememberNode(target),
            backendNodeId: null,
        };

        const webkit = window.webkit as unknown as {
            serializeNode?: (node: Node) => unknown;
        };
        webkit.serializeNode = vi.fn((node: Node) => {
            const element = node as Element;
            switch (element.id || element.localName || element.nodeName.toLowerCase()) {
            case "html":
                return { nodeId: 100, children: [] };
            case "body":
                return { nodeId: 101, children: [] };
            case "root":
                return { nodeId: 102, children: [] };
            case "target-parent":
                return { nodeId: 103, children: [] };
            case "target":
                return { nodeId: 104, children: [] };
            default:
                return null;
            }
        });

        const payload = captureDOMPayload(5);
        const bodyDescriptor = payload.root?.children?.find((child) => child.localName === "body") ?? null;
        const mainDescriptor = bodyDescriptor?.children?.find((child) =>
            Array.isArray(child.attributes) && child.attributes[1] === "root"
        ) ?? null;

        expect(payload.selectedNodeId).toBe(104);
        expect(payload.selectedLocalId).toBeTypeOf("number");
        expect(payload.selectedLocalId).not.toBe(payload.selectedNodeId);
        expect(mainDescriptor?.backendNodeId).toBe(102);
        expect(mainDescriptor?.localId).toBeTypeOf("number");
        expect(mainDescriptor?.localId).not.toBe(mainDescriptor?.backendNodeId);
    });

    it("recomputes the pending selection path from the live node before capture", () => {
        document.body.innerHTML = "<main id=\"root\"><section id=\"parent\"><div id=\"target\"></div></section></main>";
        const target = document.getElementById("target");
        const parent = document.getElementById("parent");
        expect(target).not.toBeNull();
        expect(parent).not.toBeNull();

        const webkit = window.webkit as unknown as {
            serializeNode?: (node: Node) => unknown;
        };
        webkit.serializeNode = vi.fn((node: Node) => {
            const element = node as Element;
            switch (element.id || element.localName || element.nodeName.toLowerCase()) {
            case "html":
                return { nodeId: 100, children: [] };
            case "body":
                return { nodeId: 101, children: [] };
            case "root":
                return { nodeId: 102, children: [] };
            case "parent":
                return { nodeId: 103, children: [] };
            case "before":
                return { nodeId: 109, children: [] };
            case "target":
                return { nodeId: 104, children: [] };
            default:
                return null;
            }
        });

        inspector.pendingSelectionRestoreTarget = {
            path: computeNodePath(target),
            localId: rememberNode(target),
            backendNodeId: 104,
        };

        const inserted = document.createElement("div");
        inserted.id = "before";
        parent?.insertBefore(inserted, target);
        const expectedPath = computeNodePath(target);

        const payload = captureDOMPayload(5);

        expect(payload.selectedNodeId).toBe(104);
        expect(payload.selectedLocalId).toBeTypeOf("number");
        expect(payload.selectedNodePath).toEqual(expectedPath);
    });

    it("recomputes the pending selection path from a remembered local id before a fresh snapshot reset", () => {
        document.body.innerHTML = "<main id=\"root\"><section id=\"parent\"><div id=\"target\"></div></section></main>";
        const target = document.getElementById("target");
        const parent = document.getElementById("parent");
        expect(target).not.toBeNull();
        expect(parent).not.toBeNull();

        const targetLocalId = rememberNode(target);
        inspector.pendingSelectionRestoreTarget = {
            path: computeNodePath(target),
            localId: targetLocalId,
            backendNodeId: null,
        };
        inspector.nextInitialSnapshotMode = "fresh";

        const inserted = document.createElement("div");
        inserted.id = "before";
        parent?.insertBefore(inserted, target);
        const expectedPath = computeNodePath(target);

        const payload = captureDOMPayload(5, { consumeInitialSnapshotMode: false });

        expect(payload.selectedLocalId).toBeTypeOf("number");
        expect(payload.selectedNodePath).toEqual(expectedPath);
    });

    it("falls back to the stable backend id when a remembered local handle is stale after a fresh reset", () => {
        document.body.innerHTML = "<main id=\"root\"><section id=\"parent\"><div id=\"target\"></div></section></main>";
        const originalTarget = document.getElementById("target");
        expect(originalTarget).not.toBeNull();

        const webkit = window.webkit as unknown as {
            serializeNode?: (node: Node) => unknown;
        };
        webkit.serializeNode = vi.fn((node: Node) => {
            const element = node as Element;
            switch (element.id || element.localName || element.nodeName.toLowerCase()) {
            case "html":
                return { nodeId: 100, children: [] };
            case "body":
                return { nodeId: 101, children: [] };
            case "root":
                return { nodeId: 102, children: [] };
            case "parent":
                return { nodeId: 103, children: [] };
            case "before":
                return { nodeId: 109, children: [] };
            case "target":
                return { nodeId: 104, children: [] };
            default:
                return null;
            }
        });

        const staleLocalId = rememberNode(originalTarget);
        inspector.pendingSelectionRestoreTarget = {
            path: [0, 0],
            localId: staleLocalId,
            backendNodeId: 104,
        };
        inspector.nextInitialSnapshotMode = "fresh";

        document.body.innerHTML = "<main id=\"root\"><section id=\"parent\"><div id=\"before\"></div><div id=\"target\"></div></section></main>";
        const expectedTarget = document.getElementById("target");
        const expectedPath = computeNodePath(expectedTarget);

        const payload = captureDOMPayload(5, { consumeInitialSnapshotMode: false });

        expect(payload.selectedNodeId).toBe(104);
        expect(payload.selectedNodePath).toEqual(expectedPath);
    });

    it("preserves an empty pending selection path for root selection recovery", () => {
        inspector.pendingSelectionRestoreTarget = {
            path: [],
            localId: null,
            backendNodeId: null,
        };

        const payload = captureDOMPayload(4, { consumeInitialSnapshotMode: false });

        expect(payload.selectedNodePath).toEqual([]);
        expect(payload.selectedLocalId).toBeTypeOf("number");
    });

    it("clears the pending initial snapshot mode even when snapshot posting throws", () => {
        inspector.map = new Map([[1, document.documentElement]]);
        inspector.snapshotAutoUpdateDebounce = 50;
        inspector.nextInitialSnapshotMode = "fresh";
        snapshotHandler().postMessage.mockImplementationOnce(() => {
            throw new Error("bridge failure");
        });

        triggerSnapshotUpdate("mutation");
        vi.advanceTimersByTime(66);

        expect(snapshotHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(inspector.nextInitialSnapshotMode).toBeNull();
    });

    it("promotes document URL changes to a fresh initial snapshot without losing the mode", () => {
        const originalURLDescriptor = Object.getOwnPropertyDescriptor(document, "URL");
        inspector.snapshotAutoUpdateDebounce = 50;
        inspector.documentURL = "https://example.com/page-one";

        Object.defineProperty(document, "URL", {
            configurable: true,
            value: "https://example.com/page-two"
        });

        try {
            triggerSnapshotUpdate("mutation");
            vi.advanceTimersByTime(66);

            expect(snapshotHandler().postMessage).toHaveBeenCalledTimes(1);
            const payload = parseBundleCall(snapshotHandler());
            expect(payload.kind).toBe("snapshot");
            expect(payload.reason).toBe("initial");
            expect(payload.snapshotMode).toBe("fresh");
            expect(inspector.nextInitialSnapshotMode).toBeNull();
        } finally {
            if (originalURLDescriptor) {
                Object.defineProperty(document, "URL", originalURLDescriptor);
            }
        }
    });

    it("drops pending selection restore targets when the document URL changes", () => {
        const originalURLDescriptor = Object.getOwnPropertyDescriptor(document, "URL");
        inspector.documentURL = "https://example.com/page-one";
        inspector.pendingSelectionRestoreTarget = {
            path: [0, 0, 0],
            localId: 99,
            backendNodeId: 199,
        };

        Object.defineProperty(document, "URL", {
            configurable: true,
            value: "https://example.com/page-two"
        });

        try {
            const payload = captureDOMPayload(4, { consumeInitialSnapshotMode: false });

            expect(payload.selectedNodeId).toBeNull();
            expect(payload.selectedLocalId).toBeNull();
            expect(payload.selectedNodePath).toBeNull();
            expect(inspector.pendingSelectionRestoreTarget).toBeNull();
        } finally {
            if (originalURLDescriptor) {
                Object.defineProperty(document, "URL", originalURLDescriptor);
            }
        }
    });

    it("resets remembered node handles for same-url fresh snapshots", () => {
        document.body.innerHTML = "<main id=\"before\"></main>";
        const staleNode = document.getElementById("before");
        expect(staleNode).not.toBeNull();
        expect(rememberNode(staleNode)).toBe(1);

        inspector.documentURL = document.URL || "about:blank";
        inspector.nextInitialSnapshotMode = "fresh";

        document.body.innerHTML = "<main id=\"after\"></main>";

        const payload = captureDOMPayload(4, { consumeInitialSnapshotMode: false });

        expect(payload.root?.localId).toBe(1);
        expect((inspector.map?.get(1) as Element | undefined)?.id).not.toBe("before");
        expect((inspector.map?.get(1) as Element | undefined)?.localName).toBe("html");
    });

    it("drops queued mutations after an initial full snapshot reset", () => {
        const node = document.createElement("div");
        node.setAttribute("class", "ready");
        document.body.appendChild(node);

        inspector.map = new Map([[1, document.documentElement]]);
        inspector.snapshotAutoUpdateDebounce = 50;
        inspector.nextInitialSnapshotMode = "fresh";
        inspector.pendingMutations = [{
            type: "attributes",
            target: node,
            attributeName: "class",
            addedNodes: [] as unknown as NodeList,
            removedNodes: [] as unknown as NodeList,
            previousSibling: null
        } as unknown as MutationRecord];

        triggerSnapshotUpdate("mutation");
        vi.advanceTimersByTime(66);

        expect(snapshotHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(mutationHandler().postMessage).not.toHaveBeenCalled();
        expect(parseBundleCall(snapshotHandler()).reason).toBe("initial");
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
        expect(payload.snapshotMode).toBe("preserve-ui-state");
    });

    it("does not downgrade a pending fresh snapshot when auto updates are enabled", () => {
        inspector.map = new Map([[1, document.documentElement]]);
        inspector.snapshotAutoUpdateDebounce = 50;
        inspector.pendingMutations = [];
        disableAutoSnapshot();
        inspector.nextInitialSnapshotMode = "fresh";

        enableAutoSnapshot();
        vi.advanceTimersByTime(66);

        expect(snapshotHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(parseBundleCall(snapshotHandler()).snapshotMode).toBe("fresh");
    });

    it("emits an initial full snapshot before queued mutations after auto snapshot resumes", () => {
        const node = document.createElement("div");
        node.setAttribute("class", "ready");
        document.body.appendChild(node);

        inspector.map = new Map([[1, node]]);
        inspector.snapshotAutoUpdateDebounce = 50;
        disableAutoSnapshot();
        enableAutoSnapshot();
        inspector.pendingMutations = [{
            type: "attributes",
            target: node,
            attributeName: "class",
            addedNodes: [] as unknown as NodeList,
            removedNodes: [] as unknown as NodeList,
            previousSibling: null
        } as unknown as MutationRecord];

        vi.advanceTimersByTime(82);

        expect(snapshotHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(mutationHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(snapshotHandler().postMessage.mock.invocationCallOrder[0]).toBeLessThan(
            mutationHandler().postMessage.mock.invocationCallOrder[0]
        );
        expect(parseBundleCall(snapshotHandler()).reason).toBe("initial");
        expect(parseBundleCall(snapshotHandler()).snapshotMode).toBe("preserve-ui-state");
        expect(parseBundleCall(mutationHandler()).kind).toBe("mutation");
    });
});

describe("dom-agent bootstrap", () => {
    beforeEach(() => {
        vi.resetModules();
        vi.useFakeTimers();
        document.body.innerHTML = "<main id=\"app\"></main>";
        delete (window as Window & { __wiDOMAgentBootstrap?: unknown }).__wiDOMAgentBootstrap;
        window.webkit = {
            messageHandlers: {
                webInspectorDOMSnapshot: { postMessage: vi.fn() },
                webInspectorDOMMutations: { postMessage: vi.fn() },
            }
        } as never;
    });

    afterEach(() => {
        const api = window.webInspectorDOM as { detach?: () => void } | undefined;
        api?.detach?.();
        vi.clearAllTimers();
        vi.useRealTimers();
        delete (window as Window & { __wiDOMAgentBootstrap?: unknown }).__wiDOMAgentBootstrap;
    });

    it("hydrates page context from bootstrap state and applies later bootstrap contexts exactly", async () => {
        (window as Window & { __wiDOMAgentBootstrap?: unknown }).__wiDOMAgentBootstrap = {
            pageEpoch: 4,
            documentScopeID: 7,
            autoSnapshot: {
                enabled: true,
                maxDepth: 9,
                debounce: 80
            }
        };

        await import("../Runtime/dom-agent");
        const { inspector: importedInspector } = await import("../Runtime/DOMAgent/dom-agent-state");
        const debugStatus = (window.webInspectorDOM as {
            debugStatus?: () => Record<string, unknown>;
        } | undefined)?.debugStatus?.() ?? {};

        expect(importedInspector.pageEpoch).toBe(4);
        expect(importedInspector.documentScopeID).toBe(7);
        expect(debugStatus.pageEpoch).toBe(4);
        expect(debugStatus.documentScopeID).toBe(7);
        expect(debugStatus.snapshotAutoUpdateEnabled).toBe(true);
        expect(debugStatus.snapshotAutoUpdateMaxDepth).toBe(9);
        expect(debugStatus.snapshotAutoUpdateDebounce).toBe(80);

        const api = window.webInspectorDOM as {
            bootstrap?: (bootstrap?: unknown) => boolean;
            debugStatus?: () => Record<string, unknown>;
        } | undefined;

        expect(api?.bootstrap?.({
            pageEpoch: 6,
            documentScopeID: 8,
            autoSnapshot: {
                enabled: true,
                maxDepth: 6,
                debounce: 70
            }
        })).toBe(true);
        expect(api?.bootstrap?.({
            pageEpoch: 5,
            documentScopeID: 7,
            autoSnapshot: {
                enabled: true,
                maxDepth: 4,
                debounce: 50
            }
        })).toBe(true);

        const finalDebugStatus = api?.debugStatus?.() ?? {};
        expect(finalDebugStatus.pageEpoch).toBe(5);
        expect(finalDebugStatus.documentScopeID).toBe(7);
        expect(finalDebugStatus.snapshotAutoUpdateEnabled).toBe(true);
        expect(finalDebugStatus.snapshotAutoUpdateMaxDepth).toBe(4);
        expect(finalDebugStatus.snapshotAutoUpdateDebounce).toBe(50);
    });

    it("pageshow does not force a fresh snapshot for the current context", async () => {
        await import("../Runtime/dom-agent");
        const stateModule = await import("../Runtime/DOMAgent/dom-agent-state");
        const api = window.webInspectorDOM as {
            debugStatus?: () => Record<string, unknown>;
        } | undefined;

        stateModule.inspector.nextInitialSnapshotMode = "preserve-ui-state";
        const initialMode = api?.debugStatus?.()?.nextInitialSnapshotMode;
        const regularPageShow = new Event("pageshow");
        Object.defineProperty(regularPageShow, "persisted", { value: false });
        window.dispatchEvent(regularPageShow);

        let debugStatus = api?.debugStatus?.() ?? {};
        expect(debugStatus.nextInitialSnapshotMode).toBe(initialMode);

        stateModule.inspector.nextInitialSnapshotMode = "preserve-ui-state";
        const restoredPageShow = new Event("pageshow");
        Object.defineProperty(restoredPageShow, "persisted", { value: true });
        window.dispatchEvent(restoredPageShow);

        debugStatus = api?.debugStatus?.() ?? {};
        expect(debugStatus.nextInitialSnapshotMode).toBe(initialMode);
    });

    it("pageshow promotes document URL changes to a fresh snapshot reset", async () => {
        await import("../Runtime/dom-agent");
        const stateModule = await import("../Runtime/DOMAgent/dom-agent-state");
        const originalURLDescriptor = Object.getOwnPropertyDescriptor(document, "URL");

        stateModule.inspector.snapshotAutoUpdateEnabled = true;
        stateModule.inspector.snapshotAutoUpdateDebounce = 50;
        stateModule.inspector.documentURL = "https://example.com/page-one";
        stateModule.inspector.map = new Map([[1, document.documentElement]]);

        Object.defineProperty(document, "URL", {
            configurable: true,
            value: "https://example.com/page-two"
        });

        try {
            const pageShow = new Event("pageshow");
            Object.defineProperty(pageShow, "persisted", { value: false });
            window.dispatchEvent(pageShow);

            expect(stateModule.inspector.nextInitialSnapshotMode).toBe("fresh");
        } finally {
            if (originalURLDescriptor) {
                Object.defineProperty(document, "URL", originalURLDescriptor);
            }
        }
    });

    it("pageshow ignores fragment-only URL changes for fresh snapshot promotion", async () => {
        await import("../Runtime/dom-agent");
        const stateModule = await import("../Runtime/DOMAgent/dom-agent-state");
        const originalURLDescriptor = Object.getOwnPropertyDescriptor(document, "URL");

        stateModule.inspector.snapshotAutoUpdateEnabled = true;
        stateModule.inspector.documentURL = "https://example.com/page#before";
        stateModule.inspector.nextInitialSnapshotMode = "preserve-ui-state";
        stateModule.inspector.map = new Map([[1, document.documentElement]]);

        Object.defineProperty(document, "URL", {
            configurable: true,
            value: "https://example.com/page#after"
        });

        try {
            const pageShow = new Event("pageshow");
            Object.defineProperty(pageShow, "persisted", { value: false });
            window.dispatchEvent(pageShow);

            expect(stateModule.inspector.nextInitialSnapshotMode).toBe("preserve-ui-state");
        } finally {
            if (originalURLDescriptor) {
                Object.defineProperty(document, "URL", originalURLDescriptor);
            }
        }
    });

    it("pagehide does not mark the current context for a fresh snapshot", async () => {
        await import("../Runtime/dom-agent");
        const stateModule = await import("../Runtime/DOMAgent/dom-agent-state");
        const api = window.webInspectorDOM as {
            debugStatus?: () => Record<string, unknown>;
        } | undefined;

        stateModule.inspector.nextInitialSnapshotMode = "preserve-ui-state";
        const initialMode = api?.debugStatus?.()?.nextInitialSnapshotMode;
        window.dispatchEvent(new Event("pagehide"));

        const debugStatus = api?.debugStatus?.() ?? {};
        expect(debugStatus.nextInitialSnapshotMode).toBe(initialMode);
    });

    it("bootstrap adopts lower page epochs by exact assignment", async () => {
        await import("../Runtime/dom-agent");
        const api = window.webInspectorDOM as {
            bootstrap?: (bootstrap: Record<string, unknown>) => boolean;
            debugStatus?: () => Record<string, unknown>;
        } | undefined;

        expect(api?.bootstrap?.({
            pageEpoch: 4,
            documentScopeID: 7,
            autoSnapshot: {
                enabled: true,
                maxDepth: 4,
                debounce: 50
            }
        })).toBe(true);

        inspector.nextInitialSnapshotMode = null;

        expect(api?.bootstrap?.({
            pageEpoch: 2,
            documentScopeID: 3,
            autoSnapshot: {
                enabled: true,
                maxDepth: 4,
                debounce: 50
            }
        })).toBe(true);

        const debugStatus = api?.debugStatus?.() ?? {};
        expect(debugStatus.pageEpoch).toBe(2);
        expect(debugStatus.documentScopeID).toBe(3);
        expect(debugStatus.nextInitialSnapshotMode).toBe("fresh");
    });

});
