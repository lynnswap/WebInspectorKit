// HTTP instrumentation: fetch, XHR, and resource timing.

import {
    bufferEvent,
    captureContentLength,
    captureResponseBody,
    captureXHRResponseBody,
    deliverNetworkEvents,
    enqueueThrottledEvent,
    estimatedEncodedLength,
    handleResourceEntry,
    isActiveLogging,
    networkState,
    nextRequestID,
    normalizeHeaders,
    now,
    serializeRequestBody,
    shouldQueueNetworkEvent,
    shouldCaptureNetworkBodies,
    shouldThrottleDelivery,
    shouldTrackNetworkEvents,
    wallTime
} from "./network-agent-utils";
import type { RequestBodyInfo } from "./network-agent-utils";
import { recordFailure, recordFinish, recordResponse, recordStart } from "./network-agent-core";

type PatchedFunction<T extends Function> = T & { __wiNetworkPatched?: boolean };

type XHRWithNetwork = XMLHttpRequest & {
    __wiNetwork?: {
        method: string;
        url: string;
        headers: Record<string, string>;
        requestBody?: RequestBodyInfo | null;
    };
};

const installFetchPatch = () => {
    if (typeof window.fetch !== "function") {
        return;
    }
    const nativeFetch = window.fetch as PatchedFunction<typeof window.fetch>;
    if (nativeFetch.__wiNetworkPatched) {
        return;
    }
    const patched = (async function(...args: Parameters<typeof window.fetch>) {
        const shouldTrack = shouldTrackNetworkEvents();
        const shouldCaptureRequestBodies = shouldCaptureNetworkBodies();
        const [input, init = {}] = args;
        const request = input as Request;
        const method = init.method || (request && request.method) || "GET";
        const requestId = shouldTrack ? nextRequestID() : null;
        const url = typeof input === "string" ? input : (request && request.url) || "";
        const headers = normalizeHeaders(init.headers || (request && request.headers));
        const requestBodyInfo = shouldCaptureRequestBodies ? serializeRequestBody(init.body) : null;

        if (shouldTrack && requestId != null) {
            recordStart(
                requestId,
                url,
                String(method).toUpperCase(),
                headers,
                "fetch",
                now(),
                wallTime(),
                requestBodyInfo
            );
        }

        try {
            const response = await nativeFetch.call(window, ...args);
            let mimeType;
            let responseBodyInfo = null;
            if (shouldTrack && requestId != null) {
                mimeType = recordResponse(requestId, response, "fetch");
                // Re-check capture mode after async boundaries to honor runtime mode transitions.
                if (shouldCaptureNetworkBodies()) {
                    try {
                        responseBodyInfo = await captureResponseBody(response, mimeType);
                    } catch {
                        responseBodyInfo = null;
                    }
                }
                const encodedLength = estimatedEncodedLength(
                    captureContentLength(response),
                    responseBodyInfo
                );
                recordFinish(
                    requestId,
                    encodedLength,
                    "fetch",
                    response && typeof response.status === "number" ? response.status : undefined,
                    response && typeof response.statusText === "string" ? response.statusText : undefined,
                    mimeType,
                    undefined,
                    undefined,
                    responseBodyInfo
                );
            }
            return response;
        } catch (error) {
            if (shouldTrack && requestId != null) {
                recordFailure(requestId, error, "fetch");
            }
            throw error;
        }
    }) as PatchedFunction<typeof window.fetch>;
    patched.__wiNetworkPatched = true;
    window.fetch = patched;
};

