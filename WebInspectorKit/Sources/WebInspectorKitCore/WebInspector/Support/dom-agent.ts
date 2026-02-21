import {
    captureDOM,
    captureDOMEnvelope,
    captureDOMSubtree,
    captureDOMSubtreeEnvelope,
    createNodeHandle
} from "./DOMAgent/dom-agent-dom-core";
import {clearHighlight, highlightDOMNode, highlightDOMNodeHandle} from "./DOMAgent/dom-agent-overlay";
import {cancelElementSelection, startElementSelection} from "./DOMAgent/dom-agent-selection";
import {
    configureAutoSnapshot,
    disableAutoSnapshot,
    enableAutoSnapshotIfSupported,
    triggerSnapshotUpdate
} from "./DOMAgent/dom-agent-snapshot";
import {
    debugStatus,
    outerHTMLForNode,
    removeAttributeForHandle,
    removeAttributeForNode,
    removeNodeHandle,
    removeNode,
    selectorPathForNode,
    setAttributeForHandle,
    setAttributeForNode,
    xpathForNode
} from "./DOMAgent/dom-agent-dom-utils";
import {matchedStylesForNode} from "./DOMAgent/dom-agent-styles";
function detachInspector() {
    cancelElementSelection();
    clearHighlight();
    disableAutoSnapshot();
}

if (!(window.webInspectorDOM && window.webInspectorDOM.__installed)) {
    var webInspectorDOM = {
        captureSnapshot: captureDOM,
        captureSnapshotEnvelope: captureDOMEnvelope,
        captureSubtree: captureDOMSubtree,
        captureSubtreeEnvelope: captureDOMSubtreeEnvelope,
        startSelection: startElementSelection,
        cancelSelection: cancelElementSelection,
        highlightNode: highlightDOMNode,
        highlightNodeHandle: highlightDOMNodeHandle,
        clearHighlight: clearHighlight,
        configureAutoSnapshot: configureAutoSnapshot,
        disableAutoSnapshot: disableAutoSnapshot,
        detach: detachInspector,
        triggerSnapshotUpdate: triggerSnapshotUpdate,
        outerHTMLForNode: outerHTMLForNode,
        selectorPathForNode: selectorPathForNode,
        xpathForNode: xpathForNode,
        matchedStylesForNode: matchedStylesForNode,
        createNodeHandle: createNodeHandle,
        removeNode: removeNode,
        removeNodeHandle: removeNodeHandle,
        setAttributeForNode: setAttributeForNode,
        setAttributeForHandle: setAttributeForHandle,
        removeAttributeForNode: removeAttributeForNode,
        removeAttributeForHandle: removeAttributeForHandle,
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
