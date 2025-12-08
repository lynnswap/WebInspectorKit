// Core orchestrator: shared helpers live in NetworkAgentShared.js
// This file keeps recording logic and wires sub-patches.

const recordStart = (
    identity,
    url,
    method,
    requestHeaders,
    requestType,
    startTimeOverride,
    wallTimeOverride,
    requestBody
) => {
    if (!identity) {
        return;
    }
    const startTime = typeof startTimeOverride === "number" ? startTimeOverride : now();
    const wall = typeof wallTimeOverride === "number" ? wallTimeOverride : wallTime();
    const key = trackingKey(identity);
    if (key) {
        trackedRequests.set(key, {startTime: startTime, wallTime: wall});
    }
    postNetworkEvent({
        type: "start",
        session: identity.session,
        requestId: identity.requestId,
        url: url,
        method: method,
        requestHeaders: requestHeaders || {},
        startTime: startTime,
        wallTime: wall,
        requestType: requestType,
        requestBody: requestBody ? requestBody.body : undefined,
        requestBodyBase64: requestBody ? requestBody.base64Encoded : undefined,
        requestBodySize: requestBody ? requestBody.size : undefined,
        requestBodyTruncated: requestBody ? requestBody.truncated : undefined
    });
};

const recordResponse = (identity, response, requestType) => {
    if (!identity) {
        return;
    }
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
    postNetworkEvent({
        type: "response",
        session: identity.session,
        requestId: identity.requestId,
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
    identity,
    encodedBodyLength,
    requestType,
    status,
    statusText,
    mimeType,
    endTimeOverride,
    wallTimeOverride,
    responseBody
) => {
    if (!identity) {
        return;
    }
    const time = typeof endTimeOverride === "number" ? endTimeOverride : now();
    const wall = typeof wallTimeOverride === "number" ? wallTimeOverride : wallTime();
    postNetworkEvent({
        type: "finish",
        session: identity.session,
        requestId: identity.requestId,
        endTime: time,
        wallTime: wall,
        encodedBodyLength: encodedBodyLength,
        requestType: requestType,
        status: status,
        statusText: statusText,
        mimeType: mimeType,
        responseBody: responseBody ? responseBody.body : undefined,
        responseBodyBase64: responseBody ? responseBody.base64Encoded : undefined,
        responseBodySize: responseBody ? responseBody.size : undefined,
        responseBodyTruncated: responseBody ? responseBody.truncated : undefined
    });
    const key = trackingKey(identity);
    if (key) {
        trackedRequests.delete(key);
    }
    const bodyKey = trackingKey(identity);
    if (bodyKey && responseBody && typeof responseBody.body === "string") {
        responseBodies.set(bodyKey, {
            base64Encoded: !!responseBody.base64Encoded,
            body: responseBody.body
        });
    }
};

const recordFailure = (identity, error, requestType) => {
    if (!identity) {
        return;
    }
    const time = now();
    const wall = wallTime();
    let description = "";
    if (error && typeof error.message === "string" && error.message) {
        description = error.message;
    } else if (error) {
        description = String(error);
    }
    postNetworkEvent({
        type: "fail",
        session: identity.session,
        requestId: identity.requestId,
        endTime: time,
        wallTime: wall,
        error: description,
        requestType: requestType
    });
    const key = trackingKey(identity);
    if (key) {
        trackedRequests.delete(key);
    }
};

const ensureInstalled = () => {
    if (networkState.installed) {
        return;
    }
    installFetchPatch();
    installXHRPatch();
    installResourceObserver();
    installWebSocketPatch();
    networkState.installed = true;
};

export const setNetworkLoggingEnabled = enabled => {
    const wasEnabled = networkState.enabled;
    networkState.enabled = !!enabled;
    if (networkState.enabled && !wasEnabled) {
        flushQueuedEvents();
    }
};

export const clearNetworkRecords = () => {
    trackedRequests.clear();
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

export const getResponseBody = (requestId, session) => {
    const key = (session || networkState.sessionPrefix) + "::" + String(requestId);
    if (!responseBodies.has(key)) {
        return null;
    }
    return responseBodies.get(key);
};
