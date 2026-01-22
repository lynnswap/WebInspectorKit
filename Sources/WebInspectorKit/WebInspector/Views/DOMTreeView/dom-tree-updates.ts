/**
 * DOMTreeUpdates - DOM mutation event processing.
 *
 * This module provides:
 * - DOM event batching and debouncing
 * - Mutation event handling (insert, remove, attribute changes)
 * - Tree refresh coordination
 * - Reload triggering
 */

import {
    DOMNode,
    DOMEventEntry,
    ChildNodeInsertedParams,
    ChildNodeRemovedParams,
    AttributeModifiedParams,
    CharacterDataModifiedParams,
    ChildCountUpdatedParams,
    NodeRefreshEntry,
    TEXT_CONTENT_ATTRIBUTE,
} from "./dom-tree-types";
import {
    treeState,
    childRequestDepth,
    DOM_EVENT_BATCH_LIMIT,
    DOM_EVENT_TIME_BUDGET,
    REFRESH_RETRY_LIMIT,
    REFRESH_RETRY_WINDOW,
} from "./dom-tree-state";
import { applyLayoutEntry, resolveRenderedState, timeNow } from "./dom-tree-utilities";
import { reportInspectorError, sendCommand } from "./dom-tree-protocol";
import {
    findInsertionIndex,
    indexNode,
    normalizeNodeDescriptor,
    reindexChildren,
    removeNodeEntry,
} from "./dom-tree-model";
import {
    applyFilter,
    captureTreeScrollPosition,
    reopenSelectionAncestors,
    scheduleNodeRender,
    updateDetails,
    restoreTreeScrollPosition,
} from "./dom-tree-view-support";

// =============================================================================
// Reload Handler
// =============================================================================

/** Handler for triggering snapshot reload */
let reloadHandler: ((reason: string) => void) | null = null;

/** Set the reload handler */
export function setReloadHandler(handler: ((reason: string) => void) | null): void {
    reloadHandler = typeof handler === "function" ? handler : null;
}

/** Trigger a reload */
function triggerReload(reason: string): void {
    if (typeof reloadHandler === "function") {
        reloadHandler(reason);
    }
}

// =============================================================================
// Node Refresh
// =============================================================================

/** Request refresh for a specific node */
export async function requestNodeRefresh(
    nodeId: number,
    options: { parentId?: number } = {}
): Promise<void> {
    if (typeof nodeId !== "number" || nodeId <= 0) {
        return;
    }

    if (!treeState.pendingRefreshRequests) {
        treeState.pendingRefreshRequests = new Set();
    }

    const targetNodeId =
        typeof options.parentId === "number" && options.parentId > 0 ? options.parentId : nodeId;

    if (treeState.pendingRefreshRequests.has(targetNodeId)) {
        return;
    }

    const attempts = treeState.refreshAttempts.get(targetNodeId) || { count: 0, lastRequested: 0 };
    const now = timeNow();

    if (attempts.count >= REFRESH_RETRY_LIMIT && now - attempts.lastRequested <= REFRESH_RETRY_WINDOW) {
        treeState.refreshAttempts.delete(targetNodeId);
        triggerReload("refresh-fallback");
        return;
    }

    treeState.refreshAttempts.set(targetNodeId, { count: attempts.count + 1, lastRequested: now });
    treeState.pendingRefreshRequests.add(targetNodeId);

    try {
        await sendCommand("DOM.requestChildNodes", { nodeId: targetNodeId, depth: childRequestDepth() });
    } catch (error) {
        reportInspectorError("requestChildNodes", error);
    } finally {
        treeState.pendingRefreshRequests.delete(targetNodeId);
    }
}

