export {};

type WebKitMessageHandler = {
    postMessage: (message: any) => void;
};

declare global {
    interface Window {
        webInspectorDOM?: {
            __installed?: boolean;
            detach?: () => void;
        };
        webInspectorNetworkAgent?: {
            __installed?: boolean;
        };
        webkit?: {
            createJSHandle?: (value: unknown) => unknown;
            serializeNode?: (node: Node) => unknown;
            buffers?: Record<string, unknown>;
            messageHandlers?: {
                webInspectorDOMSnapshot?: WebKitMessageHandler;
                webInspectorDOMMutations?: WebKitMessageHandler;
                webInspectorNetworkEvents?: WebKitMessageHandler;
                webInspectorNetworkReset?: WebKitMessageHandler;
                webInspectorWSUpdate?: WebKitMessageHandler;
            };
        };
    }

    interface XMLHttpRequest {
        __wiNetwork?: {
            method: string;
            url: string;
            headers: Record<string, string>;
            requestBody?: any;
        };
    }
}
