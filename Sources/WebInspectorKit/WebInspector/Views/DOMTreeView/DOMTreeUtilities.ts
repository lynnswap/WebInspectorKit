// @ts-nocheck
(function(scope) {
    const {
        INDENT_DEPTH_LIMIT,
        LAYOUT_FLAG_RENDERED,
        treeState: state
    } = scope.DOMTreeState;

    function timeNow() {
        if (typeof performance !== "undefined" && performance.now) {
            return performance.now();
        }
        return Date.now();
    }

    function safeParseJSON(value) {
        if (typeof value !== "string") {
            return value;
        }
        try {
            return JSON.parse(value);
        } catch {
            return null;
        }
    }

    function normalizeLayoutFlags(rawFlags) {
        if (!Array.isArray(rawFlags)) {
            return [];
        }
        const flags = [];
        rawFlags.forEach(flag => {
            if (typeof flag === "string" && !flags.includes(flag)) {
                flags.push(flag);
            }
        });
        return flags;
    }

    function resolveRenderedState(flags, explicitRendered) {
        if (typeof explicitRendered === "boolean") {
            return explicitRendered;
        }
        if (Array.isArray(flags)) {
            return flags.includes(LAYOUT_FLAG_RENDERED);
        }
        return true;
    }

    function applyLayoutState(node, flags, explicitRendered, parentRendered) {
        if (!node) {
            return {changed: false, isRendered: true, renderedSelf: true};
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
            renderedSelf
        };
    }

    function applyLayoutEntry(node, entry, parentRendered) {
        if (!node || !entry) {
            return {changed: false, isRendered: true, renderedSelf: true};
        }
        const hasInfo = Array.isArray(entry.layoutFlags) || typeof entry.isRendered === "boolean";
        if (!hasInfo) {
            return {changed: false, isRendered: true, renderedSelf: true};
        }
        return applyLayoutState(node, entry.layoutFlags, entry.isRendered, parentRendered);
    }

    function isNodeRendered(node) {
        if (!node) {
            return true;
        }
        if (typeof node.isRendered === "boolean") {
            return node.isRendered;
        }
        const renderedSelf = resolveRenderedState(Array.isArray(node.layoutFlags) ? node.layoutFlags : [], typeof node.renderedSelf === "boolean" ? node.renderedSelf : undefined);
        const parent = node.parentId && state.nodes ? state.nodes.get(node.parentId) : null;
        const ancestorRendered = parent ? isNodeRendered(parent) : true;
        return ancestorRendered && renderedSelf;
    }

    function clampIndentDepth(depth) {
        if (!Number.isFinite(depth)) {
            return 0;
        }
        if (depth < 0) {
            return 0;
        }
        return Math.min(depth, INDENT_DEPTH_LIMIT);
    }

    function trimText(text, limit = 80) {
        if (!text) {
            return "";
        }
        const normalized = text.replace(/\s+/g, " ").trim();
        return normalized.length > limit ? `${normalized.slice(0, limit)}…` : normalized;
    }

    scope.DOMTreeUtilities = {
        timeNow,
        safeParseJSON,
        normalizeLayoutFlags,
        resolveRenderedState,
        applyLayoutState,
        applyLayoutEntry,
        isNodeRendered,
        clampIndentDepth,
        trimText
    };
})(window.DOMTree || (window.DOMTree = {}));
