// Network agent core logic
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


const installFetchPatch = () => {
    if (typeof window.fetch !== "function") {
        return;
    }
    const nativeFetch = window.fetch;
    if (nativeFetch.__wiNetworkPatched) {
        return;
    }
    const patched = async function() {
        const shouldTrack = true;
        const args = Array.from(arguments);
        const [input, init = {}] = args;
        const method = init.method || (input && input.method) || "GET";
        const identity = shouldTrack ? nextRequestIdentity() : null;
        const url = typeof input === "string" ? input : (input && input.url) || "";
        if (shouldIgnoreUrl(url)) {
            return nativeFetch.apply(window, args);
        }
        const headers = normalizeHeaders(init.headers || (input && input.headers));
        const requestBodyInfo = serializeRequestBody(init.body);

        if (shouldTrack && identity) {
            recordStart(
                identity,
                url,
                String(method).toUpperCase(),
                headers,
                "fetch",
                undefined,
                undefined,
                requestBodyInfo
            );
        }

        try {
            const response = await nativeFetch.apply(window, args);
            let mimeType;
            let responseBodyInfo = null;
            if (shouldTrack && identity) {
                mimeType = recordResponse(identity, response, "fetch");
                try {
                    responseBodyInfo = await captureResponseBody(response, mimeType);
                } catch {
                    responseBodyInfo = null;
                }
                const encodedLength = estimatedEncodedLength(
                    captureContentLength(response),
                    responseBodyInfo
                );
                recordFinish(
                    identity,
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
            if (shouldTrack && identity) {
                recordFailure(identity, error, "fetch");
            }
            throw error;
        }
    };
    patched.__wiNetworkPatched = true;
    window.fetch = patched;
};

const installXHRPatch = () => {
    if (typeof XMLHttpRequest !== "function") {
        return;
    }
    const originalOpen = XMLHttpRequest.prototype.open;
    const originalSend = XMLHttpRequest.prototype.send;
    const originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;

    if (originalOpen.__wiNetworkPatched) {
        return;
    }

    XMLHttpRequest.prototype.open = function(method, url) {
        this.__wiNetwork = {
            method: String(method || "GET").toUpperCase(),
            url: String(url || ""),
            headers: {}
        };
        return originalOpen.apply(this, arguments);
    };

    XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
        if (this.__wiNetwork) {
            this.__wiNetwork.headers[String(name || "").toLowerCase()] = String(value || "");
        }
        return originalSetRequestHeader.apply(this, arguments);
    };

    XMLHttpRequest.prototype.send = function() {
        const shouldTrack = !!this.__wiNetwork;
        const identity = shouldTrack ? nextRequestIdentity() : null;
        const info = this.__wiNetwork;
        if (shouldTrack && identity && info) {
            if (shouldIgnoreUrl(info.url)) {
                return originalSend.apply(this, arguments);
            }
            info.requestBody = serializeRequestBody(arguments[0]);
            recordStart(
                identity,
                info.url,
                info.method,
                info.headers || {},
                "xhr",
                undefined,
                undefined,
                info.requestBody
            );
            this.addEventListener("readystatechange", function() {
                if (this.readyState === 2 && identity) {
                    recordResponse(identity, this, "xhr");
                }
            }, false);
            this.addEventListener("load", function() {
                if (identity) {
                    const responseBody = captureXHRResponseBody(this);
                    const length = estimatedEncodedLength(
                        captureContentLength(this),
                        responseBody
                    );
                    recordFinish(
                        identity,
                        length,
                        "xhr",
                        this.status,
                        this.statusText,
                        this.getResponseHeader ? this.getResponseHeader("content-type") : undefined,
                        undefined,
                        undefined,
                        responseBody
                    );
                }
            }, false);
            this.addEventListener("error", function(event) {
                if (identity) {
                    recordFailure(identity, event && event.error ? event.error : "Network error", "xhr");
                }
            }, false);
            this.addEventListener("abort", function() {
                if (identity) {
                    recordFailure(identity, "Request aborted", "xhr");
                }
            }, false);
        }
        return originalSend.apply(this, arguments);
    };

    originalOpen.__wiNetworkPatched = true;
};

const installResourceObserver = () => {
    if (networkState.resourceObserver || typeof PerformanceObserver !== "function") {
        return;
    }
    try {
        const observer = new PerformanceObserver(list => {
            const entries = list.getEntries();
            const payloads = [];
            for (let i = 0; i < entries.length; ++i) {
                const payload = handleResourceEntry(entries[i]);
                if (payload) {
                    payloads.push(payload);
                }
            }
            if (payloads.length) {
                postNetworkBatchEvents(payloads);
            }
        });
        observer.observe({type: "resource", buffered: true});
        networkState.resourceObserver = observer;
        if (!networkState.resourceSeen) {
            networkState.resourceSeen = new Set();
        }
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
