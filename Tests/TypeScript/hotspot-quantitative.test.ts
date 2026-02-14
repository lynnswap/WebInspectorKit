import { beforeEach, describe, expect, it, vi } from "vitest";

import {
    setAutoSnapshotOptions,
    triggerSnapshotUpdate
} from "../../Sources/WebInspectorKitCore/WebInspector/Support/DOMAgent/dom-agent-snapshot";
import { inspector } from "../../Sources/WebInspectorKitCore/WebInspector/Support/DOMAgent/dom-agent-state";
import {
    NetworkLoggingMode,
    bodyCache,
    clearThrottledEvents,
    networkState,
    queuedEvents,
    setThrottleOptions,
    trackedRequests
} from "../../Sources/WebInspectorKitCore/WebInspector/Support/NetworkAgent/network-agent-utils";
import { installFetchPatch } from "../../Sources/WebInspectorKitCore/WebInspector/Support/NetworkAgent/network-agent-http";

type WebKitMockHandler = {
    postMessage: ReturnType<typeof vi.fn>;
};

function snapshotHandler(): WebKitMockHandler {
    return window.webkit?.messageHandlers?.webInspectorDOMSnapshot as WebKitMockHandler;
}

function mutationHandler(): WebKitMockHandler {
    return window.webkit?.messageHandlers?.webInspectorDOMMutations as WebKitMockHandler;
}

function networkHandler(): WebKitMockHandler {
    return window.webkit?.messageHandlers?.webInspectorNetworkEvents as WebKitMockHandler;
}

function resetDOMState() {
    inspector.map = new Map();
    inspector.nodeMap = new WeakMap();
    inspector.nextId = 1;
    inspector.pendingMutations = [];
    inspector.snapshotAutoUpdateObserver = null;
    inspector.snapshotAutoUpdateEnabled = true;
    inspector.snapshotAutoUpdatePending = false;
    inspector.snapshotAutoUpdateTimer = null;
    inspector.snapshotAutoUpdateFrame = null;
    inspector.snapshotAutoUpdateDebounce = 50;
    inspector.snapshotAutoUpdateMaxDepth = 4;
    inspector.snapshotAutoUpdateReason = "mutation";
    inspector.snapshotAutoUpdateOverflow = false;
    inspector.snapshotAutoUpdateSuppressedCount = 0;
    inspector.snapshotAutoUpdatePendingWhileSuppressed = false;
    inspector.snapshotAutoUpdatePendingReason = null;
    inspector.documentURL = null;
    snapshotHandler().postMessage.mockClear();
    mutationHandler().postMessage.mockClear();
}

function resetNetworkState() {
    networkState.mode = NetworkLoggingMode.ACTIVE;
    networkState.batchSeq = 0;
    networkState.droppedEvents = 0;
    networkState.nextId = 1;
    networkState.sessionID = "quantitative-session";
    queuedEvents.splice(0, queuedEvents.length);
    trackedRequests.clear();
    clearThrottledEvents();
    bodyCache.clear();
    setThrottleOptions({ intervalMs: 0, maxQueuedEvents: 500 });
    networkHandler().postMessage.mockClear();
}

function measureEventsSize(events: Array<Record<string, any>>): number {
    return events.reduce((total, event) => total + JSON.stringify(event).length, 0);
}

