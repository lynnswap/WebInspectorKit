/**
 * DOMTreeView - Entry point for the DOM tree inspector UI.
 *
 * This module:
 * - Registers tree event handlers
 * - Initializes the public API on window.webInspectorDOMFrontend
 * - Triggers the initial document request on DOMContentLoaded
 */

import { DOMFrontendBootstrapState, WebInspectorDOMFrontend } from "./dom-tree-types";
import {
    updateConfig,
    completeChildNodeRequest,
    rejectChildNodeRequest,
    retryQueuedChildNodeRequests,
    resetChildNodeRequests,
} from "./dom-tree-protocol";
import { protocolState } from "./dom-tree-state";
import {
    applySubtree,
    completeDocumentRequest,
    rejectDocumentRequest,
    setSnapshot,
    resetDocumentRequestStateForPageEpoch,
    applyMutationBuffer,
    applyMutationBundle,
    applyMutationBundles,
    registerTreeHandlers,
    setPreferredDepth,
} from "./dom-tree-snapshot";
import { setSearchTerm } from "./dom-tree-view-support";

// =============================================================================
// Event Handlers
// =============================================================================

/** Attach event listeners for initial document load */
function attachEventListeners(): void {
    const bootstrap = readBootstrap();
    if (bootstrap.config) {
        updateConfig(bootstrap.config);
    }
    if (typeof bootstrap.preferredDepth === "number") {
        setPreferredDepth(bootstrap.preferredDepth, protocolState.pageEpoch);
    }
    try {
        window.webkit?.messageHandlers?.webInspectorReady?.postMessage({
            pageEpoch: protocolState.pageEpoch,
            documentScopeID: protocolState.documentScopeID,
        });
    } catch {
        // ignore
    }
    bootstrap.pendingDocumentRequest = null;
}

function readBootstrap(): DOMFrontendBootstrapState {
    const globalBootstrap = (window as Window & {
        __wiDOMFrontendBootstrap?: DOMFrontendBootstrapState;
    }).__wiDOMFrontendBootstrap;
    if (globalBootstrap && typeof globalBootstrap === "object") {
        return globalBootstrap;
    }
    const bootstrap: DOMFrontendBootstrapState = {};
    (window as Window & { __wiDOMFrontendBootstrap?: DOMFrontendBootstrapState }).__wiDOMFrontendBootstrap = bootstrap;
    return bootstrap;
}

// =============================================================================
// Installation
// =============================================================================

/** Install WebInspectorKit DOMTreeView frontend */
function installWebInspectorKit(): void {
    if (window.webInspectorDOMFrontend && window.webInspectorDOMFrontend.__installed) {
        return;
    }

    registerTreeHandlers();

    const webInspectorDOMFrontend: WebInspectorDOMFrontend = {
        applyFullSnapshot: (
            snapshot,
            mode = "fresh",
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (pageEpoch !== protocolState.pageEpoch || documentScopeID !== protocolState.documentScopeID) {
                return;
            }
            setSnapshot(snapshot as never, { mode });
        },
        applySubtreePayload: (
            payload,
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (pageEpoch !== protocolState.pageEpoch || documentScopeID !== protocolState.documentScopeID) {
                return;
            }
            applySubtree(payload as never);
        },
        completeChildNodeRequest: (
            nodeId,
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (pageEpoch !== protocolState.pageEpoch || documentScopeID !== protocolState.documentScopeID) {
                return;
            }
            completeChildNodeRequest(nodeId, pageEpoch, documentScopeID);
        },
        rejectChildNodeRequest: (
            nodeId,
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (pageEpoch !== protocolState.pageEpoch || documentScopeID !== protocolState.documentScopeID) {
                return;
            }
            rejectChildNodeRequest(nodeId, pageEpoch, documentScopeID);
        },
        retryQueuedChildNodeRequests: (
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (pageEpoch !== protocolState.pageEpoch || documentScopeID !== protocolState.documentScopeID) {
                return;
            }
            retryQueuedChildNodeRequests();
        },
        resetChildNodeRequests: (
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (pageEpoch !== protocolState.pageEpoch || documentScopeID !== protocolState.documentScopeID) {
                return;
            }
            resetChildNodeRequests(pageEpoch, documentScopeID);
        },
        resetDocumentRequestState: (
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (pageEpoch !== protocolState.pageEpoch || documentScopeID !== protocolState.documentScopeID) {
                return;
            }
            resetDocumentRequestStateForPageEpoch(pageEpoch, documentScopeID);
        },
        rejectDocumentRequest: (
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (pageEpoch !== protocolState.pageEpoch || documentScopeID !== protocolState.documentScopeID) {
                return;
            }
            rejectDocumentRequest(pageEpoch, documentScopeID);
        },
        completeDocumentRequest: (
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (pageEpoch !== protocolState.pageEpoch || documentScopeID !== protocolState.documentScopeID) {
                return;
            }
            completeDocumentRequest(pageEpoch, documentScopeID);
        },
        applyMutationBundle,
        applyMutationBundles,
        applyMutationBuffer,
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
