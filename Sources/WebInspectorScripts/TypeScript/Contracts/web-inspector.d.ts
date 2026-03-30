export {};

import type {
    WebInspectorDOMFrontend,
    ProtocolConfig,
    MutationBundle,
} from "../UI/DOMTree/dom-tree-types";

declare global {
    interface WebInspectorMessageHandler {
        postMessage: (payload: unknown) => void;
    }

    interface WebInspectorMessageHandlers {
        [key: string]: WebInspectorMessageHandler | undefined;
        webInspectorDomRequestDocument?: WebInspectorMessageHandler;
        webInspectorDomRequestChildren?: WebInspectorMessageHandler;
        webInspectorDomHighlight?: WebInspectorMessageHandler;
        webInspectorDomHideHighlight?: WebInspectorMessageHandler;
        webInspectorLog?: WebInspectorMessageHandler;
        webInspectorReady?: WebInspectorMessageHandler;
        webInspectorDomSelection?: WebInspectorMessageHandler;
        webInspectorWSUpdate?: WebInspectorMessageHandler;
    }

    interface WebKitBridge {
        createJSHandle?: (value: unknown) => unknown;
        serializeNode?: (node: Node) => unknown;
        buffers?: Record<string, unknown>;
        messageHandlers: WebInspectorMessageHandlers;
    }

    interface Window {
        webInspectorDOM?: Record<string, unknown>;
        webInspectorDOMFrontend?: WebInspectorDOMFrontend;
        webInspectorNetworkAgent?: Record<string, unknown>;
        webkit?: WebKitBridge;
    }

    var Buffer: {
        from: (bytes: Uint8Array) => { toString: (encoding: string) => string };
    } | undefined;
}
