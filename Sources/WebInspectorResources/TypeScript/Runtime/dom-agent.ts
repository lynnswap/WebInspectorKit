import { clearHighlight } from "./DOMAgent/dom-agent-overlay";
import { cancelElementSelection, consumePendingSelectionPath, startElementSelection } from "./DOMAgent/dom-agent-selection";

function detachInspector() {
    cancelElementSelection();
    clearHighlight();
}

if (!(window.webInspectorDOMSelection && window.webInspectorDOMSelection.__installed)) {
    var webInspectorDOMSelection = {
        startSelection: startElementSelection,
        cancelSelection: cancelElementSelection,
        consumePendingSelectionPath: consumePendingSelectionPath,
        clearHighlight: clearHighlight,
        detach: detachInspector,
        __installed: true
    };

    Object.defineProperty(window, "webInspectorDOMSelection", {
        value: Object.freeze(webInspectorDOMSelection),
        writable: false,
        configurable: false
    });
}
