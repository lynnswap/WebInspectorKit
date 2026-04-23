/**
 * DOMTreeBackendBridge - typed DOM frontend/backend communication layer.
 */

import {
    DOMDocumentContext,
    ProtocolConfig,
} from "./dom-tree-types";
import { protocolState } from "./dom-tree-state";

type TypedHandlerName =
    | "webInspectorDomRequestChildren"
    | "webInspectorDomReloadSnapshot"
    | "webInspectorDomHighlight"
    | "webInspectorDomHideHighlight";

type WebKitMockHandler = {
    postMessage: (message: unknown) => void;
};

const activeChildNodeRequests = new Map<number, number>();
const contextDidChangeHandlers = new Set<() => void>();
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
        contextID: protocolState.contextID,
    });
}

export function onContextDidChange(handler: () => void): () => void {
    contextDidChangeHandlers.add(handler);
    return () => {
        contextDidChangeHandlers.delete(handler);
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

export function adoptDocumentContext(context: DOMDocumentContext | null | undefined): boolean {
    if (typeof context !== "object" || context === null) {
        return false;
    }
    const nextContextID =
        typeof context.contextID === "number" && Number.isFinite(context.contextID)
            ? context.contextID
            : protocolState.contextID;
    if (nextContextID === protocolState.contextID) {
        return true;
    }
    protocolState.contextID = nextContextID;
    activeChildNodeRequests.clear();
    contextDidChangeHandlers.forEach((handler) => {
        handler();
    });
    return true;
}

export function matchesCurrentDocumentContext(contextID?: number): boolean {
    return typeof contextID !== "number" || contextID === protocolState.contextID;
}

export async function requestChildNodes(nodeId: number, depth: number): Promise<void> {
    if (typeof nodeId !== "number" || nodeId <= 0) {
        return;
    }
    if (activeChildNodeRequests.get(nodeId) === depth) {
        return;
    }
    activeChildNodeRequests.set(nodeId, depth);
    try {
        postTypedMessage("webInspectorDomRequestChildren", {
            nodeId,
            depth,
        });
    } catch (error) {
        activeChildNodeRequests.delete(nodeId);
        throw error;
    }
}

export function markChildNodesRequestCompleted(nodeId: number): void {
    if (typeof nodeId !== "number" || nodeId <= 0) {
        return;
    }
    activeChildNodeRequests.delete(nodeId);
    childNodeRequestCompletedHandlers.forEach((handler) => {
        handler(nodeId);
    });
}

export function finishChildNodeRequest(nodeId: number, success: boolean, contextID?: number): void {
    if (!matchesCurrentDocumentContext(contextID)) {
        return;
    }
    if (typeof nodeId !== "number" || nodeId <= 0) {
        return;
    }
    activeChildNodeRequests.delete(nodeId);
    if (success) {
        childNodeRequestCompletedHandlers.forEach((handler) => {
            handler(nodeId);
        });
    }
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

export function requestSnapshotReload(reason: string): void {
    postTypedMessage("webInspectorDomReloadSnapshot", {
        reason,
    });
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
