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
        webInspectorNetworkAgent?: {
            __installed?: boolean;
            bootstrapAuthToken?: (authToken: unknown) => void;
        };
        __wiBootstrapNetworkAuthToken?: (authToken: unknown) => void;
        webkit?: {
            createJSHandle?: (value: unknown) => unknown;
            serializeNode?: (node: Node) => unknown;
            buffers?: Record<string, unknown>;
            messageHandlers?: {
                webInspectorDomRequestChildren?: WebKitMessageHandler;
                webInspectorDomHighlight?: WebKitMessageHandler;
                webInspectorDomHideHighlight?: WebKitMessageHandler;
                webInspectorLog?: WebKitMessageHandler;
                webInspectorReady?: WebKitMessageHandler;
                webInspectorDomSelection?: WebKitMessageHandler;
                webInspectorNetworkEvents?: WebKitMessageHandler;
                webInspectorNetworkReset?: WebKitMessageHandler;
                webInspectorWSUpdate?: WebKitMessageHandler;
            };
        };
    };

    interface XMLHttpRequest {
        __wiNetwork?: {
            method: string;
            url: string;
            headers: Record<string, string>;
            requestBody?: any;
        };
    }
}
