const now = () => {
    if (typeof performance !== "undefined" && typeof performance.now === "function") {
        return performance.now();
    }
    return Date.now();
};

const wallTime = () => Date.now();

const generateSessionID = () => {
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
    sessionID: generateSessionID(),
    resourceObserver: null,
    resourceSeen: null,
    loggingListenerInstalled: false
};

const trackedRequests = new Map();
const requestBodies = new Map();
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

const inlineBodyPayload = body => {
    if (!body) {
        return undefined;
    }
    const clone = {...body};
    if (Object.prototype.hasOwnProperty.call(clone, "storageBody")) {
        delete clone.storageBody;
    }
    return clone;
};

// Keep inline payloads small to avoid OOL IPC; full body is cached separately with only a count cap.
const MAX_INLINE_BODY_LENGTH = 512;
const MAX_CAPTURE_BODY_LENGTH = 5 * 1024 * 1024;
const MAX_STORED_REQUEST_BODIES = 50;
const MAX_STORED_RESPONSE_BODIES = 50;
const MAX_QUEUED_EVENTS = 500;

/**
 * @typedef {Object} RequestBodyInfo
 * @property {"text"|"form"|"binary"} kind
 * @property {string=} body
 * @property {boolean} base64Encoded
 * @property {boolean} truncated
 * @property {number=} size
 * @property {string=} storageBody
 * @property {string=} summary
 * @property {Array<{name:string,value:string,isFile?:boolean,fileName?:string,size?:number}>=} formEntries
 */

const pruneStoredResponseBodies = () => {
    if (responseBodies.size <= MAX_STORED_RESPONSE_BODIES) {
        return;
    }
    const overLimit = responseBodies.size - MAX_STORED_RESPONSE_BODIES;
    for (let i = 0; i < overLimit; ++i) {
        const iterator = responseBodies.keys();
        const next = iterator.next();
        if (next.done) {
            break;
        }
        responseBodies.delete(next.value);
    }
};

const pruneStoredRequestBodies = () => {
    if (requestBodies.size <= MAX_STORED_REQUEST_BODIES) {
        return;
    }
    const overLimit = requestBodies.size - MAX_STORED_REQUEST_BODIES;
    for (let i = 0; i < overLimit; ++i) {
        const iterator = requestBodies.keys();
        const next = iterator.next();
        if (next.done) {
            break;
        }
        requestBodies.delete(next.value);
    }
};

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
        session: networkState.sessionID,
        events: payloads
    };
    try {
        window.webkit.messageHandlers.webInspectorHTTPBatchUpdate.postMessage(batchPayload);
    } catch {
    }
};