/** Refresh tree after DOM updates */
function refreshTreeAfterDomUpdates(
    nodesToRefresh: Map<number, NodeRefreshEntry> | null | undefined,
    modifiedAttrsByNode: Map<number, Set<string | symbol>> = new Map()
): void {
    if (!nodesToRefresh || !nodesToRefresh.size) {
        return;
    }

    const preservedScrollPosition = captureTreeScrollPosition();

    nodesToRefresh.forEach((entry) => {
        if (entry && entry.node) {
            const modifiedAttributes = modifiedAttrsByNode ? modifiedAttrsByNode.get(entry.node.id) : null;
            scheduleNodeRender(entry.node, { updateChildren: entry.updateChildren, modifiedAttributes });
        }
    });

    const selectedNodeId = treeState.selectedNodeId;
    if (selectedNodeId) {
        const selectedNode = treeState.nodes.get(selectedNodeId);
        if (selectedNode) {
            const shouldUpdateDetails =
                nodesToRefresh.has(selectedNodeId) ||
                (modifiedAttrsByNode && modifiedAttrsByNode.has(selectedNodeId));
            if (shouldUpdateDetails) {
                updateDetails(selectedNode);
            }
        } else {
            treeState.selectedNodeId = null;
            updateDetails(null);
        }
    }

    if (treeState.filter) {
        applyFilter();
    }

    if (preservedScrollPosition) {
        restoreTreeScrollPosition(preservedScrollPosition);
    }
}

// =============================================================================
// Frame Debouncer
// =============================================================================

/** Debouncer using requestAnimationFrame */
class FrameDebouncer {
    private callback: () => void;
    private frameId: number | null;

    constructor(callback: () => void) {
        this.callback = callback;
        this.frameId = null;
    }

    schedule(): void {
        if (this.frameId !== null) {
            return;
        }
        this.frameId = requestAnimationFrame(() => {
            this.frameId = null;
            this.callback();
        });
    }

    cancel(): void {
        if (this.frameId === null) {
            return;
        }
        cancelAnimationFrame(this.frameId);
        this.frameId = null;
    }
}

// =============================================================================
// DOM Tree Updater
// =============================================================================

/** Handles batched DOM mutation events */
export class DOMTreeUpdater {
    private pendingEvents: DOMEventEntry[];
    private recentlyInsertedNodes: Map<number, ChildNodeInsertedParams>;
    private recentlyDeletedNodes: Map<number, ChildNodeRemovedParams>;
    private recentlyModifiedNodes: Set<number>;
    private recentlyModifiedAttributes: Map<string | symbol, Set<number>>;
    private textContentAttributeSymbol: symbol;
    private debouncer: FrameDebouncer;

    constructor() {
        this.pendingEvents = [];
        this.recentlyInsertedNodes = new Map();
        this.recentlyDeletedNodes = new Map();
        this.recentlyModifiedNodes = new Set();
        this.recentlyModifiedAttributes = new Map();
        this.textContentAttributeSymbol = TEXT_CONTENT_ATTRIBUTE;
        this.debouncer = new FrameDebouncer(() => this.processPendingEvents());
    }

    /** Reset all pending state */
    reset(): void {
        this.pendingEvents = [];
        this.recentlyInsertedNodes.clear();
        this.recentlyDeletedNodes.clear();
        this.recentlyModifiedNodes.clear();
        this.recentlyModifiedAttributes.clear();
        this.debouncer.cancel();
    }

    /** Enqueue events for processing */
    enqueueEvents(events: DOMEventEntry[]): void {
        if (!Array.isArray(events) || !events.length) {
            return;
        }
        if (!treeState.snapshot || !treeState.snapshot.root) {
            triggerReload("missing-snapshot");
            return;
        }
        for (const event of events) {
            this.recordEvent(event);
        }
        this.debouncer.schedule();
    }

