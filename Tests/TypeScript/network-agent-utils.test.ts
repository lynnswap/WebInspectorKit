import { beforeEach, describe, expect, it, vi } from "vitest";

import {
    NetworkLoggingMode,
    clearThrottledEvents,
    enqueueNetworkEvent,
    networkState,
    queuedEvents,
    serializeRequestBody,
    setThrottleOptions
} from "../../Sources/WebInspectorKitCore/WebInspector/Support/NetworkAgent/network-agent-utils";

type WebKitMockHandler = {
    postMessage: ReturnType<typeof vi.fn>;
};

function networkEventsHandler(): WebKitMockHandler {
    return window.webkit?.messageHandlers?.webInspectorNetworkEvents as WebKitMockHandler;
}

function resetNetworkState() {
    queuedEvents.splice(0, queuedEvents.length);
    clearThrottledEvents();
    networkState.mode = NetworkLoggingMode.ACTIVE;
    networkState.batchSeq = 0;
    networkState.droppedEvents = 0;
    networkState.sessionID = "test-session";
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
});
