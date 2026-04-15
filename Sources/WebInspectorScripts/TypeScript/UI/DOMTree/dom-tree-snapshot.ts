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
    DOMSelectionRestoreTarget,
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
    transitionState,
    ensureDomElements,
    clearRenderState,
} from "./dom-tree-state";
import { safeParseJSON } from "./dom-tree-utilities";
import {
    adoptDocumentContext,
    canAdoptDocumentContext,
    isExpectedStaleProtocolResponseError,
    matchesCurrentDocumentContext,
    markChildNodesRequestCompleted,
    onChildNodeRequestCompleted,
    onPageEpochDidChange,
    resetChildNodeRequests,
    restoreDocumentContext,
    reportInspectorError,
    requestDocumentFromBackend,
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
// Document Request
// =============================================================================

let pendingDocumentRequest: Required<RequestDocumentOptions> | null = null;
let documentRequestInFlightEpoch: number | null = null;
let documentRequestInFlight: Required<RequestDocumentOptions> | null = null;

interface ResolvedMutationBundleInput {
    payload: string | MutationBundle;
    mode: "fresh" | "preserve-ui-state";
    pageEpoch?: number;
    documentScopeID?: number;
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
    const rootElement = treeState.elements.get(root.id) ?? buildNode(root);
    dom.tree.appendChild(rootElement);
    if (dom.empty) {
        dom.empty.hidden = true;
    }
}

function resetDocumentRequestState(): void {
    pendingDocumentRequest = null;
    documentRequestInFlightEpoch = null;
    documentRequestInFlight = null;
    treeState.selectionRecoveryRequestKeys.clear();
}

export function resetDocumentRequestStateForPageEpoch(pageEpoch?: number, documentScopeID?: number): void {
    if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
        return;
    }
    resetDocumentRequestState();
}

export function completeDocumentRequest(pageEpoch?: number, documentScopeID?: number): void {
    if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
        return;
    }
    markDocumentRequestCompleted();
    drainQueuedDocumentRequestIfPossible();
}

export function rejectDocumentRequest(pageEpoch?: number, documentScopeID?: number): void {
    if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
        return;
    }
    const currentPageEpoch = protocolState.pageEpoch;
    if (documentRequestInFlightEpoch === currentPageEpoch) {
        documentRequestInFlightEpoch = null;
    }
    if (documentRequestInFlight?.pageEpoch === currentPageEpoch) {
        documentRequestInFlight = null;
    }
    treeState.selectionRecoveryRequestKeys.clear();
}

function markDocumentRequestCompleted(): void {
    const currentPageEpoch = protocolState.pageEpoch;
    if (documentRequestInFlightEpoch === currentPageEpoch) {
        documentRequestInFlightEpoch = null;
    }
    if (documentRequestInFlight?.pageEpoch === currentPageEpoch) {
        documentRequestInFlight = null;
    }
    treeState.selectionRecoveryRequestKeys.clear();
}

function drainQueuedDocumentRequestIfPossible(): void {
    const currentPageEpoch = protocolState.pageEpoch;
    if (pendingDocumentRequest?.pageEpoch === currentPageEpoch && documentRequestInFlightEpoch == null) {
        const nextRequest = pendingDocumentRequest;
        pendingDocumentRequest = null;
        documentRequestInFlightEpoch = currentPageEpoch;
        documentRequestInFlight = nextRequest;
        performDocumentRequest(nextRequest);
    }
}

function queueDocumentRequest(
    normalizedOptions: Required<RequestDocumentOptions>,
    allowIdenticalInFlightRequeue = false
): void {
    const requestPageEpoch = normalizedOptions.pageEpoch;
    if (documentRequestMatches(documentRequestInFlight, normalizedOptions)) {
        if (!allowIdenticalInFlightRequeue) {
            return;
        }
        pendingDocumentRequest = normalizedOptions;
        return;
    }
    if (documentRequestMatches(pendingDocumentRequest, normalizedOptions)) {
        return;
    }
    pendingDocumentRequest = normalizedOptions;
    if (documentRequestInFlightEpoch === requestPageEpoch) {
        return;
    }

    documentRequestInFlightEpoch = requestPageEpoch;
    const request = pendingDocumentRequest;
    pendingDocumentRequest = null;
    documentRequestInFlight = request;
    performDocumentRequest(request);
}

