import {inspector, type AnyNode, type SelectionState} from "./dom-agent-state";
import {
    computeNodePath,
    rememberNode,
    stableNodeIdentifier,
    INSPECTOR_INTERNAL_SELECTION_SHIELD_ATTRIBUTE
} from "./dom-agent-dom-core";
import {selectorPathForNode} from "./dom-agent-dom-utils";
import {clearHighlight, highlightSelectionNode} from "./dom-agent-overlay";
import {resumeSnapshotAutoUpdate, suppressSnapshotAutoUpdate} from "./dom-agent-snapshot";

type SelectionAttribute = {
    name: string;
    value: string;
};

type SelectionResult = {
    cancelled: boolean;
    requiredDepth: number;
    selectedPath?: number[];
    selectedLocalId?: number;
    ancestorLocalIds?: number[];
    selectedBackendNodeId?: number;
    selectedBackendNodeIdIsStable?: boolean;
    ancestorBackendNodeIds?: number[];
    selectedAttributes?: SelectionAttribute[];
    selectedPreview?: string;
    selectedSelectorPath?: string;
};

type PointerLikeEvent = MouseEvent | PointerEvent | TouchEvent;

const INLINE_LIKE_TAG_NAMES = new Set([
    "A",
    "ABBR",
    "B",
    "CITE",
    "CODE",
    "EM",
    "I",
    "LABEL",
    "SMALL",
    "SPAN",
    "STRONG",
    "SUB",
    "SUP",
    "TIME",
]);

const REPLACED_INLINE_TAG_NAMES = new Set([
    "IMG",
    "SVG",
    "VIDEO",
    "CANVAS",
    "INPUT",
    "TEXTAREA",
    "SELECT",
    "BUTTON",
    "IFRAME",
    "EMBED",
    "OBJECT",
    "AUDIO",
]);

function enableSelectionCursor() {
    if (!inspector.cursorBackup) {
        inspector.cursorBackup = {
            html: document.documentElement ? document.documentElement.style.cursor : "",
            body: document.body ? document.body.style.cursor : ""
        };
    }
    if (document.documentElement) {
        document.documentElement.style.cursor = "crosshair";
    }
    if (document.body) {
        document.body.style.cursor = "crosshair";
    }
}

function restoreSelectionCursor() {
    var backup = inspector.cursorBackup || {html: "", body: ""};
    if (document.documentElement) {
        document.documentElement.style.cursor = backup.html || "";
    }
    if (document.body) {
        document.body.style.cursor = backup.body || "";
    }
    inspector.cursorBackup = null;
}

function interceptEvent(event: Event | null | undefined) {
    if (!event) {
        return;
    }
    if (event.cancelable) {
        event.preventDefault();
    }
    event.stopPropagation();
    if (event.stopImmediatePropagation) {
        event.stopImmediatePropagation();
    }
}

function installWindowClickBlocker() {
    if (inspector.windowClickBlockerHandler) {
        return;
    }
    inspector.windowClickBlockerPendingRelease = false;
    var handler = function(event: Event) {
        interceptEvent(event);
        if (!inspector.selectionState && inspector.windowClickBlockerPendingRelease) {
            uninstallWindowClickBlocker();
        }
    };
    inspector.windowClickBlockerHandler = handler;
    window.addEventListener("click", handler, true);
}

function uninstallWindowClickBlocker() {
    inspector.windowClickBlockerPendingRelease = false;
    if (inspector.windowClickBlockerRemovalTimer) {
        clearTimeout(inspector.windowClickBlockerRemovalTimer);
        inspector.windowClickBlockerRemovalTimer = null;
    }
    if (!inspector.windowClickBlockerHandler) {
        return;
    }
    window.removeEventListener("click", inspector.windowClickBlockerHandler, true);
    inspector.windowClickBlockerHandler = null;
}

function scheduleWindowClickBlockerRelease() {
    if (!inspector.windowClickBlockerHandler) {
        return;
    }
    inspector.windowClickBlockerPendingRelease = true;
    if (inspector.windowClickBlockerRemovalTimer) {
        return;
    }
    inspector.windowClickBlockerRemovalTimer = setTimeout(function() {
        uninstallWindowClickBlocker();
    }, 350);
}