const nextRequestID = () => {
    const requestId = networkState.nextId;
    networkState.nextId += 1;
    return requestId;
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

/** @returns {RequestBodyInfo} */
const serializeTextBody = (text, inlineLimit = MAX_INLINE_BODY_LENGTH, reportedSize, storageLimit = Infinity) => {
    const stringified = typeof text === "string" ? text : String(text ?? "");
    const size = Number.isFinite(reportedSize) ? reportedSize : stringified.length;
    const inlineTruncated = size > inlineLimit;
    const body = inlineTruncated ? stringified.slice(0, inlineLimit) : stringified;
    let storageBody = stringified;
    let storageTruncated = false;
    if (Number.isFinite(storageLimit) && storageLimit >= 0 && storageBody.length > storageLimit) {
        storageBody = storageBody.slice(0, storageLimit);
        storageTruncated = true;
    }
    return {
        kind: "text",
        body: body,
        base64Encoded: false,
        truncated: inlineTruncated || storageTruncated,
        size: size,
        storageBody: storageBody
    };
};

/** @returns {RequestBodyInfo} */
const serializeBinaryBodySummary = (size, label) => {
    const knownSize = Number.isFinite(size) && size >= 0 ? size : undefined;
    const description = label || "Binary body";
    const summary = knownSize != null ? description + " (" + knownSize + " bytes)" : description;
    const truncated = knownSize != null ? knownSize > MAX_INLINE_BODY_LENGTH : true;
    return {
        kind: "binary",
        body: summary,
        base64Encoded: false,
        truncated: truncated,
        size: knownSize,
        storageBody: summary,
        summary: summary
    };
};

/** @returns {RequestBodyInfo|null} */
const serializeFormDataBody = (formData, storageLimit = Infinity) => {
    try {
        if (typeof formData.forEach !== "function") {
            return null;
        }
        const entries = [];
        let size = 0;
        let sizeKnown = true;
        formData.forEach((value, key) => {
            const name = String(key);
            if (typeof value === "string") {
                entries.push(name + "=" + value);
                if (sizeKnown) {
                    size += value.length;
                }
                return;
            }
            if (typeof File !== "undefined" && value instanceof File) {
                const fileSize = Number.isFinite(value.size) ? value.size : undefined;
                const fileName = value.name ? value.name : "file";
                entries.push(name + "=<file " + fileName + ">");
                if (sizeKnown && fileSize != null) {
                    size += fileSize;
                } else {
                    sizeKnown = false;
                }
                return;
            }
            if (typeof Blob !== "undefined" && value instanceof Blob) {
                const blobSize = Number.isFinite(value.size) ? value.size : undefined;
                entries.push(name + "=<blob>");
                if (sizeKnown && blobSize != null) {
                    size += blobSize;
                } else {
                    sizeKnown = false;
                }
                return;
            }
            entries.push(name + "=<unserializable>");
            sizeKnown = false;
        });
        const reportedSize = sizeKnown ? size : undefined;
        const serialized = serializeTextBody(entries.join("\n"), MAX_INLINE_BODY_LENGTH, reportedSize, storageLimit);
        serialized.kind = "form";
        serialized.summary = "FormData (" + entries.length + " fields)";
        serialized.formEntries = entries.map(entry => {
            const eq = entry.indexOf("=");
            const name = eq >= 0 ? entry.slice(0, eq) : "";
            const value = eq >= 0 ? entry.slice(eq + 1) : entry;
            const isFile = value.startsWith("<file ") || value === "<blob>";
            const fileName = value.startsWith("<file ") ? value.slice("<file ".length, -1) : undefined;
            return {name, value, isFile, fileName};
        });
        if (!sizeKnown) {
            serialized.truncated = true;
        }
        return serialized;
    } catch {
    }
    return null;
};

const serializeRequestBody = (body, storageLimit = MAX_CAPTURE_BODY_LENGTH) => {
    if (body == null) {
        return null;
    }
    if (typeof body === "string") {
        return serializeTextBody(body, MAX_INLINE_BODY_LENGTH, undefined, storageLimit);
    }
    if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) {
        return serializeTextBody(body.toString(), MAX_INLINE_BODY_LENGTH, undefined, storageLimit);
    }
    if (typeof FormData !== "undefined" && body instanceof FormData) {
        const serialized = serializeFormDataBody(body, storageLimit);
        if (serialized) {
            return serialized;
        }
    }
    if (typeof Blob !== "undefined" && body instanceof Blob) {
        return serializeBinaryBodySummary(body.size, "Blob body");
    }
    if (typeof ArrayBuffer !== "undefined" && body instanceof ArrayBuffer) {
        return serializeBinaryBodySummary(body.byteLength, "ArrayBuffer body");
    }
    if (typeof ArrayBuffer !== "undefined" && typeof ArrayBuffer.isView === "function" && ArrayBuffer.isView(body)) {
        const label = body && body.constructor && typeof body.constructor.name === "string" ? body.constructor.name + " body" : "Typed array body";
        return serializeBinaryBodySummary(body.byteLength, label);
    }
    if (typeof ReadableStream !== "undefined" && body instanceof ReadableStream) {
        const summary = "ReadableStream body (not captured)";
        return {
            kind: "binary",
            summary: summary,
            body: summary,
            base64Encoded: false,
            truncated: true,
            size: undefined,
            storageBody: summary
        };
    }
    if (typeof body === "object" && !(body instanceof ArrayBuffer) && !(typeof Blob !== "undefined" && body instanceof Blob) && !(typeof FormData !== "undefined" && body instanceof FormData)) {
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

const readStreamedTextResponse = async (response, expectedSize) => {
    if (!response || !response.body || typeof response.body.getReader !== "function") {
        return null;
    }
    if (typeof TextDecoder !== "function") {
        return null;
    }
    const sizeHint = Number.isFinite(expectedSize) && expectedSize >= 0 ? expectedSize : undefined;
    if (sizeHint === 0) {
        return {text: "", size: 0, truncated: false};
    }
    const byteLimit = sizeHint != null ? Math.min(MAX_CAPTURE_BODY_LENGTH, sizeHint) : MAX_CAPTURE_BODY_LENGTH;
    let reader;
    try {
        reader = response.body.getReader();
    } catch {
        return null;
    }
    const decoder = new TextDecoder();
    const chunks = [];
    let total = 0;
    let truncated = false;
    let limitReached = false;
    try {
        while (true) {
            const result = await reader.read();
            if (result.done) {
                break;
            }
            const value = result.value;
            if (!(value instanceof Uint8Array)) {
                continue;
            }
            const remaining = byteLimit - total;
            if (remaining <= 0) {
                limitReached = true;
                truncated = true;
                break;
            }
            let chunk = value;
            if (value.byteLength > remaining) {
                chunk = value.slice(0, remaining);
                limitReached = true;
                truncated = true;
            }
            const length = chunk.byteLength;
            total += length;
            if (length > 0) {
                chunks.push(chunk);
            }
            if (total >= byteLimit) {
                limitReached = true;
                truncated = truncated || result.done === false;
                break;
            }
        }
    } catch {
        truncated = true;
    }
    if (truncated && reader && typeof reader.cancel === "function") {
        try {
            reader.cancel();
        } catch {
        }
    }
    try {
        const merged = new Uint8Array(total);
        let offset = 0;
        for (let i = 0; i < chunks.length; ++i) {
            merged.set(chunks[i], offset);
            offset += chunks[i].length;
        }
        const text = decoder.decode(merged);
        const reportedSize = Number.isFinite(sizeHint) ? sizeHint : (limitReached ? Math.max(total, byteLimit + 1) : total);
        return {text: text, size: reportedSize, truncated: truncated};
    } catch {
    }
    return null;
};

const captureResponseBody = async (response, mimeType) => {
    if (!response) {
        return null;
    }
    const shouldCapture = shouldCaptureResponseBody(mimeType);
    if (!shouldCapture) {
        return null;
    }
    const contentLength = captureContentLength(response);
    const expectedSize = Number.isFinite(contentLength) ? contentLength : undefined;
    try {
        if (typeof response.clone !== "function") {
            return null;
        }
        const clone = response.clone();
        const streamed = await readStreamedTextResponse(clone, expectedSize);
        if (streamed && typeof streamed.text === "string") {
            const serialized = serializeTextBody(
                streamed.text,
                MAX_INLINE_BODY_LENGTH,
                streamed.size
            );
            if (streamed.truncated) {
                serialized.truncated = true;
            }
            return serialized;
        }
        if (expectedSize != null && expectedSize > MAX_CAPTURE_BODY_LENGTH) {
            const summary = serializeBinaryBodySummary(expectedSize, "Response body too large");
            summary.truncated = true;
            return summary;
        }
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
            return serializeTextBody(xhr.responseText || "", MAX_INLINE_BODY_LENGTH);
        }
        if (type === "json" && xhr.response != null) {
            return serializeTextBody(JSON.stringify(xhr.response), MAX_INLINE_BODY_LENGTH);
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

    const requestId = nextRequestID();
    const startTime = typeof entry.startTime === "number" ? entry.startTime : now();
    const duration = typeof entry.duration === "number" && entry.duration >= 0 ? entry.duration : 0;
    const endTime = startTime + duration;
    const requestType = entry.initiatorType || "resource";

    let encoded = entry.transferSize;
    if (!(Number.isFinite(encoded) && encoded >= 0)) {
        encoded = entry.encodedBodySize;
    }
    let status = undefined;
    if (typeof entry.responseStatus === "number") {
        status = entry.responseStatus;
    }
    return {
        type: "resourceTiming",
        session: networkState.sessionID,
        requestId: requestId,
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