function handleDocumentUpdated(): void {
    treeState.snapshot = null;
    treeState.nodes.clear();
    treeState.elements.clear();
    treeState.deferredChildRenders.clear();
    treeState.openState.clear();
    treeState.selectionChain = [];
    treeState.selectedNodeId = null;
    resetChildNodeRequests(protocolState.pageEpoch, protocolState.documentScopeID);
    treeState.pendingRefreshRequests.clear();
    treeState.refreshAttempts.clear();
    clearRenderState();
    if (dom.tree) {
        dom.tree.innerHTML = "";
        dom.tree.scrollTop = 0;
        dom.tree.scrollLeft = 0;
    }
    if (dom.empty) {
        dom.empty.hidden = false;
    }
    updateDetails(null);
    const normalizedFreshRequest = normalizeDocumentRequestOptions({ mode: "fresh" });
    if (!normalizedFreshRequest) {
        return;
    }
    queueDocumentRequest(normalizedFreshRequest, true);
}

function requestDocumentSafely(options: RequestDocumentOptions): void {
    void requestDocument(options).catch((error) => {
        console.warn("[WebInspectorKit] requestDocument:", error);
    });
}

function normalizeSelectionRestoreTarget(
    target: DOMSelectionRestoreTarget | null | undefined
): DOMSelectionRestoreTarget | null {
    if (!target || typeof target !== "object") {
        return null;
    }
    const selectedLocalId =
        typeof target.selectedLocalId === "number"
        && Number.isFinite(target.selectedLocalId)
        && target.selectedLocalId > 0
            ? Math.floor(target.selectedLocalId)
            : null;
    const selectedNodePath = Array.isArray(target.selectedNodePath)
        && target.selectedNodePath.every((segment) => typeof segment === "number" && Number.isInteger(segment) && segment >= 0)
        ? target.selectedNodePath
        : null;
    if (selectedLocalId === null && selectedNodePath === null) {
        return null;
    }
    return {
        selectedLocalId,
        selectedNodePath,
    };
}

function selectionRestoreTargetKey(target: DOMSelectionRestoreTarget | null | undefined): string {
    if (!target) {
        return "";
    }
    const selectedLocalId = typeof target.selectedLocalId === "number" ? target.selectedLocalId : 0;
    const selectedNodePath = Array.isArray(target.selectedNodePath) ? target.selectedNodePath.join(".") : "";
    return `${selectedLocalId}|${selectedNodePath}`;
}

function documentRequestMatches(
    lhs: Required<RequestDocumentOptions> | null | undefined,
    rhs: Required<RequestDocumentOptions> | null | undefined
): boolean {
    return !!lhs
        && !!rhs
        && lhs.depth === rhs.depth
        && lhs.mode === rhs.mode
        && lhs.pageEpoch === rhs.pageEpoch
        && lhs.documentScopeID === rhs.documentScopeID
        && selectionRestoreTargetKey(lhs.selectionRestoreTarget) === selectionRestoreTargetKey(rhs.selectionRestoreTarget);
}

