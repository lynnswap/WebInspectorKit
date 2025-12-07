import {inspector} from "./DOMAgentState.js";
import {clearHighlight} from "./DOMAgentOverlay.js";
import {resumeSnapshotAutoUpdate, suppressSnapshotAutoUpdate, triggerSnapshotUpdate} from "./DOMAgentSnapshot.js";

function resolveNode(identifier) {
    var map = inspector.map;
    if (!map || !map.size) {
        return null;
    }
    return map.get(identifier) || null;
}

function classNames(element) {
    if (!element || !element.classList) {
        return [];
    }
    var names = [];
    element.classList.forEach(function(name) {
        if (name) {
            names.push(name);
        }
    });
    return names;
}

function escapedClassSelector(element) {
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

function cssPathComponent(node) {
    if (!node || node.nodeType !== Node.ELEMENT_NODE) {
        return null;
    }

    var nodeName = node.tagName ? node.tagName.toLowerCase() : (node.nodeName || "").toLowerCase();

    var parent = node.parentElement;
    if (!parent || parent.nodeType === Node.DOCUMENT_NODE) {
        return {value: nodeName, done: true};
    }

    var lowerNodeName = nodeName;
    if (lowerNodeName === "body" || lowerNodeName === "head" || lowerNodeName === "html") {
        return {value: nodeName, done: true};
    }

    if (node.id) {
        var escapedId = typeof CSS !== "undefined" && typeof CSS.escape === "function"
            ? CSS.escape(node.id)
            : node.id.replace(/([\\.\\[\\]\\+\\*\\~\\>\\:\\(\\)\\$\\^\\=\\|\\{\\}\\#])/g, "\\$1");
        return {value: "#" + escapedId, done: true};
    }

    var nthChildIndex = -1;
    var uniqueClasses = new Set(classNames(node));
    var hasUniqueTagName = true;
    var elementIndex = 0;

    var children = parent.children || [];
    for (var i = 0; i < children.length; ++i) {
        var sibling = children[i];
        if (!sibling || sibling.nodeType !== Node.ELEMENT_NODE) {
            continue;
        }

        elementIndex++;
        if (sibling === node) {
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
    if (nodeName === "input" && node.getAttribute && node.getAttribute("type") && !uniqueClasses.size) {
        selector += '[type="' + node.getAttribute("type") + '"]';
    }
    if (!hasUniqueTagName) {
        if (uniqueClasses.size) {
            selector += escapedClassSelector(node);
        } else if (nthChildIndex > 0) {
            selector += ":nth-child(" + nthChildIndex + ")";
        }
    }

    return {value: selector, done: false};
}

function cssPath(node) {
    if (!node || node.nodeType !== Node.ELEMENT_NODE) {
        return "";
    }

    var components = [];
    var current = node;
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

function xpathIndex(node) {
    if (!node || !node.parentNode) {
        return 0;
    }

    var siblings = node.parentNode.childNodes || [];
    if (siblings.length <= 1) {
        return 0;
    }

    function isSimilarNode(a, b) {
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

function xpathComponent(node) {
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

function xpath(node) {
    if (!node) {
        return "";
    }

    if (node.nodeType === Node.DOCUMENT_NODE) {
        return "/";
    }

    var components = [];
    var current = node;
    while (current) {
        var component = xpathComponent(current);
        if (!component) {
            break;
        }
        components.push(component);
        if (component.done) {
            break;
        }
        current = current.parentNode;
    }

    components.reverse();
    var prefix = components.length && components[0].done ? "" : "/";
    return prefix + components.map(function(entry) { return entry.value; }).join("/");
}

function serializedDoctype(doctype) {
    if (!doctype) {
        return "";
    }
    var publicId = doctype.publicId ? ' PUBLIC "' + doctype.publicId + '"' : "";
    var systemId = doctype.systemId ? (publicId ? ' "' + doctype.systemId + '"' : ' SYSTEM "' + doctype.systemId + '"') : "";
    return "<!DOCTYPE " + (doctype.name || "html") + publicId + systemId + ">";
}

export function outerHTMLForNode(identifier) {
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
        return serializedDoctype(node);
    default:
        try {
            return (new XMLSerializer()).serializeToString(node);
        } catch {
            return "";
        }
    }
}

export function selectorPathForNode(identifier) {
    var node = resolveNode(identifier);
    if (!node) {
        return "";
    }
    return cssPath(node);
}

export function xpathForNode(identifier) {
    var node = resolveNode(identifier);
    if (!node) {
        return "";
    }
    return xpath(node);
}

export function removeNode(identifier) {
    var node = resolveNode(identifier);
    if (!node) {
        return false;
    }
    var parent = node.parentNode;
    if (!parent) {
        return false;
    }

    var removed = false;
    suppressSnapshotAutoUpdate("remove-node");
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
        resumeSnapshotAutoUpdate("remove-node");
    }

    if (removed) {
        clearHighlight();
        triggerSnapshotUpdate("remove-node");
    }

    return removed;
}

export function setAttributeForNode(identifier, name, value) {
    var node = resolveNode(identifier);
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

export function removeAttributeForNode(identifier, name) {
    var node = resolveNode(identifier);
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
    console.log("[webInspectorKit] status:", status);
    return status;
}
