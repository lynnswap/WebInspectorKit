// HTTP instrumentation: fetch, XHR, and resource timing.

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
        const headers = normalizeHeaders(init.headers || (input && input.headers));
        const requestBodyInfo = serializeRequestBody(init.body);

        if (shouldTrack && identity) {
            postHTTPEvent({
                type: "start",
                session: identity.session,
                requestId: identity.requestId,
                url: url,
                method: String(method).toUpperCase(),
                requestHeaders: headers,
                startTime: now(),
                wallTime: wallTime(),
                requestType: "fetch",
                requestBody: requestBodyInfo ? requestBodyInfo.body : undefined,
                requestBodyBase64: requestBodyInfo ? requestBodyInfo.base64Encoded : undefined,
                requestBodySize: requestBodyInfo ? requestBodyInfo.size : undefined,
                requestBodyTruncated: requestBodyInfo ? requestBodyInfo.truncated : undefined,
                requestBodyBytesSent: requestBodyInfo ? requestBodyInfo.size : undefined
            });
        }

        try {
            const response = await nativeFetch.apply(window, args);
            let mimeType;
            let responseBodyInfo = null;
            if (shouldTrack && identity) {
                mimeType = recordResponse(identity, response, "fetch");
                postHTTPEvent({
                    type: "responseExtra",
                    session: identity.session,
                    requestId: identity.requestId,
                    responseHeaders: normalizeHeaders(response.headers),
                    blockedCookies: [],
                    wallTime: wallTime()
                });
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
            info.requestBody = serializeRequestBody(arguments[0]);
            postHTTPEvent({
                type: "start",
                session: identity.session,
                requestId: identity.requestId,
                url: info.url,
                method: info.method,
                requestHeaders: info.headers || {},
                startTime: now(),
                wallTime: wallTime(),
                requestType: "xhr",
                requestBody: info.requestBody ? info.requestBody.body : undefined,
                requestBodyBase64: info.requestBody ? info.requestBody.base64Encoded : undefined,
                requestBodySize: info.requestBody ? info.requestBody.size : undefined,
                requestBodyTruncated: info.requestBody ? info.requestBody.truncated : undefined,
                requestBodyBytesSent: info.requestBody ? info.requestBody.size : undefined
            });
            this.addEventListener("readystatechange", function() {
                if (this.readyState === 2 && identity) {
                    recordResponse(identity, this, "xhr");
                    postHTTPEvent({
                        type: "responseExtra",
                        session: identity.session,
                        requestId: identity.requestId,
                        responseHeaders: parseRawHeaders(this.getAllResponseHeaders && this.getAllResponseHeaders()),
                        blockedCookies: [],
                        wallTime: wallTime()
                    });
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
                postHTTPBatchEvents(payloads);
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
