export {};

type WebKitMessageHandler = {
    postMessage: (message: any) => void;
};

declare global {
    interface Window {
        __wiDOMFrontendInitialPageEpoch?: number;
        __wiDOMAgentBootstrap?: {
            pageEpoch?: number;
            documentScopeID?: number;
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
                pageEpoch?: number;
                documentScopeID?: number;
            };
            preferredDepth?: number;
            pendingDocumentRequest?: {
                depth?: number;
                mode?: "fresh" | "preserve-ui-state";
                pageEpoch?: number;
            } | null;
        };
        webInspectorDOM?: {
            __installed?: boolean;
            detach?: () => void;
            setPageEpoch?: (epoch: number) => void;
            setPendingSelectionPath?: (path: number[] | null) => boolean;
            bootstrap?: (bootstrap?: {
                pageEpoch?: number;
                documentScopeID?: number;
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
                webInspectorDOMLog?: WebKitMessageHandler;
                webInspectorDomRequestDocument?: WebKitMessageHandler;
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
