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
import { inspector } from "./DOMAgent/dom-agent-state";
import {
    debugStatus,
    outerHTMLForNode,
    redoRemoveNode,
    removeNodeWithUndo,
    removeAttributeForNode,
    removeNode,
    selectorPathForNode,
    setAttributeForNode,
    undoRemoveNode,
    xpathForNode
} from "./DOMAgent/dom-agent-dom-utils";
import {matchedStylesForNode} from "./DOMAgent/dom-agent-styles";
function detachInspector() {
    cancelElementSelection();
    clearHighlight();
    disableAutoSnapshot();
}

function setPageEpoch(epoch: number): boolean {
    if (typeof epoch !== "number" || !Number.isFinite(epoch)) {
        return false;
    }
    if (epoch < inspector.pageEpoch) {
        return false;
    }
    inspector.pageEpoch = epoch;
    return true;
}

function setDocumentScopeID(documentScopeID: number): boolean {
    if (typeof documentScopeID !== "number" || !Number.isFinite(documentScopeID)) {
        return false;
    }
    if (documentScopeID < inspector.documentScopeID) {
        return false;
    }
    inspector.documentScopeID = documentScopeID;
    return true;
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
        setPageEpoch: setPageEpoch,
        setDocumentScopeID: setDocumentScopeID,
        detach: detachInspector,
        triggerSnapshotUpdate: triggerSnapshotUpdate,
        outerHTMLForNode: outerHTMLForNode,
        selectorPathForNode: selectorPathForNode,
        xpathForNode: xpathForNode,
        matchedStylesForNode: matchedStylesForNode,
        createNodeHandle: createNodeHandle,
        removeNode: removeNode,
        removeNodeWithUndo: removeNodeWithUndo,
        undoRemoveNode: undoRemoveNode,
        redoRemoveNode: redoRemoveNode,
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