    /** Record a single event */
    private recordEvent(event: DOMEventEntry): void {
        if (!event || typeof event.method !== "string") {
            return;
        }
        const method = event.method.startsWith("DOM.") ? event.method.slice(4) : event.method;
        const params = event.params || {};
        this.pendingEvents.push({ method, params });

        switch (method) {
            case "childNodeInserted": {
                const insertParams = params as ChildNodeInsertedParams;
                if (insertParams.node && typeof (insertParams.node as { nodeId?: number }).nodeId === "number") {
                    this.recentlyInsertedNodes.set(
                        (insertParams.node as { nodeId: number }).nodeId,
                        insertParams
                    );
                }
                break;
            }
            case "childNodeRemoved": {
                const removeParams = params as ChildNodeRemovedParams;
                if (typeof removeParams.nodeId === "number") {
                    this.recentlyDeletedNodes.set(removeParams.nodeId, removeParams);
                }
                break;
            }
            case "attributeModified":
            case "attributeRemoved": {
                const attrParams = params as AttributeModifiedParams;
                this.nodeAttributeModified(attrParams.nodeId, attrParams.name);
                break;
            }
            case "characterDataModified": {
                const charParams = params as CharacterDataModifiedParams;
                this.nodeAttributeModified(charParams.nodeId, this.textContentAttributeSymbol);
                break;
            }
            default:
                break;
        }
    }

    /** Record an attribute modification */
    private nodeAttributeModified(nodeId: number | undefined, attribute: string | symbol | undefined): void {
        if (typeof nodeId !== "number" || !attribute) {
            return;
        }
        if (!this.recentlyModifiedAttributes.has(attribute)) {
            this.recentlyModifiedAttributes.set(attribute, new Set());
        }
        this.recentlyModifiedAttributes.get(attribute)!.add(nodeId);
        this.recentlyModifiedNodes.add(nodeId);
    }

    /** Clone modified attributes snapshot */
    private cloneModifiedAttributes(): Map<string | symbol, Set<number>> {
        const snapshot = new Map<string | symbol, Set<number>>();
        this.recentlyModifiedAttributes.forEach((nodes, attribute) => {
            if (!nodes || !nodes.size) {
                return;
            }
            snapshot.set(attribute, new Set(nodes));
        });
        return snapshot;
    }

    /** Build node-to-attributes map from attribute-to-nodes map */
    private buildModifiedAttributesByNode(
        attributeToNodes: Map<string | symbol, Set<number>>
    ): Map<number, Set<string | symbol>> {
        const nodesToAttributes = new Map<number, Set<string | symbol>>();
        attributeToNodes.forEach((nodes, attribute) => {
            nodes.forEach((nodeId) => {
                if (typeof nodeId !== "number") {
                    return;
                }
                if (!nodesToAttributes.has(nodeId)) {
                    nodesToAttributes.set(nodeId, new Set());
                }
                nodesToAttributes.get(nodeId)!.add(attribute);
            });
        });
        return nodesToAttributes;
    }

    /** Process pending events */
    private processPendingEvents(): void {
        if (!treeState.snapshot || !treeState.snapshot.root) {
            this.reset();
            return;
        }
        if (!this.pendingEvents.length) {
            return;
        }

        const nodesToRefresh = new Map<number, NodeRefreshEntry>();
        let requiresReload = false;
        const pending = this.pendingEvents;
        let index = 0;
        let processed = 0;
        const startedAt = timeNow();

        while (index < pending.length) {
            const entry = pending[index];
            index += 1;
            if (!entry || typeof entry.method !== "string") {
                continue;
            }
            if (!this.handleDomEvent(entry.method, entry.params || {}, nodesToRefresh)) {
                requiresReload = true;
                break;
            }
            processed += 1;
            const elapsed = timeNow() - startedAt;
            if (processed >= DOM_EVENT_BATCH_LIMIT || elapsed >= DOM_EVENT_TIME_BUDGET) {
                break;
            }
        }

        const modifiedAttributes = this.cloneModifiedAttributes();
        const modifiedAttrsByNode = this.buildModifiedAttributesByNode(modifiedAttributes);
        this.recentlyInsertedNodes.clear();
        this.recentlyDeletedNodes.clear();
        this.recentlyModifiedNodes.clear();
        this.recentlyModifiedAttributes.clear();

        if (requiresReload) {
            this.pendingEvents = [];
            triggerReload("dom-sync");
            return;
        }

        refreshTreeAfterDomUpdates(nodesToRefresh, modifiedAttrsByNode);

        if (index < pending.length) {
            this.pendingEvents = pending.slice(index);
            this.debouncer.schedule();
        } else {
            this.pendingEvents = [];
        }
    }

