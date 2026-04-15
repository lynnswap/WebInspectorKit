/**
 * DOMTreeBackendBridge - typed DOM frontend/backend communication layer.
 */

import {
    DOMDocumentContext,
    ProtocolConfig,
    RequestDocumentMode,
    RequestDocumentOptions,
} from "./dom-tree-types";
import { protocolState, transitionState } from "./dom-tree-state";

type TypedHandlerName =
    | "webInspectorDomRequestChildren"
    | "webInspectorDomRequestDocument"
    | "webInspectorDomHighlight"
    | "webInspectorDomHideHighlight";

type WebKitMockHandler = {
    postMessage: (message: unknown) => void;
};

const pendingChildNodeDepths = new Map<number, number>();
const activeChildNodeRequests = new Map<number, number>();
const activeChildNodeRequestDepths = new Map<number, number>();
const pageEpochDidChangeHandlers = new Set<() => void>();
const childNodeRequestCompletedHandlers = new Set<(nodeId: number) => void>();

function typedHandler(name: TypedHandlerName): WebKitMockHandler | null {
    return (window.webkit?.messageHandlers?.[name] as WebKitMockHandler | undefined) ?? null;
}

function postTypedMessage(
    handlerName: TypedHandlerName,
    payload: Record<string, unknown> = {}
): void {
    const handler = typedHandler(handlerName);
    if (!handler || typeof handler.postMessage !== "function") {
        const error = new Error(`${handlerName} handler unavailable`);
        reportInspectorError(handlerName, error);
        throw error;
    }

    handler.postMessage({
        ...payload,
        pageEpoch: protocolState.pageEpoch,
        documentScopeID: protocolState.documentScopeID,
    });
}

function drainQueuedChildNodeRequest(nodeId: number): void {
    const requestPageEpoch = protocolState.pageEpoch;
    if (activeChildNodeRequests.get(nodeId) === requestPageEpoch) {
        return;
    }
    const nextDepth = pendingChildNodeDepths.get(nodeId);
    if (typeof nextDepth !== "number") {
        return;
    }
    pendingChildNodeDepths.delete(nodeId);
    activeChildNodeRequests.set(nodeId, requestPageEpoch);
    activeChildNodeRequestDepths.set(nodeId, nextDepth);
    try {
        postTypedMessage("webInspectorDomRequestChildren", {
            nodeId,
            depth: nextDepth,
        });
    } catch (error) {
        activeChildNodeRequests.delete(nodeId);
        activeChildNodeRequestDepths.delete(nodeId);
        throw error;
    }
}

export function onPageEpochDidChange(handler: () => void): () => void {
    pageEpochDidChangeHandlers.add(handler);
    return () => {
        pageEpochDidChangeHandlers.delete(handler);
    };
}

export function onChildNodeRequestCompleted(handler: (nodeId: number) => void): () => void {
    childNodeRequestCompletedHandlers.add(handler);
    return () => {
        childNodeRequestCompletedHandlers.delete(handler);
    };
}

export function updateConfig(partial: ProtocolConfig | null | undefined): void {
    if (typeof partial !== "object" || partial === null) {
        return;
    }

    if (typeof partial.snapshotDepth === "number") {
        protocolState.snapshotDepth = partial.snapshotDepth;
    }
    if (typeof partial.subtreeDepth === "number") {
        protocolState.subtreeDepth = partial.subtreeDepth;
    }
}

type AdoptDocumentContextOptions = {
    allowOutOfOrder?: boolean;
};

type RestoreDocumentContextOptions = {
    pendingFreshSnapshotContext?: { pageEpoch: number; documentScopeID: number } | null;
};

