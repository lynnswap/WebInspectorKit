import { beforeEach, describe, expect, it, vi } from "vitest";

import {
    NetworkLoggingMode,
    clearThrottledEvents,
    enqueueNetworkEvent,
    makeBodyHandle,
    networkState,
    queuedEvents,
    serializeRequestBody,
    setThrottleOptions,
    shouldCaptureNetworkBodies
} from "../../Sources/WebInspectorKitCore/WebInspector/Support/NetworkAgent/network-agent-utils";
import {
    configureNetwork,
    getBodyForHandle,
    installNetworkObserver
} from "../../Sources/WebInspectorKitCore/WebInspector/Support/NetworkAgent/network-agent-core";

type WebKitMockHandler = {
    postMessage: ReturnType<typeof vi.fn>;
};

function networkEventsHandler(): WebKitMockHandler {
    return window.webkit?.messageHandlers?.webInspectorNetworkEvents as WebKitMockHandler;
}

function resetNetworkState() {
    if (networkState.resourceObserver && typeof networkState.resourceObserver.disconnect === "function") {
        try {
            networkState.resourceObserver.disconnect();
        } catch {
        }
    }
    queuedEvents.splice(0, queuedEvents.length);
    clearThrottledEvents();
    networkState.mode = NetworkLoggingMode.ACTIVE;
    networkState.installed = false;
    networkState.batchSeq = 0;
    networkState.droppedEvents = 0;
    networkState.sessionID = "test-session";
    networkState.controlAuthToken = "test-control-token";
    networkState.messageAuthToken = "test-control-token";
    networkState.resourceObserver = null;
    networkState.resourceSeen = null;
    setThrottleOptions({
        intervalMs: 0,
        maxQueuedEvents: 500
    });
}

