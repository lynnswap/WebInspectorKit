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

const NetworkLoggingMode = {
    ACTIVE: "active",
    BUFFERING: "buffering",
    STOPPED: "stopped"
};

const networkState = {
    mode: NetworkLoggingMode.ACTIVE,
    installed: false,
    nextId: 1,
    sessionID: generateSessionID(),
    resourceObserver: null,
    resourceSeen: null
};

const trackedRequests = new Map();
const queuedEvents = [];
const textEncoder = typeof TextEncoder === "function" ? new TextEncoder() : null;
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

const encodeTextToBytes = value => {
    if (!textEncoder) {
        return null;
    }
    try {
        const stringified = typeof value === "string" ? value : String(value ?? "");
        return textEncoder.encode(stringified);
    } catch {
    }
    return null;
};

const byteLengthOfString = value => {
    const stringified = typeof value === "string" ? value : String(value ?? "");
    const encoded = encodeTextToBytes(stringified);
    if (encoded) {
        return encoded.byteLength;
    }
    return stringified.length;
};

const clampStringToByteLength = (value, byteLimit, preEncodedBytes) => {
    const stringified = typeof value === "string" ? value : String(value ?? "");
    if (!Number.isFinite(byteLimit) || byteLimit === Infinity) {
        return {text: stringified, truncated: false};
    }
    const bytes = preEncodedBytes || encodeTextToBytes(stringified);
    if (!bytes) {
        const truncated = stringified.length > byteLimit;
        const body = truncated ? stringified.slice(0, byteLimit) : stringified;
        return {text: body, truncated: truncated};
    }
    if (bytes.byteLength <= byteLimit) {
        return {text: stringified, truncated: false};
    }
    const slice = bytes.slice(0, byteLimit);
    let decoded = null;
    if (typeof TextDecoder === "function") {
        try {
            decoded = new TextDecoder("utf-8", {fatal: false}).decode(slice);
        } catch {
        }
    }
    if (decoded == null) {
        decoded = stringified.slice(0, Math.min(stringified.length, byteLimit));
    }
    return {text: decoded, truncated: true};
};

const clampBytes = (bytes, limit) => {
    if (!(bytes instanceof Uint8Array)) {
        return {bytes: null, truncated: false};
    }
    if (!Number.isFinite(limit) || limit === Infinity || limit < 0 || bytes.byteLength <= limit) {
        return {bytes: bytes, truncated: false};
    }
    return {bytes: bytes.slice(0, limit), truncated: true};
};

const byteLengthOfText = value => {
    if (typeof value !== "string") {
        return 0;
    }
    const encoded = encodeTextToBytes(value);
    if (encoded) {
        return encoded.byteLength;
    }
    return value.length;
};

const bytesToBase64 = bytes => {
    if (!(bytes instanceof Uint8Array)) {
        return "";
    }
    try {
        if (typeof Buffer !== "undefined" && typeof Buffer.from === "function") {
            return Buffer.from(bytes).toString("base64");
        }
    } catch {
    }
    if (typeof btoa !== "function") {
        return "";
    }
    let binary = "";
    const chunkSize = 0x8000;
    for (let i = 0; i < bytes.length; i += chunkSize) {
        const chunk = bytes.subarray(i, Math.min(i + chunkSize, bytes.length));
        binary += String.fromCharCode.apply(null, chunk);
    }
    try {
        return btoa(binary);
    } catch {
    }
    return "";
};

const serializeBase64Body = (bytes, reportedSize, inlineLimit = MAX_INLINE_BODY_LENGTH, storageLimit = MAX_CAPTURE_BODY_LENGTH) => {
    if (!(bytes instanceof Uint8Array)) {
        return serializeBinaryBodySummary(reportedSize, "Binary body");
    }
    const storage = clampBytes(bytes, storageLimit);
    const base64 = bytesToBase64(storage.bytes || bytes);
    const inlineTruncated = base64.length > inlineLimit;
    const body = inlineTruncated ? base64.slice(0, inlineLimit) : base64;
    const size = Number.isFinite(reportedSize) ? reportedSize : bytes.byteLength;
    const truncated = inlineTruncated || storage.truncated || (Number.isFinite(size) && size > inlineLimit);
    return {
        kind: "text",
        body: body,
        base64Encoded: true,
        truncated: truncated,
        size: size,
        storageBody: base64
    };
};

const decodeBytesWithEncoding = (bytes, encodingLabel) => {
    if (!(bytes instanceof Uint8Array)) {
        return null;
    }
    if (typeof TextDecoder !== "function") {
        return null;
    }
    const label = encodingLabel || "utf-8";
    try {
        return new TextDecoder(label, {fatal: false}).decode(bytes);
    } catch {
        if (label.toLowerCase() !== "utf-8") {
            try {
                return new TextDecoder("utf-8", {fatal: false}).decode(bytes);
            } catch {
            }
        }
    }
    return null;
};

