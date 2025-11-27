(function(scope) {
    const {
        INDENT_DEPTH_LIMIT,
        LAYOUT_FLAG_RENDERED
    } = scope.DOMTreeState;

    function timeNow() {
        if (typeof performance !== "undefined" && performance.now)
            return performance.now();
        return Date.now();
    }

    function safeParseJSON(value) {
        if (typeof value !== "string")
            return value;
        try {
            return JSON.parse(value);
        } catch {
            return null;
        }
    }

    function normalizeLayoutFlags(rawFlags) {
        if (!Array.isArray(rawFlags))
            return [];
        const flags = [];
        rawFlags.forEach(flag => {
            if (typeof flag === "string" && !flags.includes(flag))
                flags.push(flag);
        });
        return flags;
    }

    function resolveRenderedState(flags, explicitRendered) {
        if (typeof explicitRendered === "boolean")
            return explicitRendered;
        if (Array.isArray(flags))
            return flags.includes(LAYOUT_FLAG_RENDERED);
        return true;
    }

    function applyLayoutState(node, flags, explicitRendered) {
        if (!node)
            return;
        const normalizedFlags = normalizeLayoutFlags(flags);
        node.layoutFlags = normalizedFlags;
        node.isRendered = resolveRenderedState(normalizedFlags, explicitRendered);
    }

    function applyLayoutEntry(node, entry) {
        if (!node || !entry)
            return;
        const hasInfo = Array.isArray(entry.layoutFlags) || typeof entry.isRendered === "boolean";
        if (!hasInfo)
            return;
        applyLayoutState(node, entry.layoutFlags, entry.isRendered);
    }

    function isNodeRendered(node) {
        if (!node)
            return true;
        if (typeof node.isRendered === "boolean")
            return node.isRendered;
        if (Array.isArray(node.layoutFlags))
            return node.layoutFlags.includes(LAYOUT_FLAG_RENDERED);
        return true;
    }

    function clampIndentDepth(depth) {
        if (!Number.isFinite(depth))
            return 0;
        if (depth < 0)
            return 0;
        return Math.min(depth, INDENT_DEPTH_LIMIT);
    }

    function trimText(text, limit = 80) {
        if (!text)
            return "";
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
