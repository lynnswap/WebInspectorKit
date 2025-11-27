import {
    ensureDomElements,
    clearRenderState,
    dom,
    protocolState,
    treeState as state
} from "./DOMTreeState.js";
import {safeParseJSON} from "./DOMTreeUtilities.js";
import {
    dispatchMessageFromBackend,
    onProtocolEvent,
    reportInspectorError,
    sendCommand,
    setRequestChildNodesHandler
} from "./DOMTreeProtocol.js";
import {
    domTreeUpdater,
    domUpdateEvents,
    requestNodeRefresh,
    setReloadHandler
} from "./DOMTreeUpdates.js";
import {
    indexNode,
    mergeNodeWithSource,
    normalizeNodeDescriptor,
    preserveExpansionState
} from "./DOMTreeModel.js";
import {
    applyFilter,
    buildNode,
    captureTreeScrollPosition,
    reopenSelectionAncestors,
    restoreTreeScrollPosition,
    scheduleNodeRender,
    selectNode,
    selectNodeByPath,
    setNodeExpanded,
    updateDetails
} from "./DOMTreeViewSupport.js";

export async function requestDocument(options = {}) {
    const depth = typeof options.depth === "number" ? options.depth : protocolState.snapshotDepth;
    protocolState.snapshotDepth = depth;
    const preserveState = !!options.preserveState;
    try {
        const result = await sendCommand("DOM.getDocument", {depth});
        if (result && result.root)
            setSnapshot(result, {preserveState});
    } catch (error) {
        reportInspectorError("DOM.getDocument", error);
    }
}

export function applyMutationBundle(bundle) {
    if (!bundle)
        return;
    let preserveState = true;
    let payload = bundle;
    if (typeof bundle === "object" && bundle.bundle !== undefined) {
        preserveState = bundle.preserveState !== false;
        payload = bundle.bundle;
    }
    const parsed = safeParseJSON(payload);
    if (!parsed || typeof parsed !== "object")
        return;
    if (parsed.snapshot && !parsed.messages) {
        setSnapshot(parsed.snapshot, {preserveState});
        return;
    }
    if (parsed.root && !parsed.messages) {
        setSnapshot(parsed, {preserveState});
        return;
    }
    const messages = Array.isArray(parsed.messages) ? parsed.messages : [];
    messages.forEach(message => dispatchMessageFromBackend(message));
}

export function applyMutationBundles(bundles) {
    if (!bundles) {
        return;
    }
    if (!Array.isArray(bundles)) {
        applyMutationBundle(bundles);
        return;
    }
    for (const entry of bundles) {
        applyMutationBundle(entry);
    }
}

export function setSnapshot(payload, options = {}) {
    try {
        ensureDomElements();
        let snapshot = null;
        if (payload) {
            try {
                snapshot = typeof payload === "string" ? JSON.parse(payload) : payload;
            } catch (error) {
                console.error("failed to parse snapshot", error);
                reportInspectorError("parse-snapshot", error);
            }
        }

        const preserveState = !!options.preserveState && !!state.snapshot;
        const previousSelectionId = state.selectedNodeId;
        const previousFilter = state.filter;
        const preservedOpenState = preserveState ? new Map(state.openState) : new Map();
        const preservedScrollPosition = preserveState ? captureTreeScrollPosition() : null;

        domTreeUpdater.reset();
        state.snapshot = snapshot;
        state.nodes.clear();
        state.elements.clear();
        if (!preserveState) {
            state.openState.clear();
            state.selectionChain = [];
        }
        state.pendingRefreshRequests.clear();
        state.refreshAttempts.clear();
        state.selectedNodeId = preserveState ? state.selectedNodeId : null;
        clearRenderState();
        dom.tree.innerHTML = "";

        if (!snapshot || !snapshot.root) {
            dom.empty.hidden = false;
            updateDetails(null);
            return;
        }

        dom.empty.hidden = true;

        const normalizedRoot = normalizeNodeDescriptor(snapshot.root);
        if (!normalizedRoot)
            return;
        snapshot.root = normalizedRoot;
        indexNode(normalizedRoot, 0, null);
        dom.tree.appendChild(buildNode(normalizedRoot));

        if (preserveState && preservedOpenState.size) {
            preservedOpenState.forEach((value, key) => {
                state.openState.set(key, value);
            });
        }

        state.filter = previousFilter;
        applyFilter();

        const selectionCandidateId = typeof snapshot.selectedNodeId === "number" && snapshot.selectedNodeId > 0
            ? snapshot.selectedNodeId
            : null;
        const selectionCandidatePath = Array.isArray(snapshot.selectedNodePath) ? snapshot.selectedNodePath : null;
        const hasSelectionCandidate = !!selectionCandidateId || !!selectionCandidatePath;
        const selectionChanged = hasSelectionCandidate && selectionCandidateId !== null && selectionCandidateId !== previousSelectionId;
        const shouldPreferSnapshotSelection = !preserveState || selectionChanged;
        const shouldAutoScrollSelection = hasSelectionCandidate && shouldPreferSnapshotSelection;
        const selectionOptions = {shouldHighlight: false, autoScroll: shouldAutoScrollSelection};

        const selectSnapshotCandidate = () => {
            if (typeof selectionCandidateId === "number" && selectionCandidateId > 0)
                return selectNode(selectionCandidateId, selectionOptions);
            if (Array.isArray(selectionCandidatePath))
                return selectNodeByPath(selectionCandidatePath, selectionOptions);
            return false;
        };

        let didSelect = false;
        if (shouldPreferSnapshotSelection)
            didSelect = selectSnapshotCandidate();

        if (!didSelect && preserveState && typeof previousSelectionId === "number")
            didSelect = selectNode(previousSelectionId, selectionOptions);

        if (!didSelect && !shouldPreferSnapshotSelection)
            didSelect = selectSnapshotCandidate();

        if (!didSelect) {
            updateDetails(null);
            reopenSelectionAncestors();
        }
        state.selectedNodeId = didSelect ? state.selectedNodeId : null;
        if (preservedScrollPosition)
            restoreTreeScrollPosition(preservedScrollPosition);
    } catch (error) {
        reportInspectorError("setSnapshot", error);
        throw error;
    }
}

