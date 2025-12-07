const now = () => {
    if (typeof performance !== "undefined" && typeof performance.now === "function") {
        return performance.now();
    }
    return Date.now();
};

const wallTime = () => Date.now();

const generateSessionPrefix = () => {
    try {
        if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
            return crypto.randomUUID();
        }
    } catch {
    }
    const time = Date.now().toString(36);
    const random = Math.random().toString(36).slice(2, 10);
    return time + "-" + random;
};

const networkState = {
    enabled: true,
    installed: false,
    nextId: 1,
    sessionPrefix: generateSessionPrefix(),
    resourceObserver: null,
    resourceSeen: null
};

const trackedRequests = new Map();
const trackedResourceTypes = new Set([
    "img",
    "image",
    "media",
    "video",
    "audio",
    "beacon",
    "font",
    "script",
    "link",
    "style",
    "css",
    "preload",
    "prefetch",
    "iframe",
    "frame",
    "embed",
    "object",
    "track",
    "manifest"
]);

const nextRequestIdentity = () => {
    const requestId = networkState.nextId;
    networkState.nextId += 1;
    return {
        requestId: requestId,
        session: networkState.sessionPrefix
    };
};

const trackingKey = identity => {
    if (!identity) {
        return null;
    }
    const idPart = typeof identity.requestId === "number" ? identity.requestId : identity.id;
    if (identity.session && idPart != null) {
        return identity.session + "::" + idPart;
    }
    return idPart != null ? String(idPart) : null;
};

const postNetworkEvent = payload => {
    if (!networkState.enabled) {
        return;
    }
    try {
        window.webkit.messageHandlers.webInspectorNetworkUpdate.postMessage(payload);
    } catch {
    }
};

const postNetworkReset = () => {
    try {
        window.webkit.messageHandlers.webInspectorNetworkReset.postMessage({type: "reset"});
    } catch {
    }
};

const normalizeHeaders = headers => {
    const result = {};
    if (!headers) {
        return result;
    }
    try {
        if (typeof Headers !== "undefined" && headers instanceof Headers && headers.forEach) {
            headers.forEach((value, key) => {
                result[String(key).toLowerCase()] = String(value);
            });
            return result;
        }
        if (Array.isArray(headers)) {
            headers.forEach(entry => {
                if (Array.isArray(entry) && entry.length >= 2) {
                    const name = String(entry[0] || "").toLowerCase();
                    const value = String(entry[1] || "");
                    result[name] = value;
                }
            });
            return result;
        }
        if (typeof headers === "object") {
            Object.keys(headers).forEach(key => {
                result[String(key).toLowerCase()] = String(headers[key]);
            });
        }
    } catch {
    }
    return result;
};

const parseRawHeaders = raw => {
    const headers = {};
    if (!raw || typeof raw !== "string") {
        return headers;
    }
    raw.split(/\r?\n/).forEach(line => {
        const index = line.indexOf(":");
        if (index <= 0) {
            return;
        }
        const name = line.slice(0, index).trim().toLowerCase();
        const value = line.slice(index + 1).trim();
        if (name) {
            headers[name] = value;
        }
    });
    return headers;
};

const recordStart = (identity, url, method, requestHeaders, requestType, startTimeOverride, wallTimeOverride) => {
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
        requestType: requestType
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
};

const recordFinish = (
    identity,
    encodedBodyLength,
    requestType,
    status,
    statusText,
    mimeType,
    endTimeOverride,
    wallTimeOverride
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
        mimeType: mimeType
    });
    const key = trackingKey(identity);
    if (key) {
        trackedRequests.delete(key);
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

const captureContentLength = response => {
    try {
        let value = null;
        if (response && response.headers && typeof response.headers.get === "function") {
            value = response.headers.get("content-length");
        } else if (response && typeof response.getResponseHeader === "function") {
            value = response.getResponseHeader("content-length");
        }
        if (!value) {
            return undefined;
        }
        const length = parseInt(value, 10);
        if (Number.isFinite(length) && length >= 0) {
            return length;
        }
    } catch {
    }
    return undefined;
};

const shouldTrackResourceEntry = entry => {
    if (!entry) {
        return false;
    }
    const initiator = String(entry.initiatorType || "").toLowerCase();
    if (!initiator) {
        return false;
    }
    if (initiator === "fetch" || initiator === "xmlhttprequest") {
        return false;
    }
    if (trackedResourceTypes.has(initiator)) {
        return true;
    }
    if (initiator === "other") {
        if (typeof entry.name === "string") {
            const lower = entry.name.toLowerCase();
            if (lower.endsWith(".mp4") || lower.endsWith(".webm") || lower.endsWith(".mov") || lower.endsWith(".m4v")) {
                return true;
            }
        }
    }
    return false;
};

const handleResourceEntry = entry => {
    if (!networkState.enabled) {
        return;
    }
    if (!shouldTrackResourceEntry(entry)) {
        return;
    }
    if (!networkState.resourceSeen) {
        networkState.resourceSeen = new Set();
    }
    const key = String(entry.name || "") + "::" + entry.startTime;
    if (networkState.resourceSeen.has(key)) {
        return;
    }
    networkState.resourceSeen.add(key);

    const identity = nextRequestIdentity();
    const startTime = typeof entry.startTime === "number" ? entry.startTime : now();
    const requestType = entry.initiatorType || "resource";
    recordStart(identity, entry.name || "", "GET", {}, requestType, startTime, wallTime());

    let encoded = entry.transferSize;
    if (!(Number.isFinite(encoded) && encoded >= 0)) {
        encoded = entry.encodedBodySize;
    }
    const status = encoded && encoded > 0 ? 200 : undefined;
    const endTime = startTime + (entry.duration || 0);
    recordFinish(identity, encoded, requestType, status, "", undefined, endTime, wallTime());
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
        const shouldTrack = networkState.enabled;
        const args = Array.from(arguments);
        const [input, init = {}] = args;
        const method = init.method || (input && input.method) || "GET";
        const identity = shouldTrack ? nextRequestIdentity() : null;
        const url = typeof input === "string" ? input : (input && input.url) || "";
        const headers = normalizeHeaders(init.headers || (input && input.headers));

        if (shouldTrack && identity) {
            recordStart(identity, url, String(method).toUpperCase(), headers, "fetch");
        }

        try {
            const response = await nativeFetch.apply(window, args);
            if (shouldTrack && identity) {
                recordResponse(identity, response, "fetch");
                const encodedLength = captureContentLength(response);
                recordFinish(identity, encodedLength, "fetch");
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
        const shouldTrack = networkState.enabled && !!this.__wiNetwork;
        const identity = shouldTrack ? nextRequestIdentity() : null;
        const info = this.__wiNetwork;
        if (shouldTrack && identity && info) {
            recordStart(identity, info.url, info.method, info.headers || {}, "xhr");
            this.addEventListener("readystatechange", function() {
                if (this.readyState === 2 && identity) {
                    recordResponse(identity, this, "xhr");
                }
            }, false);
            this.addEventListener("load", function() {
                if (identity) {
                    const length = captureContentLength(this);
                    recordFinish(identity, length, "xhr");
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
            for (let i = 0; i < entries.length; ++i) {
                handleResourceEntry(entries[i]);
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
    networkState.enabled = !!enabled;
};

export const clearNetworkRecords = () => {
    trackedRequests.clear();
    if (networkState.resourceSeen) {
        networkState.resourceSeen.clear();
    }
    postNetworkReset();
};

export const installNetworkObserver = () => {
    ensureInstalled();
};