const parseCharsetFromMimeType = mimeType => {
    if (!mimeType || typeof mimeType !== "string") {
        return null;
    }
    const match = mimeType.match(/charset\s*=\s*"?([^;\s"]+)/i);
    if (match && match[1]) {
        return match[1].trim();
    }
    return null;
};

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
const MAX_BODY_CACHE_BYTES = 200 * 1024 * 1024;
const MAX_QUEUED_EVENTS = 500;
const DEFAULT_THROTTLE_INTERVAL_MS = 50;

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

class BodyCache {
    constructor(maxBytes) {
        this.maxBytes = Number.isFinite(maxBytes) && maxBytes > 0 ? maxBytes : Infinity;
        this.usedBytes = 0;
        this.entries = new Map();
    }

    key(kind, requestId) {
        return String(kind) + ":" + requestId;
    }

    estimateBytes(bodyInfo) {
        if (!bodyInfo) {
            return 0;
        }
        if (Number.isFinite(bodyInfo.size) && bodyInfo.size >= 0) {
            return bodyInfo.size;
        }
        if (typeof bodyInfo.storageBody === "string") {
            return byteLengthOfText(bodyInfo.storageBody);
        }
        if (typeof bodyInfo.body === "string") {
            return byteLengthOfText(bodyInfo.body);
        }
        if (typeof bodyInfo.summary === "string") {
            return byteLengthOfText(bodyInfo.summary);
        }
        return 0;
    }

    evictUntilFits(additionalBytes) {
        if (!Number.isFinite(additionalBytes) || additionalBytes <= 0) {
            return;
        }
        while (this.usedBytes + additionalBytes > this.maxBytes && this.entries.size) {
            const next = this.entries.keys().next();
            if (next.done) {
                break;
            }
            const entry = this.entries.get(next.value);
            this.entries.delete(next.value);
            if (entry && Number.isFinite(entry.size)) {
                this.usedBytes -= entry.size;
            }
        }
    }

    store(kind, requestId, bodyInfo) {
        if (requestId == null || !bodyInfo) {
            return;
        }
        const stored = {...bodyInfo};
        if (typeof bodyInfo.storageBody === "string") {
            stored.body = bodyInfo.storageBody;
        }
        const size = this.estimateBytes(stored);
        this.evictUntilFits(size);
        if (Number.isFinite(size) && size > this.maxBytes) {
            return;
        }
        const key = this.key(kind, requestId);
        const previous = this.entries.get(key);
        if (previous && Number.isFinite(previous.size)) {
            this.usedBytes -= previous.size;
        }
        this.entries.set(key, {body: stored, size: size});
        if (Number.isFinite(size)) {
            this.usedBytes += size;
        }
    }

    take(kind, requestId) {
        const key = this.key(kind, requestId);
        if (!this.entries.has(key)) {
            return null;
        }
        const entry = this.entries.get(key);
        this.entries.delete(key);
        if (entry && Number.isFinite(entry.size)) {
            this.usedBytes -= entry.size;
        }
        return entry ? entry.body : null;
    }

    clear() {
        this.entries.clear();
        this.usedBytes = 0;
    }
}

const bodyCache = new BodyCache(MAX_BODY_CACHE_BYTES);

const throttleState = {
    intervalMs: DEFAULT_THROTTLE_INTERVAL_MS,
    maxQueuedEvents: MAX_QUEUED_EVENTS,
    queue: [],
    timer: null
};

const bufferEvent = event => {
    if (queuedEvents.length >= MAX_QUEUED_EVENTS) {
        queuedEvents.shift();
    }
    queuedEvents.push(event);
};

const clearThrottledEvents = () => {
    throttleState.queue.splice(0, throttleState.queue.length);
    if (throttleState.timer) {
        clearTimeout(throttleState.timer);
        throttleState.timer = null;
    }
};

const deliverNetworkEvents = events => {
    if (!Array.isArray(events) || !events.length) {
        return;
    }
    const payload = {
        session: networkState.sessionID,
        events: events
    };
    try {
        window.webkit.messageHandlers.webInspectorNetworkUpdate.postMessage(payload);
    } catch {
    }
};

const flushThrottledEvents = () => {
    if (!throttleState.queue.length) {
        return;
    }
    const events = throttleState.queue.splice(0, throttleState.queue.length);
    throttleState.timer = null;
    deliverNetworkEvents(events);
};

const scheduleThrottledFlush = () => {
    if (!throttleState.queue.length) {
        return;
    }
    if (throttleState.intervalMs <= 0) {
        flushThrottledEvents();
        return;
    }
    if (throttleState.timer) {
        return;
    }
    throttleState.timer = setTimeout(() => {
        throttleState.timer = null;
        flushThrottledEvents();
    }, throttleState.intervalMs);
};

const enqueueThrottledEvent = event => {
    if (throttleState.queue.length >= throttleState.maxQueuedEvents) {
        throttleState.queue.shift();
    }
    throttleState.queue.push(event);
    scheduleThrottledFlush();
};

