export {};

type WebKitMessageHandler = {
    postMessage: (message: any) => void;
};

declare global {
    interface Window {
        __wiDOMFrontendInitialContextID?: number;
        __wiDOMFrontendBootstrap?: {
            config?: {
                snapshotDepth?: number;
                subtreeDepth?: number;
                autoUpdateDebounce?: number;
            };
            context?: {
                contextID?: number;
            } | null;
        };
        webkit?: {
            createJSHandle?: (value: unknown) => unknown;
            serializeNode?: (node: Node) => unknown;
            buffers?: Record<string, unknown>;
            messageHandlers?: {
                webInspectorDomRequestChildren?: WebKitMessageHandler;
                webInspectorDomReloadSnapshot?: WebKitMessageHandler;
                webInspectorDomHighlight?: WebKitMessageHandler;
                webInspectorDomHideHighlight?: WebKitMessageHandler;
                webInspectorLog?: WebKitMessageHandler;
                webInspectorReady?: WebKitMessageHandler;
                webInspectorDomSelection?: WebKitMessageHandler;
            };
        };
    };
}
