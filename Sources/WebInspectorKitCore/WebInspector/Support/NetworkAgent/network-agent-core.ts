// Core orchestrator: shared helpers live in NetworkAgentUtils.ts
// This file keeps recording logic and wires sub-patches.

import {
    NETWORK_EVENT_VERSION,
    NetworkLoggingMode,
    bodyCache,
    buildStoredBodyPayload,
    clearThrottledEvents,
    deliverNetworkEvents,
    enqueueNetworkEvent,
    enqueueThrottledEvent,
    generateSessionID,
    makeBodyHandle,
    makeBodyPreviewPayload,
    makeBodyRef,
    makeNetworkTime,
    networkState,
    normalizeHeaders,
    parseRawHeaders,
    queuedEvents,
    setThrottleOptions,
    shouldThrottleDelivery,
    trackedRequests
} from "./network-agent-utils";
import type { RequestBodyInfo } from "./network-agent-utils";
import { installFetchPatch, installResourceObserver, installXHRPatch } from "./network-agent-http";

const buildNetworkError = (
    error: unknown,
    requestType: string,
    options: { isCanceled?: boolean; isTimeout?: boolean } = {}
) => {
    let message = "";
    const errorRecord = typeof error === "object" && error ? (error as { message?: string; name?: string }) : null;
    if (errorRecord && typeof errorRecord.message === "string" && errorRecord.message) {
        message = errorRecord.message;
    } else if (typeof error === "string" && error) {
        message = error;
    } else if (error) {
        message = String(error);
    } else {
        message = "Network error";
    }

    let code = null;
    if (errorRecord && typeof errorRecord.name === "string" && errorRecord.name) {
        code = errorRecord.name;
    }

    let domain = "other";
    if (requestType === "fetch") {
        domain = "fetch";
    } else if (requestType === "xhr") {
        domain = "xhr";
    } else if (requestType === "resource") {
        domain = "resource";
    }

    const payload: Record<string, any> = {
        domain,
        message
    };

    if (code) {
        payload.code = code;
    }

    const isCanceled = options.isCanceled === true || code === "AbortError";
    if (isCanceled) {
        payload.isCanceled = true;
    }
    if (options.isTimeout === true) {
        payload.isTimeout = true;
    }

    return payload;
};

const storeBodyForRole = (role: string, requestId: number, bodyInfo: RequestBodyInfo | null | undefined) => {
    const stored = buildStoredBodyPayload(bodyInfo);
    if (!stored) {
        return { ref: null, handle: null };
    }
    const handle = makeBodyHandle(bodyInfo, stored);
    if (handle) {
        stored.handle = handle;
    }
    const ref = makeBodyRef(role, requestId);
    if (!bodyCache.store(ref, stored)) {
        return { ref: null, handle: handle };
    }
    return { ref: ref, handle: handle };
};

const recordStart = (
    requestId: number,
    url: string,
    method: string,
    requestHeaders: Record<string, string>,
    requestType: string,
    startTimeOverride?: number,
    wallTimeOverride?: number,
    requestBody?: RequestBodyInfo | null
) => {
    const time = makeNetworkTime(startTimeOverride, wallTimeOverride);
    trackedRequests.set(requestId, {startTime: time.monotonicMs, wallTime: time.wallMs});
    const bodyPayload = storeBodyForRole("req", requestId, requestBody);
    enqueueNetworkEvent({
        kind: "requestWillBeSent",
        requestId: requestId,
        time: time,
        url: url,
        method: method,
        headers: requestHeaders || {},
        initiator: requestType,
        body: makeBodyPreviewPayload(requestBody, bodyPayload.ref, bodyPayload.handle),
        bodySize: requestBody ? requestBody.size : undefined
    });
};

const recordResponse = (requestId: number, response: Response | XMLHttpRequest | null, requestType: string) => {
    let mimeType = "";
    let headers: Record<string, string> = {};
    try {
        if (response && "headers" in response && response.headers) {
            mimeType = response.headers.get("content-type") || "";
            headers = normalizeHeaders(response.headers);
        }
        if (!mimeType && response && "getResponseHeader" in response && typeof response.getResponseHeader === "function") {
            mimeType = response.getResponseHeader("content-type") || "";
        }
        if ((!headers || !Object.keys(headers).length) && response && "getAllResponseHeaders" in response && typeof response.getAllResponseHeaders === "function") {
            headers = parseRawHeaders(response.getAllResponseHeaders());
        }
    } catch {
        mimeType = "";
        headers = {};
    }
    const time = makeNetworkTime();
    const status = typeof response === "object" && response !== null && typeof response.status === "number" ? response.status : undefined;
    const statusText = typeof response === "object" && response !== null && typeof response.statusText === "string" ? response.statusText : "";
    enqueueNetworkEvent({
        kind: "responseReceived",
        requestId: requestId,
        time: time,
        status: status,
        statusText: statusText,
        mimeType: mimeType,
        headers: headers,
        initiator: requestType
    });
    return mimeType;
};