export function applySubtree(payload) {
    try {
        ensureDomElements();
        if (!payload)
            return;
        let subtree = null;
        try {
            subtree = typeof payload === "string" ? JSON.parse(payload) : payload;
        } catch (error) {
            console.error("failed to parse subtree", error);
            reportInspectorError("parse-subtree", error);
            return;
        }
        const normalized = normalizeNodeDescriptor(subtree);
        if (!normalized)
            return;
        const target = state.nodes.get(normalized.id);
        if (!target)
            return;

        if (state.pendingRefreshRequests.has(normalized.id))
            state.pendingRefreshRequests.delete(normalized.id);
        state.refreshAttempts.delete(normalized.id);

        const preservedExpansion = preserveExpansionState(normalized, new Map());
        const previousSelectionId = state.selectedNodeId;

        mergeNodeWithSource(target, normalized, target.depth || 0);

        preservedExpansion.forEach((value, key) => {
            state.openState.set(key, value);
        });

        scheduleNodeRender(target);
        setNodeExpanded(target.id, true);

        if (previousSelectionId) {
            if (!selectNode(previousSelectionId, {shouldHighlight: false})) {
                state.selectedNodeId = null;
                updateDetails(null);
            }
        } else {
            updateDetails(null);
        }

        applyFilter();
    } catch (error) {
        reportInspectorError("applySubtree", error);
        throw error;
    }
}

export function applySetChildNodes(params) {
    const parentId = typeof params.parentId === "number" ? params.parentId : params.parentNodeId;
    if (typeof parentId !== "number" || !Array.isArray(params.nodes))
        return;
    const parent = state.nodes.get(parentId);
    if (!parent) {
        requestNodeRefresh(parentId);
        return;
    }
    if (state.pendingRefreshRequests.has(parentId))
        state.pendingRefreshRequests.delete(parentId);
    state.refreshAttempts.delete(parentId);

    const normalizedChildren = [];
    for (const child of params.nodes) {
        const normalized = normalizeNodeDescriptor(child);
        if (normalized)
            normalizedChildren.push(normalized);
    }
    const normalizedParent = {
        ...parent,
        children: normalizedChildren,
        childCount: normalizedChildren.length,
        placeholderParentId: null
    };
    const preservedExpansion = preserveExpansionState(normalizedParent, new Map());
    const previousSelectionId = state.selectedNodeId;

    mergeNodeWithSource(parent, normalizedParent, parent.depth || 0);

    preservedExpansion.forEach((value, key) => {
        state.openState.set(key, value);
    });

    scheduleNodeRender(parent);
    setNodeExpanded(parent.id, true);

    if (previousSelectionId) {
        if (!selectNode(previousSelectionId, {shouldHighlight: false})) {
            state.selectedNodeId = null;
            updateDetails(null);
        }
    } else {
        updateDetails(null);
    }

    applyFilter();
}

export function requestSnapshotReload(reason) {
    const reloadReason = reason || "dom-sync";
    console.debug("[tweetpd-inspector] request reload:", reloadReason);
    void requestDocument({preserveState: true});
}

export function setPreferredDepth(depth) {
    if (typeof depth === "number")
        protocolState.snapshotDepth = depth;
}

export function registerProtocolHandlers() {
    domUpdateEvents.forEach(method => {
        onProtocolEvent(method, params => domTreeUpdater.enqueueEvents([{method, params}]));
    });
    onProtocolEvent("DOM.setChildNodes", params => applySetChildNodes(params || {}));
    onProtocolEvent("DOM.documentUpdated", () => requestDocument({preserveState: false}));
    onProtocolEvent("DOM.inspect", params => {
        if (params && typeof params.nodeId === "number")
            selectNode(params.nodeId, {shouldHighlight: false});
    });
    setRequestChildNodesHandler(applySubtree);
}

setReloadHandler(requestSnapshotReload);
