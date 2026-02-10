import {
    MAX_INLINE_BODY_LENGTH,
    clampStringToByteLength,
    encodeTextToBytes,
    isActiveLogging,
    networkState,
    nextRequestID,
    now,
    shouldQueueNetworkEvent,
    shouldTrackNetworkEvents,
    wallTime
} from "./network-agent-utils";

const MAX_WS_FRAME_BODY_LENGTH = typeof MAX_INLINE_BODY_LENGTH === "number" ? MAX_INLINE_BODY_LENGTH : 64 * 1024;

declare const enqueueEvent: (event: any) => void;

type FramePayload = {
    payload: string;
    base64: boolean;
    size: number;
    truncated: boolean;
};

const serializeFramePayload = async (data: unknown): Promise<FramePayload> => {
    if (data == null) {
        return {payload: "", base64: false, size: 0, truncated: false};
    }
    if (typeof data === "string") {
        const encoded = encodeTextToBytes(data);
        const size = encoded ? encoded.byteLength : data.length;
        const clamped = clampStringToByteLength(data, MAX_WS_FRAME_BODY_LENGTH, encoded);
        const truncated = clamped.truncated || (Number.isFinite(size) && size > MAX_WS_FRAME_BODY_LENGTH);
        return {payload: clamped.text, base64: false, size: size, truncated: truncated};
    }
    try {
        let bytes = null;
        if (typeof Blob !== "undefined" && data instanceof Blob) {
            bytes = new Uint8Array(await data.arrayBuffer());
        } else if (data instanceof ArrayBuffer) {
            bytes = new Uint8Array(data);
        } else if (typeof Uint8Array !== "undefined" && data instanceof Uint8Array) {
            bytes = data;
        }
        if (bytes) {
            const truncated = bytes.byteLength > MAX_WS_FRAME_BODY_LENGTH;
            const slice = truncated ? bytes.slice(0, MAX_WS_FRAME_BODY_LENGTH) : bytes;
            const binary = Array.from(slice as Uint8Array, byte => String.fromCharCode(byte)).join("");
            const base64 = btoa(binary);
            return {payload: base64, base64: true, size: bytes.byteLength, truncated: truncated};
        }
    } catch {
    }
    return {payload: "", base64: false, size: 0, truncated: false};
};

const installWebSocketPatch = () => {
    if (typeof WebSocket !== "function") {
        return;
    }
    const OriginalWebSocket = WebSocket as any;
    function WrappedWebSocket(url: string | URL, protocols?: string | string[]) {
        const socket = new OriginalWebSocket(url, protocols);
        if (!shouldTrackNetworkEvents()) {
            return socket;
        }
        const requestId = nextRequestID();
        postWebSocketEvent({
            type: "wsCreated",
            session: networkState.sessionID,
            requestId: requestId,
            url: url,
            startTime: now(),
            wallTime: wallTime()
        });

        socket.addEventListener("open", () => {
            if (!shouldTrackNetworkEvents()) {
                return;
            }
            postWebSocketEvent({
                type: "wsHandshakeRequest",
                session: networkState.sessionID,
                requestId: requestId,
                // Browser APIs do not expose handshake request headers to JS for security.
                requestHeaders: {},
                startTime: now(),
                wallTime: wallTime()
            });
            postWebSocketEvent({
                type: "wsHandshake",
                session: networkState.sessionID,
                requestId: requestId,
                status: 101,
                statusText: "Switching Protocols",
                endTime: now(),
                wallTime: wallTime()
            });
        });

        socket.addEventListener("message", async (event: MessageEvent) => {
            if (!shouldTrackNetworkEvents()) {
                return;
            }
            const serialized = await serializeFramePayload(event.data);
            const opcode = typeof event.data === "string" ? 1 : 2;
            postWebSocketEvent({
                type: "wsFrame",
                session: networkState.sessionID,
                requestId: requestId,
                endTime: now(),
                wallTime: wallTime(),
                frameDirection: "incoming",
                frameOpcode: opcode,
                framePayload: serialized.payload,
                framePayloadBase64: serialized.base64,
                framePayloadSize: serialized.size,
                framePayloadTruncated: serialized.truncated
            });
        });

        const originalSend = socket.send;
        socket.send = async function(data: unknown) {
            if (!shouldTrackNetworkEvents()) {
                return originalSend.apply(this, arguments);
            }
            const serialized = await serializeFramePayload(data);
            postWebSocketEvent({
                type: "wsFrame",
                session: networkState.sessionID,
                requestId: requestId,
                endTime: now(),
                wallTime: wallTime(),
                frameDirection: "outgoing",
                frameOpcode: typeof data === "string" ? 1 : 2,
                framePayload: serialized.payload,
                framePayloadBase64: serialized.base64,
                framePayloadSize: serialized.size,
                framePayloadTruncated: serialized.truncated
            });
            return originalSend.apply(this, arguments);
        };

        socket.addEventListener("close", (event: CloseEvent) => {
            if (!shouldTrackNetworkEvents()) {
                return;
            }
            postWebSocketEvent({
                type: "wsClosed",
                session: networkState.sessionID,
                requestId: requestId,
                closeCode: event && typeof event.code === "number" ? event.code : undefined,
                closeReason: event && typeof event.reason === "string" ? event.reason : undefined,
                closeWasClean: event && typeof event.wasClean === "boolean" ? event.wasClean : undefined,
                endTime: now(),
                wallTime: wallTime()
            });
        });

        socket.addEventListener("error", (event: any) => {
            if (!shouldTrackNetworkEvents()) {
                return;
            }
            postWebSocketEvent({
                type: "wsFrameError",
                session: networkState.sessionID,
                requestId: requestId,
                endTime: now(),
                wallTime: wallTime(),
                error: event && typeof event.message === "string" && event.message ? event.message : "WebSocket error",
                closeCode: event && typeof event.code === "number" ? event.code : undefined,
                closeReason: event && typeof event.reason === "string" ? event.reason : undefined,
                closeWasClean: event && typeof event.wasClean === "boolean" ? event.wasClean : undefined
            });
        });

        return socket;
    }
    WrappedWebSocket.prototype = OriginalWebSocket.prototype;
    WrappedWebSocket.CLOSED = OriginalWebSocket.CLOSED;
    WrappedWebSocket.CLOSING = OriginalWebSocket.CLOSING;
    WrappedWebSocket.CONNECTING = OriginalWebSocket.CONNECTING;
    WrappedWebSocket.OPEN = OriginalWebSocket.OPEN;
    window.WebSocket = WrappedWebSocket as any;
};

const postWebSocketEvent = (payload: Record<string, any>) => {
    if (!isActiveLogging()) {
        if (shouldQueueNetworkEvent()) {
            enqueueEvent({kind: "websocket", payload});
        }
        return;
    }
    try {
        window.webkit?.messageHandlers?.webInspectorWSUpdate?.postMessage(payload);
    } catch {
    }
};
