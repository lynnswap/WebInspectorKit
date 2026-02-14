/**
 * DOMTreeView - Entry point for the DOM tree inspector UI.
 *
 * This module:
 * - Registers protocol event handlers
 * - Initializes the public API on window.webInspectorDOMFrontend
 * - Triggers the initial document request on DOMContentLoaded
 */

import { WebInspectorDOMFrontend } from "./dom-tree-types";
import {
    dispatchMessageFromBackend,
    updateConfig,
} from "./dom-tree-protocol";
import {
    applyMutationBundle,
    applyMutationBundles,
    registerProtocolHandlers,
    requestDocument,
    setPreferredDepth,
} from "./dom-tree-snapshot";
import { setSearchTerm } from "./dom-tree-view-support";

// =============================================================================
// Event Handlers
// =============================================================================

/** Attach event listeners for initial document load */
function attachEventListeners(): void {
    try {
        window.webkit?.messageHandlers?.webInspectorReady?.postMessage(true);
    } catch {
        // ignore
    }
    void requestDocument({ preserveState: false });
}

// =============================================================================
// Installation
// =============================================================================

/** Install WebInspectorKit DOMTreeView frontend */
function installWebInspectorKit(): void {
    if (window.webInspectorDOMFrontend && window.webInspectorDOMFrontend.__installed) {
        return;
    }

    registerProtocolHandlers();

    const webInspectorDOMFrontend: WebInspectorDOMFrontend = {
        dispatchMessageFromBackend,
        applyMutationBundle,
        applyMutationBundles,
        requestDocument,
        setSearchTerm,
        setPreferredDepth,
        updateConfig,
        __installed: true,
    };

    Object.defineProperty(window, "webInspectorDOMFrontend", {
        value: Object.freeze(webInspectorDOMFrontend),
        writable: false,
        configurable: false,
    });

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", attachEventListeners, { once: true });
    } else {
        attachEventListeners();
    }
}

// =============================================================================
// Auto-initialization
// =============================================================================

installWebInspectorKit();
