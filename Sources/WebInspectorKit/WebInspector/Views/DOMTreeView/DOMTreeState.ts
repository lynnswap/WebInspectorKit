// @ts-nocheck
(function(scope) {
    const dom = {
        tree: document.getElementById("dom-tree"),
        empty: document.getElementById("dom-empty")
    };

    function ensureDomElements() {
        if (!dom.tree) {
            dom.tree = document.getElementById("dom-tree");
        }
        if (!dom.empty) {
            dom.empty = document.getElementById("dom-empty");
        }
    }

    const NODE_TYPES = {
        ELEMENT_NODE: 1,
        TEXT_NODE: 3,
        COMMENT_NODE: 8
    };

    const INDENT_DEPTH_LIMIT = 6;
    const LAYOUT_FLAG_RENDERED = "rendered";
    const TEXT_CONTENT_ATTRIBUTE = Symbol("text-content-attribute");

    const DOM_EVENT_BATCH_LIMIT = 120;
    const DOM_EVENT_TIME_BUDGET = 6;
    const RENDER_BATCH_LIMIT = 180;
    const RENDER_TIME_BUDGET = 8;
    const REFRESH_RETRY_LIMIT = 3;
    const REFRESH_RETRY_WINDOW = 2000;

    const protocolState = {
        lastId: 0,
        pending: new Map(),
        eventHandlers: new Map(),
        snapshotDepth: 4,
        subtreeDepth: 3
    };

    const treeState = {
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

    const renderState = {
        pendingNodes: new Map(),
        frameId: null
    };

    function subtreeDepth() {
        return protocolState.subtreeDepth;
    }

    function childRequestDepth() {
        return subtreeDepth();
    }

    function clearRenderState() {
        if (renderState.frameId !== null) {
            cancelAnimationFrame(renderState.frameId);
            renderState.frameId = null;
        }
        renderState.pendingNodes.clear();
    }

    scope.DOMTreeState = {
        dom,
        ensureDomElements,
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
        protocolState,
        treeState,
        renderState,
        subtreeDepth,
        childRequestDepth,
        clearRenderState
    };
})(window.DOMTree || (window.DOMTree = {}));
