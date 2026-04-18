export {};

type WebKitMessageHandler = {
    postMessage: (message: any) => void;
};

declare global {
    interface Window {
        __wiDOMFrontendInitialContextID?: number;
        __wiDOMAgentBootstrap?: {
            contextID?: number;
            autoSnapshot?: {
                enabled?: boolean;
                maxDepth?: number;
                debounce?: number;
            };
        };
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
        webInspectorDOM?: {
            __installed?: boolean;
            detach?: () => void;
            setContextID?: (contextID: number) => void;
            bootstrap?: (bootstrap?: {
                contextID?: number;
                autoSnapshot?: {
                    enabled?: boolean;
                    maxDepth?: number;
                    debounce?: number;
                };
            } | null) => boolean;
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
                webInspectorDOMSnapshot?: WebKitMessageHandler;
                webInspectorDOMMutations?: WebKitMessageHandler;
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
