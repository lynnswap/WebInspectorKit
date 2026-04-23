/**
 * DOMTreeView - Entry point for the DOM tree inspector UI.
 */

import {
    DOMFrontendBootstrapState,
    DOMSelectionSyncPayload,
    WebInspectorDOMFrontend,
} from "./dom-tree-types";
import {
    adoptDocumentContext,
    finishChildNodeRequest,
    matchesCurrentDocumentContext,
    updateConfig,
} from "./dom-tree-protocol";
import { protocolState, treeState } from "./dom-tree-state";
import {
    applySubtree,
    applyMutationBuffer,
    applyMutationBundle,
    applyMutationBundles,
    handleDocumentUpdated,
    registerTreeHandlers,
    setSnapshot,
} from "./dom-tree-snapshot";
import {
    clearPointerHoverState,
    selectNode,
    selectNodeByPath,
    setSearchTerm,
} from "./dom-tree-view-support";

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

function applyBootstrap(bootstrap: DOMFrontendBootstrapState): void {
    if (bootstrap.config) {
        updateConfig(bootstrap.config);
    }
    if (bootstrap.context) {
        adoptDocumentContext(bootstrap.context);
    }
}

function notifyReady(): void {
    try {
        window.webkit?.messageHandlers?.webInspectorReady?.postMessage({
            contextID: protocolState.contextID,
        });
    } catch {
        // ignore
    }
}

function attachEventListeners(): void {
    applyBootstrap(readBootstrap());
    notifyReady();
}

function ensureFrontendContext(contextID: number | undefined): boolean {
    if (matchesCurrentDocumentContext(contextID)) {
        return true;
    }
    const bootstrapContextID = readBootstrap().context?.contextID;
    if (
        typeof contextID === "number"
        && Number.isFinite(contextID)
        && bootstrapContextID === contextID
        && (
            treeState.snapshot === null
            || treeState.nodes.size === 0
        )
    ) {
        adoptDocumentContext({ contextID });
        return true;
    }
    return false;
}

function normalizeSelectionSyncPayload(
    payload: number | DOMSelectionSyncPayload
): { nodeId: number | null; selectedNodePath: number[] | null } {
    if (typeof payload === "number" && Number.isFinite(payload)) {
        return {
            nodeId: payload > 0 ? payload : null,
            selectedNodePath: null,
        };
    }
    if (!payload || typeof payload !== "object") {
        return {
            nodeId: null,
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
    const nodeId =
        candidateNodeIDs.find((candidate) => typeof candidate === "number" && Number.isFinite(candidate) && candidate > 0)
        ?? null;
    const selectedNodePath = Array.isArray(payload.selectedNodePath)
        && payload.selectedNodePath.every((segment) => typeof segment === "number" && Number.isInteger(segment))
        ? payload.selectedNodePath
        : null;
    return {
        nodeId,
        selectedNodePath,
    };
}

function installWebInspectorKit(): void {
    if (window.webInspectorDOMFrontend && window.webInspectorDOMFrontend.__installed) {
        return;
    }

    registerTreeHandlers();

    const webInspectorDOMFrontend: WebInspectorDOMFrontend & {
        updateBootstrap?: (bootstrap: DOMFrontendBootstrapState) => void;
    } = {
        updateBootstrap: (bootstrap: DOMFrontendBootstrapState) => {
            (window as Window & { __wiDOMFrontendBootstrap?: DOMFrontendBootstrapState }).__wiDOMFrontendBootstrap = bootstrap;
            applyBootstrap(bootstrap);
            notifyReady();
        },
        invalidateDocumentContext: (contextID = protocolState.contextID) => {
            if (typeof contextID === "number" && Number.isFinite(contextID)) {
                adoptDocumentContext({ contextID });
            }
            handleDocumentUpdated();
        },
        applyFullSnapshot: (snapshot, contextID = protocolState.contextID) => {
            if (!ensureFrontendContext(contextID)) {
                return false;
            }
            return setSnapshot(snapshot as never);
        },
        applySubtreePayload: (payload, contextID = protocolState.contextID) => {
            if (!ensureFrontendContext(contextID)) {
                return false;
            }
            return applySubtree(payload as never);
        },
        applySelectionPayload: (payload, contextID = protocolState.contextID) => {
            if (!ensureFrontendContext(contextID)) {
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
                return selectNodeByPath(selection.selectedNodePath, selectionOptions);
            }
            treeState.selectedNodeId = null;
            return false;
        },
        finishChildNodeRequest: (nodeId, success, contextID = protocolState.contextID) => {
            if (!ensureFrontendContext(contextID)) {
                return;
            }
            finishChildNodeRequest(nodeId, success, contextID);
        },
        applyMutationBundle,
        applyMutationBundles,
        applyMutationBuffer,
        setSearchTerm,
        updateConfig,
        adoptDocumentContext,
        clearPointerHoverState,
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

installWebInspectorKit();
