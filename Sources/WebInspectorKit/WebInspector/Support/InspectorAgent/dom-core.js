import {inspector} from "./state.js";

export function rememberNode(node) {
    if (!node)
        return 0;
    if (!inspector.map)
        inspector.map = new Map();
    if (!inspector.nodeMap)
        inspector.nodeMap = new WeakMap();
    if (inspector.nodeMap.has(node)) {
        var existingId = inspector.nodeMap.get(node);
        inspector.map.set(existingId, node);
        return existingId;
    }
    var id = inspector.nextId++;
    inspector.map.set(id, node);
    inspector.nodeMap.set(node, id);
    return id;
}

export function layoutInfoForNode(node) {
    var rendered = nodeIsRendered(node);
    return {
        layoutFlags: rendered ? ["rendered"] : [],
        isRendered: rendered
    };
}

export function nodeIsRendered(node) {
    if (!node)
        return false;

    switch (node.nodeType) {
    case Node.ELEMENT_NODE:
        return elementIsRendered(node);
    case Node.TEXT_NODE:
        return textNodeIsRendered(node);
    case Node.DOCUMENT_NODE:
    case Node.DOCUMENT_FRAGMENT_NODE:
        return true;
    default:
        return true;
    }
}

export function elementIsRendered(element) {
    if (!element || !element.isConnected)
        return false;

    var style = null;
    try {
        style = window.getComputedStyle(element);
    } catch {
    }

    if (style && style.display === "none")
        return false;

    if (element.getClientRects) {
        var rectList = element.getClientRects();
        if (rectList && rectList.length) {
            for (var i = 0; i < rectList.length; ++i) {
                var rect = rectList[i];
                if (rect && (rect.width || rect.height))
                    return true;
            }
        }
    }

    if (element.getBoundingClientRect) {
        var rect = element.getBoundingClientRect();
        if (rect && (rect.width || rect.height))
            return true;
    }

    if (typeof element.offsetWidth === "number" || typeof element.offsetHeight === "number") {
        if (element.offsetWidth || element.offsetHeight)
            return true;
    }

    if (style && (style.position === "fixed" || style.position === "sticky"))
        return true;

    if (typeof element.getBBox === "function") {
        try {
            var box = element.getBBox();
            if (box && (box.width || box.height))
                return true;
        } catch {
        }
    }

    return style ? style.display !== "none" : true;
}

export function textNodeIsRendered(node) {
    if (!node || !node.parentNode || !node.nodeValue)
        return false;
    if (!nodeIsRendered(node.parentNode))
        return false;
    var range = document.createRange();
    range.selectNodeContents(node);
    var rect = range.getBoundingClientRect();
    if (range.detach)
        range.detach();
    return rect && (rect.width || rect.height);
}

export function describe(node, depth, maxDepth, selectionPath, childLimit) {
    if (!node)
        return null;

    var identifier = rememberNode(node);
    if (!identifier)
        return null;

    var descriptor = {
        nodeId: identifier,
        nodeType: node.nodeType || 0,
        nodeName: node.nodeName || "",
        localName: node.localName || (node.nodeName || "").toLowerCase(),
        nodeValue: node.nodeType === Node.TEXT_NODE || node.nodeType === Node.COMMENT_NODE ? (node.nodeValue || "") : "",
        childNodeCount: node.childNodes ? node.childNodes.length : 0,
        children: []
    };
    var layoutInfo = layoutInfoForNode(node);
    descriptor.layoutFlags = layoutInfo.layoutFlags;
    descriptor.isRendered = layoutInfo.isRendered;

    if (node.attributes && node.attributes.length) {
        var serializedAttributes = [];
        for (var i = 0; i < node.attributes.length; ++i) {
            var attr = node.attributes[i];
            serializedAttributes.push(attr.name, attr.value);
        }
        if (serializedAttributes.length)
            descriptor.attributes = serializedAttributes;
    }

    if (node.nodeType === Node.DOCUMENT_NODE) {
        descriptor.documentURL = document.URL || "";
        descriptor.xmlVersion = document.xmlVersion || "";
    } else if (node.nodeType === Node.DOCUMENT_TYPE_NODE) {
        descriptor.publicId = node.publicId || "";
        descriptor.systemId = node.systemId || "";
    } else if (node.nodeType === Node.ATTRIBUTE_NODE) {
        descriptor.name = node.name || "";
        descriptor.value = node.value || "";
    }

    if (depth < maxDepth && node.childNodes && node.childNodes.length) {
        var limit = Number.isFinite(childLimit) ? childLimit : 150;
        var selectionIndex = Array.isArray(selectionPath) && selectionPath.length > depth ? selectionPath[depth] : -1;
        for (var childIndex = 0; childIndex < node.childNodes.length; ++childIndex) {
            var childNode = node.childNodes[childIndex];
            var mustInclude = selectionIndex === childIndex;
            if (descriptor.children.length >= limit && !mustInclude)
                break;
            var childDescriptor = describe(childNode, depth + 1, maxDepth, selectionPath, childLimit);
            if (childDescriptor)
                descriptor.children.push(childDescriptor);
        }
    }

    return descriptor;
}

