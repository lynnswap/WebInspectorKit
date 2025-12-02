const networkState = {
    enabled: true,
    installed: false,
    nextId: 1
};

const trackedRequests = new Map();

function now() {
    if (typeof performance !== "undefined" && typeof performance.now === "function") {
        return performance.now();
    }
    return Date.now();
}

function wallTime() {
    return Date.now();
}

function nextRequestId() {
    var id = networkState.nextId++;
    return "net_" + id.toString(36);
}

function safePostMessage(payload) {
    if (!networkState.enabled && payload.type !== "reset") {
        return;
    }
    try {
        window.webkit.messageHandlers.webInspectorNetworkUpdate.postMessage(payload);
    } catch {
    }
}

function normalizeHeaders(headers) {
    var result = {};
    if (!headers) {
        return result;
    }
    try {
        if (typeof Headers !== "undefined" && headers instanceof Headers && headers.forEach) {
            headers.forEach(function(value, key) {
                result[String(key).toLowerCase()] = String(value);
            });
            return result;
        }
        if (Array.isArray(headers)) {
            headers.forEach(function(entry) {
                if (Array.isArray(entry) && entry.length >= 2) {
                    var name = String(entry[0] || "").toLowerCase();
                    var value = String(entry[1] || "");
                    result[name] = value;
                }
            });
            return result;
        }
        if (typeof headers === "object") {
            Object.keys(headers).forEach(function(key) {
                result[String(key).toLowerCase()] = String(headers[key]);
            });
        }
    } catch {
    }
    return result;
}

function parseRawHeaders(raw) {
    var headers = {};
    if (!raw || typeof raw !== "string") {
        return headers;
    }
    raw.split(/\r?\n/).forEach(function(line) {
        var index = line.indexOf(":");
        if (index <= 0) {
            return;
        }
        var name = line.slice(0, index).trim().toLowerCase();
        var value = line.slice(index + 1).trim();
        if (name) {
            headers[name] = value;
        }
    });
    return headers;
}

function recordStart(requestId, url, method, requestHeaders, requestType) {
    var startTime = now();
    var wall = wallTime();
    trackedRequests.set(requestId, {startTime: startTime, wallTime: wall});
    safePostMessage({
        type: "start",
        id: requestId,
        url: url,
        method: method,
        requestHeaders: requestHeaders || {},
        startTime: startTime,
        wallTime: wall,
        requestType: requestType
    });
}

function recordResponse(requestId, response, requestType) {
    var mimeType = "";
    var headers = {};
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
    var time = now();
    var wall = wallTime();
    var status = typeof response === "object" && response !== null && typeof response.status === "number" ? response.status : undefined;
    var statusText = typeof response === "object" && response !== null && typeof response.statusText === "string" ? response.statusText : "";
    safePostMessage({
        type: "response",
        id: requestId,
        status: status,
        statusText: statusText,
        mimeType: mimeType,
        responseHeaders: headers,
        endTime: time,
        wallTime: wall,
        requestType: requestType
    });
}

function recordFinish(requestId, encodedBodyLength, requestType) {
    var time = now();
    var wall = wallTime();
    safePostMessage({
        type: "finish",
        id: requestId,
        endTime: time,
        wallTime: wall,
        encodedBodyLength: encodedBodyLength,
        requestType: requestType
    });
    trackedRequests.delete(requestId);
}

function recordFailure(requestId, error, requestType) {
    var time = now();
    var wall = wallTime();
    var description = "";
    if (error && typeof error.message === "string" && error.message) {
        description = error.message;
    } else if (error) {
        description = String(error);
    }
    safePostMessage({
        type: "fail",
        id: requestId,
        endTime: time,
        wallTime: wall,
        error: description,
        requestType: requestType
    });
    trackedRequests.delete(requestId);
}

function captureContentLength(response) {
    try {
        var value = null;
        if (response && response.headers && typeof response.headers.get === "function") {
            value = response.headers.get("content-length");
        } else if (response && typeof response.getResponseHeader === "function") {
            value = response.getResponseHeader("content-length");
        }
        if (!value) {
            return undefined;
        }
        var length = parseInt(value, 10);
        if (Number.isFinite(length) && length >= 0) {
            return length;
        }
    } catch {
    }
    return undefined;
}

function installFetchPatch() {
    if (typeof window.fetch !== "function") {
        return;
    }
    var nativeFetch = window.fetch;
    if (nativeFetch.__wiNetworkPatched) {
        return;
    }
    var patched = function() {
        var shouldTrack = networkState.enabled;
        var args = Array.prototype.slice.call(arguments);
        var input = args[0];
        var init = args[1] || {};
        var method = init.method || (input && input.method) || "GET";
        var requestId = shouldTrack ? nextRequestId() : null;
        var url = typeof input === "string" ? input : (input && input.url) || "";
        var headers = normalizeHeaders(init.headers || (input && input.headers));

        if (shouldTrack && requestId) {
            recordStart(requestId, url, String(method).toUpperCase(), headers, "fetch");
        }

        return nativeFetch.apply(window, args).then(function(response) {
            if (shouldTrack && requestId) {
                recordResponse(requestId, response, "fetch");
                var encodedLength = captureContentLength(response);
                recordFinish(requestId, encodedLength, "fetch");
            }
            return response;
        }).catch(function(error) {
            if (shouldTrack && requestId) {
                recordFailure(requestId, error, "fetch");
            }
            throw error;
        });
    };
    patched.__wiNetworkPatched = true;
    window.fetch = patched;
}

function installXHRPatch() {
    if (typeof XMLHttpRequest !== "function") {
        return;
    }
    var originalOpen = XMLHttpRequest.prototype.open;
    var originalSend = XMLHttpRequest.prototype.send;
    var originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;

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
        var shouldTrack = networkState.enabled && !!this.__wiNetwork;
        var requestId = shouldTrack ? nextRequestId() : null;
        var info = this.__wiNetwork;
        if (shouldTrack && requestId && info) {
            recordStart(requestId, info.url, info.method, info.headers || {}, "xhr");
            this.addEventListener("readystatechange", function() {
                if (this.readyState === 2 && requestId) {
                    recordResponse(requestId, this, "xhr");
                }
            }, false);
            this.addEventListener("load", function() {
                if (requestId) {
                    var length = captureContentLength(this);
                    recordFinish(requestId, length, "xhr");
                }
            }, false);
            this.addEventListener("error", function(event) {
                if (requestId) {
                    recordFailure(requestId, event && event.error ? event.error : "Network error", "xhr");
                }
            }, false);
            this.addEventListener("abort", function() {
                if (requestId) {
                    recordFailure(requestId, "Request aborted", "xhr");
                }
            }, false);
        }
        return originalSend.apply(this, arguments);
    };

    originalOpen.__wiNetworkPatched = true;
}

function ensureInstalled() {
    if (networkState.installed) {
        return;
    }
    installFetchPatch();
    installXHRPatch();
    networkState.installed = true;
}

export function setNetworkLoggingEnabled(enabled) {
    networkState.enabled = !!enabled;
}

export function clearNetworkRecords() {
    trackedRequests.clear();
    safePostMessage({type: "reset"});
}

export function installNetworkObserver() {
    ensureInstalled();
}
