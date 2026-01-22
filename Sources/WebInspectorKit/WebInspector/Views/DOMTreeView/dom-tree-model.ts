/**
 * DOMTreeModel - Node normalization and tree management.
 *
 * This module provides:
 * - Node descriptor normalization
 * - Attribute deserialization
 * - Node indexing and tree traversal
 * - Node merging and removal
 * - Expansion state preservation
 */

import {
    DOMNode,
    NodeAttribute,
    RawNodeDescriptor,
    NODE_TYPES,
} from "./dom-tree-types";
import { treeState } from "./dom-tree-state";
import {
    normalizeLayoutFlags,
    resolveRenderedState,
    applyLayoutState,
} from "./dom-tree-utilities";

// =============================================================================
// Node Normalization
// =============================================================================

/**
 * Normalize a raw node descriptor into a DOMNode.
 * Returns null if the descriptor is invalid or should be omitted.
 */
export function normalizeNodeDescriptor(
    descriptor: RawNodeDescriptor | null | undefined,
    parentRendered = true
): DOMNode | null {
    if (!descriptor || typeof descriptor !== "object") {
        return null;
    }

    const resolvedId =
        typeof descriptor.nodeId === "number"
            ? descriptor.nodeId
            : typeof descriptor.id === "number"
              ? descriptor.id
              : null;

    if (typeof resolvedId !== "number") {
        return null;
    }

    const nodeType = typeof descriptor.nodeType === "number" ? descriptor.nodeType : 0;
    const nodeName = descriptor.nodeName || "";
    const displayName = computeDisplayName(nodeType, nodeName, descriptor.localName);
    const attributes = deserializeAttributes(descriptor.attributes);
    const textContent = extractTextContent(nodeType, descriptor.nodeValue);

    if (shouldOmitTextNode(nodeType, textContent)) {
        return null;
    }

    const layoutFlags = normalizeLayoutFlags(descriptor.layoutFlags);
    const renderedSelf = resolveRenderedState(layoutFlags, descriptor.isRendered);
    const isRendered = parentRendered && renderedSelf;

    const rawChildCount =
        typeof descriptor.childNodeCount === "number"
            ? descriptor.childNodeCount
            : typeof descriptor.childCount === "number"
              ? descriptor.childCount
              : Array.isArray(descriptor.children)
                ? descriptor.children.length
                : 0;

    const children: DOMNode[] = [];
    const rawChildren = Array.isArray(descriptor.children) ? descriptor.children : [];
    let filteredChildren = 0;

    for (const child of rawChildren) {
        if (isIgnorableTextDescriptor(child)) {
            filteredChildren += 1;
            continue;
        }
        const normalized = normalizeNodeDescriptor(child, isRendered);
        if (normalized) {
            children.push(normalized);
        }
    }

    const visibleChildCount = Math.max(children.length, rawChildCount - filteredChildren);

    if (visibleChildCount > children.length) {
        children.push(
            createPlaceholderNode(resolvedId, visibleChildCount - children.length, isRendered)
        );
    }

    return {
        id: resolvedId,
        nodeName,
        displayName,
        nodeType,
        attributes,
        textContent,
        layoutFlags,
        renderedSelf,
        isRendered,
        children,
        childCount: visibleChildCount,
        placeholderParentId: null,
    };
}

// =============================================================================
// Attribute Handling
// =============================================================================

/** Deserialize raw attribute array into name-value pairs */
export function deserializeAttributes(
    rawAttributes: (string | undefined)[] | undefined
): NodeAttribute[] {
    if (!Array.isArray(rawAttributes)) {
        return [];
    }
    const attributes: NodeAttribute[] = [];
    for (let index = 0; index < rawAttributes.length; index += 2) {
        const name = rawAttributes[index] || "";
        const value = rawAttributes[index + 1] || "";
        attributes.push({ name, value });
    }
    return attributes;
}

// =============================================================================
// Text Content Handling
// =============================================================================

/** Extract text content for text and comment nodes */
export function extractTextContent(
    nodeType: number,
    nodeValue: string | undefined
): string | null {
    if (nodeType === NODE_TYPES.TEXT_NODE || nodeType === NODE_TYPES.COMMENT_NODE) {
        const text = (nodeValue || "").trim();
        return text.length ? text : null;
    }
    return null;
}

/** Check if a text/comment node should be omitted (empty content) */
export function shouldOmitTextNode(
    nodeType: number,
    textContent: string | null
): boolean {
    if (nodeType !== NODE_TYPES.TEXT_NODE && nodeType !== NODE_TYPES.COMMENT_NODE) {
        return false;
    }
    return !textContent;
}

/** Check if a raw descriptor represents an ignorable text node */
export function isIgnorableTextDescriptor(
    descriptor: RawNodeDescriptor | null | undefined
): boolean {
    if (!descriptor || typeof descriptor !== "object") {
        return false;
    }
    const nodeType = typeof descriptor.nodeType === "number" ? descriptor.nodeType : 0;
    const textContent = extractTextContent(nodeType, descriptor.nodeValue);
    return shouldOmitTextNode(nodeType, textContent);
}

