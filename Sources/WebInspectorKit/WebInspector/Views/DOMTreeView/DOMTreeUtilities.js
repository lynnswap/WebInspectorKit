import {INDENT_DEPTH_LIMIT, LAYOUT_FLAG_RENDERED} from "./DOMTreeState.js";

export function timeNow() {
    if (typeof performance !== "undefined" && performance.now)
        return performance.now();
    return Date.now();
}

export function safeParseJSON(value) {
    if (typeof value !== "string")
        return value;
    try {
        return JSON.parse(value);
    } catch {
        return null;
    }
}

export function normalizeLayoutFlags(rawFlags) {
    if (!Array.isArray(rawFlags))
        return [];
    const flags = [];
    rawFlags.forEach(flag => {
        if (typeof flag === "string" && !flags.includes(flag))
            flags.push(flag);
    });
    return flags;
}

export function resolveRenderedState(flags, explicitRendered) {
    if (typeof explicitRendered === "boolean")
        return explicitRendered;
    if (Array.isArray(flags))
        return flags.includes(LAYOUT_FLAG_RENDERED);
    return true;
}

export function applyLayoutState(node, flags, explicitRendered) {
    if (!node)
        return;
    const normalizedFlags = normalizeLayoutFlags(flags);
    node.layoutFlags = normalizedFlags;
    node.isRendered = resolveRenderedState(normalizedFlags, explicitRendered);
}

export function applyLayoutEntry(node, entry) {
    if (!node || !entry)
        return;
    const hasInfo = Array.isArray(entry.layoutFlags) || typeof entry.isRendered === "boolean";
    if (!hasInfo)
        return;
    applyLayoutState(node, entry.layoutFlags, entry.isRendered);
}

export function isNodeRendered(node) {
    if (!node)
        return true;
    if (typeof node.isRendered === "boolean")
        return node.isRendered;
    if (Array.isArray(node.layoutFlags))
        return node.layoutFlags.includes(LAYOUT_FLAG_RENDERED);
    return true;
}

export function clampIndentDepth(depth) {
    if (!Number.isFinite(depth))
        return 0;
    if (depth < 0)
        return 0;
    return Math.min(depth, INDENT_DEPTH_LIMIT);
}

export function trimText(text, limit = 80) {
    if (!text)
        return "";
    const normalized = text.replace(/\s+/g, " ").trim();
    return normalized.length > limit ? `${normalized.slice(0, limit)}…` : normalized;
}
