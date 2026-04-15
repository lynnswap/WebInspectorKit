/**
 * DOMTreeView - Entry point for the DOM tree inspector UI.
 *
 * This module:
 * - Registers tree event handlers
 * - Initializes the public API on window.webInspectorDOMFrontend
 * - Triggers the initial document request on DOMContentLoaded
 */

import {
    DOMFrontendBootstrapState,
    DOMSelectionSyncPayload,
    WebInspectorDOMFrontend,
} from "./dom-tree-types";
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
import { protocolState, transitionState } from "./dom-tree-state";
import {
    applySubtree,
    completeDocumentRequest,
    rejectDocumentRequest,
    requestSelectionRecoveryIfNeeded,
    setSnapshot,
    resetDocumentRequestStateForPageEpoch,
    applyMutationBuffer,
    applyMutationBundle,
    applyMutationBundles,
    registerTreeHandlers,
    setPreferredDepth,
} from "./dom-tree-snapshot";
import { selectNode, selectNodeByPath, setSearchTerm } from "./dom-tree-view-support";

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

function normalizeSelectionSyncPayload(
    payload: number | DOMSelectionSyncPayload
): { nodeId: number | null; selectedLocalId: number | null; selectedBackendNodeId: number | null; selectedNodePath: number[] | null } {
    if (typeof payload === "number" && Number.isFinite(payload)) {
        return {
            nodeId: payload > 0 ? payload : null,
            selectedLocalId: payload > 0 ? payload : null,
            selectedBackendNodeId: null,
            selectedNodePath: null,
        };
    }
    if (!payload || typeof payload !== "object") {
        return {
            nodeId: null,
            selectedLocalId: null,
            selectedBackendNodeId: null,
            selectedNodePath: null,
        };
    }

    const candidateNodeIDs = [
        payload.selectedLocalId,
        payload.localID,
        payload.localId,
        payload.nodeId,
        payload.id,
    ];
    const selectedLocalId =
        candidateNodeIDs.find((candidate) => typeof candidate === "number" && Number.isFinite(candidate) && candidate > 0)
        ?? null;
    const selectedNodePath = Array.isArray(payload.selectedNodePath)
        && payload.selectedNodePath.every((segment) => typeof segment === "number" && Number.isInteger(segment))
        ? payload.selectedNodePath
        : null;
    const backendNodeIDCandidates = [
        payload.selectedBackendNodeId,
        payload.backendNodeId,
        payload.backendNodeID,
    ];
    const selectedBackendNodeId =
        payload.backendNodeIdIsStable === false
            ? null
            : backendNodeIDCandidates.find((candidate) => typeof candidate === "number" && Number.isFinite(candidate) && candidate > 0)
                ?? null;
    return {
        nodeId: selectedLocalId,
        selectedLocalId,
        selectedBackendNodeId,
        selectedNodePath,
    };
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
            const shouldForceFreshSnapshot =
                transitionState.pendingFreshSnapshotContext?.pageEpoch === pageEpoch
                && transitionState.pendingFreshSnapshotContext?.documentScopeID === documentScopeID;
            const snapshotMode = shouldForceFreshSnapshot ? "fresh" : mode;
            if (snapshotMode === "preserve-ui-state" && !matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
                return;
            }
            const previousContext = {
                pageEpoch: protocolState.pageEpoch,
                documentScopeID: protocolState.documentScopeID,
            };
            const previousPendingFreshSnapshotContext = transitionState.pendingFreshSnapshotContext
                ? { ...transitionState.pendingFreshSnapshotContext }
                : null;
            if (snapshotMode === "fresh" && !canAdoptDocumentContext(incomingContext)) {
                return;
            }
            if (snapshotMode === "fresh") {
                adoptDocumentContext(incomingContext);
            }
            if (!setSnapshot(snapshot as never, { mode: snapshotMode })) {
                if (snapshotMode === "fresh") {
                    restoreDocumentContext(previousContext, {
                        pendingFreshSnapshotContext: previousPendingFreshSnapshotContext,
                    });
                }
                return;
            }
            if (snapshotMode === "fresh") {
                transitionState.pendingFreshSnapshotContext = null;
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
            payload,
            pageEpoch = protocolState.pageEpoch,
            documentScopeID = protocolState.documentScopeID
        ) => {
            if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
                return false;
            }
            const selection = normalizeSelectionSyncPayload(payload);
            const selectionOptions = {
                shouldHighlight: false,
                autoScroll: true,
                notifyNative: false,
            };
            if (typeof selection.nodeId === "number" && selectNode(selection.nodeId, selectionOptions)) {
                return true;
            }
            if (Array.isArray(selection.selectedNodePath)) {
                if (selectNodeByPath(selection.selectedNodePath, selectionOptions)) {
                    return true;
                }
            }
            requestSelectionRecoveryIfNeeded(
                {
                    selectedLocalId: selection.selectedLocalId,
                    selectedBackendNodeId: selection.selectedBackendNodeId,
                    selectedNodePath: selection.selectedNodePath,
                },
                pageEpoch,
                documentScopeID
            );
            return false;
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
        adoptDocumentContext,
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
