(function(scope) {
    const {
        DOM_EVENT_BATCH_LIMIT,
        DOM_EVENT_TIME_BUDGET,
        REFRESH_RETRY_LIMIT,
        REFRESH_RETRY_WINDOW,
        TEXT_CONTENT_ATTRIBUTE,
        childRequestDepth,
        treeState: state
    } = scope.DOMTreeState;
    const {
        applyLayoutEntry,
        resolveRenderedState,
        timeNow
    } = scope.DOMTreeUtilities;
    const {reportInspectorError, sendCommand} = scope.DOMTreeProtocol;
    const {
        findInsertionIndex,
        indexNode,
        normalizeNodeDescriptor,
        reindexChildren,
        removeNodeEntry
    } = scope.DOMTreeModel;
    const {
        applyFilter,
        captureTreeScrollPosition,
        reopenSelectionAncestors,
        scheduleNodeRender,
        updateDetails,
        restoreTreeScrollPosition
    } = scope.DOMTreeViewSupport;

    let reloadHandler = null;

    function setReloadHandler(handler) {
        reloadHandler = typeof handler === "function" ? handler : null;
    }

    function triggerReload(reason) {
        if (typeof reloadHandler === "function")
            reloadHandler(reason);
    }

    async function requestNodeRefresh(nodeId, options = {}) {
        if (typeof nodeId !== "number" || nodeId <= 0)
            return;
        if (!state.pendingRefreshRequests)
            state.pendingRefreshRequests = new Set();
        const targetNodeId = typeof options.parentId === "number" && options.parentId > 0 ? options.parentId : nodeId;
        if (state.pendingRefreshRequests.has(targetNodeId))
            return;

        const attempts = state.refreshAttempts.get(targetNodeId) || {count: 0, lastRequested: 0};
        const now = timeNow();
        if (attempts.count >= REFRESH_RETRY_LIMIT && now - attempts.lastRequested <= REFRESH_RETRY_WINDOW) {
            state.refreshAttempts.delete(targetNodeId);
            triggerReload("refresh-fallback");
            return;
        }

        state.refreshAttempts.set(targetNodeId, {count: attempts.count + 1, lastRequested: now});
        state.pendingRefreshRequests.add(targetNodeId);
        try {
            await sendCommand("DOM.requestChildNodes", {nodeId: targetNodeId, depth: childRequestDepth()});
        } catch (error) {
            reportInspectorError("requestChildNodes", error);
        } finally {
            state.pendingRefreshRequests.delete(targetNodeId);
        }
    }

    function refreshTreeAfterDomUpdates(nodesToRefresh, modifiedAttrsByNode = new Map()) {
        if (!nodesToRefresh || !nodesToRefresh.size)
            return;
        const preservedScrollPosition = captureTreeScrollPosition();
        nodesToRefresh.forEach(entry => {
            if (entry && entry.node) {
                const modifiedAttributes = modifiedAttrsByNode ? modifiedAttrsByNode.get(entry.node.id) : null;
                scheduleNodeRender(entry.node, {updateChildren: entry.updateChildren, modifiedAttributes});
            }
        });
        if (state.selectedNodeId) {
            const selectedNode = state.nodes.get(state.selectedNodeId);
            if (selectedNode) {
                updateDetails(selectedNode);
            } else {
                state.selectedNodeId = null;
                updateDetails(null);
            }
        }
        applyFilter();
        if (preservedScrollPosition)
            restoreTreeScrollPosition(preservedScrollPosition);
    }

    class FrameDebouncer {
        constructor(callback) {
            this._callback = callback;
            this._frameId = null;
        }

        schedule() {
            if (this._frameId !== null)
                return;
            this._frameId = requestAnimationFrame(() => {
                this._frameId = null;
                this._callback();
            });
        }

        cancel() {
            if (this._frameId === null)
                return;
            cancelAnimationFrame(this._frameId);
            this._frameId = null;
        }
    }

    class DOMTreeUpdater {
        constructor() {
            this._pendingEvents = [];
            this._recentlyInsertedNodes = new Map();
            this._recentlyDeletedNodes = new Map();
            this._recentlyModifiedNodes = new Set();
            this._recentlyModifiedAttributes = new Map();
            this._textContentAttributeSymbol = TEXT_CONTENT_ATTRIBUTE;
            this._debouncer = new FrameDebouncer(() => this._processPendingEvents());
        }

        reset() {
            this._pendingEvents = [];
            this._recentlyInsertedNodes.clear();
            this._recentlyDeletedNodes.clear();
            this._recentlyModifiedNodes.clear();
            this._recentlyModifiedAttributes.clear();
            this._debouncer.cancel();
        }

        enqueueEvents(events) {
            if (!Array.isArray(events) || !events.length)
                return;
            if (!state.snapshot || !state.snapshot.root) {
                triggerReload("missing-snapshot");
                return;
            }
            for (const event of events)
                this._recordEvent(event);
            this._debouncer.schedule();
        }

        _recordEvent(event) {
            if (!event || typeof event.method !== "string")
                return;
            const method = event.method.startsWith("DOM.") ? event.method.slice(4) : event.method;
            const params = event.params || {};
            this._pendingEvents.push({method, params});
            switch (method) {
            case "childNodeInserted":
                if (params.node && typeof params.node.nodeId === "number")
                    this._recentlyInsertedNodes.set(params.node.nodeId, params);
                break;
            case "childNodeRemoved":
                if (typeof params.nodeId === "number")
                    this._recentlyDeletedNodes.set(params.nodeId, params);
                break;
            case "attributeModified":
            case "attributeRemoved":
                this._nodeAttributeModified(params.nodeId, params.name);
                break;
            case "characterDataModified":
                this._nodeAttributeModified(params.nodeId, this._textContentAttributeSymbol);
                break;
            default:
                break;
            }
        }

        _nodeAttributeModified(nodeId, attribute) {
            if (typeof nodeId !== "number" || !attribute)
                return;
            if (!this._recentlyModifiedAttributes.has(attribute))
                this._recentlyModifiedAttributes.set(attribute, new Set());
            this._recentlyModifiedAttributes.get(attribute).add(nodeId);
            this._recentlyModifiedNodes.add(nodeId);
        }

        _cloneModifiedAttributes() {
            const snapshot = new Map();
            this._recentlyModifiedAttributes.forEach((nodes, attribute) => {
                if (!nodes || !nodes.size)
                    return;
                snapshot.set(attribute, new Set(nodes));
            });
            return snapshot;
        }

        _buildModifiedAttributesByNode(attributeToNodes) {
            const nodesToAttributes = new Map();
            attributeToNodes.forEach((nodes, attribute) => {
                nodes.forEach(nodeId => {
                    if (typeof nodeId !== "number")
                        return;
                    if (!nodesToAttributes.has(nodeId))
                        nodesToAttributes.set(nodeId, new Set());
                    nodesToAttributes.get(nodeId).add(attribute);
                });
            });
            return nodesToAttributes;
        }

        _processPendingEvents() {
            if (!state.snapshot || !state.snapshot.root) {
                this.reset();
                return;
            }
            if (!this._pendingEvents.length)
                return;

            const nodesToRefresh = new Map();
            let requiresReload = false;
            const pending = this._pendingEvents;
            let index = 0;
            let processed = 0;
            const startedAt = timeNow();

            while (index < pending.length) {
                const entry = pending[index];
                index += 1;
                if (!entry || typeof entry.method !== "string")
                    continue;
                if (!this._handleDomEvent(entry.method, entry.params || {}, nodesToRefresh)) {
                    requiresReload = true;
                    break;
                }
                processed += 1;
                const elapsed = timeNow() - startedAt;
                if (processed >= DOM_EVENT_BATCH_LIMIT || elapsed >= DOM_EVENT_TIME_BUDGET)
                    break;
            }

            const modifiedAttributes = this._cloneModifiedAttributes();
            const modifiedAttrsByNode = this._buildModifiedAttributesByNode(modifiedAttributes);
            this._recentlyInsertedNodes.clear();
            this._recentlyDeletedNodes.clear();
            this._recentlyModifiedNodes.clear();
            this._recentlyModifiedAttributes.clear();

            if (requiresReload) {
                this._pendingEvents = [];
                triggerReload("dom-sync");
                return;
            }

            refreshTreeAfterDomUpdates(nodesToRefresh, modifiedAttrsByNode);

            if (index < pending.length) {
                this._pendingEvents = pending.slice(index);
                this._debouncer.schedule();
            } else
                this._pendingEvents = [];
        }

        _handleDomEvent(method, params, nodesToRefresh) {
            switch (method) {
            case "childNodeInserted":
                return this._handleNodeInserted(params, nodesToRefresh);
            case "childNodeRemoved":
                return this._handleNodeRemoved(params, nodesToRefresh);
            case "attributeModified":
                return this._handleAttributeUpdated(params, nodesToRefresh);
            case "attributeRemoved":
                return this._handleAttributeRemoved(params, nodesToRefresh);
            case "characterDataModified":
                return this._handleCharacterDataUpdated(params, nodesToRefresh);
            case "childNodeCountUpdated":
                return this._handleChildCountUpdate(params, nodesToRefresh);
            default:
                return true;
            }
        }

        _handleNodeInserted(entry, nodesToRefresh) {
            const parentId = typeof entry.parentId === "number" ? entry.parentId : entry.parentNodeId;
            if (!entry.node || typeof parentId !== "number")
                return true;
            const parent = state.nodes.get(parentId);
            if (!parent) {
                requestNodeRefresh(parentId);
                return true;
            }
            if (!Array.isArray(parent.children))
                parent.children = [];
            const children = parent.children;
            const descriptor = normalizeNodeDescriptor(entry.node, parent.isRendered !== false);
            if (!descriptor || typeof descriptor.id !== "number")
                return true;

            const existingIndex = children.findIndex(child => child.id === descriptor.id);
            const preservedExpansion = state.openState.has(descriptor.id) ? state.openState.get(descriptor.id) : undefined;
            if (existingIndex >= 0) {
                const [existingNode] = children.splice(existingIndex, 1);
                removeNodeEntry(existingNode);
            }

            const insertionIndex = findInsertionIndex(children, entry.previousNodeId);
            children.splice(insertionIndex, 0, descriptor);
            parent.childCount = Math.max(parent.childCount || children.length, children.length);
            indexNode(descriptor, (parent.depth || 0) + 1, parent.id, insertionIndex);
            reindexChildren(parent);
            if (preservedExpansion !== undefined)
                state.openState.set(descriptor.id, preservedExpansion);
            this._markNodeForRefresh(nodesToRefresh, parent, {updateChildren: true});
            this._markNodeForRefresh(nodesToRefresh, descriptor, {updateChildren: true});
            return true;
        }

        _handleNodeRemoved(entry, nodesToRefresh) {
            const parentId = typeof entry.parentId === "number" ? entry.parentId : entry.parentNodeId;
            if (typeof parentId !== "number" || typeof entry.nodeId !== "number")
                return true;
            const parent = state.nodes.get(parentId);
            if (!parent) {
                requestNodeRefresh(parentId);
                return true;
            }
            if (!Array.isArray(parent.children))
                return true;
            const index = parent.children.findIndex(child => child.id === entry.nodeId);
            if (index === -1)
                return true;
            const [removed] = parent.children.splice(index, 1);
            parent.childCount = Math.max(parent.children.length, parent.childCount || 0);
            reindexChildren(parent);
            removeNodeEntry(removed);
            this._markNodeForRefresh(nodesToRefresh, parent, {updateChildren: true});
            if (state.selectedNodeId === entry.nodeId) {
                state.selectedNodeId = null;
                updateDetails(null);
                reopenSelectionAncestors();
            }
            return true;
        }

        _handleAttributeUpdated(entry, nodesToRefresh) {
            if (typeof entry.nodeId !== "number" || typeof entry.name !== "string")
                return true;
            const node = state.nodes.get(entry.nodeId);
            if (!node) {
                requestNodeRefresh(entry.nodeId);
                return true;
            }
            const parentNode = typeof node.parentId === "number" ? state.nodes.get(node.parentId) : null;
            const parentRendered = parentNode ? parentNode.isRendered !== false : true;
            const layoutChange = applyLayoutEntry(node, entry, parentRendered);
            if (!Array.isArray(node.attributes))
                node.attributes = [];
            const value = typeof entry.value === "string" ? entry.value : String(entry.value ?? "");
            const index = node.attributes.findIndex(attr => attr.name === entry.name);
            const record = {name: entry.name, value};
            if (index >= 0)
                node.attributes[index] = record;
            else
                node.attributes.push(record);
            if (layoutChange.changed)
                this._propagateRenderedState(node, parentRendered, nodesToRefresh);
            this._markNodeForRefresh(nodesToRefresh, node, {updateChildren: false});
            return true;
        }

        _handleAttributeRemoved(entry, nodesToRefresh) {
            if (typeof entry.nodeId !== "number" || typeof entry.name !== "string")
                return true;
            const node = state.nodes.get(entry.nodeId);
            if (!node) {
                requestNodeRefresh(entry.nodeId);
                return true;
            }
            const parentNode = typeof node.parentId === "number" ? state.nodes.get(node.parentId) : null;
            const parentRendered = parentNode ? parentNode.isRendered !== false : true;
            const layoutChange = applyLayoutEntry(node, entry, parentRendered);
            if (!Array.isArray(node.attributes))
                node.attributes = [];
            const next = node.attributes.filter(attr => attr.name !== entry.name);
            if (next.length !== node.attributes.length) {
                node.attributes = next;
                if (layoutChange.changed)
                    this._propagateRenderedState(node, parentRendered, nodesToRefresh);
                this._markNodeForRefresh(nodesToRefresh, node, {updateChildren: false});
            }
            return true;
        }

        _handleCharacterDataUpdated(entry, nodesToRefresh) {
            if (typeof entry.nodeId !== "number")
                return true;
            const node = state.nodes.get(entry.nodeId);
            if (!node) {
                requestNodeRefresh(entry.nodeId);
                return true;
            }
            const parentNode = typeof node.parentId === "number" ? state.nodes.get(node.parentId) : null;
            const parentRendered = parentNode ? parentNode.isRendered !== false : true;
            const layoutChange = applyLayoutEntry(node, entry, parentRendered);
            node.textContent = entry.characterData || "";
            if (layoutChange.changed)
                this._propagateRenderedState(node, parentRendered, nodesToRefresh);
            this._markNodeForRefresh(nodesToRefresh, node, {updateChildren: false});
            return true;
        }

        _handleChildCountUpdate(entry, nodesToRefresh) {
            if (typeof entry.nodeId !== "number")
                return true;
            const node = state.nodes.get(entry.nodeId);
            if (!node) {
                requestNodeRefresh(entry.nodeId);
                return true;
            }
            const parentNode = typeof node.parentId === "number" ? state.nodes.get(node.parentId) : null;
            const parentRendered = parentNode ? parentNode.isRendered !== false : true;
            const layoutChange = applyLayoutEntry(node, entry, parentRendered);
            const normalizedCount = typeof entry.childNodeCount === "number" ? entry.childNodeCount : entry.childCount;
            if (typeof normalizedCount === "number")
                node.childCount = normalizedCount;
            if (layoutChange.changed)
                this._propagateRenderedState(node, parentRendered, nodesToRefresh);
            this._markNodeForRefresh(nodesToRefresh, node, {updateChildren: true});
            return true;
        }

        _propagateRenderedState(node, parentRendered, nodesToRefresh) {
            if (!node)
                return;
            const renderedSelf = resolveRenderedState(Array.isArray(node.layoutFlags) ? node.layoutFlags : [], typeof node.renderedSelf === "boolean" ? node.renderedSelf : undefined);
            const ancestorRendered = typeof parentRendered === "boolean" ? parentRendered : true;
            const isRendered = ancestorRendered && renderedSelf;
            const changed = node.isRendered !== isRendered;
            node.renderedSelf = renderedSelf;
            node.isRendered = isRendered;
            if (changed)
                this._markNodeForRefresh(nodesToRefresh, node, {updateChildren: false});
            if (Array.isArray(node.children)) {
                for (const child of node.children)
                    this._propagateRenderedState(child, isRendered, nodesToRefresh);
            }
        }

        _markNodeForRefresh(collection, node, options = {}) {
            if (!collection || !node || typeof node.id !== "number")
                return;
            const updateChildren = options.updateChildren !== false;
            const existing = collection.get(node.id);
            const merged = existing ? (existing.updateChildren || updateChildren) : updateChildren;
            collection.set(node.id, {node, updateChildren: merged});
        }
    }

    const domUpdateEvents = [
        "DOM.childNodeInserted",
        "DOM.childNodeRemoved",
        "DOM.attributeModified",
        "DOM.attributeRemoved",
        "DOM.characterDataModified",
        "DOM.childNodeCountUpdated"
    ];

    const domTreeUpdater = new DOMTreeUpdater();

    function dispatchDomUpdates(payload) {
        try {
            if (!payload || !state.snapshot || !state.snapshot.root)
                return;
            let bundle = null;
            try {
                bundle = typeof payload === "string" ? JSON.parse(payload) : payload;
            } catch (error) {
                console.error("failed to parse DOM event bundle", error);
                reportInspectorError("dispatchDomUpdates", error);
                return;
            }
            const events = Array.isArray(bundle.events) ? bundle.events : (Array.isArray(bundle.messages) ? bundle.messages : []);
            if (!bundle || !events.length)
                return;
            domTreeUpdater.enqueueEvents(events);
        } catch (error) {
            reportInspectorError("dispatchDomUpdates", error);
            throw error;
        }
    }

    scope.DOMTreeUpdates = {
        setReloadHandler,
        requestNodeRefresh,
        refreshTreeAfterDomUpdates,
        DOMTreeUpdater,
        domUpdateEvents,
        domTreeUpdater,
        dispatchDomUpdates
    };
})(window.DOMTree || (window.DOMTree = {}));
