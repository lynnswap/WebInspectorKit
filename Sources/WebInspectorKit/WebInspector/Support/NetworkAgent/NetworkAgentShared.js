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
const responseBodies = new Map();
const queuedEvents = [];
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

const MAX_INLINE_BODY_LENGTH = 64 * 1024;
const MAX_STORED_BODY_LENGTH = 512 * 1024;
const MAX_QUEUED_EVENTS = 500;

const enqueueEvent = event => {
    if (queuedEvents.length >= MAX_QUEUED_EVENTS) {
        queuedEvents.shift();
    }
    queuedEvents.push(event);
};

const postHTTPEvent = payload => {
    if (!networkState.enabled) {
        enqueueEvent({kind: "http", payload});
        return;
    }
    try {
        window.webkit.messageHandlers.webInspectorHTTPUpdate.postMessage(payload);
    } catch {
    }
};

const postHTTPBatchEvents = payloads => {
    if (!networkState.enabled) {
        enqueueEvent({kind: "httpBatch", payloads});
        return;
    }
    if (!Array.isArray(payloads) || !payloads.length) {
        return;
    }
    const batchPayload = {
        session: networkState.sessionPrefix,
        events: payloads
    };
    try {
        window.webkit.messageHandlers.webInspectorHTTPBatchUpdate.postMessage(batchPayload);
    } catch {
    }
};

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

const serializeTextBody = (text, inlineLimit = MAX_INLINE_BODY_LENGTH, storedLimit = MAX_STORED_BODY_LENGTH) => {
    const stringified = typeof text === "string" ? text : String(text ?? "");
    const inlineTruncated = stringified.length > inlineLimit;
    const body = inlineTruncated ? stringified.slice(0, inlineLimit) : stringified;
    const storedTruncated = stringified.length > storedLimit;
    const storageBody = storedTruncated ? stringified.slice(0, storedLimit) : stringified;
    return {
        body: body,
        base64Encoded: false,
        truncated: inlineTruncated,
        size: stringified.length,
        storageBody: storageBody,
        storageTruncated: storedTruncated
    };
};

const serializeRequestBody = body => {
    if (body == null) {
        return null;
    }
    if (typeof body === "string") {
        return serializeTextBody(body);
    }
    if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) {
        return serializeTextBody(body.toString());
    }
    if (typeof body === "object" && !(body instanceof ArrayBuffer) && !(typeof Blob !== "undefined" && body instanceof Blob)) {
        try {
            return serializeTextBody(JSON.stringify(body));
        } catch {
        }
    }
    return null;
};

const shouldCaptureResponseBody = mimeType => {
    const lower = String(mimeType || "").toLowerCase();
    if (!lower) {
        return false;
    }
    if (lower.startsWith("text/")) {
        return true;
    }
    if (lower.includes("json")) {
        return true;
    }
    if (lower.includes("javascript")) {
        return true;
    }
    if (lower.includes("xml")) {
        return true;
    }
    if (lower.includes("x-www-form-urlencoded")) {
        return true;
    }
    if (lower.includes("graphql")) {
        return true;
    }
    return false;
};

const captureResponseBody = async (response, mimeType) => {
    if (!response) {
        return null;
    }
    const shouldCapture = shouldCaptureResponseBody(mimeType);
    if (!shouldCapture) {
        return null;
    }
    try {
        if (typeof response.clone !== "function") {
            return null;
        }
        const clone = response.clone();
        const text = await clone.text();
        return serializeTextBody(text);
    } catch {
    }
    return null;
};

const captureXHRResponseBody = xhr => {
    if (!xhr) {
        return null;
    }
    try {
        const type = xhr.responseType;
        if (type === "" || type === "text" || type === undefined) {
            return serializeTextBody(xhr.responseText || "");
        }
        if (type === "json" && xhr.response != null) {
            return serializeTextBody(JSON.stringify(xhr.response));
        }
    } catch {
    }
    return null;
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

const estimatedEncodedLength = (explicitLength, bodyInfo) => {
    if (Number.isFinite(explicitLength)) {
        return explicitLength;
    }
    if (bodyInfo && Number.isFinite(bodyInfo.size)) {
        return bodyInfo.size;
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
    if (!shouldTrackResourceEntry(entry)) {
        return null;
    }
    if (!networkState.resourceSeen) {
        networkState.resourceSeen = new Set();
    }
    const key = String(entry.name || "") + "::" + entry.startTime;
    if (networkState.resourceSeen.has(key)) {
        return null;
    }
    networkState.resourceSeen.add(key);

    const identity = nextRequestIdentity();
    const startTime = typeof entry.startTime === "number" ? entry.startTime : now();
    const duration = typeof entry.duration === "number" && entry.duration >= 0 ? entry.duration : 0;
    const endTime = startTime + duration;
    const requestType = entry.initiatorType || "resource";

    let encoded = entry.transferSize;
    if (!(Number.isFinite(encoded) && encoded >= 0)) {
        encoded = entry.encodedBodySize;
    }
    const status = encoded && encoded > 0 ? 200 : undefined;
    return {
        type: "resourceTiming",
        session: identity.session,
        requestId: identity.requestId,
        url: entry.name || "",
        method: "GET",
        requestHeaders: {},
        startTime: startTime,
        endTime: endTime,
        wallTime: wallTime(),
        encodedBodyLength: encoded,
        requestType: requestType,
        status: status,
        statusText: "",
        mimeType: ""
    };
};
