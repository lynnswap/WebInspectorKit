/**
 * DOMTreeState - Core state management for DOMTreeView.
 *
 * This module provides:
 * - DOM element references
 * - Tree state (nodes, elements, selection)
 * - Protocol state (pending requests, event handlers)
 * - Render state (pending renders)
 * - Configuration constants
 */

import {
    DOMElements,
    DOMNode,
    DOMSnapshot,
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

const initialPageEpoch =
    typeof (window as Window & { __wiDOMFrontendInitialPageEpoch?: unknown }).__wiDOMFrontendInitialPageEpoch === "number"
        ? ((window as Window & { __wiDOMFrontendInitialPageEpoch?: number }).__wiDOMFrontendInitialPageEpoch ?? 0)
        : 0;
const initialBootstrap =
    ((window as Window & { __wiDOMFrontendBootstrap?: DOMFrontendBootstrapState }).__wiDOMFrontendBootstrap ?? {});
const initialConfig = typeof initialBootstrap.config === "object" && initialBootstrap.config !== null
    ? initialBootstrap.config
    : {};
const initialContext = typeof initialBootstrap.context === "object" && initialBootstrap.context !== null
    ? initialBootstrap.context
    : {};

// Re-export constants for convenience
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

// =============================================================================
// DOM Elements
// =============================================================================

/** DOM element references (lazily initialized) */
export const dom: DOMElements = {
    tree: null,
    empty: null,
};

/** Ensure DOM elements are initialized */
export function ensureDomElements(): void {
    if (!dom.tree) {
        dom.tree = document.getElementById("dom-tree");
    }
    if (!dom.empty) {
        dom.empty = document.getElementById("dom-empty");
    }
}

// =============================================================================
// Protocol State
// =============================================================================

/** Protocol state for managing CDP requests and events */
export const protocolState: ProtocolState = {
    snapshotDepth: typeof initialConfig.snapshotDepth === "number" ? initialConfig.snapshotDepth : 4,
    subtreeDepth: typeof initialConfig.subtreeDepth === "number" ? initialConfig.subtreeDepth : 3,
    pageEpoch: typeof initialContext.pageEpoch === "number" ? initialContext.pageEpoch : initialPageEpoch,
    documentScopeID: typeof initialContext.documentScopeID === "number" ? initialContext.documentScopeID : 0,
};

export const transitionState: {
    pendingFreshSnapshotContext: { pageEpoch: number; documentScopeID: number } | null;
} = {
    pendingFreshSnapshotContext: null,
};

// =============================================================================
// Tree State
// =============================================================================

/** Main tree state */
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

// =============================================================================
// Render State
// =============================================================================

/** Render state for batched DOM updates */
export const renderState: RenderState = {
    pendingNodes: new Map(),
    frameId: null,
};

// =============================================================================
// Helper Functions
// =============================================================================

/** Get the configured subtree depth */
export function subtreeDepth(): number {
    return protocolState.subtreeDepth;
}

/** Get the depth for child node requests */
export function childRequestDepth(): number {
    return subtreeDepth();
}

/** Clear pending render state */
export function clearRenderState(): void {
    if (renderState.frameId !== null) {
        cancelAnimationFrame(renderState.frameId);
        renderState.frameId = null;
    }
    renderState.pendingNodes.clear();
}
