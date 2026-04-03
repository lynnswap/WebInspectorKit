import {inspector, type AnyNode} from "./dom-agent-state";
import { WI_DOM_SNAPSHOT_SCHEMA_VERSION } from "../../Contracts/agent-contract";

export const INSPECTOR_INTERNAL_OVERLAY_ATTRIBUTE = "data-web-inspector-overlay";
export const INSPECTOR_INTERNAL_SELECTION_SHIELD_ATTRIBUTE = "data-web-inspector-selection-shield";

const inspectorInternalAttributes = [
    INSPECTOR_INTERNAL_OVERLAY_ATTRIBUTE,
    INSPECTOR_INTERNAL_SELECTION_SHIELD_ATTRIBUTE
];

type DOMNodeDescriptor = {
    nodeId?: number;
    children: DOMNodeDescriptor[];
    [key: string]: any;
};

type SnapshotDescriptorPayload = {
    root: DOMNodeDescriptor | null;
    selectedNodeId: number | null;
    selectedNodePath: number[] | null;
};

type SerializedNodeEnvelope = {
    type: "serialized-node-envelope";
    schemaVersion: number;
    node: unknown;
    fallback: SnapshotDescriptorPayload | DOMNodeDescriptor | null;
    selectedNodeId?: number | null;
    selectedNodePath?: number[] | null;
};

type WebKitRuntimeBridge = {
    createJSHandle?: (value: unknown) => unknown;
    serializeNode?: (node: Node) => unknown;
};

type RenderedElement = Element & {
    offsetWidth?: number;
    offsetHeight?: number;
    getBBox?: () => DOMRect;
};

function webkitRuntime(): WebKitRuntimeBridge | null {
    const runtime = (window.webkit || null) as unknown as WebKitRuntimeBridge | null;
    return runtime;
}

function serializeNodeIfSupported(node: Node | null): unknown | null {
    if (!node) {
        return null;
    }
    const runtime = webkitRuntime();
    if (!runtime || typeof runtime.serializeNode !== "function") {
        return null;
    }
    try {
        return runtime.serializeNode(node);
    } catch {
    }
    return null;
}

function parseSerializedPayload(payload: unknown): unknown {
    if (typeof payload !== "string") {
        return payload;
    }
    try {
        return JSON.parse(payload);
    } catch {
        return payload;
    }
}

function serializedNodeIdentifierFromPayload(payload: unknown): number | null {
    const resolvedPayload = parseSerializedPayload(payload);
    if (!resolvedPayload || typeof resolvedPayload !== "object") {
        return null;
    }

    const object = resolvedPayload as Record<string, unknown>;
    if (typeof object.nodeId === "number" && Number.isFinite(object.nodeId)) {
        return object.nodeId;
    }
    if (typeof object.id === "number" && Number.isFinite(object.id)) {
        return object.id;
    }
    if (object.type === "serialized-node-envelope") {
        return serializedNodeIdentifierFromPayload(object.node ?? object.fallback);
    }
    if ("root" in object) {
        return serializedNodeIdentifierFromPayload(object.root);
    }
    return null;
}

function makeSerializedEnvelope(
    node: Node | null,
    fallback: SnapshotDescriptorPayload | DOMNodeDescriptor | null,
    selectedNodeId?: number | null,
    selectedNodePath?: number[] | null
): SerializedNodeEnvelope | null {
    const serializedNode = serializeNodeIfSupported(node);
    if (!serializedNode) {
        return null;
    }

    const envelope: SerializedNodeEnvelope = {
        type: "serialized-node-envelope",
        schemaVersion: WI_DOM_SNAPSHOT_SCHEMA_VERSION,
        node: serializedNode,
        fallback: fallback,
        selectedNodeId: selectedNodeId ?? null,
        selectedNodePath: selectedNodePath ?? null
    };
    return envelope;
}

export function rememberNode(node: AnyNode | null) {
    if (!node) {
        return 0;
    }
    if (isInspectorInternalNode(node)) {
        return 0;
    }
    if (!inspector.map) {
        inspector.map = new Map();
    }
    if (!inspector.nodeMap) {
        inspector.nodeMap = new WeakMap();
    }
    if (inspector.nodeMap.has(node)) {
        var existingId = inspector.nodeMap.get(node);
        if (typeof existingId === "number") {
            inspector.map.set(existingId, node);
            return existingId;
        }
    }
    var id = inspector.nextId++;
    inspector.map.set(id, node);
    inspector.nodeMap.set(node, id);
    return id;
}

