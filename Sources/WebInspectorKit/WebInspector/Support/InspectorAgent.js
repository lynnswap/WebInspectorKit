import {captureDOM, captureDOMSubtree} from "./InspectorAgent/dom-core.js";
import {clearHighlight, highlightDOMNode} from "./InspectorAgent/overlay.js";
import {cancelElementSelection, startElementSelection} from "./InspectorAgent/selection.js";
import {
    disableAutoSnapshot,
    enableAutoSnapshot,
    enableAutoSnapshotIfSupported,
    setAutoSnapshotOptions,
    triggerSnapshotUpdate
} from "./InspectorAgent/snapshot.js";
import {
    debugStatus,
    outerHTMLForNode,
    removeAttributeForNode,
    removeNode,
    selectorPathForNode,
    setAttributeForNode,
    xpathForNode
} from "./InspectorAgent/dom-utils.js";

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
