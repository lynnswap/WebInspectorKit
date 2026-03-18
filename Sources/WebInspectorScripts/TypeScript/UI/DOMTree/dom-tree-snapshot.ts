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
    DOMEventEntry,
    DOMNode,
    DOM_SNAPSHOT_SCHEMA_VERSION,
    DOMSnapshot,
    DOMSnapshotEnvelopePayload,
    MutationBundle,
    RawNodeDescriptor,
    RequestDocumentOptions,
    SerializedNodeEnvelope,
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
    ensureTreeEventHandlers,
    reopenSelectionAncestors,
    restoreTreeScrollPosition,
    scheduleNodeRender,
    selectNode,
    selectNodeByPath,
    setNodeExpanded,
    updateDetails,
} from "./dom-tree-view-support";
import { applyMutationBundlesFromBuffer } from "./dom-tree-buffer-transport";

function readNumber(value: unknown): number | undefined {
    return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function readString(value: unknown): string | undefined {
    return typeof value === "string" ? value : undefined;
}

function makeDescriptorFromSerializedNode(serializedNode: unknown): RawNodeDescriptor | null {
    if (!serializedNode || typeof serializedNode !== "object") {
        return null;
    }

    const node = serializedNode as Node & {
        attributes?: NamedNodeMap;
        childNodes?: NodeListOf<ChildNode>;
        localName?: string;
        nodeValue?: string | null;
        publicId?: string;
        systemId?: string;
        name?: string;
        value?: string;
    };

    const descriptor: RawNodeDescriptor = {
        nodeType: readNumber((node as { nodeType?: number }).nodeType),
        nodeName: readString((node as { nodeName?: string }).nodeName) ?? "",
        localName: readString(node.localName) ?? readString((node as { nodeName?: string }).nodeName)?.toLowerCase() ?? "",
        nodeValue: readString(node.nodeValue) ?? "",
        childNodeCount: node.childNodes ? node.childNodes.length : 0,
        children: [],
    };

    if (node.attributes && node.attributes.length) {
        const rawAttributes: string[] = [];
        for (let index = 0; index < node.attributes.length; index += 1) {
            const attribute = node.attributes.item(index);
            if (!attribute) {
                continue;
            }
            rawAttributes.push(attribute.name, attribute.value);
        }
        if (rawAttributes.length) {
            descriptor.attributes = rawAttributes;
        }
    }

    if (descriptor.nodeType === Node.DOCUMENT_TYPE_NODE) {
        descriptor.publicId = readString(node.publicId) ?? "";
        descriptor.systemId = readString(node.systemId) ?? "";
    } else if (descriptor.nodeType === Node.ATTRIBUTE_NODE) {
        descriptor.name = readString(node.name) ?? "";
        descriptor.value = readString(node.value) ?? "";
    } else if (descriptor.nodeType === Node.DOCUMENT_NODE) {
        descriptor.documentURL = document.URL || "";
    }

    const rawChildren = node.childNodes ? Array.from(node.childNodes) : [];
    for (const child of rawChildren) {
        const childDescriptor = makeDescriptorFromSerializedNode(child);
        if (childDescriptor) {
            descriptor.children = descriptor.children || [];
            descriptor.children.push(childDescriptor);
        }
    }

    return descriptor;
}

function applyIdentifierHints(
    target: RawNodeDescriptor | null | undefined,
    fallback: RawNodeDescriptor | null | undefined
): void {
    if (!target || !fallback) {
        return;
    }

    if (typeof fallback.nodeId === "number") {
        target.nodeId = fallback.nodeId;
    } else if (typeof fallback.id === "number") {
        target.id = fallback.id;
    }

    if (typeof fallback.childNodeCount === "number") {
        target.childNodeCount = fallback.childNodeCount;
    } else if (typeof fallback.childCount === "number") {
        target.childCount = fallback.childCount;
    }

    const targetChildren = Array.isArray(target.children) ? target.children : [];
    const fallbackChildren = Array.isArray(fallback.children) ? fallback.children : [];
    const max = Math.min(targetChildren.length, fallbackChildren.length);
    for (let index = 0; index < max; index += 1) {
        applyIdentifierHints(targetChildren[index], fallbackChildren[index]);
    }
}

function mergeSerializedRootWithFallback(
    serialized: RawNodeDescriptor | null | undefined,
    fallback: RawNodeDescriptor | null | undefined
): RawNodeDescriptor | null {
    if (!serialized && !fallback) {
        return null;
    }
    if (!serialized) {
        return fallback || null;
    }
    if (!fallback) {
        return serialized;
    }

    const merged: RawNodeDescriptor = {
        ...fallback,
        ...serialized,
    };

    const serializedChildren = Array.isArray(serialized.children) ? serialized.children : [];
    const fallbackChildren = Array.isArray(fallback.children) ? fallback.children : [];
    const childCount = Math.max(serializedChildren.length, fallbackChildren.length);

    if (childCount > 0) {
        const children: RawNodeDescriptor[] = [];
        for (let index = 0; index < childCount; index += 1) {
            const mergedChild = mergeSerializedRootWithFallback(serializedChildren[index], fallbackChildren[index]);
            if (mergedChild) {
                children.push(mergedChild);
            }
        }
        merged.children = children;
    } else if (Array.isArray(merged.children) && !merged.children.length) {
        delete merged.children;
    }

    return merged;
}

function normalizeSnapshotEnvelopePayload(payload: unknown): DOMSnapshotEnvelopePayload | null {
    if (!payload || typeof payload !== "object") {
        return null;
    }
    if (!Object.prototype.hasOwnProperty.call(payload, "root")) {
        return null;
    }

    const snapshot = payload as DOMSnapshotEnvelopePayload;
    const resolvedRoot = resolveNodeDescriptor(snapshot.root as unknown);
    if (!resolvedRoot) {
        return null;
    }

    return {
        root: resolvedRoot,
        selectedNodeId:
            typeof snapshot.selectedNodeId === "number" ? snapshot.selectedNodeId : null,
        selectedNodePath: Array.isArray(snapshot.selectedNodePath) ? snapshot.selectedNodePath : null,
    };
}

function resolveSerializedNodeEnvelope(envelope: SerializedNodeEnvelope): DOMSnapshotEnvelopePayload | null {
    const fallbackSnapshot = normalizeSnapshotEnvelopePayload(envelope.fallback as unknown)
        || (envelope.fallback && typeof envelope.fallback === "object"
            ? { root: envelope.fallback as RawNodeDescriptor, selectedNodeId: null, selectedNodePath: null }
            : null);
    const schemaVersion = readNumber((envelope as { schemaVersion?: unknown }).schemaVersion);
    if (schemaVersion != null && schemaVersion !== DOM_SNAPSHOT_SCHEMA_VERSION) {
        return fallbackSnapshot;
    }
    const convertedRoot = makeDescriptorFromSerializedNode(envelope.node);
    if (!convertedRoot) {
        return fallbackSnapshot;
    }

    const fallbackRoot = fallbackSnapshot?.root as RawNodeDescriptor | undefined;
    if (fallbackRoot) {
        applyIdentifierHints(convertedRoot, fallbackRoot);
    }
    const mergedRoot = mergeSerializedRootWithFallback(convertedRoot, fallbackRoot);
    if (!mergedRoot) {
        return fallbackSnapshot;
    }

    return {
        root: mergedRoot,
        selectedNodeId:
            typeof envelope.selectedNodeId === "number"
                ? envelope.selectedNodeId
                : fallbackSnapshot?.selectedNodeId ?? null,
        selectedNodePath:
            Array.isArray(envelope.selectedNodePath)
                ? envelope.selectedNodePath
                : fallbackSnapshot?.selectedNodePath ?? null,
    };
}

function resolveNodeDescriptor(payload: unknown): RawNodeDescriptor | null {
    if (!payload) {
        return null;
    }
    if (typeof payload !== "object") {
        return null;
    }

    const maybeEnvelope = payload as SerializedNodeEnvelope;
    if (maybeEnvelope.type === "serialized-node-envelope") {
        const resolved = resolveSerializedNodeEnvelope(maybeEnvelope);
        return (resolved?.root as RawNodeDescriptor | null) ?? null;
    }

    const maybeSnapshot = normalizeSnapshotEnvelopePayload(payload);
    if (maybeSnapshot?.root) {
        return maybeSnapshot.root as RawNodeDescriptor;
    }

    return payload as RawNodeDescriptor;
}

function resolveSnapshotPayload(payload: unknown): DOMSnapshot | null {
    const parsed = safeParseJSON<unknown>(payload);
    if (!parsed || typeof parsed !== "object") {
        return null;
    }

    const maybeEnvelope = parsed as SerializedNodeEnvelope;
    if (maybeEnvelope.type === "serialized-node-envelope") {
        const resolved = resolveSerializedNodeEnvelope(maybeEnvelope);
        if (!resolved) {
            return null;
        }
        return {
            root: (resolved.root as unknown as DOMNode) || null,
            selectedNodeId: resolved.selectedNodeId ?? undefined,
            selectedNodePath: resolved.selectedNodePath ?? undefined,
        };
    }

    const snapshotPayload = normalizeSnapshotEnvelopePayload(parsed);
    if (snapshotPayload) {
        return {
            root: (snapshotPayload.root as unknown as DOMNode) || null,
            selectedNodeId: snapshotPayload.selectedNodeId ?? undefined,
            selectedNodePath: snapshotPayload.selectedNodePath ?? undefined,
        };
    }

    return parsed as DOMSnapshot;
}

// =============================================================================
// Document Request
// =============================================================================

/** Request the document from the backend */
export async function requestDocument(options: RequestDocumentOptions = {}): Promise<void> {
    const depth = typeof options.depth === "number" ? options.depth : protocolState.snapshotDepth;
    protocolState.snapshotDepth = depth;
    const preserveState = !!options.preserveState;

    try {
        const result = await sendCommand<unknown>("DOM.getDocument", { depth });
        if (result != null) {
            setSnapshot(result as DOMSnapshotEnvelopePayload | SerializedNodeEnvelope | string, { preserveState });
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
            setSnapshot(parsed.snapshot as unknown as DOMSnapshotEnvelopePayload | SerializedNodeEnvelope | string, { preserveState });
        }
        return;
    }

    if (parsed.kind === "mutation") {
        const events = Array.isArray(parsed.events) ? parsed.events : [];
        if (events.length) {
            domTreeUpdater.enqueueEvents(events as DOMEventEntry[]);
        }
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

/** Apply mutation bundles from a WebKit shared buffer */
export function applyMutationBuffer(bufferName: string): boolean {
    const bundles = applyMutationBundlesFromBuffer(bufferName);
    if (!bundles || !bundles.length) {
        return false;
    }
    applyMutationBundles(bundles);
    return true;
}

// =============================================================================
// Snapshot Application
// =============================================================================

/** Set the document snapshot */
export function setSnapshot(
    payload: { root?: RawNodeDescriptor } | string | SerializedNodeEnvelope | DOMSnapshotEnvelopePayload | null | undefined,
    options: { preserveState?: boolean } = {}
): void {
    try {
        ensureDomElements();
        ensureTreeEventHandlers();
        const snapshot = resolveSnapshotPayload(payload);

        const preserveState = !!options.preserveState && !!treeState.snapshot;
        const previousSelectionId = treeState.selectedNodeId;
        const previousFilter = treeState.filter;
        const preservedOpenState = preserveState ? new Map(treeState.openState) : new Map();
        const preservedScrollPosition = preserveState ? captureTreeScrollPosition() : null;

        domTreeUpdater.reset();
        treeState.snapshot = snapshot;
        treeState.nodes.clear();
        treeState.elements.clear();
        treeState.deferredChildRenders.clear();
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
            if (!preserveState) {
                dom.tree.scrollTop = 0;
                dom.tree.scrollLeft = 0;
            }
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
        if (treeState.filter) {
            applyFilter();
        }

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
export function applySubtree(
    payload: string | RawNodeDescriptor | SerializedNodeEnvelope | DOMSnapshotEnvelopePayload | null | undefined
): void {
    try {
        ensureDomElements();
        if (!payload) {
            return;
        }

        const subtree = resolveNodeDescriptor(payload);
        if (!subtree) {
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

        if (treeState.filter) {
            applyFilter();
        }
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

    if (treeState.filter) {
        applyFilter();
    }
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