function createSelectionShield() {
    const shield = document.createElement("div");
    shield.setAttribute(INSPECTOR_INTERNAL_SELECTION_SHIELD_ATTRIBUTE, "true");
    shield.style.position = "fixed";
    shield.style.left = "0";
    shield.style.top = "0";
    shield.style.width = "100vw";
    shield.style.height = "100vh";
    shield.style.zIndex = "2147483646";
    shield.style.background = "transparent";
    shield.style.cursor = "crosshair";
    shield.style.pointerEvents = "auto";
    shield.style.touchAction = "none";
    shield.style.userSelect = "none";
    document.documentElement.appendChild(shield);
    return shield;
}

function removeSelectionShield(shield: HTMLDivElement | null) {
    if (!shield || !shield.parentNode) {
        return;
    }
    shield.parentNode.removeChild(shield);
}

function computeAncestorBackendNodeIds(node: AnyNode | null): number[] {
    if (!node) {
        return [];
    }
    const root = document.documentElement || document.body;
    if (!root) {
        return [];
    }
    const ancestorNodeIds: number[] = [];
    let current = node.parentNode as AnyNode | null;
    while (current) {
        const stableNodeId = stableNodeIdentifier(current) || 0;
        if (stableNodeId > 0) {
            ancestorNodeIds.unshift(stableNodeId);
        }
        if (current === root) {
            break;
        }
        current = current.parentNode as AnyNode | null;
    }
    return ancestorNodeIds;
}

function computeAncestorLocalIds(node: AnyNode | null): number[] {
    if (!node) {
        return [];
    }
    const root = document.documentElement || document.body;
    if (!root) {
        return [];
    }
    const ancestorHandleIds: number[] = [];
    let current = node.parentNode as AnyNode | null;
    while (current) {
        const handleId = rememberNode(current);
        if (handleId) {
            ancestorHandleIds.unshift(handleId);
        }
        if (current === root) {
            break;
        }
        current = current.parentNode as AnyNode | null;
    }
    return ancestorHandleIds;
}

function isPromotableInlineLeaf(element: Element, display: string): boolean {
    if (REPLACED_INLINE_TAG_NAMES.has(element.tagName)) {
        return false;
    }
    if (element.tagName === "SPAN") {
        return false;
    }
    if (!INLINE_LIKE_TAG_NAMES.has(element.tagName)) {
        return false;
    }
    return display === "" || display === "inline" || display === "contents";
}

function isPromotableInlineWrapper(element: Element, display: string): boolean {
    if (REPLACED_INLINE_TAG_NAMES.has(element.tagName)) {
        return false;
    }
    if (element.tagName !== "SPAN" && !INLINE_LIKE_TAG_NAMES.has(element.tagName)) {
        return false;
    }
    if (!(display === "" || display === "inline" || display === "contents")) {
        return false;
    }
    return elementHasPromotableInlineContent(element);
}

function normalizedSelectionTarget(target: AnyNode | null): AnyNode | null {
    if (!target) {
        return null;
    }
    let element: Element | null = target.nodeType === Node.ELEMENT_NODE
        ? target as Element
        : target.parentElement;
    if (!element) {
        return target;
    }

    while (element && element.parentElement && element !== document.body && element !== document.documentElement) {
        const currentElement: Element = element;
        const parent = currentElement.parentElement;
        if (!parent) {
            break;
        }
        if (parent === document.body || parent === document.documentElement) {
            break;
        }
        let display = "";
        try {
            display = window.getComputedStyle(currentElement).display || "";
        } catch {
            break;
        }
        const shouldPromote =
            isPromotableInlineLeaf(currentElement, display)
            || isPromotableInlineWrapper(currentElement, display);
        if (!shouldPromote) {
            break;
        }
        element = parent;
    }

    return element as AnyNode;
}

function elementHasPromotableInlineContent(element: Element): boolean {
    let elementChildCount = 0;
    let significantTextNodeCount = 0;
    let soleElementChild: Element | null = null;
    for (const childNode of Array.from(element.childNodes)) {
        if (childNode.nodeType === Node.ELEMENT_NODE) {
            elementChildCount += 1;
            soleElementChild = childNode as Element;
            continue;
        }
        if (childNode.nodeType === Node.TEXT_NODE) {
            if ((childNode.textContent || "").trim().length === 0) {
                continue;
            }
            significantTextNodeCount += 1;
            continue;
        }
        if (childNode.nodeType === Node.COMMENT_NODE) {
            continue;
        }
        return false;
    }
    if (elementChildCount === 1 && significantTextNodeCount === 0 && soleElementChild) {
        let childDisplay = "";
        try {
            childDisplay = window.getComputedStyle(soleElementChild).display || "";
        } catch {
            return false;
        }
        const childIsInlineLike = isPromotableInlineLeaf(soleElementChild, childDisplay);
        return childIsInlineLike;
    }
    if (elementChildCount === 0 && significantTextNodeCount === 1) {
        return true;
    }
    return false;
}

