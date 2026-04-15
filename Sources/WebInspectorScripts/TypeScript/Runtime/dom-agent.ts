import {
    captureDOM,
    captureDOMEnvelope,
    captureDOMSubtree,
    captureDOMSubtreeEnvelope,
    consumePendingInitialSnapshotMode,
    createNodeHandle
} from "./DOMAgent/dom-agent-dom-core";
import {clearHighlight, highlightDOMNode, highlightDOMNodeHandle} from "./DOMAgent/dom-agent-overlay";
import {cancelElementSelection, startElementSelection} from "./DOMAgent/dom-agent-selection";
import {setPendingSelectionRestoreTarget} from "./DOMAgent/dom-agent-selection";
import {
    configureAutoSnapshot,
    disableAutoSnapshot,
    enableAutoSnapshotIfSupported,
    triggerSnapshotUpdate
} from "./DOMAgent/dom-agent-snapshot";
import {
    applyDOMAgentBootstrapContext,
    inspector,
    readDOMAgentBootstrap,
    type DOMAgentAutoSnapshotBootstrap,
    type DOMAgentBootstrapState
} from "./DOMAgent/dom-agent-state";
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
function detachInspector() {
    cancelElementSelection();
    clearHighlight();
    disableAutoSnapshot();
}

function setPageEpoch(epoch: number): boolean {
    if (typeof epoch !== "number" || !Number.isFinite(epoch)) {
        return false;
    }
    if (epoch !== inspector.pageEpoch) {
        inspector.nextInitialSnapshotMode = "fresh";
    }
    inspector.pageEpoch = epoch;
    return true;
}

function setDocumentScopeID(documentScopeID: number): boolean {
    if (typeof documentScopeID !== "number" || !Number.isFinite(documentScopeID)) {
        return false;
    }
    if (documentScopeID !== inspector.documentScopeID) {
        inspector.nextInitialSnapshotMode = "fresh";
    }
    inspector.documentScopeID = documentScopeID;
    return true;
}

function applyAutoSnapshotBootstrap(
    options: DOMAgentAutoSnapshotBootstrap | null | undefined,
    useFallback: boolean
): void {
    const configure = function() {
        if (options && typeof options === "object") {
            configureAutoSnapshot(options);
            return;
        }
        if (useFallback) {
            enableAutoSnapshotIfSupported();
        }
    };

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", configure, {once: true});
        return;
    }

    configure();
}

function bootstrapDOMAgent(bootstrap?: DOMAgentBootstrapState | null): boolean {
    const previousPageEpoch = inspector.pageEpoch;
    const previousDocumentScopeID = inspector.documentScopeID;
    const nextBootstrap = bootstrap && typeof bootstrap === "object" ? bootstrap : readDOMAgentBootstrap();
    const didApplyContext = applyDOMAgentBootstrapContext(nextBootstrap);
    const hasAutoSnapshotBootstrap = Boolean(nextBootstrap.autoSnapshot && typeof nextBootstrap.autoSnapshot === "object");
    if (didApplyContext && (inspector.pageEpoch !== previousPageEpoch || inspector.documentScopeID !== previousDocumentScopeID)) {
        inspector.nextInitialSnapshotMode = "fresh";
    }
    applyAutoSnapshotBootstrap(nextBootstrap.autoSnapshot, !hasAutoSnapshotBootstrap);
    return didApplyContext || hasAutoSnapshotBootstrap;
}

function scheduleInitialSnapshotIfNeededForCurrentDocument() {
    const currentURL = document.URL || "";
    const normalizedCurrentURL = normalizeNavigationURL(currentURL);
    const normalizedDocumentURL = normalizeNavigationURL(inspector.documentURL || "");
    const documentURLChanged = !!inspector.documentURL && normalizedDocumentURL !== normalizedCurrentURL;
    const missingDOMMap = !(inspector.map && inspector.map.size);
    if (documentURLChanged) {
        inspector.nextInitialSnapshotMode = "fresh";
    } else if (missingDOMMap && !inspector.nextInitialSnapshotMode) {
        inspector.nextInitialSnapshotMode = "preserve-ui-state";
    }
    if (!inspector.snapshotAutoUpdateEnabled) {
        return;
    }
    if (!inspector.nextInitialSnapshotMode && !documentURLChanged && !missingDOMMap) {
        return;
    }
    triggerSnapshotUpdate("initial");
}

function normalizeNavigationURL(value: string): string {
    if (!value) {
        return "";
    }
    try {
        const url = new URL(value, document.baseURI);
        url.hash = "";
        return url.toString();
    } catch {
        const hashIndex = value.indexOf("#");
        return hashIndex >= 0 ? value.slice(0, hashIndex) : value;
    }
}

if (!(window.webInspectorDOM && window.webInspectorDOM.__installed)) {
    var webInspectorDOM = {
        captureSnapshot: captureDOM,
        captureSnapshotEnvelope: captureDOMEnvelope,
        consumePendingInitialSnapshotMode: consumePendingInitialSnapshotMode,
        captureSubtree: captureDOMSubtree,
        captureSubtreeEnvelope: captureDOMSubtreeEnvelope,
        startSelection: startElementSelection,
        cancelSelection: cancelElementSelection,
        setPendingSelectionRestoreTarget: setPendingSelectionRestoreTarget,
        highlightNode: highlightDOMNode,
        highlightNodeHandle: highlightDOMNodeHandle,
        clearHighlight: clearHighlight,
        configureAutoSnapshot: configureAutoSnapshot,
        disableAutoSnapshot: disableAutoSnapshot,
        setPageEpoch: setPageEpoch,
        setDocumentScopeID: setDocumentScopeID,
        bootstrap: bootstrapDOMAgent,
        detach: detachInspector,
        triggerSnapshotUpdate: triggerSnapshotUpdate,
        outerHTMLForNode: outerHTMLForNode,
        selectorPathForNode: selectorPathForNode,
        xpathForNode: xpathForNode,
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
    bootstrapDOMAgent();
    window.addEventListener("pageshow", function() {
        scheduleInitialSnapshotIfNeededForCurrentDocument();
    });
}