export function findNodeByPath(tree, path) {
    if (!tree || !Array.isArray(path))
        return null;
    if (!path.length)
        return tree;
    var current = tree;
    for (var i = 0; i < path.length; ++i) {
        if (!Array.isArray(current.children))
            return null;
        var index = path[i];
        if (index < 0 || index >= current.children.length)
            return null;
        current = current.children[index];
    }
    return current;
}

export function computeNodePath(node) {
    if (!node)
        return null;
    var root = document.documentElement || document.body;
    if (!root)
        return null;
    var current = node;
    var path = [];
    while (current && current !== root) {
        var parent = current.parentNode;
        if (!parent)
            return null;
        var index = Array.prototype.indexOf.call(parent.childNodes, current);
        if (index < 0)
            return null;
        path.unshift(index);
        current = parent;
    }
    if (current !== root)
        return null;
    return path;
}

export function rectForNode(node) {
    if (!node)
        return null;
    if (node.nodeType === Node.TEXT_NODE) {
        var range = document.createRange();
        range.selectNodeContents(node);
        var rect = range.getBoundingClientRect();
        if (range.detach)
            range.detach();
        if (!rect || (!rect.width && !rect.height))
            return null;
        return rect;
    }
    if (node.getBoundingClientRect)
        return node.getBoundingClientRect();
    return null;
}

export function captureDOM(maxDepth) {
    var currentURL = document.URL || "";
    var shouldReset = inspector.documentURL && inspector.documentURL !== currentURL;
    if (!inspector.map || shouldReset)
        inspector.map = new Map();
    if (!inspector.nodeMap || shouldReset)
        inspector.nodeMap = new WeakMap();
    if (typeof inspector.nextId !== "number" || inspector.nextId < 1 || shouldReset)
        inspector.nextId = 1;
    inspector.documentURL = currentURL;

    var selectionPath = inspector.pendingSelectionPath;
    var depthRequirement = Array.isArray(selectionPath) ? selectionPath.length + 1 : 0;
    var effectiveDepth = Math.max(maxDepth || 5, depthRequirement);

    var rootCandidate = document.documentElement || document.body;
    var tree = rootCandidate ? describe(rootCandidate, 0, effectiveDepth, selectionPath) : null;
    var selectedNodeId = null;
    if (tree && Array.isArray(selectionPath)) {
        var selectedNode = findNodeByPath(tree, selectionPath);
        selectedNodeId = selectedNode ? (selectedNode.nodeId || null) : null;
    }
    var selectedNodePath = Array.isArray(selectionPath) ? selectionPath : null;
    inspector.pendingSelectionPath = null;

    return JSON.stringify({
        root: tree,
        selectedNodeId: selectedNodeId,
        selectedNodePath: selectedNodePath
    });
}

export function captureDOMSubtree(identifier, maxDepth) {
    var map = inspector.map;
    if (!map || !map.size)
        return "";
    var node = map.get(identifier);
    if (!node)
        return "";
    var tree = describe(node, 0, maxDepth || 4, null, Number.MAX_SAFE_INTEGER);
    return JSON.stringify(tree);
}