    /** Handle a single DOM event */
    private handleDomEvent(
        method: string,
        params: Record<string, unknown>,
        nodesToRefresh: Map<number, NodeRefreshEntry>
    ): boolean {
        switch (method) {
            case "childNodeInserted":
                return this.handleNodeInserted(params as ChildNodeInsertedParams, nodesToRefresh);
            case "childNodeRemoved":
                return this.handleNodeRemoved(params as ChildNodeRemovedParams, nodesToRefresh);
            case "attributeModified":
                return this.handleAttributeUpdated(params as AttributeModifiedParams, nodesToRefresh);
            case "attributeRemoved":
                return this.handleAttributeRemoved(params as AttributeModifiedParams, nodesToRefresh);
            case "characterDataModified":
                return this.handleCharacterDataUpdated(params as CharacterDataModifiedParams, nodesToRefresh);
            case "childNodeCountUpdated":
                return this.handleChildCountUpdate(params as ChildCountUpdatedParams, nodesToRefresh);
            default:
                return true;
        }
    }

    /** Handle node insertion */
    private handleNodeInserted(
        entry: ChildNodeInsertedParams,
        nodesToRefresh: Map<number, NodeRefreshEntry>
    ): boolean {
        const parentId =
            typeof entry.parentId === "number" ? entry.parentId : (entry.parentNodeId as number | undefined);
        if (!entry.node || typeof parentId !== "number") {
            return true;
        }

        const parent = treeState.nodes.get(parentId);
        if (!parent) {
            requestNodeRefresh(parentId);
            return true;
        }

        if (!Array.isArray(parent.children)) {
            parent.children = [];
        }
        const children = parent.children;
        const descriptor = normalizeNodeDescriptor(entry.node, parent.isRendered !== false);
        if (!descriptor || typeof descriptor.id !== "number") {
            return true;
        }

        const existingIndex = children.findIndex((child) => child.id === descriptor.id);
        const preservedExpansion = treeState.openState.has(descriptor.id)
            ? treeState.openState.get(descriptor.id)
            : undefined;
        if (existingIndex >= 0) {
            const [existingNode] = children.splice(existingIndex, 1);
            removeNodeEntry(existingNode);
        }

        const insertionIndex = findInsertionIndex(children, entry.previousNodeId);
        children.splice(insertionIndex, 0, descriptor);
        parent.childCount = Math.max(parent.childCount || children.length, children.length);
        indexNode(descriptor, (parent.depth || 0) + 1, parent.id, insertionIndex);
        reindexChildren(parent);
        if (preservedExpansion !== undefined) {
            treeState.openState.set(descriptor.id, preservedExpansion);
        }
        this.markNodeForRefresh(nodesToRefresh, parent, { updateChildren: true });
        this.markNodeForRefresh(nodesToRefresh, descriptor, { updateChildren: true });
        return true;
    }

    /** Handle node removal */
    private handleNodeRemoved(
        entry: ChildNodeRemovedParams,
        nodesToRefresh: Map<number, NodeRefreshEntry>
    ): boolean {
        const parentId =
            typeof entry.parentId === "number" ? entry.parentId : (entry.parentNodeId as number | undefined);
        if (typeof parentId !== "number" || typeof entry.nodeId !== "number") {
            return true;
        }

        const parent = treeState.nodes.get(parentId);
        if (!parent) {
            requestNodeRefresh(parentId);
            return true;
        }

        if (!Array.isArray(parent.children)) {
            return true;
        }

        const index = parent.children.findIndex((child) => child.id === entry.nodeId);
        if (index === -1) {
            return true;
        }

        const [removed] = parent.children.splice(index, 1);
        parent.childCount = Math.max(parent.children.length, parent.childCount || 0);
        reindexChildren(parent);
        removeNodeEntry(removed);
        this.markNodeForRefresh(nodesToRefresh, parent, { updateChildren: true });

        if (treeState.selectedNodeId === entry.nodeId) {
            treeState.selectedNodeId = null;
            updateDetails(null);
            reopenSelectionAncestors();
        }
        return true;
    }

