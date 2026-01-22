/**
 * DOMTreeUtilities - Utility functions for DOMTreeView.
 *
 * This module provides:
 * - Time measurement utilities
 * - JSON parsing helpers
 * - Layout flag processing
 * - Rendered state resolution
 * - Text formatting utilities
 */

import {
    DOMNode,
    LayoutFlag,
    LayoutStateResult,
    INDENT_DEPTH_LIMIT,
    LAYOUT_FLAG_RENDERED,
} from "./dom-tree-types";
import { treeState } from "./dom-tree-state";

// =============================================================================
// Time Utilities
// =============================================================================

/** Get current time in milliseconds with high precision if available */
export function timeNow(): number {
    if (typeof performance !== "undefined" && performance.now) {
        return performance.now();
    }
    return Date.now();
}

// =============================================================================
// JSON Utilities
// =============================================================================

/** Safely parse JSON, returning the input if already an object or null on error */
export function safeParseJSON<T = unknown>(value: unknown): T | null {
    if (typeof value !== "string") {
        return value as T;
    }
    try {
        return JSON.parse(value) as T;
    } catch {
        return null;
    }
}

// =============================================================================
// Layout Flag Utilities
// =============================================================================

/** Normalize raw layout flags to a clean string array */
export function normalizeLayoutFlags(rawFlags: unknown): LayoutFlag[] {
    if (!Array.isArray(rawFlags)) {
        return [];
    }
    const flags: LayoutFlag[] = [];
    for (const flag of rawFlags) {
        if (typeof flag === "string" && !flags.includes(flag)) {
            flags.push(flag);
        }
    }
    return flags;
}

/** Resolve whether a node is rendered based on flags or explicit state */
export function resolveRenderedState(
    flags: LayoutFlag[],
    explicitRendered?: boolean
): boolean {
    if (typeof explicitRendered === "boolean") {
        return explicitRendered;
    }
    if (Array.isArray(flags)) {
        return flags.includes(LAYOUT_FLAG_RENDERED);
    }
    return true;
}

/** Apply layout state to a node and return change information */
export function applyLayoutState(
    node: DOMNode | null | undefined,
    flags: unknown,
    explicitRendered: boolean | undefined,
    parentRendered: boolean
): LayoutStateResult {
    if (!node) {
        return { changed: false, isRendered: true, renderedSelf: true };
    }

    const normalizedFlags = normalizeLayoutFlags(flags);
    const previous = typeof node.isRendered === "boolean" ? node.isRendered : true;
    const renderedSelf = resolveRenderedState(normalizedFlags, explicitRendered);
    const ancestorRendered = typeof parentRendered === "boolean" ? parentRendered : true;
    const isRendered = ancestorRendered && renderedSelf;

    node.layoutFlags = normalizedFlags;
    node.renderedSelf = renderedSelf;
    node.isRendered = isRendered;

    return {
        changed: previous !== isRendered,
        isRendered,
        renderedSelf,
    };
}

/** Layout entry from protocol events */
interface LayoutEntry {
    layoutFlags?: unknown[];
    isRendered?: boolean;
}

/** Apply layout state from a protocol entry */
export function applyLayoutEntry(
    node: DOMNode | null | undefined,
    entry: LayoutEntry | null | undefined,
    parentRendered: boolean
): LayoutStateResult {
    if (!node || !entry) {
        return { changed: false, isRendered: true, renderedSelf: true };
    }

    const hasInfo =
        Array.isArray(entry.layoutFlags) || typeof entry.isRendered === "boolean";
    if (!hasInfo) {
        return { changed: false, isRendered: true, renderedSelf: true };
    }

    return applyLayoutState(node, entry.layoutFlags, entry.isRendered, parentRendered);
}

/** Check if a node is rendered, recursively checking ancestors */
export function isNodeRendered(node: DOMNode | null | undefined): boolean {
    if (!node) {
        return true;
    }

    if (typeof node.isRendered === "boolean") {
        return node.isRendered;
    }

    const renderedSelf = resolveRenderedState(
        Array.isArray(node.layoutFlags) ? node.layoutFlags : [],
        typeof node.renderedSelf === "boolean" ? node.renderedSelf : undefined
    );

    const parent =
        node.parentId != null && treeState.nodes
            ? treeState.nodes.get(node.parentId)
            : null;
    const ancestorRendered = parent ? isNodeRendered(parent) : true;

    return ancestorRendered && renderedSelf;
}

// =============================================================================
// Depth Utilities
// =============================================================================

/** Clamp indent depth to valid range */
export function clampIndentDepth(depth: number): number {
    if (!Number.isFinite(depth)) {
        return 0;
    }
    if (depth < 0) {
        return 0;
    }
    return Math.min(depth, INDENT_DEPTH_LIMIT);
}

// =============================================================================
// Text Utilities
// =============================================================================

/** Trim and truncate text for display */
export function trimText(text: string | null | undefined, limit = 80): string {
    if (!text) {
        return "";
    }
    const normalized = text.replace(/\s+/g, " ").trim();
    return normalized.length > limit ? `${normalized.slice(0, limit)}…` : normalized;
}