// =============================================================================
// Display Name Computation
// =============================================================================

/** Compute display name based on node type */
export function computeDisplayName(
    nodeType: number,
    nodeName: string,
    localName: string | undefined
): string {
    if (nodeType === NODE_TYPES.ELEMENT_NODE) {
        return (localName || nodeName || "").toLowerCase();
    }
    if (nodeType === NODE_TYPES.TEXT_NODE) {
        return "#text";
    }
    if (nodeType === NODE_TYPES.COMMENT_NODE) {
        return "#comment";
    }
    return nodeName || "";
}

// =============================================================================
// Placeholder Nodes
// =============================================================================

/** Create a placeholder node for unexpanded children */
export function createPlaceholderNode(
    parentId: number,
    remainingCount: number,
    parentRendered = true
): DOMNode {
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
        renderedSelf: true,
        isRendered: parentRendered,
        placeholderParentId: parentId || null,
    };
}

// =============================================================================
// Node Indexing
// =============================================================================

/** Index a node and its children in the tree state */
export function indexNode(
    node: DOMNode | null | undefined,
    depth: number,
    parentId: number | null,
    childIndex = 0
): void {
    if (!node || typeof node.id === "undefined") {
        return;
    }

    node.depth = depth;
    node.parentId = parentId;
    node.childIndex = childIndex;
    treeState.nodes.set(node.id, node);

    if (!Array.isArray(node.children)) {
        return;
    }

    node.children.forEach((child, index) => {
        indexNode(child, depth + 1, node.id, index);
    });
}

// =============================================================================
// Node Merging
// =============================================================================

/** Merge source node data into target node */
export function mergeNodeWithSource(
    target: DOMNode | null | undefined,
    source: DOMNode | null | undefined,
    depth: number
): void {
    if (!target || !source) {
        return;
    }

    target.nodeName = source.nodeName;
    target.displayName = source.displayName;
    target.nodeType = source.nodeType;
    target.attributes = Array.isArray(source.attributes) ? source.attributes : [];
    target.textContent = source.textContent || null;
    target.childCount =
        typeof source.childCount === "number"
            ? source.childCount
            : Array.isArray(source.children)
              ? source.children.length
              : 0;
    target.placeholderParentId = source.placeholderParentId || null;

    const parent =
        typeof target.parentId === "number" ? treeState.nodes.get(target.parentId) : null;
    const parentRendered = parent ? parent.isRendered !== false : true;

    applyLayoutState(
        target,
        source.layoutFlags,
        typeof source.renderedSelf === "boolean" ? source.renderedSelf : source.isRendered,
        parentRendered
    );

    if (typeof depth === "number") {
        target.depth = depth;
    }

    const existingChildren = new Map<number, DOMNode>();
    if (Array.isArray(target.children)) {
        for (const child of target.children) {
            existingChildren.set(child.id, child);
        }
    } else {
        target.children = [];
    }

    const nextChildren: DOMNode[] = [];
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

    existingChildren.forEach((child) => {
        removeNodeEntry(child);
    });

    target.children = nextChildren;
    treeState.nodes.set(target.id, target);
}

// =============================================================================
// Node Removal
// =============================================================================

/** Remove a node and its children from state */
export function removeNodeEntry(node: DOMNode | null | undefined): void {
    if (!node || typeof node.id === "undefined") {
        return;
    }

    if (Array.isArray(node.children)) {
        for (const child of node.children) {
            removeNodeEntry(child);
        }
    }

    const element = treeState.elements.get(node.id);
    if (element && element.parentNode) {
        element.remove();
    }

    treeState.nodes.delete(node.id);
    treeState.openState.delete(node.id);
    treeState.elements.delete(node.id);
}

// =============================================================================
// Child Reindexing
// =============================================================================

/** Reindex children after insertion/removal */
export function reindexChildren(node: DOMNode | null | undefined): void {
    if (!node || !Array.isArray(node.children)) {
        return;
    }
    node.children.forEach((child, index) => {
        child.childIndex = index;
    });
}

/** Find insertion index based on previous sibling */
export function findInsertionIndex(
    children: DOMNode[] | null | undefined,
    previousNodeId: number | null | undefined
): number {
    if (!Array.isArray(children) || !children.length) {
        return 0;
    }
    if (!previousNodeId) {
        return 0;
    }
    for (let index = 0; index < children.length; ++index) {
        if (children[index].id === previousNodeId) {
            return index + 1;
        }
    }
    return children.length;
}

// =============================================================================
// Expansion State Preservation
// =============================================================================

/** Preserve expansion state for a node and its children */
export function preserveExpansionState(
    node: DOMNode | null | undefined,
    storage = new Map<number, boolean>()
): Map<number, boolean> {
    if (!node || typeof node.id === "undefined") {
        return storage;
    }

    if (treeState.openState.has(node.id)) {
        storage.set(node.id, treeState.openState.get(node.id)!);
    }

    if (Array.isArray(node.children)) {
        for (const child of node.children) {
            preserveExpansionState(child, storage);
        }
    }

    return storage;
}
