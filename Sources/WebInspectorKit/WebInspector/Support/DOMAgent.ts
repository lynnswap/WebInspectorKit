import {captureDOM, captureDOMSubtree} from "./DOMAgent/DOMAgentDOMCore";
import {clearHighlight, highlightDOMNode} from "./DOMAgent/DOMAgentOverlay";
import {cancelElementSelection, startElementSelection} from "./DOMAgent/DOMAgentSelection";
import {
    configureAutoSnapshot,
    disableAutoSnapshot,
    enableAutoSnapshotIfSupported,
    triggerSnapshotUpdate
} from "./DOMAgent/DOMAgentSnapshot";
import {
    debugStatus,
    outerHTMLForNode,
    removeAttributeForNode,
    removeNode,
    selectorPathForNode,
    setAttributeForNode,
    xpathForNode
} from "./DOMAgent/DOMAgentDOMUtils";
function detachInspector() {
    cancelElementSelection();
    clearHighlight();
    disableAutoSnapshot();
}

if (!(window.webInspectorDOM && window.webInspectorDOM.__installed)) {
    var webInspectorDOM = {
        captureSnapshot: captureDOM,
        captureSubtree: captureDOMSubtree,
        startSelection: startElementSelection,
        cancelSelection: cancelElementSelection,
        highlightNode: highlightDOMNode,
        clearHighlight: clearHighlight,
        configureAutoSnapshot: configureAutoSnapshot,
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
    Object.defineProperty(window, "webInspectorDOM", {
        value: Object.freeze(webInspectorDOM),
        writable: false,
        configurable: false
    });

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", enableAutoSnapshotIfSupported, {once: true});
    } else {
        enableAutoSnapshotIfSupported();
    }
}
