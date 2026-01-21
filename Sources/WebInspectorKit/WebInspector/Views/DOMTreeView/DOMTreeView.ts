// @ts-nocheck
(function() {
    const {DOMTreeProtocol, DOMTreeSnapshot, DOMTreeViewSupport} = window.DOMTree || {};
    const {
        dispatchMessageFromBackend,
        updateConfig
    } = DOMTreeProtocol;
    const {
        applyMutationBundle,
        applyMutationBundles,
        registerProtocolHandlers,
        requestDocument,
        setPreferredDepth
    } = DOMTreeSnapshot;
    const {setSearchTerm} = DOMTreeViewSupport;

    function attachEventListeners() {
        try {
            window.webkit.messageHandlers.webInspectorReady.postMessage(true);
        } catch {
            // ignore
        }
        void requestDocument({preserveState: false});
    }

    function installWebInspectorKit() {
        if (window.webInspectorDOMFrontend && window.webInspectorDOMFrontend.__installed) {
            return;
        }

        registerProtocolHandlers();

        const webInspectorDOMFrontend = {
            dispatchMessageFromBackend,
            applyMutationBundle,
            applyMutationBundles,
            requestDocument,
            setSearchTerm,
            setPreferredDepth,
            updateConfig,
            __installed: true
        };

        Object.defineProperty(window, "webInspectorDOMFrontend", {
            value: Object.freeze(webInspectorDOMFrontend),
            writable: false,
            configurable: false
        });

        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", attachEventListeners, {once: true});
        } else {
            attachEventListeners();
        }
    }

    installWebInspectorKit();
})();
