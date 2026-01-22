/**
 * DOMTreeSnapshot - Snapshot management and protocol event registration.
 *
 * This module provides:
 * - Document snapshot request/application
 * - Mutation bundle processing
 * - Subtree application
 * - Protocol handler registration
 */

import {
    DOMNode,
    DOMSnapshot,
    MutationBundle,
    ProtocolMessage,
    RawNodeDescriptor,
    RequestDocumentOptions,
} from "./dom-tree-types";
import {
    dom,
    protocolState,
    treeState,
    ensureDomElements,
    clearRenderState,
} from "./dom-tree-state";
import { safeParseJSON } from "./dom-tree-utilities";
import {
    dispatchMessageFromBackend,
    onProtocolEvent,
    reportInspectorError,
    sendCommand,
    setRequestChildNodesHandler,
} from "./dom-tree-protocol";
import {
    domTreeUpdater,
    domUpdateEvents,
    requestNodeRefresh,
    setReloadHandler,
} from "./dom-tree-updates";
import {
    indexNode,
    mergeNodeWithSource,
    normalizeNodeDescriptor,
    preserveExpansionState,
} from "./dom-tree-model";
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
    updateDetails,
} from "./dom-tree-view-support";

// =============================================================================
// Document Request
// =============================================================================

/** Request the document from the backend */
export async function requestDocument(options: RequestDocumentOptions = {}): Promise<void> {
    const depth = typeof options.depth === "number" ? options.depth : protocolState.snapshotDepth;
    protocolState.snapshotDepth = depth;
    const preserveState = !!options.preserveState;

    try {
        const result = await sendCommand<{ root?: RawNodeDescriptor }>("DOM.getDocument", { depth });
        if (result && result.root) {
            setSnapshot(result, { preserveState });
        }
    } catch (error) {
        reportInspectorError("DOM.getDocument", error);
    }
}

// =============================================================================
// Mutation Bundles
// =============================================================================

/** Apply a single mutation bundle */
export function applyMutationBundle(bundle: string | MutationBundle | null | undefined): void {
    if (!bundle) {
        return;
    }

    let preserveState = true;
    let payload: string | MutationBundle = bundle;

    if (typeof bundle === "object" && bundle.bundle !== undefined) {
        preserveState = bundle.preserveState !== false;
        payload = bundle.bundle;
    }

    const parsed = safeParseJSON<MutationBundle>(payload);
    if (!parsed || typeof parsed !== "object") {
        return;
    }

    if (typeof parsed.version === "number" && parsed.version !== 1) {
        return;
    }

    if (parsed.kind === "snapshot") {
        if (parsed.snapshot) {
            // parsed.snapshot may be a JSON string or an object
            // setSnapshot accepts string | object, so pass it directly
            setSnapshot(parsed.snapshot as unknown as { root?: RawNodeDescriptor } | string, { preserveState });
        }
        return;
    }

    if (parsed.kind === "mutation") {
        const events = Array.isArray(parsed.events) ? parsed.events : [];
        events.forEach((message) => dispatchMessageFromBackend(message as ProtocolMessage));
    }
}

