import {
    WI_NETWORK_EVENT_SCHEMA_VERSION,
    type WINetworkEventBatchContract,
    type WINetworkEventRecord
} from "../../Contracts/agent-contract";

const now = () => {
    if (typeof performance !== "undefined" && typeof performance.now === "function") {
        return performance.now();
    }
    return Date.now();
};

const wallTime = () => Date.now();

type NetworkTime = {
    monotonicMs: number;
    wallMs: number;
};

type NetworkEventPayload = WINetworkEventRecord;
type HeaderMap = Record<string, string>;

const makeNetworkTime = (monotonicOverride?: number, wallOverride?: number): NetworkTime => {
    const monotonicMs = typeof monotonicOverride === "number" ? monotonicOverride : now();
    const wallMs = typeof wallOverride === "number" ? wallOverride : wallTime();
    return {monotonicMs, wallMs};
};

const makeNetworkTimeAt = (monotonicMs?: number, nowMonotonic?: number, nowWall?: number): NetworkTime => {
    const fallback = makeNetworkTime();
    if (!(typeof monotonicMs === "number" && Number.isFinite(monotonicMs))) {
        return fallback;
    }
    const referenceMonotonic = typeof nowMonotonic === "number" && Number.isFinite(nowMonotonic)
        ? nowMonotonic
        : fallback.monotonicMs;
    const referenceWall = typeof nowWall === "number" && Number.isFinite(nowWall) ? nowWall : fallback.wallMs;
    const delta = referenceMonotonic - monotonicMs;
    return {
        monotonicMs: monotonicMs,
        wallMs: referenceWall - delta
    };
};

const generateSessionID = (): string => {
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
} as const;

type NetworkLoggingModeValue = typeof NetworkLoggingMode[keyof typeof NetworkLoggingMode];

const NETWORK_EVENT_VERSION = 1;

type NetworkState = {
    mode: NetworkLoggingModeValue;
    installed: boolean;
    nextId: number;
    batchSeq: number;
    droppedEvents: number;
    sessionID: string;
    messageAuthToken: string;
    controlAuthToken: string;
    resourceObserver: PerformanceObserver | null;
    resourceSeen: Set<string> | null;
    resourceStartCutoffMs: number | null;
};

const networkState: NetworkState = {
    mode: NetworkLoggingMode.ACTIVE,
    installed: false,
    nextId: 1,
    batchSeq: 0,
    droppedEvents: 0,
    sessionID: generateSessionID(),
    messageAuthToken: "",
    controlAuthToken: "",
    resourceObserver: null,
    resourceSeen: null,
    resourceStartCutoffMs: null
};

