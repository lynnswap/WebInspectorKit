/**
 * DOMTreeProtocol - WebKit protocol communication layer.
 *
 * This module provides:
 * - Protocol message sending/receiving
 * - Command-response handling
 * - Event dispatching
 * - Error reporting
 */

import {
    ProtocolConfig,
    ProtocolEventHandler,
    ProtocolMessage,
} from "./dom-tree-types";
import { protocolState } from "./dom-tree-state";
import { safeParseJSON } from "./dom-tree-utilities";

// =============================================================================
// Request Child Nodes Handler
// =============================================================================

/** Handler for requestChildNodes command results */
let requestChildNodesHandler: ((result: unknown) => void) | null = null;

/** Set the handler for requestChildNodes results */
export function setRequestChildNodesHandler(
    handler: ((result: unknown) => void) | null
): void {
    requestChildNodesHandler = typeof handler === "function" ? handler : null;
}

// =============================================================================
// Configuration
// =============================================================================

/** Update protocol configuration */
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

// =============================================================================
// Message Sending
// =============================================================================

/** Send a raw protocol message to the backend */
export function sendProtocolMessage(message: string | object): void {
    const payload = typeof message === "string" ? message : JSON.stringify(message);
    window.webkit?.messageHandlers?.webInspectorProtocol?.postMessage(payload);
}

/** Send a protocol command and await the response */
export async function sendCommand<T = unknown>(
    method: string,
    params: Record<string, unknown> = {}
): Promise<T> {
    const id = ++protocolState.lastId;
    const message = { id, method, params };

    return new Promise((resolve, reject) => {
        protocolState.pending.set(id, {
            resolve: resolve as (value: unknown) => void,
            reject,
            method,
        });
        try {
            sendProtocolMessage(message);
        } catch (error) {
            protocolState.pending.delete(id);
            reject(error);
        }
    });
}

// =============================================================================
// Message Dispatch
// =============================================================================

/** Dispatch a message received from the backend */
export function dispatchMessageFromBackend(message: string | ProtocolMessage): void {
    const parsed = safeParseJSON<ProtocolMessage>(message);
    if (!parsed || typeof parsed !== "object") {
        return;
    }

    // Handle command response
    if (Object.prototype.hasOwnProperty.call(parsed, "id")) {
        const requestId = parsed.id;
        if (typeof requestId !== "number") {
            return;
        }

        const pending = protocolState.pending.get(requestId);
        if (!pending) {
            return;
        }

        protocolState.pending.delete(requestId);

        if (parsed.error) {
            pending.reject(parsed.error);
        } else {
            const method = pending.method || "";
            let result = parsed.result;

            if (typeof result === "string") {
                result = safeParseJSON(result) ?? result;
            }

            if (method === "DOM.requestChildNodes" && requestChildNodesHandler) {
                requestChildNodesHandler(result);
            }

            pending.resolve(result);
        }
        return;
    }

    // Handle event
    if (typeof parsed.method !== "string") {
        return;
    }

    emitProtocolEvent(parsed.method, parsed.params || {}, parsed);
}

// =============================================================================
// Event Handling
// =============================================================================

/** Register an event handler for a protocol event */
export function onProtocolEvent(method: string, handler: ProtocolEventHandler): void {
    if (!protocolState.eventHandlers.has(method)) {
        protocolState.eventHandlers.set(method, new Set());
    }
    protocolState.eventHandlers.get(method)!.add(handler);
}

/** Emit a protocol event to registered handlers */
export function emitProtocolEvent(
    method: string,
    params: Record<string, unknown>,
    rawMessage: unknown
): void {
    const listeners = protocolState.eventHandlers.get(method);
    if (!listeners || !listeners.size) {
        return;
    }

    listeners.forEach((listener) => {
        try {
            listener(params, method, rawMessage);
        } catch (error) {
            reportInspectorError(`event:${method}`, error);
        }
    });
}

// =============================================================================
// Error Reporting
// =============================================================================

/** Report an error to console and native logger */
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