/** Apply multiple mutation bundles */
export function applyMutationBundles(
    bundles: string | MutationBundle | MutationBundle[] | null | undefined
): void {
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

// =============================================================================
// Snapshot Application
// =============================================================================

/** Set the document snapshot */
export function setSnapshot(
    payload: { root?: RawNodeDescriptor } | string | null | undefined,
    options: { preserveState?: boolean } = {}
): void {
    try {
        ensureDomElements();
        let snapshot: DOMSnapshot | null = null;

        if (payload) {
            try {
                snapshot = typeof payload === "string" ? JSON.parse(payload) : payload;
            } catch (error) {
                console.error("failed to parse snapshot", error);
                reportInspectorError("parse-snapshot", error);
            }
        }

        const preserveState = !!options.preserveState && !!treeState.snapshot;
        const previousSelectionId = treeState.selectedNodeId;
        const previousFilter = treeState.filter;
        const preservedOpenState = preserveState ? new Map(treeState.openState) : new Map();
        const preservedScrollPosition = preserveState ? captureTreeScrollPosition() : null;

        domTreeUpdater.reset();
        treeState.snapshot = snapshot;
        treeState.nodes.clear();
        treeState.elements.clear();
        if (!preserveState) {
            treeState.openState.clear();
            treeState.selectionChain = [];
        }
        treeState.pendingRefreshRequests.clear();
        treeState.refreshAttempts.clear();
        treeState.selectedNodeId = preserveState ? treeState.selectedNodeId : null;
        clearRenderState();
        if (dom.tree) {
            dom.tree.innerHTML = "";
        }

        if (!snapshot || !snapshot.root) {
            if (dom.empty) {
                dom.empty.hidden = false;
            }
            updateDetails(null);
            return;
        }

        if (dom.empty) {
            dom.empty.hidden = true;
        }

        const normalizedRoot = normalizeNodeDescriptor(snapshot.root as unknown as RawNodeDescriptor);
        if (!normalizedRoot) {
            return;
        }
        snapshot.root = normalizedRoot;
        indexNode(normalizedRoot, 0, null);
        if (dom.tree) {
            dom.tree.appendChild(buildNode(normalizedRoot));
        }

        if (preserveState && preservedOpenState.size) {
            preservedOpenState.forEach((value, key) => {
                treeState.openState.set(key, value);
            });
        }

        treeState.filter = previousFilter;
        applyFilter();

        const snapshotData = snapshot as DOMSnapshot & { selectedNodeId?: number; selectedNodePath?: number[] };
        const selectionCandidateId =
            typeof snapshotData.selectedNodeId === "number" && snapshotData.selectedNodeId > 0
                ? snapshotData.selectedNodeId
                : null;
        const selectionCandidatePath = Array.isArray(snapshotData.selectedNodePath)
            ? snapshotData.selectedNodePath
            : null;
        const hasSelectionCandidate = !!selectionCandidateId || !!selectionCandidatePath;
        const selectionChanged =
            hasSelectionCandidate && selectionCandidateId !== null && selectionCandidateId !== previousSelectionId;
        const shouldPreferSnapshotSelection = !preserveState || selectionChanged;
        const shouldAutoScrollSelection = hasSelectionCandidate && shouldPreferSnapshotSelection;
        const selectionOptions = { shouldHighlight: false, autoScroll: shouldAutoScrollSelection };

        const selectSnapshotCandidate = (): boolean => {
            if (typeof selectionCandidateId === "number" && selectionCandidateId > 0) {
                return selectNode(selectionCandidateId, selectionOptions);
            }
            if (Array.isArray(selectionCandidatePath)) {
                return selectNodeByPath(selectionCandidatePath, selectionOptions);
            }
            return false;
        };

        let didSelect = false;
        if (shouldPreferSnapshotSelection) {
            didSelect = selectSnapshotCandidate();
        }

        if (!didSelect && preserveState && typeof previousSelectionId === "number") {
            didSelect = selectNode(previousSelectionId, selectionOptions);
        }

        if (!didSelect && !shouldPreferSnapshotSelection) {
            didSelect = selectSnapshotCandidate();
        }

        if (!didSelect) {
            updateDetails(null);
            reopenSelectionAncestors();
        }
        treeState.selectedNodeId = didSelect ? treeState.selectedNodeId : null;

        if (preservedScrollPosition) {
            restoreTreeScrollPosition(preservedScrollPosition);
        }
    } catch (error) {
        reportInspectorError("setSnapshot", error);
        throw error;
    }
}

// =============================================================================
// Subtree Application
// =============================================================================

/** Apply a subtree update */
export function applySubtree(payload: string | RawNodeDescriptor | null | undefined): void {
    try {
        ensureDomElements();
        if (!payload) {
            return;
        }

        let subtree: RawNodeDescriptor | null = null;
        try {
            subtree = typeof payload === "string" ? JSON.parse(payload) : payload;
        } catch (error) {
            console.error("failed to parse subtree", error);
            reportInspectorError("parse-subtree", error);
            return;
        }

        const targetId =
            subtree && typeof subtree === "object"
                ? typeof subtree.nodeId === "number"
                    ? subtree.nodeId
                    : typeof subtree.id === "number"
                      ? subtree.id
                      : null
                : null;

        const parentRendered = ((): boolean => {
            if (typeof targetId !== "number") {
                return true;
            }
            const existing = treeState.nodes.get(targetId);
            if (!existing || typeof existing.parentId !== "number") {
                return true;
            }
            const parent = treeState.nodes.get(existing.parentId);
            return !parent || parent.isRendered !== false;
        })();

        const normalized = normalizeNodeDescriptor(subtree, parentRendered);
        if (!normalized) {
            return;
        }

        const target = treeState.nodes.get(normalized.id);
        if (!target) {
            return;
        }

        if (treeState.pendingRefreshRequests.has(normalized.id)) {
            treeState.pendingRefreshRequests.delete(normalized.id);
        }
        treeState.refreshAttempts.delete(normalized.id);

        const preservedExpansion = preserveExpansionState(normalized, new Map());
        const previousSelectionId = treeState.selectedNodeId;

        mergeNodeWithSource(target, normalized, target.depth || 0);

        preservedExpansion.forEach((value, key) => {
            treeState.openState.set(key, value);
        });

        scheduleNodeRender(target);
        setNodeExpanded(target.id, true);

        if (previousSelectionId) {
            if (!selectNode(previousSelectionId, { shouldHighlight: false })) {
                treeState.selectedNodeId = null;
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

// =============================================================================
// SetChildNodes Handler
// =============================================================================

/** Apply setChildNodes event */
function applySetChildNodes(params: {
    parentId?: number;
    parentNodeId?: number;
    nodes?: RawNodeDescriptor[];
}): void {
    const parentId = typeof params.parentId === "number" ? params.parentId : params.parentNodeId;
    if (typeof parentId !== "number" || !Array.isArray(params.nodes)) {
        return;
    }

    const parent = treeState.nodes.get(parentId);
    if (!parent) {
        requestNodeRefresh(parentId);
        return;
    }

    if (treeState.pendingRefreshRequests.has(parentId)) {
        treeState.pendingRefreshRequests.delete(parentId);
    }
    treeState.refreshAttempts.delete(parentId);

    const normalizedChildren: DOMNode[] = [];
    const parentRendered = parent.isRendered !== false;

    for (const child of params.nodes) {
        const normalized = normalizeNodeDescriptor(child, parentRendered);
        if (normalized) {
            normalizedChildren.push(normalized);
        }
    }

    const normalizedParent: DOMNode = {
        ...parent,
        children: normalizedChildren,
        childCount: normalizedChildren.length,
        placeholderParentId: null,
    };

    const preservedExpansion = preserveExpansionState(normalizedParent, new Map());
    const previousSelectionId = treeState.selectedNodeId;

    mergeNodeWithSource(parent, normalizedParent, parent.depth || 0);

    preservedExpansion.forEach((value, key) => {
        treeState.openState.set(key, value);
    });

    scheduleNodeRender(parent);
    setNodeExpanded(parent.id, true);

    if (previousSelectionId) {
        if (!selectNode(previousSelectionId, { shouldHighlight: false })) {
            treeState.selectedNodeId = null;
            updateDetails(null);
        }
    } else {
        updateDetails(null);
    }

    applyFilter();
}

// =============================================================================
// Reload Request
// =============================================================================

/** Request a snapshot reload */
export function requestSnapshotReload(reason?: string): void {
    const reloadReason = reason || "dom-sync";
    console.debug("[WebInspectorKit] request reload:", reloadReason);
    void requestDocument({ preserveState: true });
}

// =============================================================================
// Configuration
// =============================================================================

/** Set preferred snapshot depth */
export function setPreferredDepth(depth: number): void {
    if (typeof depth === "number") {
        protocolState.snapshotDepth = depth;
    }
}

// =============================================================================
// Protocol Registration
// =============================================================================

/** Register protocol event handlers */
export function registerProtocolHandlers(): void {
    domUpdateEvents.forEach((method) => {
        onProtocolEvent(method, (params) => domTreeUpdater.enqueueEvents([{ method, params }]));
    });

    onProtocolEvent("DOM.setChildNodes", (params) =>
        applySetChildNodes(params as { parentId?: number; parentNodeId?: number; nodes?: RawNodeDescriptor[] })
    );

    onProtocolEvent("DOM.documentUpdated", () => requestDocument({ preserveState: false }));

    onProtocolEvent("DOM.inspect", (params) => {
        if (params && typeof (params as { nodeId?: number }).nodeId === "number") {
            selectNode((params as { nodeId: number }).nodeId, { shouldHighlight: false });
        }
    });

    setRequestChildNodesHandler((result: unknown) => applySubtree(result as string | RawNodeDescriptor | null));
}

// Initialize reload handler
setReloadHandler(requestSnapshotReload);
