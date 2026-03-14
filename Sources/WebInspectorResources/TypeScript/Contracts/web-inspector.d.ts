export {};

import type {
    WebInspectorDOMFrontend,
    ProtocolConfig,
    ProtocolMessage,
    MutationBundle,
    RequestDocumentOptions,
} from "../UI/DOMTree/dom-tree-types";

declare global {
    interface WebInspectorMessageHandler {
        postMessage: (payload: unknown) => void;
    }

    interface WebInspectorMessageHandlers {
        [key: string]: WebInspectorMessageHandler | undefined;
        webInspectorProtocol?: WebInspectorMessageHandler;
        webInspectorLog?: WebInspectorMessageHandler;
        webInspectorReady?: WebInspectorMessageHandler;
        webInspectorDomSelection?: WebInspectorMessageHandler;
        webInspectorDomSelector?: WebInspectorMessageHandler;
        webInspectorWSUpdate?: WebInspectorMessageHandler;
    }

    interface WebKitBridge {
        messageHandlers: WebInspectorMessageHandlers;
    }

    interface Window {
        webInspectorDOMSelection?: Record<string, unknown>;
        webInspectorDOMFrontend?: WebInspectorDOMFrontend;
        webkit?: WebKitBridge;
    }

    var Buffer: {
        from: (bytes: Uint8Array) => { toString: (encoding: string) => string };
    } | undefined;
}