function normalizeDocumentRequestOptions(options: RequestDocumentOptions = {}): Required<RequestDocumentOptions> | null {
    const requestPageEpoch =
        typeof options.pageEpoch === "number" && Number.isFinite(options.pageEpoch)
            ? options.pageEpoch
            : protocolState.pageEpoch;
    if (requestPageEpoch !== protocolState.pageEpoch) {
        return null;
    }
    const requestDocumentScopeID =
        typeof options.documentScopeID === "number" && Number.isFinite(options.documentScopeID)
            ? options.documentScopeID
            : protocolState.documentScopeID;
    if (requestDocumentScopeID !== protocolState.documentScopeID) {
        return null;
    }
    const depth = typeof options.depth === "number" ? options.depth : protocolState.snapshotDepth;
    return {
        depth,
        mode: options.mode === "preserve-ui-state" ? "preserve-ui-state" : "fresh",
        pageEpoch: requestPageEpoch,
        documentScopeID: requestDocumentScopeID,
        selectionRestoreTarget: normalizeSelectionRestoreTarget(options.selectionRestoreTarget),
    };
}

function performDocumentRequest(options: Required<RequestDocumentOptions>): void {
    protocolState.snapshotDepth = options.depth;
    requestDocumentFromBackend(options);
}

/** Request the document from the backend */
export async function requestDocument(options: RequestDocumentOptions = {}): Promise<void> {
    const normalizedOptions = normalizeDocumentRequestOptions(options);
    if (!normalizedOptions) {
        return;
    }
    try {
        queueDocumentRequest(normalizedOptions);
    } catch (error) {
        resetDocumentRequestState();
        throw error;
    }
}

function selectionRecoveryRequestKey(
    pageEpoch: number,
    documentScopeID: number,
    target: DOMSelectionRestoreTarget
): string {
    return `${pageEpoch}:${documentScopeID}:${selectionRestoreTargetKey(target)}`;
}

export function requestSelectionRecoveryIfNeeded(
    target: DOMSelectionRestoreTarget | null | undefined,
    pageEpoch = protocolState.pageEpoch,
    documentScopeID = protocolState.documentScopeID
): boolean {
    const normalizedTarget = normalizeSelectionRestoreTarget(target);
    if (!normalizedTarget) {
        return false;
    }
    if (!matchesCurrentDocumentContext(pageEpoch, documentScopeID)) {
        return false;
    }
    const requestKey = selectionRecoveryRequestKey(pageEpoch, documentScopeID, normalizedTarget);
    if (treeState.selectionRecoveryRequestKeys.has(requestKey)) {
        return false;
    }
    treeState.selectionRecoveryRequestKeys.add(requestKey);
    console.debug("[WebInspectorKit] request reload:", "refresh-missing-target");
    requestDocumentSafely({
        mode: "preserve-ui-state",
        pageEpoch,
        documentScopeID,
        selectionRestoreTarget: normalizedTarget,
    });
    return true;
}