export function stableNodeIdentifier(node: AnyNode | null) {
    const serializedNodeId = serializedNodeIdentifierFromPayload(serializeNodeIfSupported(node));
    if (typeof serializedNodeId === "number" && Number.isFinite(serializedNodeId) && serializedNodeId > 0) {
        return serializedNodeId;
    }
    return rememberNode(node);
}

export function layoutInfoForNode(node: AnyNode | null) {
    var rendered = nodeIsRendered(node);
    return {
        layoutFlags: rendered ? ["rendered"] : [],
        isRendered: rendered
    };
}

export function nodeIsRendered(node: AnyNode | null) {
    if (!node) {
        return false;
    }

    switch (node.nodeType) {
    case Node.ELEMENT_NODE:
        return elementIsRendered(node as RenderedElement);
    case Node.TEXT_NODE:
        return textNodeIsRendered(node);
    case Node.DOCUMENT_NODE:
    case Node.DOCUMENT_FRAGMENT_NODE:
        return true;
    default:
        return true;
    }
}

function nodeAncestorElement(node: Node | null | undefined): Element | null {
    if (!node) {
        return null;
    }
    if (node.nodeType === 1) {
        return node as Element;
    }
    return (node.parentElement || null);
}

export function isInspectorInternalNode(node: Node | null | undefined): boolean {
    var element = nodeAncestorElement(node);
    while (element) {
        for (var i = 0; i < inspectorInternalAttributes.length; ++i) {
            if (element.hasAttribute(inspectorInternalAttributes[i])) {
                return true;
            }
        }
        element = element.parentElement;
    }
    return false;
}

function inspectableChildNodes(node: Node | null | undefined): AnyNode[] {
    if (!node || !node.childNodes || !node.childNodes.length) {
        return [];
    }
    var children: AnyNode[] = [];
    for (var i = 0; i < node.childNodes.length; ++i) {
        var child = node.childNodes[i] as AnyNode;
        if (isInspectorInternalNode(child)) {
            continue;
        }
        children.push(child);
    }
    return children;
}

export function inspectableChildCount(node: Node | null | undefined): number {
    return inspectableChildNodes(node).length;
}

export function previousInspectableSibling(node: Node | null | undefined): AnyNode | null {
    var current = node || null;
    while (current) {
        if (!isInspectorInternalNode(current)) {
            return current as AnyNode;
        }
        current = current.previousSibling;
    }
    return null;
}

export function mutationTouchesInspectableDOM(record: MutationRecord | null | undefined): boolean {
    if (!record) {
        return false;
    }
    switch (record.type) {
    case "attributes":
    case "characterData":
        return !isInspectorInternalNode(record.target);
    case "childList":
        if (isInspectorInternalNode(record.target)) {
            return false;
        }
        if (record.addedNodes && record.addedNodes.length) {
            for (var i = 0; i < record.addedNodes.length; ++i) {
                if (!isInspectorInternalNode(record.addedNodes[i])) {
                    return true;
                }
            }
        }
        if (record.removedNodes && record.removedNodes.length) {
            for (var r = 0; r < record.removedNodes.length; ++r) {
                if (!isInspectorInternalNode(record.removedNodes[r])) {
                    return true;
                }
            }
        }
        return false;
    default:
        return !isInspectorInternalNode(record.target);
    }
}

export function elementIsRendered(element: RenderedElement | null) {
    if (!element || !element.isConnected) {
        return false;
    }

    var style = null;
    try {
        style = window.getComputedStyle(element);
    } catch {
    }

    if (style && style.display === "none") {
        return false;
    }

    if (element.getClientRects) {
        var rectList = element.getClientRects();
        if (rectList && rectList.length) {
            for (var i = 0; i < rectList.length; ++i) {
                var rect = rectList[i];
                if (rect && (rect.width || rect.height)) {
                    return true;
                }
            }
        }
    }

    if (element.getBoundingClientRect) {
        var rect = element.getBoundingClientRect();
        if (rect && (rect.width || rect.height)) {
            return true;
        }
    }

    if (typeof element.offsetWidth === "number" || typeof element.offsetHeight === "number") {
        if (element.offsetWidth || element.offsetHeight) {
            return true;
        }
    }

    if (style && (style.position === "fixed" || style.position === "sticky")) {
        return true;
    }

    if (typeof element.getBBox === "function") {
        try {
            var box = element.getBBox();
            if (box && (box.width || box.height)) {
                return true;
            }
        } catch {
        }
    }

    return style ? style.display !== "none" : true;
}

