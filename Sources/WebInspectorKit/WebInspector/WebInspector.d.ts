export {};

declare global {
    interface WebInspectorMessageHandler {
        postMessage: (payload: any) => void;
    }

    interface WebInspectorMessageHandlers {
        [key: string]: WebInspectorMessageHandler | undefined;
    }

    interface WebKitBridge {
        messageHandlers: WebInspectorMessageHandlers;
    }

    interface Window {
        DOMTree?: Record<string, any>;
        webInspectorDOM?: Record<string, any>;
        webInspectorDOMFrontend?: Record<string, any>;
        webInspectorNetworkAgent?: Record<string, any>;
        webkit?: WebKitBridge;
    }

    var Buffer: {
        from: (bytes: Uint8Array) => { toString: (encoding: string) => string };
    } | undefined;
}