const installXHRPatch = () => {
    if (typeof XMLHttpRequest !== "function") {
        return;
    }
    const originalOpen = XMLHttpRequest.prototype.open as PatchedFunction<typeof XMLHttpRequest.prototype.open>;
    const originalSend = XMLHttpRequest.prototype.send;
    const originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;

    if (originalOpen.__wiNetworkPatched) {
        return;
    }

    const patchedOpen = function(this: XHRWithNetwork, method: string, url: string) {
        const xhr = this as XHRWithNetwork;
        xhr.__wiNetwork = {
            method: String(method || "GET").toUpperCase(),
            url: String(url || ""),
            headers: {}
        };
        return originalOpen.apply(this, arguments as unknown as Parameters<typeof XMLHttpRequest.prototype.open>);
    } as PatchedFunction<typeof XMLHttpRequest.prototype.open>;
    patchedOpen.__wiNetworkPatched = true;
    XMLHttpRequest.prototype.open = patchedOpen;

    XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
        const xhr = this as XHRWithNetwork;
        if (xhr.__wiNetwork) {
            xhr.__wiNetwork.headers[String(name || "").toLowerCase()] = String(value || "");
        }
        return originalSetRequestHeader.apply(this, arguments as unknown as Parameters<typeof XMLHttpRequest.prototype.setRequestHeader>);
    };

    XMLHttpRequest.prototype.send = function() {
        const xhr = this as XHRWithNetwork;
        const shouldTrack = shouldTrackNetworkEvents() && !!xhr.__wiNetwork;
        const shouldCaptureRequestBodies = shouldCaptureNetworkBodies();
        const requestId = shouldTrack ? nextRequestID() : null;
        const info = xhr.__wiNetwork;
        if (shouldTrack && requestId != null && info) {
            if (shouldCaptureRequestBodies) {
                info.requestBody = serializeRequestBody((arguments as IArguments)[0]);
            } else {
                info.requestBody = null;
            }
            recordStart(
                requestId,
                info.url,
                info.method,
                info.headers || {},
                "xhr",
                now(),
                wallTime(),
                info.requestBody
            );
            xhr.addEventListener("readystatechange", function() {
                if ((this as XMLHttpRequest).readyState === 2 && requestId != null) {
                    recordResponse(requestId, this as XMLHttpRequest, "xhr");
                }
            }, false);
            xhr.addEventListener("load", function() {
                if (requestId != null) {
                    // Re-check capture mode at load-time for in-flight requests.
                    const responseBody = shouldCaptureNetworkBodies()
                        ? captureXHRResponseBody(this as XMLHttpRequest)
                        : null;
                    const length = estimatedEncodedLength(
                        captureContentLength(this as XMLHttpRequest),
                        responseBody
                    );
                    const mimeType = (this as XMLHttpRequest).getResponseHeader
                        ? (this as XMLHttpRequest).getResponseHeader("content-type")
                        : null;
                    recordFinish(
                        requestId,
                        length,
                        "xhr",
                        (this as XMLHttpRequest).status,
                        (this as XMLHttpRequest).statusText,
                        mimeType || "",
                        undefined,
                        undefined,
                        responseBody
                    );
                }
            }, false);
            xhr.addEventListener("error", function(event) {
                if (requestId != null) {
                    const failure = event && (event as { error?: unknown }).error ? (event as { error?: unknown }).error : "Network error";
                    recordFailure(requestId, failure, "xhr");
                }
            }, false);
            xhr.addEventListener("abort", function() {
                if (requestId != null) {
                    recordFailure(requestId, "Request aborted", "xhr", {isCanceled: true});
                }
            }, false);
            xhr.addEventListener("timeout", function() {
                if (requestId != null) {
                    recordFailure(requestId, "Request timeout", "xhr", {isTimeout: true});
                }
            }, false);
        }
        return originalSend.apply(this, arguments as unknown as Parameters<typeof XMLHttpRequest.prototype.send>);
    };

    originalOpen.__wiNetworkPatched = true;
};

const installResourceObserver = () => {
    if (networkState.resourceObserver || typeof PerformanceObserver !== "function") {
        return;
    }
    try {
        const observer = new PerformanceObserver(list => {
            if (!shouldTrackNetworkEvents()) {
                return;
            }
            const entries = list.getEntries();
            const payloads = [];
            for (let i = 0; i < entries.length; ++i) {
                const payload = handleResourceEntry(entries[i]);
                if (payload) {
                    payloads.push(payload);
                }
            }
            if (payloads.length) {
                if (!isActiveLogging()) {
                    if (shouldQueueNetworkEvent()) {
                        for (let i = 0; i < payloads.length; ++i) {
                            bufferEvent(payloads[i]);
                        }
                    }
                    return;
                }
                if (shouldThrottleDelivery()) {
                    for (let i = 0; i < payloads.length; ++i) {
                        enqueueThrottledEvent(payloads[i]);
                    }
                    return;
                }
                deliverNetworkEvents(payloads);
            }
        });
        observer.observe({type: "resource", buffered: true});
        networkState.resourceObserver = observer;
        if (!networkState.resourceSeen) {
            networkState.resourceSeen = new Set<string>();
        }
    } catch {
    }
};

const detachResourceObserver = () => {
    const observer = networkState.resourceObserver;
    if (!observer) {
        return;
    }
    try {
        observer.disconnect();
    } catch {
    }
    networkState.resourceObserver = null;
    if (networkState.resourceSeen) {
        networkState.resourceSeen.clear();
    }
};

const setResourceObserverEnabled = (enabled: boolean) => {
    if (enabled) {
        installResourceObserver();
        return;
    }
    detachResourceObserver();
};

export { installFetchPatch, installResourceObserver, installXHRPatch, setResourceObserverEnabled };
