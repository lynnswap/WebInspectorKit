(function(scope) {
    const {protocolState} = scope.DOMTreeState;
    const {safeParseJSON} = scope.DOMTreeUtilities;

    let requestChildNodesHandler = null;

    function setRequestChildNodesHandler(handler) {
        requestChildNodesHandler = typeof handler === "function" ? handler : null;
    }

    function updateConfig(partial) {
        if (typeof partial !== "object" || partial === null) {
            return;
        }
        if (typeof partial.snapshotDepth === "number") {
            protocolState.snapshotDepth = partial.snapshotDepth;
        }
        if (typeof partial.subtreeDepth === "number") {
            protocolState.subtreeDepth = partial.subtreeDepth;
        }
    }

    function sendProtocolMessage(message) {
        const payload = typeof message === "string" ? message : JSON.stringify(message);
        window.webkit.messageHandlers.webInspectorProtocol.postMessage(payload);
    }

    async function sendCommand(method, params = {}) {
        const id = ++protocolState.lastId;
        const message = {id, method, params};
        return new Promise((resolve, reject) => {
            protocolState.pending.set(id, {resolve, reject, method});
            try {
                sendProtocolMessage(message);
            } catch (error) {
                protocolState.pending.delete(id);
                reject(error);
            }
        });
    }

    function dispatchMessageFromBackend(message) {
        const parsed = safeParseJSON(message);
        if (!parsed || typeof parsed !== "object") {
            return;
        }
        if (Object.prototype.hasOwnProperty.call(parsed, "id")) {
            const requestId = parsed.id;
            if (typeof requestId !== "number") {
                return;
            }
            const pending = protocolState.pending.get(requestId);
            if (!pending) {
                return;
            }
            protocolState.pending.delete(requestId);
            if (parsed.error) {
                pending.reject(parsed.error);
            } else {
                const method = pending.method || "";
                let result = parsed.result;
                if (typeof result === "string") {
                    result = safeParseJSON(result) || result;
                }
                if (method === "DOM.requestChildNodes" && typeof requestChildNodesHandler === "function") {
                    requestChildNodesHandler(result);
                }
                pending.resolve(result);
            }
            return;
        }
        if (typeof parsed.method !== "string") {
            return;
        }
        emitProtocolEvent(parsed.method, parsed.params || {}, parsed);
    }

    function onProtocolEvent(method, handler) {
        if (!protocolState.eventHandlers.has(method)) {
            protocolState.eventHandlers.set(method, new Set());
        }
        protocolState.eventHandlers.get(method).add(handler);
    }

    function emitProtocolEvent(method, params, rawMessage) {
        const listeners = protocolState.eventHandlers.get(method);
        if (!listeners || !listeners.size) {
            return;
        }
        listeners.forEach(listener => {
            try {
                listener(params, method, rawMessage);
            } catch (error) {
                reportInspectorError(`event:${method}`, error);
            }
        });
    }

    function reportInspectorError(context, error) {
        const details = error && error.stack
            ? error.stack
            : (error && error.message ? error.message : String(error));
        console.error(`[WebInspectorKit] ${context}:`, error);
        try {
            window.webkit.messageHandlers.webInspectorLog.postMessage(`${context}: ${details}`);
        } catch {
            // ignore logging failures
        }
    }

    scope.DOMTreeProtocol = {
        setRequestChildNodesHandler,
        updateConfig,
        sendProtocolMessage,
        sendCommand,
        dispatchMessageFromBackend,
        onProtocolEvent,
        emitProtocolEvent,
        reportInspectorError
    };
})(window.DOMTree || (window.DOMTree = {}));
