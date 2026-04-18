import {
    captureDOM,
    captureDOMEnvelope,
    captureDOMSubtree,
    captureDOMSubtreeEnvelope,
    createNodeHandle
} from "./DOMAgent/dom-agent-dom-core";
import {clearHighlight, highlightDOMNode} from "./DOMAgent/dom-agent-overlay";
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
    removeAttributeForNode,
    removeNode,
    removeNodeWithUndo,
    selectorPathForNode,
    setAttributeForNode,
    undoRemoveNode,
    xpathForNode
} from "./DOMAgent/dom-agent-dom-utils";

function detachInspector() {
    clearHighlight();
    disableAutoSnapshot();
}

function setContextID(contextID: number): boolean {
    if (typeof contextID !== "number" || !Number.isFinite(contextID)) {
        return false;
    }
    if (contextID !== inspector.contextID) {
        inspector.nextInitialSnapshotMode = "fresh";
    }
    inspector.contextID = contextID;
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
    const previousContextID = inspector.contextID;
    const nextBootstrap = bootstrap && typeof bootstrap === "object" ? bootstrap : readDOMAgentBootstrap();
    const didApplyContext = applyDOMAgentBootstrapContext(nextBootstrap);
    const hasAutoSnapshotBootstrap = Boolean(nextBootstrap.autoSnapshot && typeof nextBootstrap.autoSnapshot === "object");
    if (didApplyContext && inspector.contextID !== previousContextID) {
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
    if (documentURLChanged || missingDOMMap) {
        inspector.nextInitialSnapshotMode = "fresh";
    }
    if (!inspector.snapshotAutoUpdateEnabled || !inspector.nextInitialSnapshotMode) {
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
    const webInspectorDOM = {
        captureSnapshot: captureDOM,
        captureSnapshotEnvelope: captureDOMEnvelope,
        captureSubtree: captureDOMSubtree,
        captureSubtreeEnvelope: captureDOMSubtreeEnvelope,
        highlightNode: highlightDOMNode,
        clearHighlight: clearHighlight,
        configureAutoSnapshot: configureAutoSnapshot,
        disableAutoSnapshot: disableAutoSnapshot,
        setContextID: setContextID,
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