const setThrottleOptions = options => {
    const interval = options && Number.isFinite(options.intervalMs) ? options.intervalMs : DEFAULT_THROTTLE_INTERVAL_MS;
    const limit = options && Number.isFinite(options.maxQueuedEvents) ? options.maxQueuedEvents : MAX_QUEUED_EVENTS;
    throttleState.intervalMs = interval >= 0 ? interval : 0;
    throttleState.maxQueuedEvents = limit > 0 ? limit : MAX_QUEUED_EVENTS;
    if (throttleState.intervalMs === 0 && throttleState.queue.length) {
        flushThrottledEvents();
    }
};

const shouldThrottleDelivery = () => throttleState.intervalMs != null && throttleState.intervalMs > 0;

const isActiveLogging = () => networkState.mode === NetworkLoggingMode.ACTIVE;
const shouldTrackNetworkEvents = () => networkState.mode !== NetworkLoggingMode.STOPPED;
const shouldQueueNetworkEvent = () => networkState.mode === NetworkLoggingMode.BUFFERING;

const enqueueNetworkEvent = event => {
    if (!isActiveLogging()) {
        if (shouldQueueNetworkEvent()) {
            bufferEvent(event);
        }
        return;
    }
    if (shouldThrottleDelivery()) {
        enqueueThrottledEvent(event);
        return;
    }
    deliverNetworkEvents([event]);
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
    const encoded = encodeTextToBytes(stringified);
    const measuredSize = encoded ? encoded.byteLength : stringified.length;
    const size = Number.isFinite(reportedSize) ? reportedSize : measuredSize;
    const inlineClamped = clampStringToByteLength(stringified, inlineLimit, encoded);
    const storageClamped = clampStringToByteLength(stringified, storageLimit, encoded);
    const truncated = inlineClamped.truncated || storageClamped.truncated || (Number.isFinite(size) && size > inlineLimit);
    return {
        kind: "text",
        body: inlineClamped.text,
        base64Encoded: false,
        truncated: truncated,
        size: size,
        storageBody: storageClamped.text
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
                    size += byteLengthOfString(value);
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

const readStreamedTextResponse = async (response, expectedSize, encodingLabel) => {
    if (!response || !response.body || typeof response.body.getReader !== "function") {
        return null;
    }
    const sizeHint = Number.isFinite(expectedSize) && expectedSize >= 0 ? expectedSize : undefined;
    if (sizeHint === 0) {
        return {text: "", size: 0, truncated: false, bytes: new Uint8Array()};
    }
    const byteLimit = sizeHint != null ? Math.min(MAX_CAPTURE_BODY_LENGTH, sizeHint) : MAX_CAPTURE_BODY_LENGTH;
    let reader;
    try {
        reader = response.body.getReader();
    } catch {
        return null;
    }
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
        const text = decodeBytesWithEncoding(merged, encodingLabel);
        const reportedSize = Number.isFinite(sizeHint) ? sizeHint : (limitReached ? Math.max(total, byteLimit + 1) : total);
        return {text: text, size: reportedSize, truncated: truncated, bytes: merged};
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
    const charset = parseCharsetFromMimeType(mimeType);
    const contentLength = captureContentLength(response);
    const expectedSize = Number.isFinite(contentLength) ? contentLength : undefined;
    try {
        if (typeof response.clone !== "function") {
            return null;
        }
        const clone = response.clone();
        const streamed = await readStreamedTextResponse(clone, expectedSize, charset);
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
        if (streamed && streamed.bytes instanceof Uint8Array) {
            const serialized = serializeBase64Body(streamed.bytes, streamed.size);
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
            return serializeTextBody(
                xhr.responseText || "",
                MAX_INLINE_BODY_LENGTH,
                captureContentLength(xhr),
                MAX_CAPTURE_BODY_LENGTH
            );
        }
        if (type === "json" && xhr.response != null) {
            return serializeTextBody(
                JSON.stringify(xhr.response),
                MAX_INLINE_BODY_LENGTH,
                captureContentLength(xhr),
                MAX_CAPTURE_BODY_LENGTH
            );
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

    let encoded = entry.encodedBodySize;
    if (!(Number.isFinite(encoded) && encoded >= 0)) {
        encoded = entry.transferSize;
    }
    if (!(Number.isFinite(encoded) && encoded >= 0)) {
        encoded = undefined;
    }
    const decodedSize = Number.isFinite(entry.decodedBodySize) && entry.decodedBodySize >= 0 ? entry.decodedBodySize : undefined;
    let status = undefined;
    if (typeof entry.responseStatus === "number") {
        status = entry.responseStatus;
    }
    const method = typeof entry.requestMethod === "string" ? entry.requestMethod.toUpperCase() : undefined;
    return {
        type: "resourceTiming",
        session: networkState.sessionID,
        requestId: requestId,
        url: entry.name || "",
        method: method,
        requestHeaders: {},
        startTime: startTime,
        endTime: endTime,
        wallTime: wallTime(),
        encodedBodyLength: encoded,
        decodedBodySize: decodedSize,
        requestType: requestType,
        status: status,
        statusText: "",
        mimeType: ""
    };
};