export function textNodeIsRendered(node: AnyNode | null) {
    if (!node || !node.parentNode || !node.nodeValue) {
        return false;
    }
    if (!nodeIsRendered(node.parentNode)) {
        return false;
    }
    var range = document.createRange();
    range.selectNodeContents(node);
    var rect = range.getBoundingClientRect();
    if (range.detach) {
        range.detach();
    }
    return rect && (rect.width || rect.height);
}

export function describe(node: AnyNode | null, depth: number, maxDepth: number, selectionPath: number[] | null, childLimit?: number): DOMNodeDescriptor | null {
    if (!node) {
        return null;
    }
    if (isInspectorInternalNode(node)) {
        return null;
    }

    var identifier = rememberNode(node);
    if (!identifier) {
        return null;
    }

    var descriptor: DOMNodeDescriptor = {
        nodeId: identifier,
        nodeType: node.nodeType || 0,
        nodeName: node.nodeName || "",
        localName: node.localName || (node.nodeName || "").toLowerCase(),
        nodeValue: node.nodeType === Node.TEXT_NODE || node.nodeType === Node.COMMENT_NODE ? (node.nodeValue || "") : "",
        childNodeCount: inspectableChildCount(node),
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
        if (serializedAttributes.length) {
            descriptor.attributes = serializedAttributes;
        }
    }

    if (node.nodeType === Node.DOCUMENT_NODE) {
        const documentAny = document as any;
        descriptor.documentURL = document.URL || "";
        descriptor.xmlVersion = typeof documentAny.xmlVersion === "string" ? documentAny.xmlVersion : "";
    } else if (node.nodeType === Node.DOCUMENT_TYPE_NODE) {
        descriptor.publicId = node.publicId || "";
        descriptor.systemId = node.systemId || "";
    } else if (node.nodeType === Node.ATTRIBUTE_NODE) {
        descriptor.name = node.name || "";
        descriptor.value = node.value || "";
    }

    var children = inspectableChildNodes(node);
    if (depth < maxDepth && children.length) {
        var limit = typeof childLimit === "number" && Number.isFinite(childLimit) ? childLimit : 150;
        var selectionIndex = Array.isArray(selectionPath) && selectionPath.length > depth ? selectionPath[depth] : -1;
        for (var childIndex = 0; childIndex < children.length; ++childIndex) {
            var childNode = children[childIndex];
            var mustInclude = selectionIndex === childIndex;
            if (descriptor.children.length >= limit && !mustInclude) {
                break;
            }
            var childDescriptor = describe(childNode as AnyNode, depth + 1, maxDepth, selectionPath, childLimit);
            if (childDescriptor) {
                descriptor.children.push(childDescriptor);
            }
        }
    }

    return descriptor;
}

export function findNodeByPath(tree: DOMNodeDescriptor | null, path: number[]) {
    if (!tree || !Array.isArray(path)) {
        return null;
    }
    if (!path.length) {
        return tree;
    }
    var current: DOMNodeDescriptor | undefined | null = tree;
    for (var i = 0; i < path.length; ++i) {
        if (!current || !Array.isArray(current.children)) {
            return null;
        }
        var index = path[i];
        if (index < 0 || index >= current.children.length) {
            return null;
        }
        current = current.children[index];
    }
    return current;
}

export function computeNodePath(node: AnyNode | null) {
    if (!node) {
        return null;
    }
    if (isInspectorInternalNode(node)) {
        return null;
    }
    var root = document.documentElement || document.body;
    if (!root) {
        return null;
    }
    var current = node;
    var path: number[] = [];
    while (current && current !== root) {
        var parent = current.parentNode;
        if (!parent) {
            return null;
        }
        var siblings = inspectableChildNodes(parent);
        var index = siblings.indexOf(current);
        if (index < 0) {
            return null;
        }
        path.unshift(index);
        current = parent;
    }
    if (current !== root) {
        return null;
    }
    return path;
}