describe("hotspot quantitative acceptance", () => {
    beforeEach(() => {
        resetDOMState();
        resetNetworkState();
        document.body.innerHTML = "";
    });

    it("reduces full snapshot count by at least 50% and keeps mutation as primary path", () => {
        const stableNode = document.createElement("main");
        document.body.appendChild(stableNode);
        inspector.map = new Map([[1, stableNode]]);
        setAutoSnapshotOptions({ debounce: 50 });

        const runs = 20;
        for (let index = 0; index < runs; index += 1) {
            inspector.pendingMutations = [];
            triggerSnapshotUpdate("mutation");
            vi.advanceTimersByTime(66);
        }

        const currentFullSnapshots = snapshotHandler().postMessage.mock.calls.length;
        const legacyFullSnapshots = runs;
        const reduction = legacyFullSnapshots > 0
            ? (legacyFullSnapshots - currentFullSnapshots) / legacyFullSnapshots
            : 0;

        const mutationNode = document.createElement("div");
        mutationNode.setAttribute("class", "active");
        document.body.appendChild(mutationNode);
        inspector.map = new Map([[1, mutationNode]]);

        for (let index = 0; index < runs; index += 1) {
            inspector.pendingMutations = [{
                type: "attributes",
                target: mutationNode,
                attributeName: "class",
                addedNodes: [] as unknown as NodeList,
                removedNodes: [] as unknown as NodeList,
                previousSibling: null
            } as unknown as MutationRecord];
            triggerSnapshotUpdate("mutation");
            vi.advanceTimersByTime(66);
        }

        const mutationBundles = mutationHandler().postMessage.mock.calls.length;
        const fallbackFullSnapshots = snapshotHandler().postMessage.mock.calls.length;

        console.info(
            `[quant] dom_full_snapshot_reduction=${(reduction * 100).toFixed(2)}% ` +
            `legacy=${legacyFullSnapshots} current=${currentFullSnapshots}`
        );
        console.info(
            `[quant] dom_mutation_vs_full mutationBundles=${mutationBundles} fullSnapshots=${fallbackFullSnapshots}`
        );

        expect(reduction).toBeGreaterThanOrEqual(0.5);
        expect(mutationBundles).toBeGreaterThan(fallbackFullSnapshots);
    });

    it("reduces buffering payload size by at least 30% compared to body-capturing baseline", async () => {
        const responseBody = JSON.stringify({
            items: Array.from({ length: 80 }, (_, index) => `response-item-${index}`)
        });
        const requestBody = JSON.stringify({
            payload: Array.from({ length: 80 }, (_, index) => `request-item-${index}`)
        });
        const originalWindowFetch = window.fetch;
        const originalGlobalFetch = globalThis.fetch;

        const nativeFetch = vi.fn(async () => {
            return new Response(responseBody, {
                status: 200,
                statusText: "OK",
                headers: {
                    "content-type": "application/json",
                    "content-length": String(responseBody.length)
                }
            });
        });
        Object.defineProperty(window, "fetch", {
            configurable: true,
            writable: true,
            value: nativeFetch
        });
        Object.defineProperty(globalThis, "fetch", {
            configurable: true,
            writable: true,
            value: nativeFetch
        });
        try {
            installFetchPatch();

            networkState.mode = NetworkLoggingMode.ACTIVE;
            await window.fetch("https://example.com/metrics", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: requestBody
            });
            const activeEvents = networkHandler().postMessage.mock.calls.flatMap(call => {
                const payload = call[0] as { events?: Array<Record<string, any>> };
                return Array.isArray(payload.events) ? payload.events : [];
            });
            const baselineBytes = measureEventsSize(activeEvents);

            resetNetworkState();
            networkState.mode = NetworkLoggingMode.BUFFERING;
            await window.fetch("https://example.com/metrics", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: requestBody
            });
            const bufferingBytes = measureEventsSize(queuedEvents as Array<Record<string, any>>);
            const reduction = baselineBytes > 0 ? (baselineBytes - bufferingBytes) / baselineBytes : 0;

            console.info(
                `[quant] network_payload_reduction=${(reduction * 100).toFixed(2)}% ` +
                `baselineBytes=${baselineBytes} bufferingBytes=${bufferingBytes}`
            );

            expect(baselineBytes).toBeGreaterThan(0);
            expect(bufferingBytes).toBeLessThan(baselineBytes);
            expect(reduction).toBeGreaterThanOrEqual(0.3);
        } finally {
            Object.defineProperty(window, "fetch", {
                configurable: true,
                writable: true,
                value: originalWindowFetch
            });
            Object.defineProperty(globalThis, "fetch", {
                configurable: true,
                writable: true,
                value: originalGlobalFetch
            });
        }
    });

    it("skips response body capture when mode switches to buffering before fetch resolves", async () => {
        const responseBody = JSON.stringify({
            items: Array.from({ length: 160 }, (_, index) => `late-response-item-${index}`)
        });
        const originalWindowFetch = window.fetch;
        const originalGlobalFetch = globalThis.fetch;

        let resolveFetch: (value: Response) => void = () => {
            throw new Error("fetch resolver was not initialized");
        };
        const pendingFetch = new Promise<Response>(resolve => {
            resolveFetch = resolve;
        });
        const nativeFetch = vi.fn(() => pendingFetch);

        Object.defineProperty(window, "fetch", {
            configurable: true,
            writable: true,
            value: nativeFetch
        });
        Object.defineProperty(globalThis, "fetch", {
            configurable: true,
            writable: true,
            value: nativeFetch
        });

        try {
            installFetchPatch();
            networkState.mode = NetworkLoggingMode.ACTIVE;

            const inFlight = window.fetch("https://example.com/in-flight", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ payload: "request" })
            });

            networkState.mode = NetworkLoggingMode.BUFFERING;
            resolveFetch(new Response(responseBody, {
                status: 200,
                statusText: "OK",
                headers: {
                    "content-type": "application/json",
                    "content-length": String(responseBody.length)
                }
            }));
            await inFlight;

            const loadingFinished = (queuedEvents as Array<Record<string, any>>).find(event => {
                return event.kind === "loadingFinished";
            });
            expect(loadingFinished).toBeDefined();
            expect(loadingFinished?.decodedBodySize).toBeUndefined();
            expect(loadingFinished?.body).toBeUndefined();
        } finally {
            Object.defineProperty(window, "fetch", {
                configurable: true,
                writable: true,
                value: originalWindowFetch
            });
            Object.defineProperty(globalThis, "fetch", {
                configurable: true,
                writable: true,
                value: originalGlobalFetch
            });
        }
    });
});
