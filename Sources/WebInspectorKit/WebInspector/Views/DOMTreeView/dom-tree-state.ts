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
    lastId: 0,
    pending: new Map(),
    eventHandlers: new Map(),
    snapshotDepth: 4,
    subtreeDepth: 3,
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
    filter: "",
    pendingRefreshRequests: new Set(),
    refreshAttempts: new Map(),
    selectionChain: [],
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
