export {};

type WebKitMessageHandler = {
    postMessage: (message: any) => void;
};

declare global {
    interface Window {
        webInspectorDOMSelection?: {
            __installed?: boolean;
            detach?: () => void;
            startSelection?: () => Promise<{ cancelled: boolean; requiredDepth: number }>;
            cancelSelection?: () => boolean;
            consumePendingSelectionPath?: () => number[] | null;
            clearHighlight?: () => void;
        };
        webkit?: {
            messageHandlers?: {
                webInspectorProtocol?: WebKitMessageHandler;
                webInspectorLog?: WebKitMessageHandler;
                webInspectorReady?: WebKitMessageHandler;
                webInspectorDomSelection?: WebKitMessageHandler;
                webInspectorDomSelector?: WebKitMessageHandler;
                webInspectorWSUpdate?: WebKitMessageHandler;
            };
        };
    }
}