    /** Handle attribute update */
    private handleAttributeUpdated(
        entry: AttributeModifiedParams,
        nodesToRefresh: Map<number, NodeRefreshEntry>
    ): boolean {
        if (typeof entry.nodeId !== "number" || typeof entry.name !== "string") {
            return true;
        }

        const node = treeState.nodes.get(entry.nodeId);
        if (!node) {
            requestNodeRefresh(entry.nodeId);
            return true;
        }

        const parentNode =
            typeof node.parentId === "number" ? treeState.nodes.get(node.parentId) : null;
        const parentRendered = parentNode ? parentNode.isRendered !== false : true;
        const layoutChange = applyLayoutEntry(node, entry, parentRendered);

        if (!Array.isArray(node.attributes)) {
            node.attributes = [];
        }

        const value = typeof entry.value === "string" ? entry.value : String(entry.value ?? "");
        const index = node.attributes.findIndex((attr) => attr.name === entry.name);
        const record = { name: entry.name, value };

        if (index >= 0) {
            node.attributes[index] = record;
        } else {
            node.attributes.push(record);
        }

        if (layoutChange.changed) {
            this.propagateRenderedState(node, parentRendered, nodesToRefresh);
        }
        this.markNodeForRefresh(nodesToRefresh, node, { updateChildren: false });
        return true;
    }

    /** Handle attribute removal */
    private handleAttributeRemoved(
        entry: AttributeModifiedParams,
        nodesToRefresh: Map<number, NodeRefreshEntry>
    ): boolean {
        if (typeof entry.nodeId !== "number" || typeof entry.name !== "string") {
            return true;
        }

        const node = treeState.nodes.get(entry.nodeId);
        if (!node) {
            requestNodeRefresh(entry.nodeId);
            return true;
        }

        const parentNode =
            typeof node.parentId === "number" ? treeState.nodes.get(node.parentId) : null;
        const parentRendered = parentNode ? parentNode.isRendered !== false : true;
        const layoutChange = applyLayoutEntry(node, entry, parentRendered);

        if (!Array.isArray(node.attributes)) {
            node.attributes = [];
        }

        const next = node.attributes.filter((attr) => attr.name !== entry.name);
        if (next.length !== node.attributes.length) {
            node.attributes = next;
            if (layoutChange.changed) {
                this.propagateRenderedState(node, parentRendered, nodesToRefresh);
            }
            this.markNodeForRefresh(nodesToRefresh, node, { updateChildren: false });
        }
        return true;
    }

    /** Handle character data update */
    private handleCharacterDataUpdated(
        entry: CharacterDataModifiedParams,
        nodesToRefresh: Map<number, NodeRefreshEntry>
    ): boolean {
        if (typeof entry.nodeId !== "number") {
            return true;
        }

        const node = treeState.nodes.get(entry.nodeId);
        if (!node) {
            requestNodeRefresh(entry.nodeId);
            return true;
        }

        const parentNode =
            typeof node.parentId === "number" ? treeState.nodes.get(node.parentId) : null;
        const parentRendered = parentNode ? parentNode.isRendered !== false : true;
        const layoutChange = applyLayoutEntry(node, entry, parentRendered);
        node.textContent = entry.characterData || "";

        if (layoutChange.changed) {
            this.propagateRenderedState(node, parentRendered, nodesToRefresh);
        }
        this.markNodeForRefresh(nodesToRefresh, node, { updateChildren: false });
        return true;
    }

