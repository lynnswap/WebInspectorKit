import {NODE_TYPES, treeState as state} from "./DOMTreeState.js";
import {
    applyLayoutState,
    normalizeLayoutFlags,
    resolveRenderedState
} from "./DOMTreeUtilities.js";

export function normalizeNodeDescriptor(descriptor) {
    if (!descriptor || typeof descriptor !== "object")
        return null;

    const resolvedId = typeof descriptor.nodeId === "number"
        ? descriptor.nodeId
        : (typeof descriptor.id === "number" ? descriptor.id : null);
    if (typeof resolvedId !== "number")
        return null;
    const nodeType = typeof descriptor.nodeType === "number" ? descriptor.nodeType : 0;
    const nodeName = descriptor.nodeName || "";
    const displayName = computeDisplayName(nodeType, nodeName, descriptor.localName);
    const attributes = deserializeAttributes(descriptor.attributes);
    const textContent = extractTextContent(nodeType, descriptor.nodeValue);
    if (shouldOmitTextNode(nodeType, textContent))
        return null;
    const layoutFlags = normalizeLayoutFlags(descriptor.layoutFlags);
    const isRendered = resolveRenderedState(layoutFlags, descriptor.isRendered);
    const rawChildCount = typeof descriptor.childNodeCount === "number"
        ? descriptor.childNodeCount
        : (typeof descriptor.childCount === "number"
            ? descriptor.childCount
            : (Array.isArray(descriptor.children) ? descriptor.children.length : 0));
    const children = [];
    const rawChildren = Array.isArray(descriptor.children) ? descriptor.children : [];
    let filteredChildren = 0;

    rawChildren.forEach(child => {
        if (isIgnorableTextDescriptor(child)) {
            filteredChildren += 1;
            return;
        }
        const normalized = normalizeNodeDescriptor(child);
        if (normalized)
            children.push(normalized);
    });

    const visibleChildCount = Math.max(children.length, rawChildCount - filteredChildren);

    if (visibleChildCount > children.length) {
        children.push(createPlaceholderNode(resolvedId, visibleChildCount - children.length));
    }

    return {
        id: resolvedId,
        nodeName,
        displayName,
        nodeType,
        attributes,
        textContent,
        layoutFlags,
        isRendered,
        children,
        childCount: visibleChildCount,
        placeholderParentId: null
    };
}

export function deserializeAttributes(rawAttributes) {
    if (!Array.isArray(rawAttributes))
        return [];
    const attributes = [];
    for (let index = 0; index < rawAttributes.length; index += 2) {
        const name = rawAttributes[index] || "";
        const value = rawAttributes[index + 1] || "";
        attributes.push({name, value});
    }
    return attributes;
}

export function extractTextContent(nodeType, nodeValue) {
    if (nodeType === NODE_TYPES.TEXT_NODE || nodeType === NODE_TYPES.COMMENT_NODE) {
        const text = (nodeValue || "").trim();
        return text.length ? text : null;
    }
    return null;
}

export function shouldOmitTextNode(nodeType, textContent) {
    if (nodeType !== NODE_TYPES.TEXT_NODE && nodeType !== NODE_TYPES.COMMENT_NODE)
        return false;
    return !textContent;
}

export function isIgnorableTextDescriptor(descriptor) {
    if (!descriptor || typeof descriptor !== "object")
        return false;
    const nodeType = typeof descriptor.nodeType === "number" ? descriptor.nodeType : 0;
    const textContent = extractTextContent(nodeType, descriptor.nodeValue);
    return shouldOmitTextNode(nodeType, textContent);
}

export function computeDisplayName(nodeType, nodeName, localName) {
    if (nodeType === NODE_TYPES.ELEMENT_NODE)
        return (localName || nodeName || "").toLowerCase();
    if (nodeType === NODE_TYPES.TEXT_NODE)
        return "#text";
    if (nodeType === NODE_TYPES.COMMENT_NODE)
        return "#comment";
    return nodeName || "";
}

export function createPlaceholderNode(parentId, remainingCount) {
    return {
        id: -Math.abs(parentId || 0) || -1,
        nodeName: "...",
        displayName: "…",
        nodeType: 0,
        attributes: [],
        textContent: null,
        children: [],
        childCount: remainingCount,
        layoutFlags: [],
        isRendered: true,
        placeholderParentId: parentId || null
    };
}

export function indexNode(node, depth, parentId, childIndex) {
    if (!node || typeof node.id === "undefined")
        return;
    if (typeof childIndex !== "number")
        childIndex = 0;
    node.depth = depth;
    node.parentId = parentId;
    node.childIndex = childIndex;
    state.nodes.set(node.id, node);
    if (!Array.isArray(node.children))
        return;
    node.children.forEach((child, index) => {
        indexNode(child, depth + 1, node.id, index);
    });
}

export function mergeNodeWithSource(target, source, depth) {
    if (!target || !source)
        return;
    target.nodeName = source.nodeName;
    target.displayName = source.displayName;
    target.nodeType = source.nodeType;
    target.attributes = Array.isArray(source.attributes) ? source.attributes : [];
    target.textContent = source.textContent || null;
    target.childCount = typeof source.childCount === "number" ? source.childCount : (Array.isArray(source.children) ? source.children.length : 0);
    target.placeholderParentId = source.placeholderParentId || null;
    applyLayoutState(target, source.layoutFlags, source.isRendered);
    if (typeof depth === "number")
        target.depth = depth;

    const existingChildren = new Map();
    if (Array.isArray(target.children)) {
        for (const child of target.children)
            existingChildren.set(child.id, child);
    } else
        target.children = [];

    const nextChildren = [];
    const childDepth = (target.depth || 0) + 1;
    if (Array.isArray(source.children)) {
        source.children.forEach((childSource, index) => {
            let child = existingChildren.get(childSource.id);
            if (child) {
                existingChildren.delete(childSource.id);
                child.parentId = target.id;
                child.childIndex = index;
                mergeNodeWithSource(child, childSource, childDepth);
            } else {
                child = childSource;
                indexNode(child, childDepth, target.id, index);
            }
            nextChildren.push(child);
        });
    }

    existingChildren.forEach(child => {
        removeNodeEntry(child);
    });

    target.children = nextChildren;
    state.nodes.set(target.id, target);
}

export function removeNodeEntry(node) {
    if (!node || typeof node.id === "undefined")
        return;
    if (Array.isArray(node.children)) {
        for (const child of node.children)
            removeNodeEntry(child);
    }
    const element = state.elements.get(node.id);
    if (element && element.parentNode)
        element.remove();
    state.nodes.delete(node.id);
    state.openState.delete(node.id);
    state.elements.delete(node.id);
}

export function reindexChildren(node) {
    if (!node || !Array.isArray(node.children))
        return;
    node.children.forEach((child, index) => {
        child.childIndex = index;
    });
}

export function findInsertionIndex(children, previousNodeId) {
    if (!Array.isArray(children) || !children.length)
        return 0;
    if (!previousNodeId)
        return 0;
    for (let index = 0; index < children.length; ++index) {
        if (children[index].id === previousNodeId)
            return index + 1;
    }
    return children.length;
}

export function preserveExpansionState(node, storage = new Map()) {
    if (!node || typeof node.id === "undefined")
        return storage;
    if (state.openState.has(node.id))
        storage.set(node.id, state.openState.get(node.id));
    if (Array.isArray(node.children)) {
        for (const child of node.children) {
            preserveExpansionState(child, storage);
        }
    }
    return storage;
}
