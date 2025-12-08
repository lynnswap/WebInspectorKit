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

const postWebSocketEvent = payload => {
    postNetworkEvent(payload);
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
            type: "webSocketCreated",
            session: identity.session,
            requestId: identity.requestId,
            url: url,
            startTime: now(),
            wallTime: wallTime()
        });

        socket.addEventListener("open", () => {
            postWebSocketEvent({
                type: "webSocketHandshake",
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
            postWebSocketEvent({
                type: "webSocketFrameReceived",
                session: identity.session,
                requestId: identity.requestId,
                endTime: now(),
                wallTime: wallTime(),
                frameDirection: "incoming",
                frameOpcode: typeof event.type === "string" ? 1 : 1,
                framePayload: serialized.payload,
                framePayloadBase64: serialized.base64,
                framePayloadSize: serialized.size
            });
        });

        const originalSend = socket.send;
        socket.send = async function(data) {
            const serialized = await serializeFramePayload(data);
            postWebSocketEvent({
                type: "webSocketFrameSent",
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
                type: "webSocketClosed",
                session: identity.session,
                requestId: identity.requestId,
                endTime: now(),
                wallTime: wallTime()
            });
        });

        socket.addEventListener("error", () => {
            postWebSocketEvent({
                type: "webSocketError",
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
