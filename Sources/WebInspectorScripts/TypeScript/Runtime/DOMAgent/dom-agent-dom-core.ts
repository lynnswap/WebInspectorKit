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
    localId?: number;
    backendNodeId?: number;
    children: DOMNodeDescriptor[];
    [key: string]: any;
};

type SnapshotDescriptorPayload = {
    root: DOMNodeDescriptor | null;
    selectedNodeId: number | null;
    selectedLocalId: number | null;
    selectedNodePath: number[] | null;
};

type SnapshotCaptureOptions = {
    consumeInitialSnapshotMode?: boolean;
};

export type NodeTargetIdentifier = number | {
    kind?: "local" | "backend";
    value?: number;
    localID?: number;
    backendNodeID?: number;
};

type SerializedNodeEnvelope = {
    type: "serialized-node-envelope";
    schemaVersion: number;
    node: unknown;
    fallback: SnapshotDescriptorPayload | DOMNodeDescriptor | null;
    selectedNodeId?: number | null;
    selectedLocalId?: number | null;
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

function normalizeDocumentURL(value: string): string {
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
    selectedLocalId?: number | null,
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
        selectedLocalId: selectedLocalId ?? null,
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

function resetRememberedNodeHandles() {
    inspector.map = new Map();
    inspector.nodeMap = new WeakMap();
    inspector.nextId = 1;
}

function rememberedNode(identifier: number): AnyNode | null {
    const map = inspector.map;
    if (!map || !map.size) {
        return null;
    }
    return map.get(identifier) || null;
}

function targetValue(value: unknown): number | null {
    if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
        return null;
    }
    return Math.floor(value);
}

function findNodeByStableIdentifier(identifier: number): AnyNode | null {
    const stableIdentifier = targetValue(identifier);
    if (!stableIdentifier) {
        return null;
    }
    const root = (document.documentElement || document.body) as AnyNode | null;
    if (!root) {
        return null;
    }
    const queue: AnyNode[] = [root];
    while (queue.length) {
        const current = queue.shift() as AnyNode;
        if (!isInspectorInternalNode(current) && stableNodeIdentifier(current) === stableIdentifier) {
            return current;
        }
        const children = inspectableChildNodes(current);
        for (let index = 0; index < children.length; index += 1) {
            queue.push(children[index]);
        }
    }
    return null;
}

export function resolveNodeTarget(identifier: NodeTargetIdentifier | null | undefined): AnyNode | null {
    if (typeof identifier === "number") {
        return rememberedNode(identifier) || findNodeByStableIdentifier(identifier);
    }
    if (!identifier || typeof identifier !== "object") {
        return null;
    }
    if (identifier.kind === "local") {
        const localID = targetValue(identifier.value ?? identifier.localID);
        return localID ? rememberedNode(localID) : null;
    }
    if (identifier.kind === "backend") {
        const backendNodeID = targetValue(identifier.value ?? identifier.backendNodeID);
        return backendNodeID ? findNodeByStableIdentifier(backendNodeID) : null;
    }

    const localID = targetValue(identifier.localID ?? identifier.value);
    if (localID) {
        const localNode = rememberedNode(localID);
        if (localNode) {
            return localNode;
        }
    }
    const backendNodeID = targetValue(identifier.backendNodeID ?? identifier.value);
    if (backendNodeID) {
        return findNodeByStableIdentifier(backendNodeID);
    }
    return null;
}

export function forgetRemovedNodeHandles(node: AnyNode | null): void {
    if (!node) {
        return;
    }
    const rememberedID = inspector.nodeMap?.get(node);
    if (typeof rememberedID === "number") {
        inspector.map?.delete(rememberedID);
    }
    const children = Array.from(node.childNodes || []);
    for (let index = 0; index < children.length; index += 1) {
        forgetRemovedNodeHandles(children[index] as AnyNode);
    }
}

export function stableNodeIdentifier(node: AnyNode | null) {
    const serializedNodeId = serializedNodeIdentifierFromPayload(serializeNodeIfSupported(node));
    if (typeof serializedNodeId === "number" && Number.isFinite(serializedNodeId) && serializedNodeId > 0) {
        return serializedNodeId;
    }
    return 0;
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

    var localIdentifier = rememberNode(node);
    if (!localIdentifier) {
        return null;
    }
    var stableIdentifier = stableNodeIdentifier(node) || 0;

    var descriptor: DOMNodeDescriptor = {
        nodeId: localIdentifier,
        localId: localIdentifier,
        nodeType: node.nodeType || 0,
        nodeName: node.nodeName || "",
        localName: node.localName || (node.nodeName || "").toLowerCase(),
        nodeValue: node.nodeType === Node.TEXT_NODE || node.nodeType === Node.COMMENT_NODE ? (node.nodeValue || "") : "",
        childNodeCount: inspectableChildCount(node),
        children: []
    };
    if (stableIdentifier && stableIdentifier !== localIdentifier) {
        descriptor.backendNodeId = stableIdentifier;
    }
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

export function captureDOMPayload(maxDepth?: number, options?: SnapshotCaptureOptions): SnapshotDescriptorPayload {
    var currentURL = document.URL || "";
    var normalizedCurrentURL = normalizeDocumentURL(currentURL);
    var normalizedPreviousURL = normalizeDocumentURL(inspector.documentURL || "");
    var shouldResetForURLChange = !!inspector.documentURL && normalizedPreviousURL !== normalizedCurrentURL;
    var shouldReset = inspector.nextInitialSnapshotMode === "fresh" || shouldResetForURLChange;
    if (shouldReset || !inspector.map || !inspector.nodeMap || typeof inspector.nextId !== "number" || inspector.nextId < 1) {
        resetRememberedNodeHandles();
    }
    if (shouldResetForURLChange) {
        inspector.nextInitialSnapshotMode = "fresh";
    }
    inspector.documentURL = currentURL;

    var selectionPath = inspector.pendingSelectionPath;
    var depthRequirement = Array.isArray(selectionPath) ? selectionPath.length + 1 : 0;
    var effectiveDepth = Math.max(maxDepth || 5, depthRequirement);

    var rootCandidate = document.documentElement || document.body;
    var tree = rootCandidate ? describe(rootCandidate, 0, effectiveDepth, selectionPath) : null;
    var selectedNodeId: number | null = null;
    var selectedLocalId: number | null = null;
    if (tree && Array.isArray(selectionPath)) {
        var selectedNode = findNodeByPath(tree, selectionPath);
        selectedNodeId = selectedNode ? (selectedNode.backendNodeId || null) : null;
        selectedLocalId = selectedNode ? (selectedNode.localId || null) : null;
    }
    var selectedNodePath: number[] | null = Array.isArray(selectionPath) ? selectionPath : null;
    inspector.pendingSelectionPath = null;
    if (options?.consumeInitialSnapshotMode !== false) {
        inspector.nextInitialSnapshotMode = null;
    }

    return {
        root: tree,
        selectedNodeId: selectedNodeId,
        selectedLocalId: selectedLocalId,
        selectedNodePath: selectedNodePath
    };
}

export function captureDOM(maxDepth?: number, options?: SnapshotCaptureOptions) {
    return JSON.stringify(captureDOMPayload(maxDepth, options));
}

export function captureDOMEnvelope(maxDepth?: number, options?: SnapshotCaptureOptions) {
    const snapshot = captureDOMPayload(maxDepth, options);
    const rootCandidate = document.documentElement || document.body;
    const serializedEnvelope = makeSerializedEnvelope(
        rootCandidate,
        snapshot,
        snapshot.selectedNodeId,
        snapshot.selectedLocalId,
        snapshot.selectedNodePath
    );
    if (serializedEnvelope) {
        return serializedEnvelope;
    }
    return snapshot;
}

export function consumePendingInitialSnapshotMode(expectedPageEpoch?: number, expectedDocumentScopeID?: number) {
    if (typeof expectedPageEpoch === "number" && inspector.pageEpoch !== expectedPageEpoch) {
        return false;
    }
    if (typeof expectedDocumentScopeID === "number" && inspector.documentScopeID !== expectedDocumentScopeID) {
        return false;
    }
    inspector.nextInitialSnapshotMode = null;
    return true;
}

export function captureDOMSubtree(identifier: NodeTargetIdentifier, maxDepth?: number) {
    const payload = captureDOMSubtreePayload(identifier, maxDepth);
    if (!payload) {
        return "";
    }
    return JSON.stringify(payload);
}

export function captureDOMSubtreePayload(identifier: NodeTargetIdentifier, maxDepth?: number): DOMNodeDescriptor | null {
    var node = resolveNodeTarget(identifier);
    if (!node) {
        return null;
    }
    return describe(node, 0, maxDepth || 4, null, Number.MAX_SAFE_INTEGER);
}

export function captureDOMSubtreeEnvelope(identifier: NodeTargetIdentifier, maxDepth?: number) {
    const subtree = captureDOMSubtreePayload(identifier, maxDepth);
    if (!subtree) {
        return "";
    }
    const node = resolveNodeTarget(identifier);
    const serializedEnvelope = makeSerializedEnvelope(node as Node | null, subtree);
    if (serializedEnvelope) {
        return serializedEnvelope;
    }
    return subtree;
}

export function createNodeHandle(identifier: NodeTargetIdentifier): unknown | null {
    const node = resolveNodeTarget(identifier);
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
