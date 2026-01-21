import {inspector} from "./DOMAgentState.js";
import {nodeIsRendered, rectForNode} from "./DOMAgentDOMCore.js";

function ensureOverlay() {
    var overlay = inspector.overlay;
    if (overlay && overlay.parentNode) {
        return overlay;
    }
    overlay = document.createElement("div");
    overlay.style.position = "fixed";
    overlay.style.background = "rgba(0, 122, 255, 0.25)";
    overlay.style.border = "2px solid rgba(0, 122, 255, 0.9)";
    overlay.style.zIndex = 2147483647;
    overlay.style.pointerEvents = "none";
    overlay.style.boxSizing = "border-box";
    overlay.style.display = "none";
    document.documentElement.appendChild(overlay);
    inspector.overlay = overlay;
    return overlay;
}

function hideOverlay() {
    var overlay = inspector.overlay;
    if (overlay) {
        overlay.style.display = "none";
    }
}

function installOverlayAutoUpdateHandlers() {
    if (inspector.overlayAutoUpdateConfigured) {
        return;
    }
    inspector.overlayAutoUpdateConfigured = true;

    function handleViewportChange() {
        scheduleOverlayUpdate();
    }

    window.addEventListener("scroll", handleViewportChange, true);
    document.addEventListener("scroll", handleViewportChange, true);
    window.addEventListener("resize", handleViewportChange);
    if (window.visualViewport) {
        window.visualViewport.addEventListener("scroll", handleViewportChange);
        window.visualViewport.addEventListener("resize", handleViewportChange);
    }
}

function connectOverlayMutationObserver() {
    if (inspector.overlayMutationObserverActive) {
        return;
    }
    if (typeof MutationObserver === "undefined") {
        return;
    }
    if (!inspector.overlayMutationObserver) {
        inspector.overlayMutationObserver = new MutationObserver(function() {
            scheduleOverlayUpdate();
        });
    }
    var target = document.documentElement || document.body;
    if (!target) {
        return;
    }
    inspector.overlayMutationObserver.observe(target, {attributes: true, childList: true, subtree: true, characterData: true});
    inspector.overlayMutationObserverActive = true;
}

function disconnectOverlayMutationObserver() {
    if (!inspector.overlayMutationObserverActive || !inspector.overlayMutationObserver) {
        return;
    }
    inspector.overlayMutationObserver.disconnect();
    inspector.overlayMutationObserverActive = false;
}

function updateOverlayForCurrentTarget() {
    var target = inspector.overlayTarget;
    if (!target) {
        hideOverlay();
        return;
    }
    if (!document.contains(target)) {
        inspector.overlayTarget = null;
        hideOverlay();
        disconnectOverlayMutationObserver();
        return;
    }
    var overlay = ensureOverlay();
    var rect = rectForNode(target);
    if (!rect) {
        hideOverlay();
        return;
    }
    overlay.style.display = "block";
    overlay.style.left = rect.left + "px";
    overlay.style.top = rect.top + "px";
    overlay.style.width = rect.width + "px";
    overlay.style.height = rect.height + "px";
}

function scheduleOverlayUpdate() {
    if (!inspector.overlayTarget) {
        return;
    }
    if (inspector.pendingOverlayUpdate) {
        return;
    }
    inspector.pendingOverlayUpdate = true;
    requestAnimationFrame(function() {
        inspector.pendingOverlayUpdate = false;
        updateOverlayForCurrentTarget();
    });
}

export function setOverlayTarget(node) {
    if (inspector.overlayTarget === node) {
        scheduleOverlayUpdate();
        return;
    }
    inspector.overlayTarget = node || null;
    inspector.pendingOverlayUpdate = false;
    if (inspector.overlayTarget) {
        installOverlayAutoUpdateHandlers();
        connectOverlayMutationObserver();
        updateOverlayForCurrentTarget();
    } else {
        disconnectOverlayMutationObserver();
        hideOverlay();
    }
}

function viewportMetrics() {
    var vv = window.visualViewport;
    var top = vv ? vv.pageTop : (window.scrollY || 0);
    var left = vv ? vv.pageLeft : (window.scrollX || 0);
    var width = vv ? vv.width : (window.innerWidth || document.documentElement.clientWidth || 0);
    var height = vv ? vv.height : (window.innerHeight || document.documentElement.clientHeight || 0);
    return {top: top, left: left, width: width, height: height};
}

function scrollRectIntoViewIfNeeded(rect) {
    if (!rect) {
        return false;
    }
    var margin = 8;
    var viewport = viewportMetrics();
    var rectTop = rect.top + viewport.top;
    var rectLeft = rect.left + viewport.left;
    var rectBottom = rectTop + rect.height;
    var rectRight = rectLeft + rect.width;
    var visibleTop = viewport.top + margin;
    var visibleLeft = viewport.left + margin;
    var visibleBottom = viewport.top + viewport.height - margin;
    var visibleRight = viewport.left + viewport.width - margin;
    var verticallyVisible = rectBottom > visibleTop && rectTop < visibleBottom;
    var horizontallyVisible = rectRight > visibleLeft && rectLeft < visibleRight;
    if (verticallyVisible && horizontallyVisible) {
        return false;
    }

    var targetTop = rectTop - viewport.height / 3;
    var targetLeft = rectLeft - viewport.width / 5;
    var maxTop = Math.max(0, (document.documentElement ? document.documentElement.scrollHeight : 0) - viewport.height);
    var maxLeft = Math.max(0, (document.documentElement ? document.documentElement.scrollWidth : 0) - viewport.width);
    if (isFinite(maxTop)) {
        targetTop = Math.min(Math.max(0, targetTop), maxTop);
    }
    if (isFinite(maxLeft)) {
        targetLeft = Math.min(Math.max(0, targetLeft), maxLeft);
    }
    window.scrollTo({top: targetTop, left: targetLeft, behavior: "auto"});
    return true;
}

export function highlightDOMNode(identifier) {
    var map = inspector.map;
    if (!map || !map.size) {
        return false;
    }
    var node = map.get(identifier);
    if (!node) {
        return false;
    }
    if (!nodeIsRendered(node)) {
        clearHighlight();
        return true;
    }
    setOverlayTarget(node);
    var rect = rectForNode(node);
    if (rect) {
        scrollRectIntoViewIfNeeded(rect);
    }
    return true;
}

export function clearHighlight() {
    setOverlayTarget(null);
}

export function highlightSelectionNode(node) {
    setOverlayTarget(node || null);
}