const recordFinish = (
    requestId: number,
    encodedBodyLength: number | undefined,
    requestType: string,
    status: number | undefined,
    statusText: string | undefined,
    mimeType: string,
    endTimeOverride?: number,
    wallTimeOverride?: number,
    responseBody?: RequestBodyInfo | null
) => {
    const time = makeNetworkTime(endTimeOverride, wallTimeOverride);
    const bodyPayload = storeBodyForRole("res", requestId, responseBody);
    enqueueNetworkEvent({
        kind: "loadingFinished",
        requestId: requestId,
        time: time,
        encodedBodyLength: encodedBodyLength,
        decodedBodySize: responseBody ? responseBody.size : undefined,
        status: status,
        statusText: statusText,
        mimeType: mimeType,
        initiator: requestType,
        body: makeBodyPreviewPayload(responseBody, bodyPayload.ref, bodyPayload.handle)
    });
    trackedRequests.delete(requestId);
};

const recordFailure = (
    requestId: number,
    error: unknown,
    requestType: string,
    options: { isCanceled?: boolean; isTimeout?: boolean } = {}
) => {
    const time = makeNetworkTime();
    enqueueNetworkEvent({
        kind: "loadingFailed",
        requestId: requestId,
        time: time,
        error: buildNetworkError(error, requestType, options),
        initiator: requestType
    });
    trackedRequests.delete(requestId);
};

const flushQueuedEvents = () => {
    if (!queuedEvents.length) {
        return;
    }
    const pending = queuedEvents.splice(0, queuedEvents.length);
    if (shouldThrottleDelivery()) {
        for (let i = 0; i < pending.length; ++i) {
            enqueueThrottledEvent(pending[i]);
        }
        return;
    }
    deliverNetworkEvents(pending);
};

const postNetworkReset = () => {
    try {
        window.webkit?.messageHandlers?.webInspectorNetworkReset?.postMessage({
            version: NETWORK_EVENT_VERSION,
            sessionId: networkState.sessionID
        });
    } catch {
    }
};

const clearDisabledNetworkState = () => {
    queuedEvents.splice(0, queuedEvents.length);
    clearThrottledEvents();
    networkState.droppedEvents = 0;
};

const resetNetworkState = () => {
    queuedEvents.splice(0, queuedEvents.length);
    trackedRequests.clear();
    bodyCache.clear();
    clearThrottledEvents();
    const resourceSeen = networkState.resourceSeen;
    if (resourceSeen) {
        resourceSeen.clear();
    }
    networkState.sessionID = generateSessionID();
    networkState.nextId = 1;
    networkState.batchSeq = 0;
    networkState.droppedEvents = 0;
    postNetworkReset();
};

const ensureInstalled = () => {
    if (networkState.installed) {
        return;
    }
    installFetchPatch();
    installXHRPatch();
    installResourceObserver();
    // WebSocket capture disabled for this release; keep patch uninstalled intentionally.
    // installWebSocketPatch();
    networkState.installed = true;
};

const normalizeLoggingMode = (mode: string) => {
    if (mode === NetworkLoggingMode.BUFFERING) {
        return NetworkLoggingMode.BUFFERING;
    }
    if (mode === NetworkLoggingMode.STOPPED) {
        return NetworkLoggingMode.STOPPED;
    }
    return NetworkLoggingMode.ACTIVE;
};

const setNetworkLoggingMode = (mode: string) => {
    const previousMode = networkState.mode;
    const resolvedMode = normalizeLoggingMode(mode);
    networkState.mode = resolvedMode;
    if (networkState.mode === NetworkLoggingMode.STOPPED) {
        resetNetworkState();
        return;
    }
    if (networkState.mode === NetworkLoggingMode.ACTIVE && previousMode !== NetworkLoggingMode.ACTIVE) {
        flushQueuedEvents();
    }
};

const clearNetworkRecords = () => {
    trackedRequests.clear();
    const resourceSeen = networkState.resourceSeen;
    if (resourceSeen) {
        resourceSeen.clear();
    }
    bodyCache.clear();
    clearThrottledEvents();
    queuedEvents.splice(0, queuedEvents.length);
    networkState.batchSeq = 0;
    networkState.droppedEvents = 0;
    postNetworkReset();
};

