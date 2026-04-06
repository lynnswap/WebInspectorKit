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
    adoptDocumentContext,
    canAdoptDocumentContext,
    restoreDocumentContext,
    updateConfig,
    completeChildNodeRequest,
    rejectChildNodeRequest,
    retryQueuedChildNodeRequests,
    resetChildNodeRequests,
    matchesCurrentDocumentContext,
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
import { selectNode, setSearchTerm } from "./dom-tree-view-support";

// =============================================================================
// Event Handlers
// =============================================================================

/** Attach event listeners for initial document load */
function attachEventListeners(): void {
    const bootstrap = readBootstrap();
    if (bootstrap.config) {
        updateConfig(bootstrap.config);
    }
    if (bootstrap.context) {
        adoptDocumentContext(bootstrap.context);
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
            const incomingContext = { pageEpoch, documentScopeID };
            if (mode === "preserve-ui-state" && !matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
                return;
            }
            const previousContext = {
                pageEpoch: protocolState.pageEpoch,
                documentScopeID: protocolState.documentScopeID,
            };
            if (mode === "fresh" && !canAdoptDocumentContext(incomingContext)) {
                return;
            }
            if (mode === "fresh") {
                adoptDocumentContext(incomingContext);
            }
            if (!setSnapshot(snapshot as never, { mode })) {
                if (mode === "fresh") {
                    restoreDocumentContext(previousContext);
                }
                return;
            }
        },
        applySubtreePayload: (
            payload,
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
                return;
            }
            if (!applySubtree(payload as never)) {
                return;
            }
        },
        applySelectionPayload: (
            nodeId,
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
                return false;
            }
            return selectNode(nodeId, {
                shouldHighlight: false,
                autoScroll: true,
                notifyNative: false,
            });
        },
        completeChildNodeRequest: (
            nodeId,
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
                return;
            }
            completeChildNodeRequest(nodeId, pageEpoch, documentScopeID);
        },
        rejectChildNodeRequest: (
            nodeId,
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
                return;
            }
            rejectChildNodeRequest(nodeId, pageEpoch, documentScopeID);
        },
        retryQueuedChildNodeRequests: (
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
                return;
            }
            retryQueuedChildNodeRequests();
        },
        resetChildNodeRequests: (
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
                return;
            }
            resetChildNodeRequests(pageEpoch, documentScopeID);
        },
        resetDocumentRequestState: (
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
                return;
            }
            resetDocumentRequestStateForPageEpoch(pageEpoch, documentScopeID);
        },
        rejectDocumentRequest: (
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
                return;
            }
            rejectDocumentRequest(pageEpoch, documentScopeID);
        },
        completeDocumentRequest: (
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
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
