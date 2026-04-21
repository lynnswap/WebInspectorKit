/**
 * DOMTreeState - Core state management for DOMTreeView.
 */

import {
    DOMElements,
    DOMNode,
    PendingRenderItem,
    ProtocolState,
    RefreshAttempt,
    RenderState,
    TreeState,
    DOMFrontendBootstrapState,
    NODE_TYPES,
    INDENT_DEPTH_LIMIT,
    LAYOUT_FLAG_RENDERED,
    TEXT_CONTENT_ATTRIBUTE,
    DOM_EVENT_BATCH_LIMIT,
    DOM_EVENT_TIME_BUDGET,
    RENDER_BATCH_LIMIT,
    RENDER_TIME_BUDGET,
    REFRESH_RETRY_LIMIT,
    REFRESH_RETRY_WINDOW,
} from "./dom-tree-types";

const initialBootstrap =
    ((window as Window & { __wiDOMFrontendBootstrap?: DOMFrontendBootstrapState }).__wiDOMFrontendBootstrap ?? {});
const initialConfig = typeof initialBootstrap.config === "object" && initialBootstrap.config !== null
    ? initialBootstrap.config
    : {};
const initialContext = typeof initialBootstrap.context === "object" && initialBootstrap.context !== null
    ? initialBootstrap.context
    : {};

export {
    NODE_TYPES,
    INDENT_DEPTH_LIMIT,
    LAYOUT_FLAG_RENDERED,
    TEXT_CONTENT_ATTRIBUTE,
    DOM_EVENT_BATCH_LIMIT,
    DOM_EVENT_TIME_BUDGET,
    RENDER_BATCH_LIMIT,
    RENDER_TIME_BUDGET,
    REFRESH_RETRY_LIMIT,
    REFRESH_RETRY_WINDOW,
};

export const dom: DOMElements = {
    tree: null,
    empty: null,
};

export function ensureDomElements(): void {
    if (!dom.tree || !dom.tree.isConnected || dom.tree.id !== "dom-tree") {
        dom.tree = document.getElementById("dom-tree");
    }
    if (!dom.empty || !dom.empty.isConnected || dom.empty.id !== "dom-empty") {
        dom.empty = document.getElementById("dom-empty");
    }
}

export const protocolState: ProtocolState = {
    snapshotDepth: typeof initialConfig.snapshotDepth === "number" ? initialConfig.snapshotDepth : 4,
    subtreeDepth: typeof initialConfig.subtreeDepth === "number" ? initialConfig.subtreeDepth : 3,
    contextID: typeof initialContext.contextID === "number" ? initialContext.contextID : 0,
};

export const treeState: TreeState = {
    snapshot: null,
    nodes: new Map(),
    elements: new Map(),
    openState: new Map(),
    selectedNodeId: null,
    styleRevision: 0,
    filter: "",
    pendingRefreshRequests: new Set(),
    refreshAttempts: new Map(),
    selectionChain: [],
    deferredChildRenders: new Set(),
    selectionRecoveryRequestKeys: new Set(),
};

export const renderState: RenderState = {
    pendingNodes: new Map(),
    frameId: null,
    isProcessing: false,
};

export function subtreeDepth(): number {
    return protocolState.subtreeDepth;
}

export function childRequestDepth(): number {
    return subtreeDepth();
}

export function clearRenderState(): void {
    if (renderState.frameId !== null) {
        cancelAnimationFrame(renderState.frameId);
        renderState.frameId = null;
    }
    renderState.pendingNodes.clear();
    renderState.isProcessing = false;
}