function selectionPreviewForNode(node: AnyNode | null): string {
    if (!node) {
        return "";
    }
    if (node.nodeType === Node.ELEMENT_NODE) {
        const element = node as Element;
        let preview = `<${element.localName || element.nodeName.toLowerCase()}`;
        if (element.id) {
            preview += ` id="${element.id}"`;
        }
        preview += ">";
        return preview;
    }
    if (node.nodeType === Node.TEXT_NODE) {
        return node.nodeValue || "#text";
    }
    return node.nodeName || "";
}

function selectionAttributesForNode(node: AnyNode | null): SelectionAttribute[] {
    if (!node || node.nodeType !== Node.ELEMENT_NODE) {
        return [];
    }
    const element = node as Element;
    const attributes: SelectionAttribute[] = [];
    for (let index = 0; index < element.attributes.length; index += 1) {
        const attribute = element.attributes[index];
        attributes.push({
            name: attribute.name,
            value: attribute.value
        });
    }
    return attributes;
}

export function startElementSelection() {
    cancelElementSelection();
    return new Promise<SelectionResult>(function(resolve) {
        const selectionShield = createSelectionShield();
        var state: SelectionState = {
            active: true,
            latestTarget: null,
            bindings: []
        };
        inspector.selectionState = state;

        suppressSnapshotAutoUpdate("selection");
        enableSelectionCursor();
        installWindowClickBlocker();

        var listenerOptions = {capture: true, passive: false};

        function bind(type: string, handler: EventListenerOrEventListenerObject) {
            selectionShield.addEventListener(type, handler, listenerOptions);
            state.bindings.push([type, handler]);
        }

        function removeListeners() {
            for (var i = 0; i < state.bindings.length; ++i) {
                var binding = state.bindings[i];
                if (binding[0] === "keydown") {
                    document.removeEventListener(binding[0], binding[1], listenerOptions);
                    continue;
                }
                selectionShield.removeEventListener(binding[0], binding[1], listenerOptions);
            }
            state.bindings = [];
        }

        function finish(payload: SelectionResult) {
            if (!state.active) {
                return;
            }
            state.active = false;
            removeListeners();
            restoreSelectionCursor();
            scheduleWindowClickBlockerRelease();
            setTimeout(function() {
                removeSelectionShield(selectionShield);
            }, 350);
            inspector.selectionState = null;
            resumeSnapshotAutoUpdate("selection");
            resolve(payload);
        }

        function cancelSelection() {
            inspector.pendingSelectionPath = null;
            clearHighlight();
            finish({ cancelled: true, requiredDepth: 0 });
        }

        state.cancel = cancelSelection;

        function selectTarget(target: AnyNode | null) {
            var node = target || state.latestTarget;
            if (!node) {
                cancelSelection();
                return;
            }
            const selectedLocalId = rememberNode(node);
            if (!selectedLocalId) {
                cancelSelection();
                return;
            }
            const selectedBackendNodeId = stableNodeIdentifier(node) || undefined;
            const selectedBackendNodeIdIsStable = typeof selectedBackendNodeId === "number" && selectedBackendNodeId > 0;
            var path = computeNodePath(node);
            highlightSelectionNode(node);
            finish({
                cancelled: false,
                requiredDepth: Array.isArray(path) ? path.length : computeAncestorLocalIds(node).length,
                selectedPath: path || undefined,
                selectedLocalId,
                ancestorLocalIds: computeAncestorLocalIds(node),
                selectedBackendNodeId,
                selectedBackendNodeIdIsStable,
                ancestorBackendNodeIds: computeAncestorBackendNodeIds(node),
                selectedAttributes: selectionAttributesForNode(node),
                selectedPreview: selectionPreviewForNode(node),
                selectedSelectorPath: selectorPathForNode(selectedLocalId) || undefined,
            });
        }

        function resolveEventTarget(event: Event | null) {
            if (!event) {
                return null;
            }
            function elementAtPoint(x: number, y: number) {
                selectionShield.style.pointerEvents = "none";
                try {
                    return document.elementFromPoint(x, y);
                } finally {
                    selectionShield.style.pointerEvents = "auto";
                }
            }
            if ("touches" in event && (event as TouchEvent).touches && (event as TouchEvent).touches.length) {
                var touch = (event as TouchEvent).touches[(event as TouchEvent).touches.length - 1];
                var candidate = elementAtPoint(touch.clientX, touch.clientY);
                return normalizedSelectionTarget((candidate as AnyNode | null) || (event.target as AnyNode | null) || null);
            }
            if ("changedTouches" in event && (event as TouchEvent).changedTouches && (event as TouchEvent).changedTouches.length) {
                var changed = (event as TouchEvent).changedTouches[(event as TouchEvent).changedTouches.length - 1];
                var fallback = elementAtPoint(changed.clientX, changed.clientY);
                return normalizedSelectionTarget((fallback as AnyNode | null) || (event.target as AnyNode | null) || null);
            }
            if ("clientX" in event && "clientY" in event) {
                const pointerEvent = event as MouseEvent | PointerEvent;
                if (typeof pointerEvent.clientX === "number" && typeof pointerEvent.clientY === "number") {
                    var pointTarget = elementAtPoint(pointerEvent.clientX, pointerEvent.clientY);
                    return normalizedSelectionTarget((pointTarget as AnyNode | null) || (event.target as AnyNode | null) || null);
                }
            }
            return normalizedSelectionTarget((event.target as AnyNode | null) || null);
        }

        function updateLatestTarget(event: Event) {
            var target = resolveEventTarget(event);
            if (!target) {
                return;
            }
            state.latestTarget = target;
            highlightSelectionNode(target);
        }

        function handlePointerLikeMove(event: Event) {
            interceptEvent(event);
            updateLatestTarget(event);
        }

        function handlePointerLikeDown(event: Event) {
            interceptEvent(event);
            updateLatestTarget(event);
        }

        function handlePointerLikeUp(event: Event) {
            interceptEvent(event);
            selectTarget(resolveEventTarget(event));
        }

        function handleTouchCancel(event: Event) {
            interceptEvent(event);
            cancelSelection();
        }

        function handleKeyDown(event: Event) {
            if ((event as KeyboardEvent).key === "Escape") {
                interceptEvent(event);
                cancelSelection();
            }
        }

        function preventDefaultHandler(event: Event) {
            interceptEvent(event);
        }

        var moveEvents = ["pointermove", "mousemove", "touchmove"];
        var downEvents = ["pointerdown", "mousedown", "touchstart"];
        var upEvents = ["pointerup", "mouseup", "touchend"];
        var blockOnlyEvents = ["click", "contextmenu", "submit", "dragstart"];

        moveEvents.forEach(function(type) { bind(type, handlePointerLikeMove); });
        downEvents.forEach(function(type) { bind(type, handlePointerLikeDown); });
        upEvents.forEach(function(type) { bind(type, handlePointerLikeUp); });
        bind("touchcancel", handleTouchCancel);
        blockOnlyEvents.forEach(function(type) { bind(type, preventDefaultHandler); });
        document.addEventListener("keydown", handleKeyDown, listenerOptions);
        state.bindings.push(["keydown", handleKeyDown]);
    });
}

export function cancelElementSelection() {
    if (inspector.selectionState && inspector.selectionState.cancel) {
        inspector.selectionState.cancel();
        inspector.selectionState = null;
        return true;
    }
    inspector.pendingSelectionPath = null;
    restoreSelectionCursor();
    uninstallWindowClickBlocker();
    removeSelectionShield(
        document.querySelector(`[${INSPECTOR_INTERNAL_SELECTION_SHIELD_ATTRIBUTE}]`) as HTMLDivElement | null
    );
    return false;
}

export function setPendingSelectionPath(path: unknown) {
    if (!Array.isArray(path)) {
        inspector.pendingSelectionPath = null;
        return false;
    }
    const normalizedPath = path.filter(function(entry): entry is number {
        return typeof entry === "number" && Number.isFinite(entry) && entry >= 0;
    });
    inspector.pendingSelectionPath = normalizedPath.length ? normalizedPath : null;
    return normalizedPath.length > 0;
}