export function rectForNode(node: AnyNode | null) {
    if (!node) {
        return null;
    }
    if (node.nodeType === Node.TEXT_NODE) {
        var range = document.createRange();
        range.selectNodeContents(node);
        var rect = range.getBoundingClientRect();
        if (range.detach) {
            range.detach();
        }
        if (!rect || (!rect.width && !rect.height)) {
            return null;
        }
        return rect;
    }
    if (node.getBoundingClientRect) {
        return node.getBoundingClientRect();
    }
    return null;
}

export function captureDOMPayload(maxDepth?: number): SnapshotDescriptorPayload {
    var currentURL = document.URL || "";
    var shouldReset = inspector.documentURL && inspector.documentURL !== currentURL;
    if (!inspector.map || shouldReset) {
        inspector.map = new Map();
    }
    if (!inspector.nodeMap || shouldReset) {
        inspector.nodeMap = new WeakMap();
    }
    if (typeof inspector.nextId !== "number" || inspector.nextId < 1 || shouldReset) {
        inspector.nextId = 1;
    }
    if (shouldReset) {
        inspector.nextInitialSnapshotMode = "fresh";
    }
    inspector.documentURL = currentURL;

    var selectionPath = inspector.pendingSelectionPath;
    var depthRequirement = Array.isArray(selectionPath) ? selectionPath.length + 1 : 0;
    var effectiveDepth = Math.max(maxDepth || 5, depthRequirement);

    var rootCandidate = document.documentElement || document.body;
    var tree = rootCandidate ? describe(rootCandidate, 0, effectiveDepth, selectionPath) : null;
    var selectedNodeId: number | null = null;
    if (tree && Array.isArray(selectionPath)) {
        var selectedNode = findNodeByPath(tree, selectionPath);
        selectedNodeId = selectedNode ? (selectedNode.nodeId || null) : null;
    }
    var selectedNodePath: number[] | null = Array.isArray(selectionPath) ? selectionPath : null;
    inspector.pendingSelectionPath = null;

    return {
        root: tree,
        selectedNodeId: selectedNodeId,
        selectedNodePath: selectedNodePath
    };
}

export function captureDOM(maxDepth?: number) {
    return JSON.stringify(captureDOMPayload(maxDepth));
}

export function captureDOMEnvelope(maxDepth?: number) {
    const snapshot = captureDOMPayload(maxDepth);
    const rootCandidate = document.documentElement || document.body;
    const serializedEnvelope = makeSerializedEnvelope(
        rootCandidate,
        snapshot,
        snapshot.selectedNodeId,
        snapshot.selectedNodePath
    );
    if (serializedEnvelope) {
        return serializedEnvelope;
    }
    return snapshot;
}

export function captureDOMSubtree(identifier: number, maxDepth?: number) {
    const payload = captureDOMSubtreePayload(identifier, maxDepth);
    if (!payload) {
        return "";
    }
    return JSON.stringify(payload);
}

export function captureDOMSubtreePayload(identifier: number, maxDepth?: number): DOMNodeDescriptor | null {
    var map = inspector.map;
    if (!map || !map.size) {
        return null;
    }
    var node = map.get(identifier);
    if (!node) {
        return null;
    }
    return describe(node, 0, maxDepth || 4, null, Number.MAX_SAFE_INTEGER);
}

export function captureDOMSubtreeEnvelope(identifier: number, maxDepth?: number) {
    const subtree = captureDOMSubtreePayload(identifier, maxDepth);
    if (!subtree) {
        return "";
    }
    const node = inspector.map?.get(identifier) || null;
    const serializedEnvelope = makeSerializedEnvelope(node as Node | null, subtree);
    if (serializedEnvelope) {
        return serializedEnvelope;
    }
    return subtree;
}

export function createNodeHandle(identifier: number): unknown | null {
    const map = inspector.map;
    if (!map || !map.size) {
        return null;
    }
    const node = map.get(identifier) || null;
    if (!node) {
        return null;
    }
    const runtime = webkitRuntime();
    if (!runtime || typeof runtime.createJSHandle !== "function") {
        return null;
    }
    try {
        return runtime.createJSHandle(node);
    } catch {
    }
    return null;
}
