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
    NODE_TYPES,
    DOMSnapshot,
    DOMSnapshotEnvelopePayload,
    MutationBundle,
    RawNodeDescriptor,
    SerializedNodeEnvelope,
} from "./dom-tree-types";
import { requestSnapshotReload as protocolRequestSnapshotReload } from "./dom-tree-protocol";
import {
    dom,
    protocolState,
    treeState,
    ensureDomElements,
    clearRenderState,
} from "./dom-tree-state";
import { safeParseJSON } from "./dom-tree-utilities";
import {
    adoptDocumentContext,
    isExpectedStaleProtocolResponseError,
    matchesCurrentDocumentContext,
    markChildNodesRequestCompleted,
    onChildNodeRequestCompleted,
    onContextDidChange,
    reportInspectorError,
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
    captureTreeScrollTop,
    clearPointerHoverState,
    ensureTreeEventHandlers,
    reopenSelectionAncestors,
    processPendingNodeRenders,
    restoreTreeScrollPosition,
    restoreTreeScrollTop,
    scheduleNodeRender,
    selectNode,
    selectNodeByPath,
    setNodeExpanded,
    syncTreeScrollMetrics,
    updateDetails,
} from "./dom-tree-view-support";
import { applyMutationBundlesFromBuffer } from "./dom-tree-buffer-transport";

function renderableRootNodes(root: DOMNode | null | undefined): DOMNode[] {
    if (!root) {
        return [];
    }
    if (root.nodeType === NODE_TYPES.DOCUMENT_NODE) {
        return Array.isArray(root.children) ? root.children : [];
    }
    return [root];
}