    /** Handle child count update */
    private handleChildCountUpdate(
        entry: ChildCountUpdatedParams,
        nodesToRefresh: Map<number, NodeRefreshEntry>
    ): boolean {
        if (typeof entry.nodeId !== "number") {
            return true;
        }

        const node = treeState.nodes.get(entry.nodeId);
        if (!node) {
            requestNodeRefresh(entry.nodeId);
            return true;
        }

        const parentNode =
            typeof node.parentId === "number" ? treeState.nodes.get(node.parentId) : null;
        const parentRendered = parentNode ? parentNode.isRendered !== false : true;
        const layoutChange = applyLayoutEntry(node, entry, parentRendered);
        const normalizedCount =
            typeof entry.childNodeCount === "number" ? entry.childNodeCount : entry.childCount;

        if (typeof normalizedCount === "number") {
            node.childCount = normalizedCount;
        }

        if (layoutChange.changed) {
            this.propagateRenderedState(node, parentRendered, nodesToRefresh);
        }
        this.markNodeForRefresh(nodesToRefresh, node, { updateChildren: true });
        return true;
    }

    /** Propagate rendered state to descendants */
    private propagateRenderedState(
        node: DOMNode,
        parentRendered: boolean,
        nodesToRefresh: Map<number, NodeRefreshEntry>
    ): void {
        if (!node) {
            return;
        }

        const renderedSelf = resolveRenderedState(
            Array.isArray(node.layoutFlags) ? node.layoutFlags : [],
            typeof node.renderedSelf === "boolean" ? node.renderedSelf : undefined
        );
        const ancestorRendered = typeof parentRendered === "boolean" ? parentRendered : true;
        const isRendered = ancestorRendered && renderedSelf;
        const changed = node.isRendered !== isRendered;

        node.renderedSelf = renderedSelf;
        node.isRendered = isRendered;

        if (changed) {
            this.markNodeForRefresh(nodesToRefresh, node, { updateChildren: false });
        }

        if (Array.isArray(node.children)) {
            for (const child of node.children) {
                this.propagateRenderedState(child, isRendered, nodesToRefresh);
            }
        }
    }

    /** Mark a node for refresh */
    private markNodeForRefresh(
        collection: Map<number, NodeRefreshEntry>,
        node: DOMNode,
        options: { updateChildren?: boolean } = {}
    ): void {
        if (!collection || !node || typeof node.id !== "number") {
            return;
        }
        const updateChildren = options.updateChildren !== false;
        const existing = collection.get(node.id);
        const merged = existing ? existing.updateChildren || updateChildren : updateChildren;
        collection.set(node.id, { node, updateChildren: merged });
    }
}

// =============================================================================
// DOM Update Events
// =============================================================================

/** List of DOM update event methods */
export const domUpdateEvents = [
    "DOM.childNodeInserted",
    "DOM.childNodeRemoved",
    "DOM.attributeModified",
    "DOM.attributeRemoved",
    "DOM.characterDataModified",
    "DOM.childNodeCountUpdated",
] as const;

/** Singleton DOM tree updater instance */
export const domTreeUpdater = new DOMTreeUpdater();

// =============================================================================
// External API
// =============================================================================

/** Dispatch DOM updates from external source */
export function dispatchDomUpdates(payload: string | { events?: unknown[] }): void {
    try {
        if (!payload || !treeState.snapshot || !treeState.snapshot.root) {
            return;
        }

        let bundle: { events?: unknown[] } | null = null;
        try {
            bundle = typeof payload === "string" ? JSON.parse(payload) : payload;
        } catch (error) {
            console.error("failed to parse DOM event bundle", error);
            reportInspectorError("dispatchDomUpdates", error);
            return;
        }

        const events = Array.isArray(bundle?.events) ? bundle!.events : [];
        if (!bundle || !events.length) {
            return;
        }

        domTreeUpdater.enqueueEvents(events as DOMEventEntry[]);
    } catch (error) {
        reportInspectorError("dispatchDomUpdates", error);
        throw error;
    }
}
