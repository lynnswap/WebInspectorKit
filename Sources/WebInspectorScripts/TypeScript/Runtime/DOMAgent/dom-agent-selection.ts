import {inspector, type AnyNode, type SelectionState} from "./dom-agent-state";
import {computeNodePath} from "./dom-agent-dom-core";
import {clearHighlight, highlightSelectionNode} from "./dom-agent-overlay";
import {resumeSnapshotAutoUpdate, suppressSnapshotAutoUpdate} from "./dom-agent-snapshot";

type SelectionResult = {
    cancelled: boolean;
    requiredDepth: number;
};

type PointerLikeEvent = MouseEvent | PointerEvent | TouchEvent;

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

export function startElementSelection() {
    cancelElementSelection();
    return new Promise<SelectionResult>(function(resolve) {
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
            document.addEventListener(type, handler, listenerOptions);
            state.bindings.push([type, handler]);
        }

        function removeListeners() {
            for (var i = 0; i < state.bindings.length; ++i) {
                var binding = state.bindings[i];
                document.removeEventListener(binding[0], binding[1], listenerOptions);
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
            var path = computeNodePath(node);
            if (!path) {
                cancelSelection();
                return;
            }
            inspector.pendingSelectionPath = path;
            highlightSelectionNode(node);
            finish({ cancelled: false, requiredDepth: path.length });
        }

        function resolveEventTarget(event: Event | null) {
            if (!event) {
                return null;
            }
            if ("touches" in event && (event as TouchEvent).touches && (event as TouchEvent).touches.length) {
                var touch = (event as TouchEvent).touches[(event as TouchEvent).touches.length - 1];
                var candidate = document.elementFromPoint(touch.clientX, touch.clientY);
                return (candidate as AnyNode | null) || (event.target as AnyNode | null) || null;
            }
            if ("changedTouches" in event && (event as TouchEvent).changedTouches && (event as TouchEvent).changedTouches.length) {
                var changed = (event as TouchEvent).changedTouches[(event as TouchEvent).changedTouches.length - 1];
                var fallback = document.elementFromPoint(changed.clientX, changed.clientY);
                return (fallback as AnyNode | null) || (event.target as AnyNode | null) || null;
            }
            if ("clientX" in event && "clientY" in event) {
                const pointerEvent = event as MouseEvent | PointerEvent;
                if (typeof pointerEvent.clientX === "number" && typeof pointerEvent.clientY === "number") {
                    var pointTarget = document.elementFromPoint(pointerEvent.clientX, pointerEvent.clientY);
                    return (pointTarget as AnyNode | null) || (event.target as AnyNode | null) || null;
                }
            }
            return (event.target as AnyNode | null) || null;
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
        bind("keydown", handleKeyDown);
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
    return false;
}
