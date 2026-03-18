import {inspector, type AnyNode} from "./dom-agent-state";
import {clearHighlight} from "./dom-agent-overlay";
import {resumeSnapshotAutoUpdate, suppressSnapshotAutoUpdate, triggerSnapshotUpdate} from "./dom-agent-snapshot";

type RemovedNodeUndoEntry = {
    token: number;
    node: AnyNode;
    parent: AnyNode;
    nextSibling: AnyNode | null;
    removed: boolean;
};

var removeUndoTokenSequence = 0;
var removedNodeUndoEntries = new Map<number, RemovedNodeUndoEntry>();
var removedNodeUndoOrder: number[] = [];
var maxRemovedNodeUndoEntries = 128;

function resolveNode(identifier: number) {
    var map = inspector.map;
    if (!map || !map.size) {
        return null;
    }
    return map.get(identifier) || null;
}

function resolveHandleNode(handle: unknown): AnyNode | null {
    if (!handle || typeof handle !== "object") {
        return null;
    }
    return handle as AnyNode;
}

function classNames(element: Element | null) {
    if (!element || !element.classList) {
        return [];
    }
    var names: string[] = [];
    element.classList.forEach(function(name) {
        if (name) {
            names.push(name);
        }
    });
    return names;
}

function escapedClassSelector(element: Element | null) {
    var names = classNames(element);
    if (!names.length) {
        return "";
    }
    return "." + names.map(function(name) {
        if (typeof CSS !== "undefined" && typeof CSS.escape === "function") {
            return CSS.escape(name);
        }
        return name.replace(/([\\.\\[\\]\\+\\*\\~\\>\\:\\(\\)\\$\\^\\=\\|\\{\\}])/g, "\\$1");
    }).join(".");
}

