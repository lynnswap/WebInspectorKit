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
        const shouldTrack = shouldTrackNetworkEvents();
        const args = Array.from(arguments);
        const [input, init = {}] = args;
        const method = init.method || (input && input.method) || "GET";
        const requestId = shouldTrack ? nextRequestID() : null;
        const url = typeof input === "string" ? input : (input && input.url) || "";
        const headers = normalizeHeaders(init.headers || (input && input.headers));
        const requestBodyInfo = serializeRequestBody(init.body);

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
            const response = await nativeFetch.apply(window, args);
            let mimeType;
            let responseBodyInfo = null;
            if (shouldTrack && requestId != null) {
                mimeType = recordResponse(requestId, response, "fetch");
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
        const shouldTrack = shouldTrackNetworkEvents() && !!this.__wiNetwork;
        const requestId = shouldTrack ? nextRequestID() : null;
        const info = this.__wiNetwork;
        if (shouldTrack && requestId != null && info) {
            info.requestBody = serializeRequestBody(arguments[0]);
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
            this.addEventListener("readystatechange", function() {
                if (this.readyState === 2 && requestId != null) {
                    recordResponse(requestId, this, "xhr");
                }
            }, false);
            this.addEventListener("load", function() {
                if (requestId != null) {
                    const responseBody = captureXHRResponseBody(this);
                    const length = estimatedEncodedLength(
                        captureContentLength(this),
                        responseBody
                    );
                    recordFinish(
                        requestId,
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
                if (requestId != null) {
                    recordFailure(requestId, event && event.error ? event.error : "Network error", "xhr");
                }
            }, false);
            this.addEventListener("abort", function() {
                if (requestId != null) {
                    recordFailure(requestId, "Request aborted", "xhr", {isCanceled: true});
                }
            }, false);
            this.addEventListener("timeout", function() {
                if (requestId != null) {
                    recordFailure(requestId, "Request timeout", "xhr", {isTimeout: true});
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
            networkState.resourceSeen = new Set();
        }
    } catch {
    }
};