onPageEpochDidChange(() => {
    resetDocumentRequestState();
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
    fallbackPageEpoch?: number
): ResolvedMutationBundleInput | null {
    if (!bundle) {
        return null;
    }

    let mode: "fresh" | "preserve-ui-state" = "preserve-ui-state";
    let payload: string | MutationBundle = bundle;
    let pageEpoch = fallbackPageEpoch;
    let documentScopeID: number | undefined;

    if (typeof bundle === "object" && bundle.bundle !== undefined) {
        mode = bundle.mode === "fresh" ? "fresh" : "preserve-ui-state";
        payload = bundle.bundle;
        if (typeof bundle.pageEpoch === "number" && Number.isFinite(bundle.pageEpoch)) {
            pageEpoch = bundle.pageEpoch;
        }
        if (typeof bundle.documentScopeID === "number" && Number.isFinite(bundle.documentScopeID)) {
            documentScopeID = bundle.documentScopeID;
        }
    }

    return {
        payload,
        mode,
        pageEpoch,
        documentScopeID,
    };
}

function resolveMutationBundleContext(
    bundle: MutationBundle,
    resolvedBundle: ResolvedMutationBundleInput
): { pageEpoch: number; documentScopeID: number } {
    const pageEpoch =
        typeof resolvedBundle.pageEpoch === "number" && Number.isFinite(resolvedBundle.pageEpoch)
            ? resolvedBundle.pageEpoch
            : typeof bundle.pageEpoch === "number" && Number.isFinite(bundle.pageEpoch)
                ? bundle.pageEpoch
                : protocolState.pageEpoch;
    const documentScopeID =
        typeof resolvedBundle.documentScopeID === "number" && Number.isFinite(resolvedBundle.documentScopeID)
            ? resolvedBundle.documentScopeID
            : typeof bundle.documentScopeID === "number" && Number.isFinite(bundle.documentScopeID)
                ? bundle.documentScopeID
                : protocolState.documentScopeID;

    return { pageEpoch, documentScopeID };
}

function resolveSnapshotMode(
    bundle: MutationBundle,
    resolvedBundle: ResolvedMutationBundleInput,
    effectiveContext: { pageEpoch: number; documentScopeID: number }
): "fresh" | "preserve-ui-state" {
    if (shouldForceFreshSnapshot(effectiveContext)) {
        return "fresh";
    }
    if (bundle.snapshotMode === "fresh" || bundle.snapshotMode === "preserve-ui-state") {
        return bundle.snapshotMode;
    }
    return resolvedBundle.mode;
}

function shouldForceFreshSnapshot(
    effectiveContext: { pageEpoch: number; documentScopeID: number }
): boolean {
    const pendingContext = transitionState.pendingFreshSnapshotContext;
    return !!pendingContext
        && pendingContext.pageEpoch === effectiveContext.pageEpoch
        && pendingContext.documentScopeID === effectiveContext.documentScopeID;
}

function clearPendingFreshSnapshotContext(
    effectiveContext: { pageEpoch: number; documentScopeID: number }
): void {
    if (shouldForceFreshSnapshot(effectiveContext)) {
        transitionState.pendingFreshSnapshotContext = null;
    }
}

/** Apply a single mutation bundle */
export function applyMutationBundle(
    bundle: string | MutationBundle | null | undefined,
    pageEpoch?: number
): void {
    const resolvedBundle = resolveMutationBundleInput(bundle, pageEpoch);
    if (!resolvedBundle) {
        return;
    }

    const parsed = safeParseJSON<MutationBundle>(resolvedBundle.payload);
    if (!parsed || typeof parsed !== "object") {
        return;
    }
    if (typeof parsed.version === "number" && parsed.version !== 1) {
        return;
    }
    const effectiveContext = resolveMutationBundleContext(parsed, resolvedBundle);

    if (parsed.kind === "snapshot") {
        const snapshotMode = resolveSnapshotMode(parsed, resolvedBundle, effectiveContext);
        if (snapshotMode === "preserve-ui-state"
            && !matchesCurrentDocumentContext(effectiveContext.pageEpoch, effectiveContext.documentScopeID)) {
            return;
        }
        if (parsed.snapshot) {
            if (snapshotMode === "fresh" && !canAdoptDocumentContext(effectiveContext)) {
                return;
            }
            const previousContext = {
                pageEpoch: protocolState.pageEpoch,
                documentScopeID: protocolState.documentScopeID,
            };
            const previousPendingFreshSnapshotContext = transitionState.pendingFreshSnapshotContext
                ? { ...transitionState.pendingFreshSnapshotContext }
                : null;
            if (snapshotMode === "fresh") {
                adoptDocumentContext(effectiveContext);
            }
            const didApplySnapshot = setSnapshot(
                parsed.snapshot as unknown as DOMSnapshotEnvelopePayload | SerializedNodeEnvelope | string,
                { mode: snapshotMode }
            );
            if (!didApplySnapshot) {
                if (snapshotMode === "fresh") {
                    restoreDocumentContext(previousContext, {
                        pendingFreshSnapshotContext: previousPendingFreshSnapshotContext,
                    });
                }
                return;
            }
            clearPendingFreshSnapshotContext(effectiveContext);
        }
        return;
    }

    if (parsed.kind === "mutation") {
        if (!matchesCurrentDocumentContext(effectiveContext.pageEpoch, effectiveContext.documentScopeID)) {
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
    pageEpoch?: number
): void {
    if (!bundles) {
        return;
    }
    if (!Array.isArray(bundles)) {
        applyMutationBundle(bundles, pageEpoch);
        return;
    }
    for (const entry of bundles) {
        applyMutationBundle(entry, pageEpoch);
    }
}

/** Apply mutation bundles from a WebKit shared buffer */
export function applyMutationBuffer(bufferName: string, pageEpoch?: number): boolean {
    if (typeof pageEpoch === "number" && pageEpoch !== protocolState.pageEpoch) {
        return false;
    }
    const bundles = applyMutationBundlesFromBuffer(bufferName);
    if (!bundles || !bundles.length) {
        return false;
    }
    applyMutationBundles(bundles, pageEpoch);
    return true;
}

// =============================================================================
// Snapshot Application
// =============================================================================

/** Set the document snapshot */
export function setSnapshot(
    payload: { root?: RawNodeDescriptor } | string | SerializedNodeEnvelope | DOMSnapshotEnvelopePayload | null | undefined,
    options: { mode?: "fresh" | "preserve-ui-state" } = {}
): boolean {
    try {
        ensureDomElements();
        ensureTreeEventHandlers();
        const snapshot = resolveSnapshotPayload(payload);
        if (snapshot === null && payload != null) {
            return false;
        }

        const preserveState = options.mode === "preserve-ui-state" && !!treeState.snapshot;
        const previousSnapshotRoot = preserveState ? treeState.snapshot?.root ?? null : null;
        const previousSelectionId = treeState.selectedNodeId;
        const previousFilter = treeState.filter;
        const preservedOpenState = preserveState ? new Map(treeState.openState) : new Map();
        const preservedScrollPosition = preserveState ? captureTreeScrollPosition() : null;

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
            resetChildNodeRequests(protocolState.pageEpoch, protocolState.documentScopeID);
            clearRenderState();
            if (dom.tree) {
                dom.tree.innerHTML = "";
                dom.tree.scrollTop = 0;
                dom.tree.scrollLeft = 0;
            }
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
            if (!preserveState || !canReuseRoot) {
                resetChildNodeRequests(protocolState.pageEpoch, protocolState.documentScopeID);
            }
            clearRenderState();
            if (dom.tree) {
                dom.tree.innerHTML = "";
                if (!preserveState) {
                    dom.tree.scrollTop = 0;
                    dom.tree.scrollLeft = 0;
                }
            }
            treeState.snapshot = snapshot;
            snapshot.root = normalizedRoot;
            indexNode(normalizedRoot, 0, null);
            if (dom.tree) {
                dom.tree.appendChild(buildNode(normalizedRoot));
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

        if (preservedScrollPosition) {
            restoreTreeScrollPosition(preservedScrollPosition);
        }
        return true;
    } catch (error) {
        reportInspectorError("setSnapshot", error);
        throw error;
    } finally {
        markDocumentRequestCompleted();
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

        const target = treeState.nodes.get(normalized.id);
        if (!target) {
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

        scheduleNodeRender(target);
        setNodeExpanded(target.id, true);

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
    console.debug("[WebInspectorKit] request reload:", reloadReason);
    requestDocumentSafely({ mode: "fresh" });
}

// =============================================================================
// Configuration
// =============================================================================

/** Set preferred snapshot depth */
export function setPreferredDepth(depth: number, pageEpoch?: number): void {
    if (typeof pageEpoch === "number" && pageEpoch !== protocolState.pageEpoch) {
        return;
    }
    if (typeof depth === "number") {
        protocolState.snapshotDepth = depth;
    }
}

// =============================================================================
// Tree Event Wiring
// =============================================================================

/** Register tree-side reload handlers */
export function registerTreeHandlers(): void {
    setReloadHandler(requestSnapshotReload);
    ensureRenderedSnapshotIfNeeded();
}
