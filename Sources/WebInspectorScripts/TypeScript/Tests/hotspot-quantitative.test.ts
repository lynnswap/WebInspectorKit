import { beforeEach, describe, expect, it, vi } from "vitest";

import {
    NetworkLoggingMode,
    bodyCache,
    clearThrottledEvents,
    networkState,
    queuedEvents,
    setThrottleOptions,
    trackedRequests
} from "../Runtime/NetworkAgent/network-agent-utils";
import { installFetchPatch } from "../Runtime/NetworkAgent/network-agent-http";

type WebKitMockHandler = {
    postMessage: ReturnType<typeof vi.fn>;
};

function networkHandler(): WebKitMockHandler {
    return window.webkit?.messageHandlers?.webInspectorNetworkEvents as WebKitMockHandler;
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
        resetNetworkState();
        document.body.innerHTML = "";
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
