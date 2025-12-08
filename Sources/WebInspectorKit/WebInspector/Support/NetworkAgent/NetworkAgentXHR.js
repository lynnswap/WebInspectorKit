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
                requestBodyTruncated: info.requestBody ? info.requestBody.truncated : undefined
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
