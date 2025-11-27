export const dom = {
    tree: document.getElementById("dom-tree"),
    empty: document.getElementById("dom-empty")
};

export function ensureDomElements() {
    if (!dom.tree)
        dom.tree = document.getElementById("dom-tree");
    if (!dom.empty)
        dom.empty = document.getElementById("dom-empty");
}

export const NODE_TYPES = {
    ELEMENT_NODE: 1,
    TEXT_NODE: 3,
    COMMENT_NODE: 8
};

export const INDENT_DEPTH_LIMIT = 6;
export const LAYOUT_FLAG_RENDERED = "rendered";
export const TEXT_CONTENT_ATTRIBUTE = Symbol("text-content-attribute");

export const DOM_EVENT_BATCH_LIMIT = 120;
export const DOM_EVENT_TIME_BUDGET = 6;
export const RENDER_BATCH_LIMIT = 180;
export const RENDER_TIME_BUDGET = 8;
export const REFRESH_RETRY_LIMIT = 3;
export const REFRESH_RETRY_WINDOW = 2000;

export const protocolState = {
    lastId: 0,
    pending: new Map(),
    eventHandlers: new Map(),
    snapshotDepth: 4,
    subtreeDepth: 3
};

export const treeState = {
    snapshot: null,
    nodes: new Map(),
    elements: new Map(),
    openState: new Map(),
    selectedNodeId: null,
    filter: "",
    pendingRefreshRequests: new Set(),
    refreshAttempts: new Map(),
    selectionChain: []
};

export const renderState = {
    pendingNodes: new Map(),
    frameId: null
};

export function subtreeDepth() {
    return protocolState.subtreeDepth;
}

export function childRequestDepth() {
    return subtreeDepth();
}

export function clearRenderState() {
    if (renderState.frameId !== null) {
        cancelAnimationFrame(renderState.frameId);
        renderState.frameId = null;
    }
    renderState.pendingNodes.clear();
}