function cssPathComponent(node: AnyNode | null) {
    if (!node || node.nodeType !== Node.ELEMENT_NODE) {
        return null;
    }

    var element = node as Element;
    var nodeName = element.tagName ? element.tagName.toLowerCase() : (element.nodeName || "").toLowerCase();

    var parent = element.parentElement;
    if (!parent || parent.nodeType === Node.DOCUMENT_NODE) {
        return {value: nodeName, done: true};
    }

    var lowerNodeName = nodeName;
    if (lowerNodeName === "body" || lowerNodeName === "head" || lowerNodeName === "html") {
        return {value: nodeName, done: true};
    }

    if (element.id) {
        var escapedId = typeof CSS !== "undefined" && typeof CSS.escape === "function"
            ? CSS.escape(element.id)
            : element.id.replace(/([\\.\\[\\]\\+\\*\\~\\>\\:\\(\\)\\$\\^\\=\\|\\{\\}\\#])/g, "\\$1");
        return {value: "#" + escapedId, done: true};
    }

    var nthChildIndex = -1;
    var uniqueClasses = new Set(classNames(element));
    var hasUniqueTagName = true;
    var elementIndex = 0;

    var children = parent.children || [];
    for (var i = 0; i < children.length; ++i) {
        var sibling = children[i];
        if (!sibling || sibling.nodeType !== Node.ELEMENT_NODE) {
            continue;
        }

        elementIndex++;
        if (sibling === element) {
            nthChildIndex = elementIndex;
            continue;
        }

        if (sibling.tagName && sibling.tagName.toLowerCase() === nodeName) {
            hasUniqueTagName = false;
        }

        if (uniqueClasses.size) {
            var siblingClassNames = classNames(sibling);
            siblingClassNames.forEach(function(name) { uniqueClasses.delete(name); });
        }
    }

    var selector = nodeName;
    if (nodeName === "input" && element.getAttribute && element.getAttribute("type") && !uniqueClasses.size) {
        selector += '[type="' + element.getAttribute("type") + '"]';
    }
    if (!hasUniqueTagName) {
        if (uniqueClasses.size) {
            selector += escapedClassSelector(element);
        } else if (nthChildIndex > 0) {
            selector += ":nth-child(" + nthChildIndex + ")";
        }
    }

    return {value: selector, done: false};
}

function cssPath(node: AnyNode | null) {
    if (!node || node.nodeType !== Node.ELEMENT_NODE) {
        return "";
    }

    var components = [];
    var current: AnyNode | null = node;
    while (current) {
        var component = cssPathComponent(current);
        if (!component) {
            break;
        }
        components.push(component);
        if (component.done) {
            break;
        }
        current = current.parentElement;
    }

    components.reverse();
    return components.map(function(entry) { return entry.value; }).join(" > ");
}

function xpathIndex(node: AnyNode) {
    if (!node || !node.parentNode) {
        return 0;
    }

    var siblings = node.parentNode.childNodes || [];
    if (siblings.length <= 1) {
        return 0;
    }

    function isSimilarNode(a: AnyNode, b: AnyNode) {
        if (a === b) {
            return true;
        }

        var aType = a && a.nodeType;
        var bType = b && b.nodeType;

        if (aType === Node.ELEMENT_NODE && bType === Node.ELEMENT_NODE) {
            return a.localName === b.localName;
        }

        if (aType === Node.CDATA_SECTION_NODE) {
            return bType === Node.TEXT_NODE;
        }
        if (bType === Node.CDATA_SECTION_NODE) {
            return aType === Node.TEXT_NODE;
        }

        return aType === bType;
    }

    var unique = true;
    var foundIndex = -1;
    var counter = 1;
    for (var i = 0; i < siblings.length; ++i) {
        var sibling = siblings[i];
        if (!isSimilarNode(node, sibling)) {
            continue;
        }

        if (node === sibling) {
            foundIndex = counter;
            if (!unique) {
                return foundIndex;
            }
        } else {
            unique = false;
            if (foundIndex !== -1) {
                return foundIndex;
            }
        }
        counter++;
    }

    if (unique) {
        return 0;
    }
    return foundIndex > 0 ? foundIndex : 0;
}

function xpathComponent(node: AnyNode) {
    if (!node) {
        return null;
    }

    var index = xpathIndex(node);
    if (index === -1) {
        return null;
    }

    var value;
    switch (node.nodeType) {
    case Node.DOCUMENT_NODE:
        return {value: "", done: true};
    case Node.ELEMENT_NODE:
        if (node.id) {
            return {value: '//*[@id="' + node.id + '"]', done: true};
        }
        value = node.localName || (node.tagName ? node.tagName.toLowerCase() : "");
        break;
    case Node.ATTRIBUTE_NODE:
        value = "@" + node.nodeName;
        break;
    case Node.TEXT_NODE:
    case Node.CDATA_SECTION_NODE:
        value = "text()";
        break;
    case Node.COMMENT_NODE:
        value = "comment()";
        break;
    case Node.PROCESSING_INSTRUCTION_NODE:
        value = "processing-instruction()";
        break;
    default:
        value = "";
        break;
    }

    if (index > 0) {
        value += "[" + index + "]";
    }

    return {value: value, done: false};
}

function xpath(node: AnyNode | null) {
    if (!node) {
        return "";
    }

    if (node.nodeType === Node.DOCUMENT_NODE) {
        return "/";
    }

    var components = [];
    var current: AnyNode | null = node;
    while (current) {
        var component = xpathComponent(current);
        if (!component) {
            break;
        }
        components.push(component);
        if (component.done) {
            break;
        }
        current = current.parentNode as AnyNode | null;
    }

    components.reverse();
    var prefix = components.length && components[0].done ? "" : "/";
    return prefix + components.map(function(entry) { return entry.value; }).join("/");
}

function serializedDoctype(doctype: DocumentType | null) {
    if (!doctype) {
        return "";
    }
    var publicId = doctype.publicId ? ' PUBLIC "' + doctype.publicId + '"' : "";
    var systemId = doctype.systemId ? (publicId ? ' "' + doctype.systemId + '"' : ' SYSTEM "' + doctype.systemId + '"') : "";
    return "<!DOCTYPE " + (doctype.name || "html") + publicId + systemId + ">";
}

export function outerHTMLForNode(identifier: number) {
    var node = resolveNode(identifier);
    if (!node) {
        return "";
    }

    switch (node.nodeType) {
    case Node.ELEMENT_NODE:
        return node.outerHTML || "";
    case Node.TEXT_NODE:
    case Node.CDATA_SECTION_NODE:
        return node.nodeValue || "";
    case Node.COMMENT_NODE:
        return "<!-- " + (node.nodeValue || "") + " -->";
    case Node.DOCUMENT_NODE:
        var docType = serializedDoctype(node.doctype);
        var root = node.documentElement;
        var html = root && root.outerHTML ? root.outerHTML : "";
        return docType + html;
    case Node.DOCUMENT_TYPE_NODE:
        return serializedDoctype(node as DocumentType);
    default:
        try {
            return (new XMLSerializer()).serializeToString(node);
        } catch {
            return "";
        }
    }
}

export function selectorPathForNode(identifier: number) {
    var node = resolveNode(identifier);
    if (!node) {
        return "";
    }
    return cssPath(node);
}

export function xpathForNode(identifier: number) {
    var node = resolveNode(identifier);
    if (!node) {
        return "";
    }
    return xpath(node);
}

export function removeNode(identifier: number) {
    var node = resolveNode(identifier);
    return removeResolvedNode(node);
}

export function removeNodeHandle(handle: unknown) {
    return removeResolvedNode(resolveHandleNode(handle));
}

export function removeNodeWithUndo(identifier: number) {
    var node = resolveNode(identifier);
    return removeResolvedNodeWithUndo(node);
}

export function removeNodeHandleWithUndo(handle: unknown) {
    return removeResolvedNodeWithUndo(resolveHandleNode(handle));
}

export function undoRemoveNode(token: number | null | undefined) {
    var resolvedToken = normalizeUndoToken(token);
    if (!resolvedToken) {
        return false;
    }
    var entry = removedNodeUndoEntries.get(resolvedToken);
    if (!entry || !entry.removed) {
        return false;
    }

    var parent = entry.parent;
    var node = entry.node;
    if (!parent || !node) {
        return false;
    }

    var restored = false;
    suppressSnapshotAutoUpdate("undo-remove-node");
    try {
        var nextSibling = entry.nextSibling;
        if (nextSibling && nextSibling.parentNode === parent && typeof parent.insertBefore === "function") {
            parent.insertBefore(node, nextSibling);
            restored = true;
        } else if (typeof parent.appendChild === "function") {
            parent.appendChild(node);
            restored = true;
        }
    } catch {
        restored = false;
    } finally {
        resumeSnapshotAutoUpdate("undo-remove-node");
    }

    if (!restored) {
        return false;
    }

    entry.removed = false;
    clearHighlight();
    triggerSnapshotUpdate("undo-remove-node");
    return true;
}

export function redoRemoveNode(token: number | null | undefined) {
    var resolvedToken = normalizeUndoToken(token);
    if (!resolvedToken) {
        return false;
    }
    var entry = removedNodeUndoEntries.get(resolvedToken);
    if (!entry || entry.removed) {
        return false;
    }

    var node = entry.node;
    if (!node || !node.parentNode) {
        return false;
    }

    entry.parent = node.parentNode as AnyNode;
    entry.nextSibling = node.nextSibling as AnyNode | null;

    var removed = performNodeRemoval(node, "redo-remove-node");
    if (removed) {
        entry.removed = true;
    }
    return removed;
}

function removeResolvedNode(node: AnyNode | null) {
    return performNodeRemoval(node, "remove-node");
}

function removeResolvedNodeWithUndo(node: AnyNode | null) {
    if (!node) {
        return 0;
    }
    var parent = node.parentNode;
    if (!parent) {
        return 0;
    }
    var nextSibling = node.nextSibling as AnyNode | null;

    var removed = performNodeRemoval(node, "remove-node");
    if (!removed) {
        return 0;
    }

    var entry: RemovedNodeUndoEntry = {
        token: nextRemoveUndoToken(),
        node: node,
        parent: parent as AnyNode,
        nextSibling: nextSibling,
        removed: true
    };
    rememberRemovedNodeUndoEntry(entry);
    return entry.token;
}

function performNodeRemoval(node: AnyNode | null, reason: string) {
    if (!node) {
        return false;
    }
    var parent = node.parentNode;
    if (!parent) {
        return false;
    }

    var removed = false;
    suppressSnapshotAutoUpdate(reason);
    try {
        if (typeof parent.removeChild === "function") {
            parent.removeChild(node);
            removed = true;
        } else if (typeof node.remove === "function") {
            node.remove();
            removed = true;
        }
    } catch {
    } finally {
        resumeSnapshotAutoUpdate(reason);
    }

    if (removed) {
        clearHighlight();
        triggerSnapshotUpdate(reason);
    }

    return removed;
}

function nextRemoveUndoToken() {
    removeUndoTokenSequence += 1;
    return removeUndoTokenSequence;
}

function rememberRemovedNodeUndoEntry(entry: RemovedNodeUndoEntry) {
    removedNodeUndoEntries.set(entry.token, entry);
    removedNodeUndoOrder.push(entry.token);

    while (removedNodeUndoOrder.length > maxRemovedNodeUndoEntries) {
        var oldestToken = removedNodeUndoOrder.shift();
        if (typeof oldestToken !== "number") {
            continue;
        }
        removedNodeUndoEntries.delete(oldestToken);
    }
}

function normalizeUndoToken(token: number | null | undefined) {
    if (typeof token === "number" && Number.isFinite(token) && token > 0) {
        return Math.floor(token);
    }
    return 0;
}

export function setAttributeForNode(identifier: number, name: string | null | undefined, value: string | null | undefined) {
    var node = resolveNode(identifier);
    return setAttributeForResolvedNode(node, name, value);
}

export function setAttributeForHandle(handle: unknown, name: string | null | undefined, value: string | null | undefined) {
    return setAttributeForResolvedNode(resolveHandleNode(handle), name, value);
}

function setAttributeForResolvedNode(node: AnyNode | null, name: string | null | undefined, value: string | null | undefined) {
    if (!node || node.nodeType !== Node.ELEMENT_NODE) {
        return false;
    }
    var attributeName = String(name || "");
    var attributeValue = String(value || "");

    suppressSnapshotAutoUpdate("set-attribute");
    try {
        node.setAttribute(attributeName, attributeValue);
    } catch {
        resumeSnapshotAutoUpdate("set-attribute");
        return false;
    }
    resumeSnapshotAutoUpdate("set-attribute");
    triggerSnapshotUpdate("set-attribute");
    return true;
}

export function removeAttributeForNode(identifier: number, name: string | null | undefined) {
    var node = resolveNode(identifier);
    return removeAttributeForResolvedNode(node, name);
}

export function removeAttributeForHandle(handle: unknown, name: string | null | undefined) {
    return removeAttributeForResolvedNode(resolveHandleNode(handle), name);
}

function removeAttributeForResolvedNode(node: AnyNode | null, name: string | null | undefined) {
    if (!node || node.nodeType !== Node.ELEMENT_NODE) {
        return false;
    }
    var attributeName = String(name || "");
    suppressSnapshotAutoUpdate("remove-attribute");
    try {
        node.removeAttribute(attributeName);
    } catch {
        resumeSnapshotAutoUpdate("remove-attribute");
        return false;
    }
    resumeSnapshotAutoUpdate("remove-attribute");
    triggerSnapshotUpdate("remove-attribute");
    return true;
}

export function debugStatus() {
    var status = {
        snapshotAutoUpdateEnabled: !!inspector.snapshotAutoUpdateEnabled,
        snapshotAutoUpdatePending: !!inspector.snapshotAutoUpdatePending,
        snapshotAutoUpdateTimer: !!inspector.snapshotAutoUpdateTimer,
        snapshotAutoUpdateDebounce: inspector.snapshotAutoUpdateDebounce,
        snapshotAutoUpdateMaxDepth: inspector.snapshotAutoUpdateMaxDepth,
        pendingMutations: Array.isArray(inspector.pendingMutations) ? inspector.pendingMutations.length : 0,
        overlayActive: !!inspector.overlayTarget,
        selectionActive: !!inspector.selectionState,
        documentURL: inspector.documentURL || document.URL || ""
    };
    console.log("[webInspectorDOM] status:", status);
    return status;
}