describe("network-agent-utils", () => {
    beforeEach(() => {
        resetNetworkState();
        networkEventsHandler().postMessage.mockClear();
    });

    it("drops oldest buffered events when buffering queue exceeds cap", () => {
        networkState.mode = NetworkLoggingMode.BUFFERING;

        for (let requestId = 0; requestId < 505; requestId += 1) {
            enqueueNetworkEvent({
                kind: "requestWillBeSent",
                requestId
            });
        }

        expect(queuedEvents.length).toBe(500);
        expect(queuedEvents[0].requestId).toBe(5);
        expect(queuedEvents[queuedEvents.length - 1].requestId).toBe(504);
        expect(networkState.droppedEvents).toBe(5);
        expect(networkEventsHandler().postMessage).not.toHaveBeenCalled();
    });

    it("throttles active delivery and reports dropped count from throttle queue", () => {
        setThrottleOptions({
            intervalMs: 100,
            maxQueuedEvents: 2
        });

        enqueueNetworkEvent({ kind: "requestWillBeSent", requestId: 1 });
        enqueueNetworkEvent({ kind: "requestWillBeSent", requestId: 2 });
        enqueueNetworkEvent({ kind: "requestWillBeSent", requestId: 3 });

        expect(networkEventsHandler().postMessage).not.toHaveBeenCalled();

        vi.advanceTimersByTime(100);

        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(1);
        const payload = networkEventsHandler().postMessage.mock.calls[0][0] as {
            dropped?: number;
            events: Array<{ requestId: number }>;
        };
        expect(payload.events.map(event => event.requestId)).toEqual([2, 3]);
        expect(payload.dropped).toBe(1);
        expect(networkState.droppedEvents).toBe(0);
    });

    it("flushes pending throttled events immediately when interval is set to zero", () => {
        setThrottleOptions({
            intervalMs: 200,
            maxQueuedEvents: 8
        });
        enqueueNetworkEvent({ kind: "requestWillBeSent", requestId: 77 });
        expect(networkEventsHandler().postMessage).not.toHaveBeenCalled();

        setThrottleOptions({
            intervalMs: 0,
            maxQueuedEvents: 8
        });

        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(1);
        const payload = networkEventsHandler().postMessage.mock.calls[0][0] as {
            events: Array<{ requestId: number }>;
        };
        expect(payload.events.map(event => event.requestId)).toEqual([77]);
    });

    it("clamps inline request body preview length for large payloads", () => {
        const serialized = serializeRequestBody("x".repeat(800));
        expect(serialized).not.toBeNull();
        expect(serialized?.kind).toBe("text");
        expect(serialized?.body?.length).toBe(512);
        expect(serialized?.truncated).toBe(true);
        expect(serialized?.size).toBe(800);
    });

    it("disables body capture while buffering and re-enables it on active mode", () => {
        networkState.mode = NetworkLoggingMode.BUFFERING;
        expect(shouldCaptureNetworkBodies()).toBe(false);

        networkState.mode = NetworkLoggingMode.ACTIVE;
        expect(shouldCaptureNetworkBodies()).toBe(true);
    });

    it("builds handle payload as metadata-preserving object", () => {
        const createJSHandle = vi.fn((value: unknown) => ({ marker: "handle", value }));
        const webkit = window.webkit as unknown as { createJSHandle?: (value: unknown) => unknown };
        webkit.createJSHandle = createJSHandle;

        const handle = makeBodyHandle(
            {
                kind: "binary",
                body: "AQI=",
                storageBody: "AQID",
                base64Encoded: true,
                truncated: true,
                size: 4,
                summary: "Binary body (4 bytes)"
            },
            {
                kind: "binary",
                encoding: "base64",
                truncated: true,
                size: 4,
                content: "AQID",
                summary: "Binary body (4 bytes)"
            }
        );

        expect(handle).toEqual({
            marker: "handle",
            value: {
                kind: "binary",
                encoding: "base64",
                truncated: true,
                size: 4,
                content: "AQID",
                summary: "Binary body (4 bytes)"
            }
        });
        expect(createJSHandle).toHaveBeenCalledTimes(1);
    });

    it("restores stored metadata from object handle payload", () => {
        const restored = getBodyForHandle({
            kind: "binary",
            encoding: "base64",
            truncated: true,
            size: 9,
            content: "AQIDBA==",
            summary: "Binary body (9 bytes)"
        }, {
            controlAuthToken: "test-control-token"
        }) as Record<string, unknown> | null;

        expect(restored).not.toBeNull();
        expect(restored).toMatchObject({
            kind: "binary",
            encoding: "base64",
            truncated: true,
            size: 9,
            content: "AQIDBA==",
            summary: "Binary body (9 bytes)"
        });
    });

    it("accepts string-like handle objects via valueOf fallback", () => {
        const restored = getBodyForHandle({
            valueOf: () => "body-from-value-of"
        }, {
            controlAuthToken: "test-control-token"
        }) as Record<string, unknown> | null;

        expect(restored).toMatchObject({
            kind: "text",
            encoding: "utf-8",
            content: "body-from-value-of",
            size: "body-from-value-of".length
        });
    });

    it("keeps fetch/xhr patch active while disabling resource observer mode", () => {
        class FakePerformanceObserver {
            readonly callback: PerformanceObserverCallback;
            observe = vi.fn();
            disconnect = vi.fn();

            constructor(callback: PerformanceObserverCallback) {
                this.callback = callback;
            }
        }

        Object.defineProperty(window, "PerformanceObserver", {
            configurable: true,
            writable: true,
            value: FakePerformanceObserver
        });
        Object.defineProperty(globalThis, "PerformanceObserver", {
            configurable: true,
            writable: true,
            value: FakePerformanceObserver
        });

        installNetworkObserver({
            pageHookMode: "enabled"
        });

        const installedObserver = networkState.resourceObserver as FakePerformanceObserver | null;
        expect(installedObserver).not.toBeNull();
        expect((window.fetch as ((...args: unknown[]) => unknown) & { __wiNetworkPatched?: boolean }).__wiNetworkPatched).toBe(true);
        expect((XMLHttpRequest.prototype.open as ((...args: unknown[]) => unknown) & { __wiNetworkPatched?: boolean }).__wiNetworkPatched).toBe(true);

        configureNetwork({
            controlAuthToken: "test-control-token",
            resourceObserverMode: "disabled"
        });

        expect(installedObserver?.disconnect).toHaveBeenCalledTimes(1);
        expect(networkState.resourceObserver).toBeNull();
        expect((window.fetch as ((...args: unknown[]) => unknown) & { __wiNetworkPatched?: boolean }).__wiNetworkPatched).toBe(true);
        expect((XMLHttpRequest.prototype.open as ((...args: unknown[]) => unknown) & { __wiNetworkPatched?: boolean }).__wiNetworkPatched).toBe(true);
    });
});
