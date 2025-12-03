import {captureDOM, captureDOMSubtree} from "./InspectorAgent/InspectorAgentDOMCore.js";
import {clearHighlight, highlightDOMNode} from "./InspectorAgent/InspectorAgentOverlay.js";
import {cancelElementSelection, startElementSelection} from "./InspectorAgent/InspectorAgentSelection.js";
import {
    disableAutoSnapshot,
    enableAutoSnapshot,
    enableAutoSnapshotIfSupported,
    setAutoSnapshotOptions,
    triggerSnapshotUpdate
} from "./InspectorAgent/InspectorAgentSnapshot.js";
import {
    debugStatus,
    outerHTMLForNode,
    removeAttributeForNode,
    removeNode,
    selectorPathForNode,
    setAttributeForNode,
    xpathForNode
} from "./InspectorAgent/InspectorAgentDOMUtils.js";
function detachInspector() {
    cancelElementSelection();
    clearHighlight();
    disableAutoSnapshot();
}

if (!(window.webInspectorKit && window.webInspectorKit.__installed)) {
    var webInspectorKit = {
        captureDOM: captureDOM,
        captureDOMSubtree: captureDOMSubtree,
        startElementSelection: startElementSelection,
        cancelElementSelection: cancelElementSelection,
        highlightDOMNode: highlightDOMNode,
        clearHighlight: clearHighlight,
        setAutoSnapshotOptions: setAutoSnapshotOptions,
        setAutoSnapshotEnabled: enableAutoSnapshot,
        disableAutoSnapshot: disableAutoSnapshot,
        detach: detachInspector,
        triggerSnapshotUpdate: triggerSnapshotUpdate,
        outerHTMLForNode: outerHTMLForNode,
        selectorPathForNode: selectorPathForNode,
        xpathForNode: xpathForNode,
        removeNode: removeNode,
        setAttributeForNode: setAttributeForNode,
        removeAttributeForNode: removeAttributeForNode,
        debugStatus: debugStatus,
        __installed: true
    };
    Object.defineProperty(window, "webInspectorKit", {
        value: Object.freeze(webInspectorKit),
        writable: false,
        configurable: false
    });

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", enableAutoSnapshotIfSupported, {once: true});
    } else {
        enableAutoSnapshotIfSupported();
    }
}