const trackedRequests = new Map<number, { startTime: number; wallTime: number }>();
const queuedEvents: NetworkEventPayload[] = [];
const textEncoder: TextEncoder | null = typeof TextEncoder === "function" ? new TextEncoder() : null;
const trackedResourceTypes = new Set<string>([
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

const encodeTextToBytes = (value: unknown): Uint8Array | null => {
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

const byteLengthOfString = (value: unknown): number => {
    const stringified = typeof value === "string" ? value : String(value ?? "");
    const encoded = encodeTextToBytes(stringified);
    if (encoded) {
        return encoded.byteLength;
    }
    return stringified.length;
};

const clampStringToByteLength = (value: unknown, byteLimit: number, preEncodedBytes?: Uint8Array | null) => {
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

const clampBytes = (bytes: Uint8Array | null, limit: number) => {
    if (!(bytes instanceof Uint8Array)) {
        return {bytes: null, truncated: false};
    }
    if (!Number.isFinite(limit) || limit === Infinity || limit < 0 || bytes.byteLength <= limit) {
        return {bytes: bytes, truncated: false};
    }
    return {bytes: bytes.slice(0, limit), truncated: true};
};

const byteLengthOfText = (value: unknown): number => {
    if (typeof value !== "string") {
        return 0;
    }
    const encoded = encodeTextToBytes(value);
    if (encoded) {
        return encoded.byteLength;
    }
    return value.length;
};

const bytesToBase64 = (bytes: Uint8Array | null): string => {
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
        binary += String.fromCharCode.apply(null, Array.from(chunk));
    }
    try {
        return btoa(binary);
    } catch {
    }
    return "";
};

const serializeBase64Body = (
    bytes: Uint8Array | null,
    reportedSize?: number,
    inlineLimit = MAX_INLINE_BODY_LENGTH,
    storageLimit = MAX_CAPTURE_BODY_LENGTH
) => {
    if (!(bytes instanceof Uint8Array)) {
        return serializeBinaryBodySummary(reportedSize, "Binary body");
    }
    const storage = clampBytes(bytes, storageLimit);
    const base64 = bytesToBase64(storage.bytes || bytes);
    const inlineTruncated = base64.length > inlineLimit;
    const body = inlineTruncated ? base64.slice(0, inlineLimit) : base64;
    const size = typeof reportedSize === "number" && Number.isFinite(reportedSize) ? reportedSize : bytes.byteLength;
    const truncated = inlineTruncated || storage.truncated || size > inlineLimit;
    return {
        kind: "binary",
        body: body,
        base64Encoded: true,
        truncated: truncated,
        size: size,
        storageBody: base64
    };
};

const decodeBytesWithEncoding = (bytes: Uint8Array | null, encodingLabel?: string | null) => {
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

const parseCharsetFromMimeType = (mimeType?: string | null) => {
    if (!mimeType || typeof mimeType !== "string") {
        return null;
    }
    const match = mimeType.match(/charset\s*=\s*"?([^;\s"]+)/i);
    if (match && match[1]) {
        return match[1].trim();
    }
    return null;
};

const makeBodyRef = (role: string, requestId: number) => {
    return `${role}:${requestId}`;
};

const buildHandlePayload = (
    bodyInfo: RequestBodyInfo | null | undefined,
    storedPayload?: Record<string, any> | null
) => {
    const payload: Record<string, any> = {};
    const source = storedPayload && typeof storedPayload === "object" ? storedPayload : null;

    const kind = source && typeof source.kind === "string" && source.kind
        ? source.kind
        : (typeof bodyInfo?.kind === "string" && bodyInfo.kind ? bodyInfo.kind : "text");
    payload.kind = kind;

    const sourceEncoding = source && typeof source.encoding === "string" ? source.encoding : null;
    payload.encoding = sourceEncoding || (bodyInfo?.base64Encoded ? "base64" : (kind === "binary" ? "none" : "utf-8"));
    payload.truncated = source && typeof source.truncated === "boolean" ? source.truncated : !!bodyInfo?.truncated;

    const sourceSize = source ? source.size : undefined;
    if (Number.isFinite(sourceSize)) {
        payload.size = sourceSize;
    } else if (Number.isFinite(bodyInfo?.size)) {
        payload.size = bodyInfo?.size;
    }

    const content = (source && typeof source.content === "string" ? source.content : null)
        || (typeof bodyInfo?.storageBody === "string" ? bodyInfo.storageBody : null)
        || (typeof bodyInfo?.body === "string" ? bodyInfo.body : null);
    if (content != null) {
        payload.content = content;
    }

    const summary = (source && typeof source.summary === "string" ? source.summary : null)
        || (typeof bodyInfo?.summary === "string" ? bodyInfo.summary : null);
    if (summary != null) {
        payload.summary = summary;
    }

    const formEntries = source && Array.isArray(source.formEntries)
        ? source.formEntries.slice()
        : (Array.isArray(bodyInfo?.formEntries) ? bodyInfo.formEntries.slice() : null);
    if (formEntries && formEntries.length) {
        payload.formEntries = formEntries;
    }

    if (!payload.content && !payload.summary && !(Array.isArray(payload.formEntries) && payload.formEntries.length)) {
        return null;
    }

    return payload;
};

const makeBodyHandle = (bodyInfo: RequestBodyInfo | null | undefined, storedPayload?: Record<string, any> | null) => {
    const runtime = (window.webkit || null) as unknown as { createJSHandle?: (value: unknown) => unknown } | null;
    if (!runtime || typeof runtime.createJSHandle !== "function") {
        return null;
    }

    const handlePayload = buildHandlePayload(bodyInfo, storedPayload);
    if (!handlePayload) {
        return null;
    }

    try {
        return runtime.createJSHandle(handlePayload);
    } catch {
    }
    return null;
};

const buildStoredBodyPayload = (bodyInfo: RequestBodyInfo | null | undefined) => {
    if (!bodyInfo) {
        return null;
    }
    const encoding = bodyInfo.base64Encoded ? "base64" : (bodyInfo.kind === "binary" ? "none" : "utf-8");
    const payload: Record<string, any> = {
        kind: bodyInfo.kind || "other",
        encoding: encoding,
        truncated: !!bodyInfo.truncated
    };
    if (Number.isFinite(bodyInfo.size)) {
        payload.size = bodyInfo.size;
    }
    const content = typeof bodyInfo.storageBody === "string"
        ? bodyInfo.storageBody
        : (!bodyInfo.truncated && typeof bodyInfo.body === "string" ? bodyInfo.body : null);
    if (content != null) {
        payload.content = content;
    }
    if (typeof bodyInfo.summary === "string") {
        payload.summary = bodyInfo.summary;
    }
    if (Array.isArray(bodyInfo.formEntries) && bodyInfo.formEntries.length) {
        payload.formEntries = bodyInfo.formEntries;
    }
    if (!payload.content && !payload.summary && !(payload.formEntries && payload.formEntries.length)) {
        return null;
    }
    return payload;
};

const makeBodyPreviewPayload = (
    bodyInfo: RequestBodyInfo | null | undefined,
    ref?: string | null,
    handle?: unknown
) => {
    if (!bodyInfo) {
        return undefined;
    }
    const encoding = bodyInfo.base64Encoded ? "base64" : (bodyInfo.kind === "binary" ? "none" : "utf-8");
    const payload: Record<string, any> = {
        kind: bodyInfo.kind || "other",
        encoding: encoding,
        truncated: !!bodyInfo.truncated
    };
    if (Number.isFinite(bodyInfo.size)) {
        payload.size = bodyInfo.size;
    }
    if (typeof bodyInfo.body === "string" && bodyInfo.body.length) {
        payload.preview = bodyInfo.body;
    }
    if (typeof bodyInfo.summary === "string") {
        payload.summary = bodyInfo.summary;
    }
    if (Array.isArray(bodyInfo.formEntries) && bodyInfo.formEntries.length) {
        payload.formEntries = bodyInfo.formEntries;
    }
    if (ref) {
        payload.ref = ref;
    }
    if (handle) {
        payload.handle = handle;
    }
    return payload;
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
type RequestBodyInfo = {
    kind?: string;
    body?: string;
    base64Encoded?: boolean;
    truncated?: boolean;
    size?: number;
    storageBody?: string;
    summary?: string;
    preview?: string;
    formEntries?: Array<{ name: string; value: string; isFile?: boolean; fileName?: string; size?: number }>;
};

class BodyCache {
    maxBytes: number;
    usedBytes: number;
    entries: Map<string, { body: any; size: number }>;

    constructor(maxBytes: number) {
        this.maxBytes = Number.isFinite(maxBytes) && maxBytes > 0 ? maxBytes : Infinity;
        this.usedBytes = 0;
        this.entries = new Map<string, { body: any; size: number }>();
    }

    key(ref: string | null | undefined) {
        return String(ref || "");
    }

    estimateBytes(bodyInfo: Record<string, any>) {
        if (!bodyInfo) {
            return 0;
        }
        if (Number.isFinite(bodyInfo.size) && bodyInfo.size >= 0) {
            return bodyInfo.size;
        }
        if (typeof bodyInfo.content === "string") {
            return byteLengthOfText(bodyInfo.content);
        }
        if (typeof bodyInfo.summary === "string") {
            return byteLengthOfText(bodyInfo.summary);
        }
        if (typeof bodyInfo.preview === "string") {
            return byteLengthOfText(bodyInfo.preview);
        }
        return 0;
    }

    evictUntilFits(additionalBytes: number) {
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

    store(ref: string, bodyInfo: Record<string, any>) {
        if (!ref || !bodyInfo) {
            return false;
        }
        const stored = {...bodyInfo};
        const size = this.estimateBytes(stored);
        this.evictUntilFits(size);
        if (Number.isFinite(size) && size > this.maxBytes) {
            return false;
        }
        const key = this.key(ref);
        const previous = this.entries.get(key);
        if (previous && Number.isFinite(previous.size)) {
            this.usedBytes -= previous.size;
        }
        this.entries.set(key, {body: stored, size: size});
        if (Number.isFinite(size)) {
            this.usedBytes += size;
        }
        return true;
    }

    take(ref: string) {
        const key = this.key(ref);
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

type ThrottleState = {
    intervalMs: number;
    maxQueuedEvents: number;
    queue: NetworkEventPayload[];
    timer: ReturnType<typeof setTimeout> | null;
};

const throttleState: ThrottleState = {
    intervalMs: DEFAULT_THROTTLE_INTERVAL_MS,
    maxQueuedEvents: MAX_QUEUED_EVENTS,
    queue: [],
    timer: null
};

const recordDroppedEvents = (count: number) => {
    if (!Number.isFinite(count) || count <= 0) {
        return;
    }
    networkState.droppedEvents += count;
};

const bufferEvent = (event: NetworkEventPayload) => {
    if (queuedEvents.length >= MAX_QUEUED_EVENTS) {
        queuedEvents.shift();
        recordDroppedEvents(1);
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

const deliverNetworkEvents = (events: NetworkEventPayload[]) => {
    if (!Array.isArray(events) || !events.length) {
        return;
    }
    const payload: WINetworkEventBatchContract = {
        authToken: networkState.messageAuthToken,
        version: NETWORK_EVENT_VERSION,
        schemaVersion: WI_NETWORK_EVENT_SCHEMA_VERSION,
        sessionId: networkState.sessionID,
        seq: networkState.batchSeq + 1,
        events: events
    };
    if (networkState.droppedEvents > 0) {
        payload.dropped = networkState.droppedEvents;
        networkState.droppedEvents = 0;
    }
    try {
        networkState.batchSeq += 1;
        window.webkit?.messageHandlers?.webInspectorNetworkEvents?.postMessage(payload);
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

const enqueueThrottledEvent = (event: NetworkEventPayload) => {
    if (throttleState.queue.length >= throttleState.maxQueuedEvents) {
        throttleState.queue.shift();
        recordDroppedEvents(1);
    }
    throttleState.queue.push(event);
    scheduleThrottledFlush();
};

const setThrottleOptions = (options: { intervalMs?: number; maxQueuedEvents?: number } | null | undefined) => {
    const interval = typeof options?.intervalMs === "number" && Number.isFinite(options.intervalMs)
        ? options.intervalMs
        : DEFAULT_THROTTLE_INTERVAL_MS;
    const limit = typeof options?.maxQueuedEvents === "number" && Number.isFinite(options.maxQueuedEvents)
        ? options.maxQueuedEvents
        : MAX_QUEUED_EVENTS;
    throttleState.intervalMs = interval >= 0 ? interval : 0;
    throttleState.maxQueuedEvents = limit > 0 ? limit : MAX_QUEUED_EVENTS;
    if (throttleState.intervalMs === 0 && throttleState.queue.length) {
        flushThrottledEvents();
    }
};

const shouldThrottleDelivery = () => throttleState.intervalMs != null && throttleState.intervalMs > 0;

const isActiveLogging = () => networkState.mode === NetworkLoggingMode.ACTIVE;
const shouldCaptureNetworkBodies = () => networkState.mode === NetworkLoggingMode.ACTIVE;
const shouldTrackNetworkEvents = () => networkState.mode !== NetworkLoggingMode.STOPPED;
const shouldQueueNetworkEvent = () => networkState.mode === NetworkLoggingMode.BUFFERING;

const enqueueNetworkEvent = (event: NetworkEventPayload) => {
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

const normalizeHeaders = (headers: Headers | Array<[string, string]> | Record<string, unknown> | null | undefined): HeaderMap => {
    const result: HeaderMap = {};
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
                result[String(key).toLowerCase()] = String((headers as Record<string, unknown>)[key]);
            });
        }
    } catch {
    }
    return result;
};

const parseRawHeaders = (raw: string | null | undefined): HeaderMap => {
    const headers: HeaderMap = {};
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
const serializeTextBody = (
    text: unknown,
    inlineLimit = MAX_INLINE_BODY_LENGTH,
    reportedSize?: number,
    storageLimit = Infinity
): RequestBodyInfo => {
    const stringified = typeof text === "string" ? text : String(text ?? "");
    const encoded = encodeTextToBytes(stringified);
    const measuredSize = encoded ? encoded.byteLength : stringified.length;
    const size = typeof reportedSize === "number" && Number.isFinite(reportedSize) ? reportedSize : measuredSize;
    const inlineClamped = clampStringToByteLength(stringified, inlineLimit, encoded);
    const storageClamped = clampStringToByteLength(stringified, storageLimit, encoded);
    const truncated = inlineClamped.truncated || storageClamped.truncated || size > inlineLimit;
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
const serializeBinaryBodySummary = (size?: number, label?: string): RequestBodyInfo => {
    const knownSize = typeof size === "number" && Number.isFinite(size) && size >= 0 ? size : undefined;
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
const serializeFormDataBody = (formData: FormData, storageLimit = Infinity): RequestBodyInfo | null => {
    try {
        if (typeof formData.forEach !== "function") {
            return null;
        }
        const entries: string[] = [];
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

const serializeRequestBody = (body: unknown, storageLimit = MAX_CAPTURE_BODY_LENGTH): RequestBodyInfo | null => {
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

const shouldCaptureResponseBody = (mimeType?: string | null) => {
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

type StreamedResponse = {
    text: string | null;
    size: number;
    truncated: boolean;
    bytes: Uint8Array;
};

const readStreamedTextResponse = async (
    response: Response,
    expectedSize?: number,
    encodingLabel?: string | null
): Promise<StreamedResponse | null> => {
    if (!response || !response.body || typeof response.body.getReader !== "function") {
        return null;
    }
    const sizeHint = typeof expectedSize === "number" && Number.isFinite(expectedSize) && expectedSize >= 0 ? expectedSize : undefined;
    if (sizeHint === 0) {
        return {text: "", size: 0, truncated: false, bytes: new Uint8Array()};
    }
    const byteLimit = sizeHint != null ? Math.min(MAX_CAPTURE_BODY_LENGTH, sizeHint) : MAX_CAPTURE_BODY_LENGTH;
    let reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
    try {
        reader = response.body.getReader();
    } catch {
        return null;
    }
    const chunks: Uint8Array[] = [];
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
        const reportedSize = typeof sizeHint === "number" ? sizeHint : (limitReached ? Math.max(total, byteLimit + 1) : total);
        return {text: text, size: reportedSize, truncated: truncated, bytes: merged};
    } catch {
    }
    return null;
};

const captureResponseBody = async (response: Response, mimeType?: string | null): Promise<RequestBodyInfo | null> => {
    if (!response) {
        return null;
    }
    const shouldCapture = shouldCaptureResponseBody(mimeType);
    if (!shouldCapture) {
        return null;
    }
    const charset = parseCharsetFromMimeType(mimeType);
    const contentLength = captureContentLength(response);
    const expectedSize = typeof contentLength === "number" && Number.isFinite(contentLength) ? contentLength : undefined;
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

const captureXHRResponseBody = (xhr: XMLHttpRequest) => {
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

const captureContentLength = (response: Response | XMLHttpRequest) => {
    try {
        let value = null;
        if (response && "headers" in response && response.headers && typeof response.headers.get === "function") {
            value = response.headers.get("content-length");
        } else if (response && "getResponseHeader" in response && typeof response.getResponseHeader === "function") {
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

const estimatedEncodedLength = (explicitLength?: number, bodyInfo?: RequestBodyInfo | null) => {
    if (typeof explicitLength === "number" && Number.isFinite(explicitLength)) {
        return explicitLength;
    }
    if (bodyInfo && typeof bodyInfo.size === "number" && Number.isFinite(bodyInfo.size)) {
        return bodyInfo.size;
    }
    return undefined;
};

const shouldTrackResourceEntry = (entry: PerformanceEntry): entry is PerformanceResourceTiming => {
    if (!entry) {
        return false;
    }
    const resourceEntry = entry as PerformanceResourceTiming;
    const initiator = String(resourceEntry.initiatorType || "").toLowerCase();
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
        if (typeof resourceEntry.name === "string") {
            const lower = resourceEntry.name.toLowerCase();
            if (lower.endsWith(".mp4") || lower.endsWith(".webm") || lower.endsWith(".mov") || lower.endsWith(".m4v")) {
                return true;
            }
        }
    }
    return false;
};

const handleResourceEntry = (entry: PerformanceEntry): NetworkEventPayload | null => {
    if (!shouldTrackResourceEntry(entry)) {
        return null;
    }
    const resourceEntry = entry as PerformanceResourceTiming;
    const startTime = typeof resourceEntry.startTime === "number" ? resourceEntry.startTime : now();
    const resourceStartCutoffMs = networkState.resourceStartCutoffMs;
    if (typeof resourceStartCutoffMs === "number" && startTime < resourceStartCutoffMs) {
        return null;
    }
    if (!networkState.resourceSeen) {
        networkState.resourceSeen = new Set<string>();
    }
    const resourceSeen = networkState.resourceSeen;
    if (!resourceSeen) {
        return null;
    }
    const key = String(resourceEntry.name || "") + "::" + startTime;
    if (resourceSeen.has(key)) {
        return null;
    }
    resourceSeen.add(key);

    const requestId = nextRequestID();
    const duration = typeof resourceEntry.duration === "number" && resourceEntry.duration >= 0 ? resourceEntry.duration : 0;
    const endTime = startTime + duration;
    const requestType = resourceEntry.initiatorType || "resource";

    const nowMonotonic = now();
    const nowWall = wallTime();
    const startTimePayload = makeNetworkTimeAt(startTime, nowMonotonic, nowWall);
    const endTimePayload = makeNetworkTimeAt(endTime, nowMonotonic, nowWall);

    let encoded: number | undefined = resourceEntry.encodedBodySize;
    if (!(Number.isFinite(encoded) && encoded >= 0)) {
        encoded = resourceEntry.transferSize;
    }
    if (!(Number.isFinite(encoded) && encoded >= 0)) {
        encoded = undefined;
    }
    const decodedSize = Number.isFinite(resourceEntry.decodedBodySize) && resourceEntry.decodedBodySize >= 0
        ? resourceEntry.decodedBodySize
        : undefined;
    let status: number | undefined = undefined;
    if (typeof resourceEntry.responseStatus === "number") {
        status = resourceEntry.responseStatus;
    }
    const requestMethod = (resourceEntry as { requestMethod?: string }).requestMethod;
    const method = typeof requestMethod === "string" && requestMethod.trim().length > 0
        ? requestMethod.toUpperCase()
        : "GET";
    return {
        kind: "resourceTiming",
        requestId: requestId,
        url: resourceEntry.name || "",
        method: method,
        status: status,
        mimeType: "",
        initiator: requestType,
        startTime: startTimePayload,
        endTime: endTimePayload,
        encodedBodyLength: encoded,
        decodedBodySize: decodedSize
    };
};

export {
    MAX_INLINE_BODY_LENGTH,
    NETWORK_EVENT_VERSION,
    NetworkLoggingMode,
    bodyCache,
    buildStoredBodyPayload,
    bufferEvent,
    captureContentLength,
    captureResponseBody,
    captureXHRResponseBody,
    clampStringToByteLength,
    clearThrottledEvents,
    deliverNetworkEvents,
    encodeTextToBytes,
    enqueueNetworkEvent,
    enqueueThrottledEvent,
    estimatedEncodedLength,
    generateSessionID,
    handleResourceEntry,
    isActiveLogging,
    makeBodyPreviewPayload,
    makeBodyHandle,
    makeBodyRef,
    makeNetworkTime,
    networkState,
    nextRequestID,
    normalizeHeaders,
    now,
    parseRawHeaders,
    queuedEvents,
    serializeRequestBody,
    setThrottleOptions,
    shouldCaptureNetworkBodies,
    shouldQueueNetworkEvent,
    shouldThrottleDelivery,
    shouldTrackNetworkEvents,
    trackedRequests,
    wallTime
};

export type { RequestBodyInfo };
