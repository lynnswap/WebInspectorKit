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
        const stored = {...requestBody, body: requestBody.storageBody};
        if (stored.truncated) {
            stored.truncated = false;
        }
        requestBodies.set(requestId, stored);
        pruneStoredRequestBodies();
    }
    postHTTPEvent({
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
    postHTTPEvent({
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
    postHTTPEvent({
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
        const storedBody = {...responseBody};
        if (typeof responseBody.storageBody === "string") {
            storedBody.body = responseBody.storageBody;
        }
        responseBodies.set(requestId, storedBody);
        pruneStoredResponseBodies();
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
    postHTTPEvent({
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
    const batchPayload = {
        session: networkState.sessionID,
        events: pending
    };
    try {
        window.webkit.messageHandlers.webInspectorNetworkQueuedUpdate.postMessage(batchPayload);
    } catch {
    }
};

const postNetworkReset = () => {
    try {
        window.webkit.messageHandlers.webInspectorNetworkReset.postMessage({type: "reset"});
    } catch {
    }
};

const clearDisabledNetworkState = () => {
    queuedEvents.splice(0, queuedEvents.length);
};

const resetNetworkState = () => {
    queuedEvents.splice(0, queuedEvents.length);
    trackedRequests.clear();
    requestBodies.clear();
    responseBodies.clear();
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
    requestBodies.clear();
    if (networkState.resourceSeen) {
        networkState.resourceSeen.clear();
    }
    responseBodies.clear();
    queuedEvents.splice(0, queuedEvents.length);
    postNetworkReset();
};

export const installNetworkObserver = () => {
    ensureInstalled();
};

export const getResponseBody = requestId => {
    if (!responseBodies.has(requestId)) {
        return null;
    }
    const body = responseBodies.get(requestId);
    responseBodies.delete(requestId);
    return body;
};

export const getRequestBody = requestId => {
    if (!requestBodies.has(requestId)) {
        return null;
    }
    const body = requestBodies.get(requestId);
    requestBodies.delete(requestId);
    return body;
};
