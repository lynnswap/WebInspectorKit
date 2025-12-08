const serializeFramePayload = async data => {
    if (data == null) {
        return {payload: "", base64: false, size: 0};
    }
    if (typeof data === "string") {
        const truncated = data.length > MAX_BODY_LENGTH;
        const body = truncated ? data.slice(0, MAX_BODY_LENGTH) : data;
        return {payload: body, base64: false, size: data.length};
    }
    try {
        if (typeof Blob !== "undefined" && data instanceof Blob) {
            const buffer = await data.arrayBuffer();
            return serializeFramePayload(new Uint8Array(buffer));
        }
        if (data instanceof ArrayBuffer) {
            return serializeFramePayload(new Uint8Array(data));
        }
        if (typeof Uint8Array !== "undefined" && data instanceof Uint8Array) {
            const binary = Array.from(data, byte => String.fromCharCode(byte)).join("");
            const base64 = btoa(binary);
            return {payload: base64, base64: true, size: data.byteLength};
        }
    } catch {
    }
    return {payload: "", base64: false, size: 0};
};

const installWebSocketPatch = () => {
    if (typeof WebSocket !== "function") {
        return;
    }
    const OriginalWebSocket = WebSocket;
    function WrappedWebSocket(url, protocols) {
        const socket = new OriginalWebSocket(url, protocols);
        const identity = nextRequestIdentity();
        postWebSocketEvent({
            type: "wsCreated",
            session: identity.session,
            requestId: identity.requestId,
            url: url,
            startTime: now(),
            wallTime: wallTime()
        });

        socket.addEventListener("open", () => {
            postWebSocketEvent({
                type: "wsHandshakeRequest",
                session: identity.session,
                requestId: identity.requestId,
                requestHeaders: {},
                startTime: now(),
                wallTime: wallTime()
            });
            postWebSocketEvent({
                type: "wsHandshake",
                session: identity.session,
                requestId: identity.requestId,
                status: 101,
                statusText: "Switching Protocols",
                endTime: now(),
                wallTime: wallTime()
            });
        });

        socket.addEventListener("message", async event => {
            const serialized = await serializeFramePayload(event.data);
            const opcode = typeof event.data === "string" ? 1 : 2;
            postWebSocketEvent({
                type: "wsFrame",
                session: identity.session,
                requestId: identity.requestId,
                endTime: now(),
                wallTime: wallTime(),
                frameDirection: "incoming",
                frameOpcode: opcode,
                framePayload: serialized.payload,
                framePayloadBase64: serialized.base64,
                framePayloadSize: serialized.size
            });
        });

        const originalSend = socket.send;
        socket.send = async function(data) {
            const serialized = await serializeFramePayload(data);
            postWebSocketEvent({
                type: "wsFrame",
                session: identity.session,
                requestId: identity.requestId,
                endTime: now(),
                wallTime: wallTime(),
                frameDirection: "outgoing",
                frameOpcode: typeof data === "string" ? 1 : 2,
                framePayload: serialized.payload,
                framePayloadBase64: serialized.base64,
                framePayloadSize: serialized.size
            });
            return originalSend.apply(this, arguments);
        };

        socket.addEventListener("close", () => {
            postWebSocketEvent({
                type: "wsClosed",
                session: identity.session,
                requestId: identity.requestId,
                endTime: now(),
                wallTime: wallTime()
            });
        });

        socket.addEventListener("error", () => {
            postWebSocketEvent({
                type: "wsFrameError",
                session: identity.session,
                requestId: identity.requestId,
                endTime: now(),
                wallTime: wallTime(),
                error: "WebSocket error"
            });
        });

        return socket;
    }
    WrappedWebSocket.prototype = OriginalWebSocket.prototype;
    WrappedWebSocket.CLOSED = OriginalWebSocket.CLOSED;
    WrappedWebSocket.CLOSING = OriginalWebSocket.CLOSING;
    WrappedWebSocket.CONNECTING = OriginalWebSocket.CONNECTING;
    WrappedWebSocket.OPEN = OriginalWebSocket.OPEN;
    window.WebSocket = WrappedWebSocket;
};
const postWebSocketEvent = payload => {
    if (!networkState.enabled) {
        queuedEvents.push({kind: "websocket", payload});
        return;
    }
    try {
        window.webkit.messageHandlers.webInspectorWSUpdate.postMessage(payload);
    } catch {
    }
};
