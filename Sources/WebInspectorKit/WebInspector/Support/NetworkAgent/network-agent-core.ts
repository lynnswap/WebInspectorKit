// Core orchestrator: shared helpers live in NetworkAgentUtils.ts
// This file keeps recording logic and wires sub-patches.

const buildNetworkError = (error, requestType, options: { isCanceled?: boolean; isTimeout?: boolean } = {}) => {
    let message = "";
    if (error && typeof error.message === "string" && error.message) {
        message = error.message;
    } else if (typeof error === "string" && error) {
        message = error;
    } else if (error) {
        message = String(error);
    } else {
        message = "Network error";
    }

    let code = null;
    if (error && typeof error.name === "string" && error.name) {
        code = error.name;
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

const storeBodyForRole = (role, requestId, bodyInfo) => {
    const stored = buildStoredBodyPayload(bodyInfo);
    if (!stored) {
        return null;
    }
    const ref = makeBodyRef(role, requestId);
    if (!bodyCache.store(ref, stored)) {
        return null;
    }
    return ref;
};

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
    const time = makeNetworkTime(startTimeOverride, wallTimeOverride);
    trackedRequests.set(requestId, {startTime: time.monotonicMs, wallTime: time.wallMs});
    const bodyRef = storeBodyForRole("req", requestId, requestBody);
    enqueueNetworkEvent({
        kind: "requestWillBeSent",
        requestId: requestId,
        time: time,
        url: url,
        method: method,
        headers: requestHeaders || {},
        initiator: requestType,
        body: makeBodyPreviewPayload(requestBody, bodyRef),
        bodySize: requestBody ? requestBody.size : undefined
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
    const time = makeNetworkTime(endTimeOverride, wallTimeOverride);
    const bodyRef = storeBodyForRole("res", requestId, responseBody);
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
        body: makeBodyPreviewPayload(responseBody, bodyRef)
    });
    trackedRequests.delete(requestId);
};

const recordFailure = (requestId, error, requestType, options: { isCanceled?: boolean; isTimeout?: boolean } = {}) => {
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
        window.webkit.messageHandlers.webInspectorNetworkReset.postMessage({
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
    if (networkState.resourceSeen) {
        networkState.resourceSeen.clear();
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

const normalizeLoggingMode = mode => {
    if (mode === NetworkLoggingMode.BUFFERING) {
        return NetworkLoggingMode.BUFFERING;
    }
    if (mode === NetworkLoggingMode.STOPPED) {
        return NetworkLoggingMode.STOPPED;
    }
    return NetworkLoggingMode.ACTIVE;
};

const setNetworkLoggingMode = mode => {
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
    if (networkState.resourceSeen) {
        networkState.resourceSeen.clear();
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

const getBody = ref => {
    if (!ref || typeof ref !== "string") {
        return null;
    }
    return bodyCache.take(ref);
};

const configureNetwork = options => {
    if (!options || typeof options !== "object") {
        return;
    }
    if (Object.prototype.hasOwnProperty.call(options, "mode")) {
        setNetworkLoggingMode(options.mode);
    }
    if (Object.prototype.hasOwnProperty.call(options, "throttle")) {
        setNetworkThrottling(options.throttle);
    }
    if (options.clear === true) {
        clearNetworkRecords();
    }
};

const setNetworkThrottling = options => {
    setThrottleOptions(options);
};

export {
    clearNetworkRecords,
    configureNetwork,
    getBody,
    installNetworkObserver,
    setNetworkLoggingMode,
    setNetworkThrottling
};