export function adoptDocumentContext(
    context: DOMDocumentContext | null | undefined,
    options: AdoptDocumentContextOptions = {}
): boolean {
    if (typeof context !== "object" || context === null) {
        return false;
    }

    const nextPageEpoch =
        typeof context.pageEpoch === "number" && Number.isFinite(context.pageEpoch)
            ? context.pageEpoch
            : protocolState.pageEpoch;
    const nextDocumentScopeID =
        typeof context.documentScopeID === "number" && Number.isFinite(context.documentScopeID)
            ? context.documentScopeID
            : protocolState.documentScopeID;

    if (!options.allowOutOfOrder && !canAdoptResolvedDocumentContext(nextPageEpoch, nextDocumentScopeID)) {
        return false;
    }

    const didChange =
        nextPageEpoch !== protocolState.pageEpoch
        || nextDocumentScopeID !== protocolState.documentScopeID;
    if (!didChange) {
        return true;
    }

    protocolState.pageEpoch = nextPageEpoch;
    protocolState.documentScopeID = nextDocumentScopeID;
    transitionState.pendingFreshSnapshotContext = {
        pageEpoch: nextPageEpoch,
        documentScopeID: nextDocumentScopeID,
    };
    pendingChildNodeDepths.clear();
    activeChildNodeRequests.clear();
    activeChildNodeRequestDepths.clear();
    pageEpochDidChangeHandlers.forEach((handler) => {
        handler();
    });
    return true;
}

export function canAdoptDocumentContext(context: DOMDocumentContext | null | undefined): boolean {
    if (typeof context !== "object" || context === null) {
        return false;
    }

    const nextPageEpoch =
        typeof context.pageEpoch === "number" && Number.isFinite(context.pageEpoch)
            ? context.pageEpoch
            : protocolState.pageEpoch;
    const nextDocumentScopeID =
        typeof context.documentScopeID === "number" && Number.isFinite(context.documentScopeID)
            ? context.documentScopeID
            : protocolState.documentScopeID;
    return canAdoptResolvedDocumentContext(nextPageEpoch, nextDocumentScopeID);
}

export function restoreDocumentContext(
    context: DOMDocumentContext | null | undefined,
    options: RestoreDocumentContextOptions = {}
): boolean {
    if (typeof context !== "object" || context === null) {
        return false;
    }

    const nextPageEpoch =
        typeof context.pageEpoch === "number" && Number.isFinite(context.pageEpoch)
            ? context.pageEpoch
            : protocolState.pageEpoch;
    const nextDocumentScopeID =
        typeof context.documentScopeID === "number" && Number.isFinite(context.documentScopeID)
            ? context.documentScopeID
            : protocolState.documentScopeID;

    protocolState.pageEpoch = nextPageEpoch;
    protocolState.documentScopeID = nextDocumentScopeID;
    transitionState.pendingFreshSnapshotContext = options.pendingFreshSnapshotContext ?? null;
    return true;
}

function canAdoptResolvedDocumentContext(nextPageEpoch: number, nextDocumentScopeID: number): boolean {
    const isOlderPageEpoch = nextPageEpoch < protocolState.pageEpoch;
    const isOlderDocumentScopeID =
        nextPageEpoch === protocolState.pageEpoch
        && nextDocumentScopeID < protocolState.documentScopeID;
    return !(isOlderPageEpoch || isOlderDocumentScopeID);
}

export function matchesCurrentDocumentContext(
    pageEpoch?: number,
    documentScopeID?: number
): boolean {
    if (typeof pageEpoch === "number" && pageEpoch !== protocolState.pageEpoch) {
        return false;
    }
    if (typeof documentScopeID === "number" && documentScopeID !== protocolState.documentScopeID) {
        return false;
    }
    return true;
}

export function requestDocumentFromBackend(options: RequestDocumentOptions = {}): void {
    const requestPageEpoch =
        typeof options.pageEpoch === "number" && Number.isFinite(options.pageEpoch)
            ? options.pageEpoch
            : protocolState.pageEpoch;
    if (requestPageEpoch !== protocolState.pageEpoch) {
        return;
    }

    const requestDocumentScopeID =
        typeof options.documentScopeID === "number" && Number.isFinite(options.documentScopeID)
            ? options.documentScopeID
            : protocolState.documentScopeID;
    if (requestDocumentScopeID !== protocolState.documentScopeID) {
        return;
    }

    const depth = typeof options.depth === "number" ? options.depth : protocolState.snapshotDepth;
    const mode: RequestDocumentMode = options.mode === "preserve-ui-state" ? "preserve-ui-state" : "fresh";
    const payload: Record<string, unknown> = {
        depth,
        mode,
        pageEpoch: requestPageEpoch,
        documentScopeID: requestDocumentScopeID,
    };
    if (options.selectionRestoreTarget && typeof options.selectionRestoreTarget === "object") {
        payload.selectionRestoreTarget = options.selectionRestoreTarget;
    }
    postTypedMessage("webInspectorDomRequestDocument", payload);
}

