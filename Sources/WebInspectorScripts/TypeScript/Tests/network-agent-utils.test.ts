import { beforeEach, describe, expect, it, vi } from "vitest";

import {
    NetworkLoggingMode,
    clearThrottledEvents,
    enqueueNetworkEvent,
    handleResourceEntry,
    makeBodyHandle,
    materializeReservedResourceEntry,
    networkState,
    queuedEvents,
    reserveResourceEntry,
    serializeRequestBody,
    setThrottleOptions,
    shouldCaptureNetworkBodies
} from "../Runtime/NetworkAgent/network-agent-utils";
import {
    configureNetwork,
    getBody,
    getBodyForHandle,
    installNetworkObserver
} from "../Runtime/NetworkAgent/network-agent-core";

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
    networkState.nextId = 1;
    networkState.batchSeq = 0;
    networkState.droppedEvents = 0;
    networkState.sessionID = "test-session";
    networkState.controlAuthToken = "test-control-token";
    networkState.messageAuthToken = "test-control-token";
    networkState.resourceObserver = null;
    networkState.resourceSeen = null;
    networkState.resourceReserved = null;
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

    it("returns an agent-unavailable sentinel when body access is unauthorized", () => {
        const restored = getBody("body-ref", {
            controlAuthToken: "wrong-token"
        }) as Record<string, unknown> | null;

        expect(restored).toEqual({
            __wiBodyFetchState: "agentUnavailable"
        });
    });

    it("returns an agent-unavailable sentinel for unauthorized handle access", () => {
        const restored = getBodyForHandle("body-handle", {
            controlAuthToken: "wrong-token"
        }) as Record<string, unknown> | null;

        expect(restored).toEqual({
            __wiBodyFetchState: "agentUnavailable"
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

    it("bootstraps existing resource timings when configure activates current page capture", () => {
        const entriesSpy = vi.spyOn(performance, "getEntriesByType").mockImplementation(type => {
            if (type !== "resource") {
                return [];
            }
            return ([{
                name: "https://example.com/app.js",
                startTime: 12,
                duration: 4,
                initiatorType: "script",
                encodedBodySize: 128,
                decodedBodySize: 256,
                responseStatus: 200,
                requestMethod: "GET"
            }] as unknown) as PerformanceEntryList;
        });

        configureNetwork({
            controlAuthToken: "test-control-token",
            clear: true,
            mode: NetworkLoggingMode.ACTIVE,
            resourceObserverMode: "disabled"
        });

        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(1);
        const payload = networkEventsHandler().postMessage.mock.calls[0][0] as {
            events: Array<Record<string, unknown>>;
        };
        expect(payload.events).toHaveLength(1);
        expect(payload.events[0]).toMatchObject({
            kind: "resourceTiming",
            url: "https://example.com/app.js",
            initiator: "script",
            encodedBodyLength: 128,
            decodedBodySize: 256,
            status: 200,
            method: "GET"
        });

        entriesSpy.mockRestore();
    });

    it("delivers bootstrapped resource snapshots losslessly while preserving throttle cadence", () => {
        const entriesSpy = vi.spyOn(performance, "getEntriesByType").mockImplementation(type => {
            if (type !== "resource") {
                return [];
            }
            return Array.from({length: 5}, (_, index) => ({
                name: `https://example.com/bootstrap-${index + 1}.js`,
                startTime: 12 + index,
                duration: 4,
                initiatorType: "script",
                encodedBodySize: 128 + index,
                decodedBodySize: 256 + index,
                responseStatus: 200,
                requestMethod: "GET"
            })) as unknown as PerformanceEntryList;
        });

        configureNetwork({
            controlAuthToken: "test-control-token",
            clear: true,
            mode: NetworkLoggingMode.ACTIVE,
            resourceObserverMode: "disabled",
            throttle: {
                intervalMs: 100,
                maxQueuedEvents: 2
            }
        });

        expect(networkEventsHandler().postMessage).not.toHaveBeenCalled();

        vi.advanceTimersByTime(100);
        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(1);

        vi.advanceTimersByTime(100);
        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(2);

        vi.advanceTimersByTime(100);
        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(3);

        const urls = networkEventsHandler().postMessage.mock.calls.flatMap(call => {
            const payload = call[0] as {
                events: Array<Record<string, unknown>>;
            };
            return payload.events.map(event => String(event.url));
        });
        expect(urls).toEqual([
            "https://example.com/bootstrap-1.js",
            "https://example.com/bootstrap-2.js",
            "https://example.com/bootstrap-3.js",
            "https://example.com/bootstrap-4.js",
            "https://example.com/bootstrap-5.js"
        ]);
        expect(networkState.droppedEvents).toBe(0);

        entriesSpy.mockRestore();
    });

    it("drains live throttled events alongside bootstrapped replay batches", () => {
        const entriesSpy = vi.spyOn(performance, "getEntriesByType").mockImplementation(type => {
            if (type !== "resource") {
                return [];
            }
            return Array.from({length: 4}, (_, index) => ({
                name: `https://example.com/bootstrap-live-${index + 1}.js`,
                startTime: 20 + index,
                duration: 4,
                initiatorType: "script",
                encodedBodySize: 64 + index,
                decodedBodySize: 96 + index,
                responseStatus: 200,
                requestMethod: "GET"
            })) as unknown as PerformanceEntryList;
        });

        configureNetwork({
            controlAuthToken: "test-control-token",
            clear: true,
            mode: NetworkLoggingMode.ACTIVE,
            resourceObserverMode: "disabled",
            throttle: {
                intervalMs: 100,
                maxQueuedEvents: 2
            }
        });
        enqueueNetworkEvent({
            kind: "requestWillBeSent",
            requestId: 99
        });

        vi.advanceTimersByTime(100);

        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(1);
        const firstPayload = networkEventsHandler().postMessage.mock.calls[0][0] as {
            events: Array<Record<string, unknown>>;
        };
        expect(firstPayload.events).toHaveLength(2);
        expect(firstPayload.events[0]).toMatchObject({
            kind: "requestWillBeSent",
            requestId: 99
        });
        expect(firstPayload.events[1]).toMatchObject({
            kind: "resourceTiming",
            url: "https://example.com/bootstrap-live-1.js"
        });

        vi.advanceTimersByTime(100);
        vi.advanceTimersByTime(100);

        const replayedURLs = networkEventsHandler().postMessage.mock.calls.flatMap(call => {
            const payload = call[0] as {
                events: Array<Record<string, unknown>>;
            };
            return payload.events
                .filter(event => event.kind === "resourceTiming")
                .map(event => String(event.url));
        });
        expect(replayedURLs).toEqual([
            "https://example.com/bootstrap-live-1.js",
            "https://example.com/bootstrap-live-2.js",
            "https://example.com/bootstrap-live-3.js",
            "https://example.com/bootstrap-live-4.js"
        ]);

        entriesSpy.mockRestore();
    });

    it("keeps replay batches progressing when throttled delivery is limited to one event", () => {
        const entriesSpy = vi.spyOn(performance, "getEntriesByType").mockImplementation(type => {
            if (type !== "resource") {
                return [];
            }
            return Array.from({length: 2}, (_, index) => ({
                name: `https://example.com/bootstrap-single-${index + 1}.js`,
                startTime: 30 + index,
                duration: 4,
                initiatorType: "script",
                encodedBodySize: 48 + index,
                decodedBodySize: 64 + index,
                responseStatus: 200,
                requestMethod: "GET"
            })) as unknown as PerformanceEntryList;
        });

        configureNetwork({
            controlAuthToken: "test-control-token",
            clear: true,
            mode: NetworkLoggingMode.ACTIVE,
            resourceObserverMode: "disabled",
            throttle: {
                intervalMs: 100,
                maxQueuedEvents: 1
            }
        });

        for (let requestId = 1; requestId <= 4; requestId += 1) {
            enqueueNetworkEvent({
                kind: "requestWillBeSent",
                requestId
            });
            vi.advanceTimersByTime(100);
        }

        const replayedURLs = networkEventsHandler().postMessage.mock.calls.flatMap(call => {
            const payload = call[0] as {
                events: Array<Record<string, unknown>>;
            };
            return payload.events
                .filter(event => event.kind === "resourceTiming")
                .map(event => String(event.url));
        });
        expect(replayedURLs).toEqual([
            "https://example.com/bootstrap-single-1.js",
            "https://example.com/bootstrap-single-2.js"
        ]);

        entriesSpy.mockRestore();
    });

    it("reserves bootstrapped resource entries before throttled replay drains", () => {
        const reservedEntry = {
            name: "https://example.com/reserved-bootstrap.js",
            startTime: 44,
            duration: 4,
            initiatorType: "script",
            encodedBodySize: 80,
            decodedBodySize: 96,
            responseStatus: 200,
            requestMethod: "GET"
        } as unknown as PerformanceEntry;
        const entriesSpy = vi.spyOn(performance, "getEntriesByType").mockImplementation(type => {
            if (type !== "resource") {
                return [];
            }
            return [reservedEntry] as unknown as PerformanceEntryList;
        });

        configureNetwork({
            controlAuthToken: "test-control-token",
            clear: true,
            mode: NetworkLoggingMode.ACTIVE,
            throttle: {
                intervalMs: 100,
                maxQueuedEvents: 1
            }
        });

        expect(handleResourceEntry(reservedEntry)).toBeNull();

        vi.advanceTimersByTime(100);

        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(1);
        const payload = networkEventsHandler().postMessage.mock.calls[0][0] as {
            events: Array<Record<string, unknown>>;
        };
        expect(payload.events).toHaveLength(1);
        expect(payload.events[0]).toMatchObject({
            kind: "resourceTiming",
            url: "https://example.com/reserved-bootstrap.js"
        });

        entriesSpy.mockRestore();
    });

    it("allocates resource timing request IDs only when entries are emitted", () => {
        const firstEntry = {
            name: "https://example.com/reserved-id.js",
            startTime: 10,
            duration: 2,
            initiatorType: "script",
            encodedBodySize: 32,
            decodedBodySize: 48,
            responseStatus: 200,
            requestMethod: "GET"
        } as unknown as PerformanceEntry;
        const secondEntry = {
            name: "https://example.com/live-id.js",
            startTime: 20,
            duration: 2,
            initiatorType: "script",
            encodedBodySize: 32,
            decodedBodySize: 48,
            responseStatus: 200,
            requestMethod: "GET"
        } as unknown as PerformanceEntry;

        const reservedKey = reserveResourceEntry(firstEntry);
        expect(reservedKey).toBeTruthy();

        const reservedPayload = materializeReservedResourceEntry(String(reservedKey)) as Record<string, unknown> | null;
        expect(reservedPayload).not.toBeNull();
        expect(reservedPayload?.requestId).toBe(1);

        const livePayload = handleResourceEntry(secondEntry) as Record<string, unknown> | null;
        expect(livePayload).not.toBeNull();
        expect(livePayload?.requestId).toBe(2);
    });

    it("deduplicates bootstrapped resource timings until clear resets the snapshot state", () => {
        const entriesSpy = vi.spyOn(performance, "getEntriesByType").mockImplementation(type => {
            if (type !== "resource") {
                return [];
            }
            return ([{
                name: "https://example.com/bootstrap.css",
                startTime: 18,
                duration: 3,
                initiatorType: "link",
                encodedBodySize: 64,
                decodedBodySize: 80,
                responseStatus: 200,
                requestMethod: "GET"
            }] as unknown) as PerformanceEntryList;
        });

        configureNetwork({
            controlAuthToken: "test-control-token",
            clear: true,
            mode: NetworkLoggingMode.ACTIVE,
            resourceObserverMode: "disabled"
        });
        configureNetwork({
            controlAuthToken: "test-control-token",
            mode: NetworkLoggingMode.ACTIVE,
            resourceObserverMode: "disabled"
        });

        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(1);

        configureNetwork({
            controlAuthToken: "test-control-token",
            mode: NetworkLoggingMode.ACTIVE,
            resourceObserverMode: "disabled",
            clear: true
        });

        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(2);
        const replayedPayload = networkEventsHandler().postMessage.mock.calls[1][0] as {
            events: Array<Record<string, unknown>>;
        };
        expect(replayedPayload.events).toHaveLength(1);
        expect(replayedPayload.events[0]).toMatchObject({
            kind: "resourceTiming",
            url: "https://example.com/bootstrap.css"
        });

        entriesSpy.mockRestore();
    });

    it("does not rebootstrap the same page snapshot when resourceSeen was populated by another path", () => {
        const entriesSpy = vi.spyOn(performance, "getEntriesByType").mockImplementation(type => {
            if (type !== "resource") {
                return [];
            }
            return ([{
                name: "https://example.com/native-captured.css",
                startTime: 24,
                duration: 5,
                initiatorType: "link",
                encodedBodySize: 72,
                decodedBodySize: 96,
                responseStatus: 200,
                requestMethod: "GET"
            }] as unknown) as PerformanceEntryList;
        });

        configureNetwork({
            controlAuthToken: "test-control-token",
            clear: true,
            mode: NetworkLoggingMode.ACTIVE,
            resourceObserverMode: "disabled"
        });

        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(1);

        configureNetwork({
            controlAuthToken: "test-control-token",
            mode: NetworkLoggingMode.ACTIVE,
            resourceObserverMode: "disabled"
        });

        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(1);

        entriesSpy.mockRestore();
    });

    it("clears the buffering cutoff before replaying a cleared page snapshot", () => {
        const entriesSpy = vi.spyOn(performance, "getEntriesByType").mockImplementation(type => {
            if (type !== "resource") {
                return [];
            }
            return ([{
                name: "https://example.com/reopened.js",
                startTime: 12,
                duration: 2,
                initiatorType: "script",
                encodedBodySize: 32,
                decodedBodySize: 48,
                responseStatus: 200,
                requestMethod: "GET"
            }] as unknown) as PerformanceEntryList;
        });

        networkState.resourceStartCutoffMs = 100;
        configureNetwork({
            controlAuthToken: "test-control-token",
            clear: true,
            mode: NetworkLoggingMode.ACTIVE,
            resourceObserverMode: "disabled"
        });

        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(1);
        const payload = networkEventsHandler().postMessage.mock.calls[0][0] as {
            events: Array<Record<string, unknown>>;
        };
        expect(payload.events[0]).toMatchObject({
            kind: "resourceTiming",
            url: "https://example.com/reopened.js"
        });

        entriesSpy.mockRestore();
    });

    it("bootstraps current page resources when transitioning from stopped back to active", () => {
        const entriesSpy = vi.spyOn(performance, "getEntriesByType").mockImplementation(type => {
            if (type !== "resource") {
                return [];
            }
            return ([{
                name: "https://example.com/resume.js",
                startTime: 18,
                duration: 2,
                initiatorType: "script",
                encodedBodySize: 24,
                decodedBodySize: 36,
                responseStatus: 200,
                requestMethod: "GET"
            }] as unknown) as PerformanceEntryList;
        });

        networkState.mode = NetworkLoggingMode.STOPPED;
        configureNetwork({
            controlAuthToken: "test-control-token",
            mode: NetworkLoggingMode.ACTIVE,
            resourceObserverMode: "disabled"
        });

        expect(networkEventsHandler().postMessage).toHaveBeenCalledTimes(1);
        const payload = networkEventsHandler().postMessage.mock.calls[0][0] as {
            events: Array<Record<string, unknown>>;
        };
        expect(payload.events[0]).toMatchObject({
            kind: "resourceTiming",
            url: "https://example.com/resume.js"
        });

        entriesSpy.mockRestore();
    });

    it("bootstraps current page resources before starting the buffering cutoff", () => {
        const entriesSpy = vi.spyOn(performance, "getEntriesByType").mockImplementation(type => {
            if (type !== "resource") {
                return [];
            }
            return ([{
                name: "https://example.com/bootstrap-buffered.js",
                startTime: 18,
                duration: 2,
                initiatorType: "script",
                encodedBodySize: 24,
                decodedBodySize: 36,
                responseStatus: 200,
                requestMethod: "GET"
            }] as unknown) as PerformanceEntryList;
        });

        configureNetwork({
            controlAuthToken: "test-control-token",
            clear: true,
            mode: NetworkLoggingMode.BUFFERING,
            resourceObserverMode: "enabled"
        });

        expect(queuedEvents).toHaveLength(1);
        expect(queuedEvents[0]).toMatchObject({
            kind: "resourceTiming",
            url: "https://example.com/bootstrap-buffered.js"
        });
        expect(typeof networkState.resourceStartCutoffMs).toBe("number");

        entriesSpy.mockRestore();
    });
});
