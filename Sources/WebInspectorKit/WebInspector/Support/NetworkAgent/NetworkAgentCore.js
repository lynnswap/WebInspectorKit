// Core orchestrator: shared helpers live in NetworkAgentUtils.js
// This file keeps recording logic and wires sub-patches.

const recordStart = (
    requestId,
    url,
    method,
    requestHeaders,
    requestType,
    startTimeOverride,
    wallTimeOverride,
    requestBody
) => {
    const startTime = typeof startTimeOverride === "number" ? startTimeOverride : now();
    const wall = typeof wallTimeOverride === "number" ? wallTimeOverride : wallTime();
    trackedRequests.set(requestId, {startTime: startTime, wallTime: wall});
    if (requestBody && typeof requestBody.storageBody === "string") {
        bodyCache.store("request", requestId, requestBody);
    }
    enqueueNetworkEvent({
        type: "start",
        session: networkState.sessionID,
        requestId: requestId,
        url: url,
        method: method,
        requestHeaders: requestHeaders || {},
        startTime: startTime,
        wallTime: wall,
        requestType: requestType,
        requestBody: inlineBodyPayload(requestBody),
        requestBodyBytesSent: requestBody ? requestBody.size : undefined
    });
};

const recordResponse = (requestId, response, requestType) => {
    let mimeType = "";
    let headers = {};
    try {
        if (response && response.headers) {
            mimeType = response.headers.get("content-type") || "";
            headers = normalizeHeaders(response.headers);
        }
        if (!mimeType && response && typeof response.getResponseHeader === "function") {
            mimeType = response.getResponseHeader("content-type") || "";
        }
        if ((!headers || !Object.keys(headers).length) && response && typeof response.getAllResponseHeaders === "function") {
            headers = parseRawHeaders(response.getAllResponseHeaders());
        }
    } catch {
        mimeType = "";
        headers = {};
    }
    const time = now();
    const wall = wallTime();
    const status = typeof response === "object" && response !== null && typeof response.status === "number" ? response.status : undefined;
    const statusText = typeof response === "object" && response !== null && typeof response.statusText === "string" ? response.statusText : "";
    enqueueNetworkEvent({
        type: "response",
        session: networkState.sessionID,
        requestId: requestId,
        status: status,
        statusText: statusText,
        mimeType: mimeType,
        responseHeaders: headers,
        endTime: time,
        wallTime: wall,
        requestType: requestType
    });
    return mimeType;
};

const recordFinish = (
    requestId,
    encodedBodyLength,
    requestType,
    status,
    statusText,
    mimeType,
    endTimeOverride,
    wallTimeOverride,
    responseBody
) => {
    const time = typeof endTimeOverride === "number" ? endTimeOverride : now();
    const wall = typeof wallTimeOverride === "number" ? wallTimeOverride : wallTime();
    enqueueNetworkEvent({
        type: "finish",
        session: networkState.sessionID,
        requestId: requestId,
        endTime: time,
        wallTime: wall,
        encodedBodyLength: encodedBodyLength,
        requestType: requestType,
        status: status,
        statusText: statusText,
        mimeType: mimeType,
        decodedBodySize: responseBody ? responseBody.size : undefined,
        responseBody: inlineBodyPayload(responseBody)
    });
    trackedRequests.delete(requestId);
    if (responseBody) {
        bodyCache.store("response", requestId, responseBody);
    }
};

const recordFailure = (requestId, error, requestType) => {
    const time = now();
    const wall = wallTime();
    let description = "";
    if (error && typeof error.message === "string" && error.message) {
        description = error.message;
    } else if (error) {
        description = String(error);
    }
    enqueueNetworkEvent({
        type: "fail",
        session: networkState.sessionID,
        requestId: requestId,
        endTime: time,
        wallTime: wall,
        error: description,
        requestType: requestType
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
    deliverNetworkEvents([{
        type: "reset",
        session: networkState.sessionID
    }]);
};

const clearDisabledNetworkState = () => {
    queuedEvents.splice(0, queuedEvents.length);
    clearThrottledEvents();
};

const resetNetworkState = () => {
    queuedEvents.splice(0, queuedEvents.length);
    trackedRequests.clear();
    bodyCache.clear();
    clearThrottledEvents();
    if (networkState.resourceSeen) {
        networkState.resourceSeen.clear();
    }
    networkState.sessionID = generateSessionID();
    networkState.nextId = 1;
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

const normalizeLoggingMode = mode => {
    if (mode === NetworkLoggingMode.BUFFERING) {
        return NetworkLoggingMode.BUFFERING;
    }
    if (mode === NetworkLoggingMode.STOPPED) {
        return NetworkLoggingMode.STOPPED;
    }
    return NetworkLoggingMode.ACTIVE;
};

export const setNetworkLoggingMode = mode => {
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

export const clearNetworkRecords = () => {
    trackedRequests.clear();
    if (networkState.resourceSeen) {
        networkState.resourceSeen.clear();
    }
    bodyCache.clear();
    clearThrottledEvents();
    queuedEvents.splice(0, queuedEvents.length);
    postNetworkReset();
};

export const installNetworkObserver = () => {
    ensureInstalled();
};

export const getResponseBody = requestId => {
    return bodyCache.take("response", requestId);
};

export const getRequestBody = requestId => {
    return bodyCache.take("request", requestId);
};

export const setNetworkThrottling = options => {
    setThrottleOptions(options);
};