export async function requestChildNodes(nodeId: number, depth: number): Promise<void> {
    if (typeof nodeId !== "number" || nodeId <= 0) {
        return;
    }

    const requestPageEpoch = protocolState.pageEpoch;
    if (
        activeChildNodeRequests.get(nodeId) === requestPageEpoch
        && activeChildNodeRequestDepths.get(nodeId) === depth
    ) {
        return;
    }
    if (pendingChildNodeDepths.get(nodeId) === depth) {
        return;
    }

    pendingChildNodeDepths.set(nodeId, depth);
    drainQueuedChildNodeRequest(nodeId);
}

export function markChildNodesRequestCompleted(nodeId: number): void {
    if (typeof nodeId !== "number" || nodeId <= 0) {
        return;
    }
    activeChildNodeRequests.delete(nodeId);
    activeChildNodeRequestDepths.delete(nodeId);
    childNodeRequestCompletedHandlers.forEach((handler) => {
        handler(nodeId);
    });
    drainQueuedChildNodeRequest(nodeId);
}

export function rejectChildNodeRequest(nodeId: number, pageEpoch?: number, documentScopeID?: number): void {
    if (typeof pageEpoch === "number" && pageEpoch !== protocolState.pageEpoch) {
        return;
    }
    if (typeof documentScopeID === "number" && documentScopeID !== protocolState.documentScopeID) {
        return;
    }
    if (typeof nodeId !== "number" || nodeId <= 0) {
        return;
    }

    const activeDepth = activeChildNodeRequestDepths.get(nodeId);
    activeChildNodeRequests.delete(nodeId);
    activeChildNodeRequestDepths.delete(nodeId);
    if (typeof activeDepth === "number" && !pendingChildNodeDepths.has(nodeId)) {
        pendingChildNodeDepths.set(nodeId, activeDepth);
    }
}

export function resetChildNodeRequests(pageEpoch?: number, documentScopeID?: number): void {
    if (typeof pageEpoch === "number" && pageEpoch !== protocolState.pageEpoch) {
        return;
    }
    if (typeof documentScopeID === "number" && documentScopeID !== protocolState.documentScopeID) {
        return;
    }
    pendingChildNodeDepths.clear();
    activeChildNodeRequests.clear();
    activeChildNodeRequestDepths.clear();
}

export function retryQueuedChildNodeRequests(): void {
    const pendingNodeIDs = [...pendingChildNodeDepths.keys()];
    for (const nodeId of pendingNodeIDs) {
        drainQueuedChildNodeRequest(nodeId);
    }
}

export function completeChildNodeRequest(nodeId: number, pageEpoch?: number, documentScopeID?: number): void {
    if (typeof pageEpoch === "number" && pageEpoch !== protocolState.pageEpoch) {
        return;
    }
    if (typeof documentScopeID === "number" && documentScopeID !== protocolState.documentScopeID) {
        return;
    }
    markChildNodesRequestCompleted(nodeId);
}

export function requestHighlightNode(nodeId: number, options: { reveal?: boolean } = {}): void {
    if (typeof nodeId !== "number" || nodeId <= 0) {
        return;
    }
    postTypedMessage("webInspectorDomHighlight", {
        nodeId,
        reveal: options.reveal !== false,
    });
}

export function requestHideHighlight(): void {
    postTypedMessage("webInspectorDomHideHighlight");
}

export function reportInspectorError(context: string, error: unknown): void {
    const details =
        error && typeof error === "object" && "stack" in error
            ? (error as Error).stack
            : error && typeof error === "object" && "message" in error
              ? (error as Error).message
              : String(error);

    console.error(`[WebInspectorKit] ${context}:`, error);

    try {
        window.webkit?.messageHandlers?.webInspectorLog?.postMessage(`${context}: ${details}`);
    } catch {
        // ignore logging failures
    }
}

export function isExpectedStaleProtocolResponseError(error: unknown): boolean {
    return error instanceof Error && error.message === "Stale DOM request";
}