const installNetworkObserver = () => {
    ensureInstalled();
};

const getBody = (ref: string | null | undefined) => {
    if (!ref || typeof ref !== "string") {
        return null;
    }
    return bodyCache.take(ref);
};

const cloneStoredBodyPayload = (source: Record<string, any>) => {
    const payload: Record<string, any> = {};
    const kind = typeof source.kind === "string" && source.kind ? source.kind : "other";
    payload.kind = kind;
    payload.encoding = typeof source.encoding === "string" && source.encoding
        ? source.encoding
        : (kind === "binary" ? "none" : "utf-8");
    payload.truncated = source.truncated === true;
    if (Number.isFinite(source.size)) {
        payload.size = source.size;
    }
    if (typeof source.content === "string") {
        payload.content = source.content;
    }
    if (typeof source.summary === "string") {
        payload.summary = source.summary;
    }
    if (Array.isArray(source.formEntries) && source.formEntries.length) {
        payload.formEntries = source.formEntries.slice();
    }
    if (!payload.content && !payload.summary && !(Array.isArray(payload.formEntries) && payload.formEntries.length)) {
        return null;
    }
    return payload;
};

const buildStoredBodyPayloadFromHandleRecord = (source: Record<string, any>) => {
    const normalized = cloneStoredBodyPayload(source);
    if (normalized) {
        return normalized;
    }

    const synthesized = buildStoredBodyPayload({
        kind: typeof source.kind === "string" ? source.kind : undefined,
        body: typeof source.body === "string"
            ? source.body
            : (typeof source.preview === "string" ? source.preview : undefined),
        storageBody: typeof source.storageBody === "string"
            ? source.storageBody
            : (typeof source.content === "string" ? source.content : undefined),
        base64Encoded: source.base64Encoded === true || source.encoding === "base64",
        truncated: source.truncated === true,
        size: Number.isFinite(source.size) ? source.size : undefined,
        summary: typeof source.summary === "string" ? source.summary : undefined,
        formEntries: Array.isArray(source.formEntries) ? source.formEntries : undefined
    });
    if (!synthesized) {
        return null;
    }
    if (typeof source.encoding === "string" && source.encoding) {
        synthesized.encoding = source.encoding;
    }
    return synthesized;
};

const coerceHandleToString = (handle: unknown) => {
    if (typeof handle === "string") {
        return handle;
    }
    if (!handle || typeof handle !== "object") {
        return null;
    }

    try {
        const viaValueOf = (handle as { valueOf?: () => unknown }).valueOf?.();
        if (typeof viaValueOf === "string") {
            return viaValueOf;
        }
    } catch {
    }

    try {
        const viaToString = (handle as { toString?: () => string }).toString?.();
        if (typeof viaToString === "string" && viaToString && viaToString !== "[object Object]") {
            return viaToString;
        }
    } catch {
    }

    return null;
};

const getBodyForHandle = (handle: unknown) => {
    if (handle == null) {
        return null;
    }

    if (typeof handle === "object") {
        const fromHandleRecord = buildStoredBodyPayloadFromHandleRecord(handle as Record<string, any>);
        if (fromHandleRecord) {
            return fromHandleRecord;
        }
    }

    const handleText = coerceHandleToString(handle);
    if (typeof handleText !== "string") {
        return null;
    }

    const stored = buildStoredBodyPayload({
        kind: "text",
        body: handleText,
        storageBody: handleText,
        base64Encoded: false,
        truncated: false,
        size: handleText.length
    });
    return stored || null;
};

const configureNetwork = (options: { mode?: string; throttle?: unknown; clear?: boolean } | null | undefined) => {
    if (!options || typeof options !== "object") {
        return;
    }
    if (Object.prototype.hasOwnProperty.call(options, "mode")) {
        const mode = typeof options.mode === "string" ? options.mode : "";
        setNetworkLoggingMode(mode);
    }
    if (Object.prototype.hasOwnProperty.call(options, "throttle")) {
        setNetworkThrottling(options.throttle as { intervalMs?: number; maxQueuedEvents?: number } | null | undefined);
    }
    if (options.clear === true) {
        clearNetworkRecords();
    }
};

const setNetworkThrottling = (options: { intervalMs?: number; maxQueuedEvents?: number } | null | undefined) => {
    setThrottleOptions(options);
};

export {
    clearNetworkRecords,
    configureNetwork,
    getBody,
    getBodyForHandle,
    installNetworkObserver,
    recordFailure,
    recordFinish,
    recordResponse,
    recordStart,
    setNetworkLoggingMode,
    setNetworkThrottling
};