function readNumber(value: unknown): number | undefined {
    return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function readString(value: unknown): string | undefined {
    return typeof value === "string" ? value : undefined;
}

function contentDocumentForSerializedNode(
    serializedNode: unknown
): Node | null {
    if (!serializedNode || typeof serializedNode !== "object") {
        return null;
    }

    const node = serializedNode as Node & {
        contentDocument?: Document | null;
    };

    if (readNumber((node as { nodeType?: unknown }).nodeType) !== Node.ELEMENT_NODE) {
        return null;
    }

    try {
        return node.contentDocument ?? null;
    } catch {
        return null;
    }
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
        frameId: readString((node as { frameId?: string }).frameId),
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
        descriptor.documentURL = readString((node as Document).URL) || document.URL || "";
    } else if (descriptor.nodeType === Node.ELEMENT_NODE) {
        const contentDocumentDescriptor = makeDescriptorFromSerializedNode(contentDocumentForSerializedNode(node));
        if (contentDocumentDescriptor) {
            descriptor.contentDocument = contentDocumentDescriptor;
            descriptor.childNodeCount = Math.max(descriptor.childNodeCount ?? 0, 1);
        }
    }

    if (!descriptor.contentDocument) {
        const rawChildren = node.childNodes ? Array.from(node.childNodes) : [];
        for (const child of rawChildren) {
            const childDescriptor = makeDescriptorFromSerializedNode(child);
            if (childDescriptor) {
                descriptor.children = descriptor.children || [];
                descriptor.children.push(childDescriptor);
            }
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

    if (typeof fallback.frameId === "string") {
        target.frameId = fallback.frameId;
    }

    if (fallback.contentDocument) {
        target.contentDocument = target.contentDocument || fallback.contentDocument;
        applyIdentifierHints(target.contentDocument, fallback.contentDocument);
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

    const mergedContentDocument = mergeSerializedRootWithFallback(
        serialized.contentDocument,
        fallback.contentDocument
    );
    if (mergedContentDocument) {
        merged.contentDocument = mergedContentDocument;
        delete merged.children;
    } else {
        delete merged.contentDocument;
    }

    const serializedChildren = Array.isArray(serialized.children) ? serialized.children : [];
    const fallbackChildren = Array.isArray(fallback.children) ? fallback.children : [];
    const childCount = Math.max(serializedChildren.length, fallbackChildren.length);

    if (!mergedContentDocument && childCount > 0) {
        const children: RawNodeDescriptor[] = [];
        for (let index = 0; index < childCount; index += 1) {
            const mergedChild = mergeSerializedRootWithFallback(serializedChildren[index], fallbackChildren[index]);
            if (mergedChild) {
                children.push(mergedChild);
            }
        }
        merged.children = children;
    } else if (!mergedContentDocument && Array.isArray(merged.children) && !merged.children.length) {
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
        selectedLocalId:
            typeof (snapshot as DOMSnapshotEnvelopePayload).selectedLocalId === "number"
                ? (snapshot as DOMSnapshotEnvelopePayload).selectedLocalId
                : null,
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
        selectedLocalId:
            typeof envelope.selectedLocalId === "number"
                ? envelope.selectedLocalId
                : fallbackSnapshot?.selectedLocalId ?? null,
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

function resolveSubtreeTargetId(payload: unknown): number | null {
    const parsed =
        typeof payload === "string"
            ? safeParseJSON<unknown>(payload)
            : payload;
    if (!parsed || typeof parsed !== "object") {
        return null;
    }
    const candidate = parsed as { nodeId?: unknown; id?: unknown };
    if (typeof candidate.nodeId === "number") {
        return candidate.nodeId;
    }
    if (typeof candidate.id === "number") {
        return candidate.id;
    }
    return null;
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
            selectedLocalId: resolved.selectedLocalId ?? undefined,
            selectedNodePath: resolved.selectedNodePath ?? undefined,
        };
    }

    const snapshotPayload = normalizeSnapshotEnvelopePayload(parsed);
    if (snapshotPayload) {
        return {
            root: (snapshotPayload.root as unknown as DOMNode) || null,
            selectedNodeId: snapshotPayload.selectedNodeId ?? undefined,
            selectedLocalId: snapshotPayload.selectedLocalId ?? undefined,
            selectedNodePath: snapshotPayload.selectedNodePath ?? undefined,
        };
    }

    return parsed as DOMSnapshot;
}

// =============================================================================
// Context / Mutation Wiring
// =============================================================================

interface ResolvedMutationBundleInput {
    payload: string | MutationBundle;
    contextID?: number;
}

function ensureRenderedSnapshotIfNeeded(): void {
    ensureDomElements();
    const root = treeState.snapshot?.root;
    if (!dom.tree || !root) {
        return;
    }
    if (dom.tree.childElementCount > 0) {
        return;
    }
    if (!treeState.nodes.has(root.id)) {
        treeState.nodes.clear();
        indexNode(root, 0, null);
    }
    for (const rootNode of renderableRootNodes(root)) {
        const rootElement = treeState.elements.get(rootNode.id) ?? buildNode(rootNode);
        dom.tree.appendChild(rootElement);
    }
    if (dom.empty) {
        dom.empty.hidden = true;
    }
}

function resetTreeViewportScroll(): void {
    const scrollElement =
        document.scrollingElement instanceof HTMLElement
            ? document.scrollingElement
            : document.documentElement;
    scrollElement.scrollTop = 0;
    scrollElement.scrollLeft = 0;
    syncTreeScrollMetrics();
}

export function handleDocumentUpdated(): void {
    clearPointerHoverState();
    domTreeUpdater.reset();
    treeState.snapshot = null;
    treeState.nodes.clear();
    treeState.elements.clear();
    treeState.deferredChildRenders.clear();
    treeState.openState.clear();
    treeState.selectionChain = [];
    treeState.selectedNodeId = null;
    treeState.pendingRefreshRequests.clear();
    treeState.refreshAttempts.clear();
    clearRenderState();
    if (dom.tree) {
        dom.tree.innerHTML = "";
    }
    resetTreeViewportScroll();
    if (dom.empty) {
        dom.empty.hidden = false;
    }
    updateDetails(null);
}

onContextDidChange(() => {
    treeState.pendingRefreshRequests.clear();
    treeState.refreshAttempts.clear();
    treeState.selectionRecoveryRequestKeys.clear();
});
onChildNodeRequestCompleted((nodeId) => {
    treeState.pendingRefreshRequests.delete(nodeId);
});

// =============================================================================
// Mutation Bundles
// =============================================================================

function resolveMutationBundleInput(
    bundle: string | MutationBundle | null | undefined,
    fallbackContextID?: number
): ResolvedMutationBundleInput | null {
    if (!bundle) {
        return null;
    }

    let payload: string | MutationBundle = bundle;
    let contextID = fallbackContextID;

    if (typeof bundle === "object" && bundle.bundle !== undefined) {
        payload = bundle.bundle;
        if (typeof bundle.contextID === "number" && Number.isFinite(bundle.contextID)) {
            contextID = bundle.contextID;
        }
    }

    return {
        payload,
        contextID,
    };
}

function resolveMutationBundleContext(
    bundle: MutationBundle,
    resolvedBundle: ResolvedMutationBundleInput
): number {
    return typeof resolvedBundle.contextID === "number" && Number.isFinite(resolvedBundle.contextID)
        ? resolvedBundle.contextID
        : typeof bundle.contextID === "number" && Number.isFinite(bundle.contextID)
            ? bundle.contextID
            : protocolState.contextID;
}

/** Apply a single mutation bundle */
export function applyMutationBundle(
    bundle: string | MutationBundle | null | undefined,
    contextID?: number
): void {
    const resolvedBundle = resolveMutationBundleInput(bundle, contextID);
    if (!resolvedBundle) {
        return;
    }

    const parsed = safeParseJSON<MutationBundle>(resolvedBundle.payload);
    if (!parsed || typeof parsed !== "object") {
        return;
    }
    if (typeof parsed.version === "number" && parsed.version !== DOM_SNAPSHOT_SCHEMA_VERSION) {
        return;
    }
    const effectiveContextID = resolveMutationBundleContext(parsed, resolvedBundle);

    if (parsed.kind === "snapshot") {
        if (!matchesCurrentDocumentContext(effectiveContextID)) {
            return;
        }
        if (parsed.snapshot) {
            adoptDocumentContext({ contextID: effectiveContextID });
            setSnapshot(
                parsed.snapshot as unknown as DOMSnapshotEnvelopePayload | SerializedNodeEnvelope | string
            );
        }
        return;
    }

    if (parsed.kind === "mutation") {
        if (!matchesCurrentDocumentContext(effectiveContextID)) {
            return;
        }
        ensureRenderedSnapshotIfNeeded();
        const events = Array.isArray(parsed.events) ? parsed.events : [];
        if (events.length) {
            let bufferedEvents: DOMEventEntry[] = [];
            for (const event of events as DOMEventEntry[]) {
                if (event?.method === "DOM.documentUpdated") {
                    if (bufferedEvents.length) {
                        domTreeUpdater.enqueueEvents(bufferedEvents);
                        domTreeUpdater.flushPendingEvents();
                    }
                    handleDocumentUpdated();
                    return;
                }
                bufferedEvents.push(event);
            }
            if (bufferedEvents.length) {
                domTreeUpdater.enqueueEvents(bufferedEvents);
            }
        }
    }
}

/** Apply multiple mutation bundles */
export function applyMutationBundles(
    bundles: string | MutationBundle | MutationBundle[] | null | undefined,
    contextID?: number
): void {
    if (!bundles) {
        return;
    }
    if (!Array.isArray(bundles)) {
        applyMutationBundle(bundles, contextID);
        return;
    }
    for (const entry of bundles) {
        applyMutationBundle(entry, contextID);
    }
}

/** Apply mutation bundles from a WebKit shared buffer */
export function applyMutationBuffer(bufferName: string, contextID?: number): boolean {
    if (!matchesCurrentDocumentContext(contextID)) {
        return false;
    }
    const bundles = applyMutationBundlesFromBuffer(bufferName);
    if (!bundles || !bundles.length) {
        return false;
    }
    applyMutationBundles(bundles, contextID);
    return true;
}

// =============================================================================
// Snapshot Application
// =============================================================================

/** Set the document snapshot */
export function setSnapshot(
    payload: { root?: RawNodeDescriptor } | string | SerializedNodeEnvelope | DOMSnapshotEnvelopePayload | null | undefined,
    options: { preserveState?: boolean } = {}
): boolean {
    try {
        ensureDomElements();
        ensureTreeEventHandlers();
        const snapshot = resolveSnapshotPayload(payload);
        if (snapshot === null && payload != null) {
            return false;
        }

        const preserveState = options.preserveState === true && !!treeState.snapshot;
        const previousSnapshotRoot = preserveState ? treeState.snapshot?.root ?? null : null;
        const previousSelectionId = treeState.selectedNodeId;
        const previousFilter = treeState.filter;
        const preservedOpenState = preserveState ? new Map(treeState.openState) : new Map();
        const preservedScrollPosition = preserveState ? captureTreeScrollPosition() : null;
        const preservedScrollTop = preserveState ? captureTreeScrollTop() : null;

        domTreeUpdater.reset();

        if (!snapshot || !snapshot.root) {
            treeState.snapshot = snapshot;
            treeState.nodes.clear();
            treeState.elements.clear();
            treeState.deferredChildRenders.clear();
            treeState.openState.clear();
            treeState.selectionChain = [];
            treeState.pendingRefreshRequests.clear();
            treeState.refreshAttempts.clear();
            treeState.selectedNodeId = null;
            clearRenderState();
            if (dom.tree) {
                dom.tree.innerHTML = "";
            }
            resetTreeViewportScroll();
            if (dom.empty) {
                dom.empty.hidden = false;
            }
            updateDetails(null);
            return true;
        }

        if (dom.empty) {
            dom.empty.hidden = true;
        }

        const normalizedRoot = normalizeNodeDescriptor(snapshot.root as unknown as RawNodeDescriptor);
        if (!normalizedRoot) {
            return false;
        }
        const existingRoot = previousSnapshotRoot;
        const canReuseRoot = !!existingRoot && existingRoot.id === normalizedRoot.id;

        if (preserveState && canReuseRoot && existingRoot) {
            clearRenderState();
            treeState.pendingRefreshRequests.clear();
            treeState.refreshAttempts.clear();
            treeState.selectedNodeId = previousSelectionId;
            mergeNodeWithSource(existingRoot, normalizedRoot, 0);
            treeState.snapshot = {
                ...snapshot,
                root: existingRoot,
            };
            scheduleNodeRender(existingRoot, { updateChildren: true });
            ensureRenderedSnapshotIfNeeded();
        } else {
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
            treeState.selectedNodeId = preserveState ? previousSelectionId : null;
            clearRenderState();
            dom.tree?.replaceChildren();
            if (!preserveState) {
                resetTreeViewportScroll();
            }
            treeState.snapshot = snapshot;
            snapshot.root = normalizedRoot;
            indexNode(normalizedRoot, 0, null);
            if (dom.tree) {
                for (const rootNode of renderableRootNodes(normalizedRoot)) {
                    dom.tree.appendChild(buildNode(rootNode));
                }
            }
            ensureRenderedSnapshotIfNeeded();
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

        const snapshotData = snapshot as DOMSnapshot & {
            selectedNodeId?: number;
            selectedLocalId?: number;
            selectedNodePath?: number[];
        };
        const selectionCandidateId =
            typeof snapshotData.selectedLocalId === "number" && snapshotData.selectedLocalId > 0
                ? snapshotData.selectedLocalId
                :
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

        if (preservedScrollPosition !== null) {
            restoreTreeScrollPosition(preservedScrollPosition);
        } else if (preservedScrollTop !== null) {
            restoreTreeScrollTop(preservedScrollTop);
        }
        return true;
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
): boolean {
    try {
        ensureDomElements();
        if (!payload) {
            return false;
        }

        const targetId = resolveSubtreeTargetId(payload);
        const subtree = resolveNodeDescriptor(payload);
        if (!subtree) {
            if (typeof targetId === "number") {
                markChildNodesRequestCompleted(targetId);
            }
            return false;
        }

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
            if (typeof targetId === "number") {
                markChildNodesRequestCompleted(targetId);
            }
            return false;
        }

        const snapshotRootID = treeState.snapshot?.root?.id ?? null;
        if (
            dom.tree
            && dom.tree.childElementCount === 0
            && (
                normalized.nodeType === NODE_TYPES.DOCUMENT_NODE
                || snapshotRootID === normalized.id
            )
        ) {
            return setSnapshot({ root: subtree }, { preserveState: false });
        }

        const target = treeState.nodes.get(normalized.id);
        if (!target) {
            const canBootstrapFromSubtree =
                normalized.nodeType === NODE_TYPES.DOCUMENT_NODE
                || snapshotRootID === normalized.id
                || treeState.nodes.size === 0;
            if (canBootstrapFromSubtree) {
                return setSnapshot({ root: subtree }, { preserveState: false });
            }
            markChildNodesRequestCompleted(normalized.id);
            return false;
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

        const shouldForceRender = !!dom.tree && dom.tree.childElementCount === 0;
        scheduleNodeRender(target);
        ensureRenderedSnapshotIfNeeded();
        if (shouldForceRender) {
            processPendingNodeRenders();
        }
        setNodeExpanded(target.id, true, { requestChildren: true });

        if (previousSelectionId) {
            treeState.styleRevision += 1;
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
        markChildNodesRequestCompleted(normalized.id);
        return true;
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
    markChildNodesRequestCompleted(parentId);

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
    };

    const preservedExpansion = preserveExpansionState(normalizedParent, new Map());
    const previousSelectionId = treeState.selectedNodeId;

    mergeNodeWithSource(parent, normalizedParent, parent.depth || 0);

    preservedExpansion.forEach((value, key) => {
        treeState.openState.set(key, value);
    });

    const shouldForceRender = !!dom.tree && dom.tree.childElementCount === 0;
    scheduleNodeRender(parent);
    ensureRenderedSnapshotIfNeeded();
    if (shouldForceRender) {
        processPendingNodeRenders();
    }
    setNodeExpanded(parent.id, true, { requestChildren: true });

    if (previousSelectionId) {
        treeState.styleRevision += 1;
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
    try {
        protocolRequestSnapshotReload(reloadReason);
    } catch {
        console.debug("[WebInspectorKit] request reload:", reloadReason);
    }
}

// =============================================================================
// Tree Event Wiring
// =============================================================================

/** Register tree-side reload handlers */
export function registerTreeHandlers(): void {
    setReloadHandler(() => {
        requestSnapshotReload();
    });
    ensureRenderedSnapshotIfNeeded();
}
