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

const isRootFrame = (() => {
    try {
        return window === window.top;
    } catch {
        return true;
    }
})();

networkState.isRootFrame = isRootFrame;

const rootState = (() => {
    try {
        if (window.top) {
            if (!window.top.__wiNetworkRootState) {
                window.top.__wiNetworkRootState = {
                    enabled: networkState.enabled,
                    lastClearId: networkState.lastClearId
                };
            }
            return window.top.__wiNetworkRootState;
        }
    } catch {
    }
    return null;
})();

const applyRootStateSnapshot = () => {
    if (!rootState || networkState.isRootFrame) {
        return;
    }
    if (typeof rootState.enabled === "boolean") {
        networkState.enabled = rootState.enabled;
    }
    if (rootState.lastClearId != null) {
        networkState.lastClearId = rootState.lastClearId;
    }
};

const broadcastToChildren = payload => {
    if (!networkState.isRootFrame) {
        return;
    }
    try {
        const frames = window.frames || [];
        for (let i = 0; i < frames.length; ++i) {
            try {
                frames[i].postMessage({...payload, __wiNetworkFromRoot: true}, "*");
            } catch {
            }
        }
    } catch {
    }
};

const requestInitialSync = () => {
    if (networkState.isRootFrame) {
        return;
    }
    try {
        if (window.parent && typeof window.parent.postMessage === "function") {
            window.parent.postMessage({__wiNetworkSyncRequest: true}, "*");
        }
    } catch {
    }
};

const setNetworkLoggingEnabledInternal = (enabled, {propagate = true, updateRoot = true} = {}) => {
    const wasEnabled = networkState.enabled;
    networkState.enabled = !!enabled;
    if (updateRoot && rootState) {
        rootState.enabled = networkState.enabled;
    }
    if (propagate) {
        broadcastToChildren({__wiNetworkLoggingEnabled: networkState.enabled});
    }
    if (networkState.enabled && !wasEnabled) {
        flushQueuedEvents();
    }
};

const clearNetworkRecordsInternal = (clearId, {propagate = true, updateRoot = true} = {}) => {
    if (clearId != null && networkState.lastClearId === clearId) {
        return;
    }
    const appliedClearId = clearId != null ? clearId : generateSessionID();
    networkState.lastClearId = appliedClearId;
    if (updateRoot && rootState) {
        rootState.lastClearId = appliedClearId;
    }
    trackedRequests.clear();
    requestBodies.clear();
    if (networkState.resourceSeen) {
        networkState.resourceSeen.clear();
    }
    responseBodies.clear();
    queuedEvents.splice(0, queuedEvents.length);
    postNetworkReset();
    if (propagate) {
        broadcastToChildren({__wiNetworkClearRecords: true, __wiNetworkClearId: appliedClearId});
    }
};

const installLoggingToggleListener = () => {
    if (networkState.loggingListenerInstalled) {
        return;
    }
    try {
        window.addEventListener("message", event => {
            if (!event || !event.data || typeof event.data !== "object") {
                return;
            }
            const data = event.data;
            if (typeof data.__wiNetworkLoggingEnabled === "boolean") {
                setNetworkLoggingEnabledInternal(data.__wiNetworkLoggingEnabled, {propagate: false, updateRoot: false});
            }
            if (data.__wiNetworkClearRecords === true) {
                clearNetworkRecordsInternal(data.__wiNetworkClearId, {propagate: false, updateRoot: false});
            }
            if (data.__wiNetworkSyncRequest === true && networkState.isRootFrame && event.source && typeof event.source.postMessage === "function") {
                try {
                    event.source.postMessage({
                        __wiNetworkFromRoot: true,
                        __wiNetworkLoggingEnabled: rootState ? rootState.enabled : networkState.enabled,
                        __wiNetworkClearRecords: rootState && rootState.lastClearId != null ? true : false,
                        __wiNetworkClearId: rootState ? rootState.lastClearId : networkState.lastClearId
                    }, "*");
                } catch {
                }
            }
        });
        networkState.loggingListenerInstalled = true;
    } catch {
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
    installLoggingToggleListener();
    requestInitialSync();
    networkState.installed = true;
};

applyRootStateSnapshot();

export const setNetworkLoggingEnabled = enabled => {
    setNetworkLoggingEnabledInternal(enabled, {propagate: true, updateRoot: true});
};

export const clearNetworkRecords = () => {
    clearNetworkRecordsInternal(null, {propagate: true, updateRoot: true});
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
