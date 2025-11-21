(function () {
    "use strict";

    if (window.webInspectorKit && window.webInspectorKit.__installed)
        return;

    const dom = {
        tree: document.getElementById("dom-tree"),
        empty: document.getElementById("dom-empty"),
        summary: document.getElementById("dom-tree-summary"),
        collapseAll: document.getElementById("collapse-all"),
        expandAll: document.getElementById("expand-all"),
        preview: document.getElementById("node-preview"),
        description: document.getElementById("node-description"),
        attributes: document.getElementById("node-attributes")
    };

    function ensureDomElements() {
        if (!dom.tree)
            dom.tree = document.getElementById("dom-tree");
        if (!dom.empty)
            dom.empty = document.getElementById("dom-empty");
        if (!dom.summary)
            dom.summary = document.getElementById("dom-tree-summary");
        if (!dom.collapseAll)
            dom.collapseAll = document.getElementById("collapse-all");
        if (!dom.expandAll)
            dom.expandAll = document.getElementById("expand-all");
        if (!dom.preview)
            dom.preview = document.getElementById("node-preview");
        if (!dom.description)
            dom.description = document.getElementById("node-description");
        if (!dom.attributes)
            dom.attributes = document.getElementById("node-attributes");
    }

    const NODE_TYPES = {
        ELEMENT_NODE: 1,
        TEXT_NODE: 3,
        COMMENT_NODE: 8
    };
    const INDENT_DEPTH_LIMIT = 6;

    const DEFAULT_REQUEST_DEPTH = 4;
    const REQUEST_CHILDREN_DEPTH = 3;
    const DOM_EVENT_BATCH_LIMIT = 120;
    const DOM_EVENT_TIME_BUDGET = 6;
    const RENDER_BATCH_LIMIT = 180;
    const RENDER_TIME_BUDGET = 8;
    const REFRESH_RETRY_LIMIT = 3;
    const REFRESH_RETRY_WINDOW = 2000;

    const state = {
        snapshot: null,
        nodes: new Map(),
        elements: new Map(),
        openState: new Map(),
        selectedNodeId: null,
        filter: "",
        pendingRefreshRequests: new Set(),
        refreshAttempts: new Map(),
        selectionChain: []
    };

    const renderState = {
        pendingNodes: new Map(),
        frameId: null
    };

    const protocolState = {
        lastId: 0,
        pending: new Map(),
        eventHandlers: new Map(),
        defaultDepth: DEFAULT_REQUEST_DEPTH
    };

    function childRequestDepth() {
        const preferred = Math.max(1, protocolState.defaultDepth);
        return Math.max(1, Math.min(preferred, REQUEST_CHILDREN_DEPTH));
    }

    function timeNow() {
        if (typeof performance !== "undefined" && performance.now)
            return performance.now();
        return Date.now();
    }

    function safeParseJSON(value) {
        if (typeof value !== "string")
            return value;
        try {
            return JSON.parse(value);
        } catch {
            return null;
        }
    }

    function sendProtocolMessage(message) {
        const payload = typeof message === "string" ? message : JSON.stringify(message);
        window.webkit.messageHandlers.webInspector.postMessage({ type: "protocol", payload });
    }

    function sendCommand(method, params = {}) {
        if (!window.webkit.messageHandlers.webInspector)
            return Promise.reject(new Error("host unavailable"));
        const id = ++protocolState.lastId;
        const message = { id, method, params };
        return new Promise((resolve, reject) => {
            protocolState.pending.set(id, { resolve, reject, method });
            sendProtocolMessage(message);
        });
    }

    function dispatchMessageFromBackend(message) {
        const parsed = safeParseJSON(message);
        if (!parsed || typeof parsed !== "object")
            return;
        if (Object.prototype.hasOwnProperty.call(parsed, "id")) {
            const requestId = parsed.id;
            if (typeof requestId !== "number")
                return;
            const pending = protocolState.pending.get(requestId);
            if (!pending)
                return;
            protocolState.pending.delete(requestId);
            if (parsed.error)
                pending.reject(parsed.error);
            else {
                const method = pending.method || "";
                let result = parsed.result;
                if (typeof result === "string")
                    result = safeParseJSON(result) || result;
                if (method === "DOM.requestChildNodes")
                    applySubtree(result);
                pending.resolve(result);
            }
            return;
        }
        if (typeof parsed.method !== "string")
            return;
        emitProtocolEvent(parsed.method, parsed.params || {}, parsed);
    }

    function onProtocolEvent(method, handler) {
        if (!protocolState.eventHandlers.has(method))
            protocolState.eventHandlers.set(method, new Set());
        protocolState.eventHandlers.get(method).add(handler);
    }

    function emitProtocolEvent(method, params, rawMessage) {
        const listeners = protocolState.eventHandlers.get(method);
        if (!listeners || !listeners.size)
            return;
        listeners.forEach(listener => {
            try {
                listener(params, method, rawMessage);
            } catch (error) {
                reportInspectorError(`event:${method}`, error);
            }
        });
    }

    function reportInspectorError(context, error) {
        const details = error && error.stack
            ? error.stack
            : (error && error.message ? error.message : String(error));
        console.error(`[tweetpd-inspector] ${context}:`, error);
        try {
            window.webkit.messageHandlers.webInspector.postMessage({ type: "log", payload: { message: `${context}: ${details}` } });
        } catch {
            // ignore logging failures
        }
    }

    function requestDocument(options = {}) {
        const depthOption = typeof options.depth === "number" && options.depth > 0 ? options.depth : protocolState.defaultDepth;
        const depth = Math.max(1, depthOption);
        protocolState.defaultDepth = depth;
        const preserveState = !!options.preserveState;
        return sendCommand("DOM.getDocument", { depth }).then(result => {
            if (result && result.root)
                setSnapshot(result, { preserveState });
        }).catch(error => reportInspectorError("DOM.getDocument", error));
    }

    function applyMutationBundle(bundle) {
        if (!bundle)
            return;
        let preserveState = true;
        let payload = bundle;
        if (typeof bundle === "object" && bundle.bundle !== undefined) {
            preserveState = bundle.preserveState !== false;
            payload = bundle.bundle;
        }
        const parsed = safeParseJSON(payload);
        if (!parsed || typeof parsed !== "object")
            return;
        if (parsed.snapshot && !parsed.messages) {
            setSnapshot(parsed.snapshot, { preserveState });
            return;
        }
        if (parsed.root && !parsed.messages) {
            setSnapshot(parsed, { preserveState });
            return;
        }
        const messages = Array.isArray(parsed.messages) ? parsed.messages : [];
        messages.forEach(message => dispatchMessageFromBackend(message));
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
            this._textContentAttributeSymbol = Symbol("text-content-attribute");
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
                requestSnapshotReload("missing-snapshot");
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
                if (!handleDomEvent(entry.method, entry.params || {}, nodesToRefresh)) {
                    requiresReload = true;
                    break;
                }
                processed += 1;
                const elapsed = timeNow() - startedAt;
                if (processed >= DOM_EVENT_BATCH_LIMIT || elapsed >= DOM_EVENT_TIME_BUDGET)
                    break;
            }

            this._recentlyInsertedNodes.clear();
            this._recentlyDeletedNodes.clear();
            this._recentlyModifiedNodes.clear();
            this._recentlyModifiedAttributes.clear();

            if (requiresReload) {
                this._pendingEvents = [];
                requestSnapshotReload("dom-sync");
                return;
            }

            refreshTreeAfterDomUpdates(nodesToRefresh);

            if (index < pending.length) {
                this._pendingEvents = pending.slice(index);
                this._debouncer.schedule();
            } else
                this._pendingEvents = [];
        }
    }

    const domTreeUpdater = new DOMTreeUpdater();

    const domUpdateEvents = [
        "DOM.childNodeInserted",
        "DOM.childNodeRemoved",
        "DOM.attributeModified",
        "DOM.attributeRemoved",
        "DOM.characterDataModified",
        "DOM.childNodeCountUpdated"
    ];

    domUpdateEvents.forEach(method => {
        onProtocolEvent(method, params => domTreeUpdater.enqueueEvents([{ method, params }]));
    });

    onProtocolEvent("DOM.setChildNodes", params => applySetChildNodes(params || {}));
    onProtocolEvent("DOM.documentUpdated", () => requestDocument({ preserveState: false }));
    onProtocolEvent("DOM.inspect", params => {
        if (params && typeof params.nodeId === "number")
            selectNode(params.nodeId, { shouldHighlight: false });
    });

    function captureTreeScrollPosition() {
        if (!dom.tree)
            return null;
        return {
            top: dom.tree.scrollTop,
            left: dom.tree.scrollLeft
        };
    }

    function restoreTreeScrollPosition(position) {
        if (!position || !dom.tree)
            return;
        dom.tree.scrollTop = position.top;
        dom.tree.scrollLeft = position.left;
    }

    function normalizeNodeDescriptor(descriptor) {
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
        const childCount = typeof descriptor.childNodeCount === "number"
            ? descriptor.childNodeCount
            : (typeof descriptor.childCount === "number"
                ? descriptor.childCount
                : (Array.isArray(descriptor.children) ? descriptor.children.length : 0));
        const children = [];
        const rawChildren = Array.isArray(descriptor.children) ? descriptor.children : [];

        rawChildren.forEach(child => {
            const normalized = normalizeNodeDescriptor(child);
            if (normalized)
                children.push(normalized);
        });

        if (childCount > children.length) {
            children.push(createPlaceholderNode(resolvedId, childCount - children.length));
        }

        return {
            id: resolvedId,
            nodeName,
            displayName,
            nodeType,
            attributes,
            textContent,
            children,
            childCount,
            placeholderParentId: null
        };
    }

    function deserializeAttributes(rawAttributes) {
        if (!Array.isArray(rawAttributes))
            return [];
        const attributes = [];
        for (let index = 0; index < rawAttributes.length; index += 2) {
            const name = rawAttributes[index] || "";
            const value = rawAttributes[index + 1] || "";
            attributes.push({ name, value });
        }
        return attributes;
    }

    function extractTextContent(nodeType, nodeValue) {
        if (nodeType === NODE_TYPES.TEXT_NODE || nodeType === NODE_TYPES.COMMENT_NODE) {
            const text = (nodeValue || "").trim();
            return text.length ? text : null;
        }
        return null;
    }

    function computeDisplayName(nodeType, nodeName, localName) {
        if (nodeType === NODE_TYPES.ELEMENT_NODE)
            return (localName || nodeName || "").toLowerCase();
        if (nodeType === NODE_TYPES.TEXT_NODE)
            return "#text";
        if (nodeType === NODE_TYPES.COMMENT_NODE)
            return "#comment";
        return nodeName || "";
    }

    function createPlaceholderNode(parentId, remainingCount) {
        return {
            id: -Math.abs(parentId || 0) || -1,
            nodeName: "...",
            displayName: "…",
            nodeType: 0,
            attributes: [],
            textContent: null,
            children: [],
            childCount: remainingCount,
            placeholderParentId: parentId || null
        };
    }

    function setSnapshot(payload, options = {}) {
        try {
            ensureDomElements();
            let snapshot = null;
            if (payload) {
                try {
                    snapshot = typeof payload === "string" ? JSON.parse(payload) : payload;
                } catch (error) {
                    console.error("failed to parse snapshot", error);
                    reportInspectorError("parse-snapshot", error);
                }
            }

            const preserveState = !!options.preserveState && !!state.snapshot;
            const previousSelectionId = state.selectedNodeId;
            const previousFilter = state.filter;
            const preservedOpenState = preserveState ? new Map(state.openState) : new Map();
            const preservedScrollPosition = preserveState ? captureTreeScrollPosition() : null;

            domTreeUpdater.reset();
            state.snapshot = snapshot;
            state.nodes.clear();
            state.elements.clear();
            if (!preserveState) {
                state.openState.clear();
                state.selectionChain = [];
            }
            state.pendingRefreshRequests.clear();
            state.refreshAttempts.clear();
            state.selectedNodeId = preserveState ? state.selectedNodeId : null;
            if (renderState.frameId !== null) {
                cancelAnimationFrame(renderState.frameId);
                renderState.frameId = null;
            }
            renderState.pendingNodes.clear();
            dom.tree.innerHTML = "";

            if (!snapshot || !snapshot.root) {
                dom.empty.hidden = false;
                dom.summary.textContent = "DOM情報が見つかりません";
                dom.preview.textContent = "";
                dom.description.textContent = "";
                dom.attributes.innerHTML = "";
                return;
            }

            dom.empty.hidden = true;

            const normalizedRoot = normalizeNodeDescriptor(snapshot.root);
            if (!normalizedRoot) {
                dom.summary.textContent = "DOM情報が見つかりません";
                return;
            }
            snapshot.root = normalizedRoot;
            indexNode(normalizedRoot, 0, null);
            dom.tree.appendChild(buildNode(normalizedRoot));
            dom.summary.textContent = `DOM Nodes: ${state.nodes.size.toLocaleString()}`;

            if (preserveState && preservedOpenState.size) {
                preservedOpenState.forEach((value, key) => {
                    state.openState.set(key, value);
                });
            }

            state.filter = previousFilter;
            applyFilter();

            const selectionCandidateId = typeof snapshot.selectedNodeId === "number" && snapshot.selectedNodeId > 0
                ? snapshot.selectedNodeId
                : null;
            const selectionCandidatePath = Array.isArray(snapshot.selectedNodePath) ? snapshot.selectedNodePath : null;
            const hasSelectionCandidate = !!selectionCandidateId || !!selectionCandidatePath;
            const selectionChanged = !preserveState || (selectionCandidateId !== null && selectionCandidateId !== previousSelectionId);
            const shouldAutoScrollSelection = hasSelectionCandidate && selectionChanged;
            const selectionOptions = { shouldHighlight: false, autoScroll: shouldAutoScrollSelection };
            let didSelect = false;
            if (preserveState && typeof previousSelectionId === "number") {
                didSelect = selectNode(previousSelectionId, selectionOptions);
            }
            if (!didSelect) {
                if (typeof snapshot.selectedNodeId === "number" && snapshot.selectedNodeId > 0) {
                    didSelect = selectNode(snapshot.selectedNodeId, selectionOptions);
                } else if (Array.isArray(snapshot.selectedNodePath)) {
                    didSelect = selectNodeByPath(snapshot.selectedNodePath, selectionOptions);
                }
            }
            if (!didSelect) {
                updateDetails(null);
                reopenSelectionAncestors();
            }
            state.selectedNodeId = didSelect ? state.selectedNodeId : null;
            if (preservedScrollPosition)
                restoreTreeScrollPosition(preservedScrollPosition);
        } catch (error) {
            reportInspectorError("setSnapshot", error);
            throw error;
        }
    }

    function applySubtree(payload) {
        try {
            ensureDomElements();
            if (!payload)
                return;
            let subtree = null;
            try {
                subtree = typeof payload === "string" ? JSON.parse(payload) : payload;
            } catch (error) {
                console.error("failed to parse subtree", error);
                reportInspectorError("parse-subtree", error);
                return;
            }
            const normalized = normalizeNodeDescriptor(subtree);
            if (!normalized)
                return;
            const target = state.nodes.get(normalized.id);
            if (!target)
                return;

            if (state.pendingRefreshRequests.has(normalized.id))
                state.pendingRefreshRequests.delete(normalized.id);
            state.refreshAttempts.delete(normalized.id);

            const preservedExpansion = preserveExpansionState(normalized, new Map());
            const previousSelectionId = state.selectedNodeId;

            mergeNodeWithSource(target, normalized, target.depth || 0);

            preservedExpansion.forEach((value, key) => {
                state.openState.set(key, value);
            });

            scheduleNodeRender(target);
            setNodeExpanded(target.id, true);

            if (previousSelectionId) {
                if (!selectNode(previousSelectionId, { shouldHighlight: false })) {
                    state.selectedNodeId = null;
                    updateDetails(null);
                }
            } else {
            updateDetails(null);
        }

        applyFilter();
        } catch (error) {
            reportInspectorError("applySubtree", error);
            throw error;
        }
    }

    function applySetChildNodes(params) {
        const parentId = typeof params.parentId === "number" ? params.parentId : params.parentNodeId;
        if (typeof parentId !== "number" || !Array.isArray(params.nodes))
            return;
        const parent = state.nodes.get(parentId);
        if (!parent) {
            requestNodeRefresh(parentId);
            return;
        }
        if (state.pendingRefreshRequests.has(parentId))
            state.pendingRefreshRequests.delete(parentId);
        state.refreshAttempts.delete(parentId);

        const normalizedChildren = [];
        for (const child of params.nodes) {
            const normalized = normalizeNodeDescriptor(child);
            if (normalized)
                normalizedChildren.push(normalized);
        }
        const normalizedParent = {
            ...parent,
            children: normalizedChildren,
            childCount: normalizedChildren.length,
            placeholderParentId: null
        };
        const preservedExpansion = preserveExpansionState(normalizedParent, new Map());
        const previousSelectionId = state.selectedNodeId;

        mergeNodeWithSource(parent, normalizedParent, parent.depth || 0);

        preservedExpansion.forEach((value, key) => {
            state.openState.set(key, value);
        });

        scheduleNodeRender(parent);
        setNodeExpanded(parent.id, true);

        if (previousSelectionId) {
            if (!selectNode(previousSelectionId, { shouldHighlight: false })) {
                state.selectedNodeId = null;
                updateDetails(null);
            }
        } else {
            updateDetails(null);
        }

        applyFilter();
    }

    // 差分適用処理（DOMManager/DOMTreeUpdater相当）
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

    function refreshTreeAfterDomUpdates(nodesToRefresh) {
        if (!nodesToRefresh || !nodesToRefresh.size)
            return;
        const preservedScrollPosition = captureTreeScrollPosition();
        nodesToRefresh.forEach(entry => {
            if (entry && entry.node)
                scheduleNodeRender(entry.node, { updateChildren: entry.updateChildren });
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

    function requestSnapshotReload(reason) {
        const reloadReason = reason || "dom-sync";
        console.debug("[tweetpd-inspector] request reload:", reloadReason);
        requestDocument({ preserveState: true }).catch(() => {});
    }

    function markNodeForRefresh(collection, node, options = {}) {
        if (!collection || !node || typeof node.id !== "number")
            return;
        const updateChildren = options.updateChildren !== false;
        const existing = collection.get(node.id);
        const merged = existing ? (existing.updateChildren || updateChildren) : updateChildren;
        collection.set(node.id, { node, updateChildren: merged });
    }

    function handleDomEvent(method, params, nodesToRefresh) {
        switch (method) {
        case "childNodeInserted":
            return handleNodeInserted(params, nodesToRefresh);
        case "childNodeRemoved":
            return handleNodeRemoved(params, nodesToRefresh);
        case "attributeModified":
            return handleAttributeUpdated(params, nodesToRefresh);
        case "attributeRemoved":
            return handleAttributeRemoved(params, nodesToRefresh);
        case "characterDataModified":
            return handleCharacterDataUpdated(params, nodesToRefresh);
        case "childNodeCountUpdated":
            return handleChildCountUpdate(params, nodesToRefresh);
        default:
            return true;
        }
    }

    function handleNodeInserted(entry, nodesToRefresh) {
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
        const descriptor = normalizeNodeDescriptor(entry.node);
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
        markNodeForRefresh(nodesToRefresh, parent, { updateChildren: true });
        markNodeForRefresh(nodesToRefresh, descriptor, { updateChildren: true });
        return true;
    }

    function handleNodeRemoved(entry, nodesToRefresh) {
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
        markNodeForRefresh(nodesToRefresh, parent, { updateChildren: true });
        if (state.selectedNodeId === entry.nodeId) {
            state.selectedNodeId = null;
            updateDetails(null);
            reopenSelectionAncestors();
        }
        return true;
    }

    function handleAttributeUpdated(entry, nodesToRefresh) {
        if (typeof entry.nodeId !== "number" || typeof entry.name !== "string")
            return true;
        const node = state.nodes.get(entry.nodeId);
        if (!node) {
            requestNodeRefresh(entry.nodeId);
            return true;
        }
        if (!Array.isArray(node.attributes))
            node.attributes = [];
        const value = typeof entry.value === "string" ? entry.value : String(entry.value ?? "");
        const index = node.attributes.findIndex(attr => attr.name === entry.name);
        const record = { name: entry.name, value };
        if (index >= 0)
            node.attributes[index] = record;
        else
            node.attributes.push(record);
        markNodeForRefresh(nodesToRefresh, node, { updateChildren: false });
        return true;
    }

    function handleAttributeRemoved(entry, nodesToRefresh) {
        if (typeof entry.nodeId !== "number" || typeof entry.name !== "string")
            return true;
        const node = state.nodes.get(entry.nodeId);
        if (!node) {
            requestNodeRefresh(entry.nodeId);
            return true;
        }
        if (!Array.isArray(node.attributes))
            node.attributes = [];
        const next = node.attributes.filter(attr => attr.name !== entry.name);
        if (next.length !== node.attributes.length) {
            node.attributes = next;
            markNodeForRefresh(nodesToRefresh, node, { updateChildren: false });
        }
        return true;
    }

    function handleCharacterDataUpdated(entry, nodesToRefresh) {
        if (typeof entry.nodeId !== "number")
            return true;
        const node = state.nodes.get(entry.nodeId);
        if (!node) {
            requestNodeRefresh(entry.nodeId);
            return true;
        }
        node.textContent = entry.characterData || "";
        markNodeForRefresh(nodesToRefresh, node, { updateChildren: false });
        return true;
    }

    function handleChildCountUpdate(entry, nodesToRefresh) {
        if (typeof entry.nodeId !== "number")
            return true;
        const node = state.nodes.get(entry.nodeId);
        if (!node) {
            requestNodeRefresh(entry.nodeId);
            return true;
        }
        const normalizedCount = typeof entry.childNodeCount === "number" ? entry.childNodeCount : entry.childCount;
        if (typeof normalizedCount === "number")
            node.childCount = normalizedCount;
        markNodeForRefresh(nodesToRefresh, node, { updateChildren: true });
        return true;
    }

    function findInsertionIndex(children, previousNodeId) {
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

    function reindexChildren(node) {
        if (!node || !Array.isArray(node.children))
            return;
        node.children.forEach((child, index) => {
            child.childIndex = index;
        });
    }

    function requestNodeRefresh(nodeId, options = {}) {
        if (typeof nodeId !== "number" || nodeId <= 0)
            return;
        if (!state.pendingRefreshRequests)
            state.pendingRefreshRequests = new Set();
        const targetNodeId = typeof options.parentId === "number" && options.parentId > 0 ? options.parentId : nodeId;
        if (state.pendingRefreshRequests.has(targetNodeId))
            return;

        const attempts = state.refreshAttempts.get(targetNodeId) || { count: 0, lastRequested: 0 };
        const now = timeNow();
        if (attempts.count >= REFRESH_RETRY_LIMIT && now - attempts.lastRequested <= REFRESH_RETRY_WINDOW) {
            state.refreshAttempts.delete(targetNodeId);
            requestSnapshotReload("refresh-fallback");
            return;
        }

        state.refreshAttempts.set(targetNodeId, { count: attempts.count + 1, lastRequested: now });
        state.pendingRefreshRequests.add(targetNodeId);
        sendCommand("DOM.requestChildNodes", { nodeId: targetNodeId, depth: childRequestDepth() }).catch(error => {
            reportInspectorError("requestChildNodes", error);
        }).finally(() => {
            state.pendingRefreshRequests.delete(targetNodeId);
        });
    }

    function preserveExpansionState(node, storage = new Map()) {
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

    function mergeNodeWithSource(target, source, depth) {
        if (!target || !source)
            return;
        target.nodeName = source.nodeName;
        target.displayName = source.displayName;
        target.nodeType = source.nodeType;
        target.attributes = Array.isArray(source.attributes) ? source.attributes : [];
        target.textContent = source.textContent || null;
        target.childCount = typeof source.childCount === "number" ? source.childCount : (Array.isArray(source.children) ? source.children.length : 0);
        target.placeholderParentId = source.placeholderParentId || null;
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

    function removeNodeEntry(node) {
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

    function indexNode(node, depth, parentId, childIndex) {
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

    function buildNode(node) {
        const container = document.createElement("div");
        container.className = "tree-node";
        container.dataset.nodeId = node.id;
        container.style.setProperty("--depth", node.depth || 0);
        container.style.setProperty("--indent-depth", clampIndentDepth(node.depth || 0));

        const row = createNodeRow(node);
        container.appendChild(row);

        const childrenContainer = document.createElement("div");
        childrenContainer.className = "tree-node__children";
        container.appendChild(childrenContainer);
        state.elements.set(node.id, container);

        renderChildren(childrenContainer, node, {initialRender: true});

        const expanded = nodeShouldBeExpanded(node);
        setNodeExpanded(node.id, expanded);

        return container;
    }

    function createNodeRow(node) {
        const row = document.createElement("div");
        row.className = "tree-node__row";
        row.setAttribute("role", "treeitem");
        row.setAttribute("aria-level", (node.depth || 0) + 1);
        row.addEventListener("click", event => handleRowClick(event, node));
        row.addEventListener("mouseenter", () => handleRowHover(node));
        row.addEventListener("mouseleave", handleRowLeave);

        const hasChildren = Array.isArray(node.children) && node.children.length > 0;
        const isPlaceholder = node.nodeType === 0 && node.childCount > 0;

        if (hasChildren) {
            const disclosure = document.createElement("button");
            disclosure.className = "tree-node__disclosure";
            disclosure.type = "button";
            disclosure.setAttribute("aria-label", "子ノードの展開/折りたたみ");
            disclosure.addEventListener("click", event => {
                event.stopPropagation();
                toggleNode(node.id);
            });
            row.appendChild(disclosure);
        } else {
            const spacer = document.createElement("span");
            spacer.className = "tree-node__disclosure-spacer";
            spacer.setAttribute("aria-hidden", "true");
            row.appendChild(spacer);
        }

        const label = document.createElement("div");
        label.className = "tree-node__label";
        if (isPlaceholder) {
            row.classList.add("tree-node__row--placeholder");
            const placeholderText = document.createElement("span");
            placeholderText.textContent = `… ${node.childCount} more nodes`;
            label.appendChild(placeholderText);
        } else {
            label.appendChild(createPrimaryLabel(node));
        }
        row.appendChild(label);

        return row;
    }

    function createPlaceholderElement(node) {
        const wrapper = document.createElement("div");
        wrapper.className = "tree-node__placeholder";
        wrapper.style.padding = "0 16px 16px 16px";

        const placeholderButton = document.createElement("button");
        placeholderButton.textContent = "読み込む";
        placeholderButton.className = "control-button";
        placeholderButton.style.width = "auto";
        placeholderButton.addEventListener("click", event => {
            event.stopPropagation();
            requestChildren(node);
        });

        wrapper.appendChild(placeholderButton);
        return wrapper;
    }

    function renderChildren(container, node, {initialRender = false} = {}) {
        if (!container)
            return;

        const isPlaceholder = node.nodeType === 0 && node.childCount > 0;
        if (isPlaceholder) {
            container.replaceChildren(createPlaceholderElement(node));
            return;
        }

        if (initialRender) {
            container.innerHTML = "";
            if (Array.isArray(node.children)) {
                for (const child of node.children)
                    container.appendChild(buildNode(child));
            }
            return;
        }

        container.querySelectorAll(":scope > .tree-node__placeholder").forEach(element => element.remove());

        const existingElements = new Map();
        container.querySelectorAll(":scope > .tree-node").forEach(element => {
            const id = Number(element.dataset.nodeId);
            if (!Number.isNaN(id))
                existingElements.set(id, element);
        });

        const desiredChildren = Array.isArray(node.children) ? node.children : [];
        const orderedElements = [];
        for (const child of desiredChildren) {
            let childElement = state.elements.get(child.id);
            if (!childElement) {
                childElement = buildNode(child);
            }
            orderedElements.push(childElement);
            existingElements.delete(child.id);
        }

        existingElements.forEach((element, id) => {
            element.remove();
            state.elements.delete(id);
        });

        let referenceNode = container.firstChild;
        for (const element of orderedElements) {
            if (element === referenceNode) {
                referenceNode = referenceNode ? referenceNode.nextSibling : null;
                continue;
            }
            container.insertBefore(element, referenceNode);
        }
    }

    function refreshNodeElement(node, options = {}) {
        const updateChildren = options.updateChildren !== false;
        const element = state.elements.get(node.id);
        if (!element)
            return;

        element.dataset.nodeId = node.id;
        element.style.setProperty("--depth", node.depth || 0);
        element.style.setProperty("--indent-depth", clampIndentDepth(node.depth || 0));

        const newRow = createNodeRow(node);
        const existingRow = element.querySelector(":scope > .tree-node__row");
        if (existingRow)
            existingRow.replaceWith(newRow);
        else
            element.insertBefore(newRow, element.firstChild);

        let childrenContainer = element.querySelector(":scope > .tree-node__children");
        if (!childrenContainer) {
            childrenContainer = document.createElement("div");
            childrenContainer.className = "tree-node__children";
            element.appendChild(childrenContainer);
        }
        if (updateChildren)
            renderChildren(childrenContainer, node);

        setNodeExpanded(node.id, nodeShouldBeExpanded(node));
    }

    function scheduleNodeRender(node, options = {}) {
        if (!node || typeof node.id === "undefined")
            return;
        const updateChildren = options.updateChildren !== false;
        const existing = renderState.pendingNodes.get(node.id);
        const merged = existing ? (existing.updateChildren || updateChildren) : updateChildren;
        renderState.pendingNodes.set(node.id, { node, updateChildren: merged });
        if (renderState.frameId !== null)
            return;
        renderState.frameId = requestAnimationFrame(() => processPendingNodeRenders());
    }

    function processPendingNodeRenders() {
        renderState.frameId = null;
        const pending = Array.from(renderState.pendingNodes.values());
        renderState.pendingNodes.clear();
        if (!pending.length)
            return;

        pending.sort((a, b) => (a.node.depth || 0) - (b.node.depth || 0));

        let index = 0;
        const startedAt = timeNow();

        while (index < pending.length) {
            const item = pending[index];
            index += 1;
            if (!item || !item.node)
                continue;
            refreshNodeElement(item.node, { updateChildren: item.updateChildren });
            const elapsed = timeNow() - startedAt;
            if (index >= RENDER_BATCH_LIMIT || elapsed >= RENDER_TIME_BUDGET)
                break;
        }

        if (index < pending.length) {
            for (; index < pending.length; ++index) {
                const item = pending[index];
                if (!item || !item.node)
                    continue;
                const existing = renderState.pendingNodes.get(item.node.id);
                const merged = existing ? (existing.updateChildren || item.updateChildren) : item.updateChildren;
                renderState.pendingNodes.set(item.node.id, { node: item.node, updateChildren: merged });
            }
            renderState.frameId = requestAnimationFrame(() => processPendingNodeRenders());
        }
    }

    function clampIndentDepth(depth) {
        if (!Number.isFinite(depth))
            return 0;
        if (depth < 0)
            return 0;
        return Math.min(depth, INDENT_DEPTH_LIMIT);
    }

    function nodeShouldBeExpanded(node) {
        if (state.openState.has(node.id))
            return state.openState.get(node.id);
        if (shouldCollapseByDefault(node))
            return false;
        return (node.depth || 0) <= 1;
    }

    function shouldCollapseByDefault(node) {
        if (!node)
            return false;
        const name = (node.displayName || node.nodeName || "").toLowerCase();
        return name === "head";
    }

    function setNodeExpanded(nodeId, expanded) {
        state.openState.set(nodeId, expanded);
        const element = state.elements.get(nodeId);
        if (!element)
            return;
        if (expanded)
            element.classList.remove("is-collapsed");
        else
            element.classList.add("is-collapsed");
        element.setAttribute("aria-expanded", expanded ? "true" : "false");
        const row = element.firstElementChild;
        if (row) {
            const disclosure = row.querySelector(".tree-node__disclosure");
            if (disclosure)
                disclosure.setAttribute("aria-expanded", expanded ? "true" : "false");
        }
    }

    function toggleNode(nodeId) {
        const node = state.nodes.get(nodeId);
        if (!node)
            return;
        const current = nodeShouldBeExpanded(node);
        setNodeExpanded(nodeId, !current);
    }

    function handleRowClick(event, node) {
        if (node.nodeType === 0 && node.childCount > 0) {
            requestChildren(node);
            return;
        }
        selectNode(node.id);
    }

    function sendHighlight(nodeId) {
        if (!nodeId || nodeId <= 0)
            return;
        sendCommand("DOM.highlightNode", { nodeId }).catch(() => {});
    }

    function clearPageHighlight() {
        sendCommand("Overlay.hideHighlight", {}).catch(() => {});
    }

    function handleRowHover(node) {
        if (node.id > 0)
            sendHighlight(node.id);
    }

    function handleRowLeave() {
        clearPageHighlight();
    }

    function scheduleSelectionScroll(nodeId) {
        if (!nodeId || !dom.tree)
            return;
        requestAnimationFrame(() => {
            scrollSelectionIntoView(nodeId);
        });
    }

    function scrollSelectionIntoView(nodeId) {
        const container = dom.tree;
        const element = state.elements.get(nodeId);
        if (!container || !element)
            return false;
        if (state.selectedNodeId !== nodeId)
            return true;
        const row = element.querySelector(".tree-node__row") || element;
        const containerRect = container.getBoundingClientRect();
        const targetRect = row.getBoundingClientRect();
        const margin = 8;
        const relativeTop = targetRect.top - containerRect.top;
        const relativeBottom = targetRect.bottom - containerRect.top;
        const relativeLeft = targetRect.left - containerRect.left;
        const relativeRight = targetRect.right - containerRect.left;

        const viewportHeight = window.visualViewport.height;
        const viewportWidth = window.visualViewport.width;
        const visibleHeight = Math.max(1, Math.min(containerRect.bottom, viewportHeight) - Math.max(0, containerRect.top));
        const visibleWidth = Math.max(1, Math.min(containerRect.right, viewportWidth) - Math.max(0, containerRect.left));

        const contentTop = container.scrollTop + relativeTop;
        const contentBottom = container.scrollTop + relativeBottom;
        const contentLeft = container.scrollLeft + relativeLeft;
        const contentRight = container.scrollLeft + relativeRight;

        const visibleTop = container.scrollTop;
        const visibleBottom = container.scrollTop + visibleHeight;
        const visibleLeft = container.scrollLeft;
        const visibleRight = container.scrollLeft + visibleWidth;

        const isContainerScrollableV = Math.abs(container.scrollHeight - container.clientHeight) > 1;
        const isContainerScrollableH = Math.abs(container.scrollWidth - container.clientWidth) > 1;
        const visibleInViewportV = targetRect.bottom > margin && targetRect.top < viewportHeight - margin;
        const visibleInViewportH = targetRect.right > margin && targetRect.left < viewportWidth - margin;
        const verticallyVisible = contentBottom > visibleTop + margin && contentTop < visibleBottom - margin;
        const horizontallyVisible = contentRight > visibleLeft + margin && contentLeft < visibleRight - margin;
        if (verticallyVisible && horizontallyVisible)
            return true;

        let nextTop = container.scrollTop;
        if (!verticallyVisible) {
            if (isContainerScrollableV) {
                const desiredTop = contentTop - visibleHeight / 3;
                const maxTop = Math.max(0, container.scrollHeight - visibleHeight);
                nextTop = Math.min(Math.max(0, desiredTop), maxTop);
            } else if (!visibleInViewportV) {
                const desiredPageTop = (window.scrollY || 0) + targetRect.top - viewportHeight / 3;
                window.scrollTo({ top: Math.max(0, desiredPageTop), behavior: "auto" });
            }
        }
        let nextLeft = container.scrollLeft;
        if (!horizontallyVisible) {
            if (isContainerScrollableH) {
                const desiredLeft = contentLeft - visibleWidth / 5;
                const maxLeft = Math.max(0, container.scrollWidth - visibleWidth);
                nextLeft = Math.min(Math.max(0, desiredLeft), maxLeft);
            } else if (!visibleInViewportH) {
                const desiredPageLeft = (window.scrollX || 0) + targetRect.left - viewportWidth / 5;
                window.scrollTo({ left: Math.max(0, desiredPageLeft), behavior: "auto" });
            }
        }
        const alreadyAtTarget = Math.abs(container.scrollTop - nextTop) < 0.5 && Math.abs(container.scrollLeft - nextLeft) < 0.5;
        if (alreadyAtTarget)
            return true;
        container.scrollTo({ top: nextTop, left: nextLeft, behavior: "auto" });
        return false;
    }

    function selectNode(nodeId, options = {}) {
        if (!state.nodes.has(nodeId))
            return false;
        const { shouldHighlight = true, autoScroll = false } = options;
        revealAncestors(nodeId);
        const previous = state.elements.get(state.selectedNodeId);
        if (previous)
            previous.classList.remove("is-selected");

        const element = state.elements.get(nodeId);
        if (element)
            element.classList.add("is-selected");

        state.selectedNodeId = nodeId;
        setNodeExpanded(nodeId, true);
        const node = state.nodes.get(nodeId);
        updateDetails(node);
        updateSelectionChain(nodeId);

        if (nodeId > 0 && shouldHighlight)
            sendHighlight(nodeId);

        if (autoScroll)
            scheduleSelectionScroll(nodeId);

        return true;
    }

    function updateSelectionChain(nodeId) {
        const chain = [];
        let current = state.nodes.get(nodeId);
        while (current) {
            chain.unshift(current.id);
            if (!current.parentId)
                break;
            current = state.nodes.get(current.parentId);
        }
        state.selectionChain = chain;
    }

    function reopenSelectionAncestors() {
        if (!Array.isArray(state.selectionChain) || !state.selectionChain.length)
            return;
        const nextChain = [];
        for (let index = 0; index < state.selectionChain.length; ++index) {
            const nodeId = state.selectionChain[index];
            const node = state.nodes.get(nodeId);
            if (!node)
                break;
            nextChain.push(nodeId);
            setNodeExpanded(nodeId, true);
        }
        state.selectionChain = nextChain;
    }

    function revealAncestors(nodeId) {
        let current = state.nodes.get(nodeId);
        while (current && current.parentId) {
            setNodeExpanded(current.parentId, true);
            current = state.nodes.get(current.parentId);
        }
    }

    function resolveNodeByPath(path) {
        if (!state.snapshot || !state.snapshot.root)
            return null;
        if (!Array.isArray(path))
            return null;
        let node = state.snapshot.root;
        if (!path.length)
            return node;
        for (const index of path) {
            if (!node.children || index < 0 || index >= node.children.length)
                return null;
            node = node.children[index];
        }
        return node;
    }

    function selectNodeByPath(path, options = {}) {
        const target = resolveNodeByPath(path);
        if (!target)
            return false;
        selectNode(target.id, options);
        return true;
    }

    function requestChildren(node) {
        if (!node.placeholderParentId && node.id > 0) {
            sendCommand("DOM.requestChildNodes", { nodeId: node.id, depth: childRequestDepth() }).catch(error => {
                reportInspectorError("requestChildNodes", error);
            });
            return;
        }
        const parent = node.placeholderParentId || node.parentId || node.id;
        sendCommand("DOM.requestChildNodes", { nodeId: parent, depth: childRequestDepth() }).catch(error => {
            reportInspectorError("requestChildNodes", error);
        });
    }

    function createPrimaryLabel(node) {
        const fragment = document.createDocumentFragment();
        if (node.nodeType === NODE_TYPES.TEXT_NODE) {
            const span = document.createElement("span");
            span.className = "tree-node__text";
            span.textContent = trimText(node.textContent || "");
            fragment.appendChild(span);
            return fragment;
        }
        if (node.nodeType === NODE_TYPES.COMMENT_NODE) {
            const span = document.createElement("span");
            span.className = "tree-node__text";
            span.textContent = `<!-- ${trimText(node.textContent || "")} -->`;
            fragment.appendChild(span);
            return fragment;
        }

        const tag = document.createElement("span");
        tag.className = "tree-node__name";
        tag.textContent = `<${node.displayName}>`;
        fragment.appendChild(tag);

        if (Array.isArray(node.attributes)) {
            for (const attr of node.attributes) {
                const attrName = document.createElement("span");
                attrName.className = "tree-node__attribute";
                attrName.textContent = ` ${attr.name}`;
                fragment.appendChild(attrName);

                const attrValue = document.createElement("span");
                attrValue.className = "tree-node__value";
                attrValue.textContent = `="${attr.value}"`;
                fragment.appendChild(attrValue);
            }
        }

        fragment.appendChild(document.createTextNode(">"));
        return fragment;
    }

    function updateDetails(node) {
        if (!node) {
            dom.preview.textContent = "";
            dom.description.textContent = "";
            dom.attributes.innerHTML = "";
            return;
        }
        dom.preview.textContent = renderPreview(node);
        dom.description.textContent = node.textContent ? trimText(node.textContent, 240) : "";

        dom.attributes.innerHTML = "";
        if (Array.isArray(node.attributes) && node.attributes.length) {
            for (const attr of node.attributes) {
                const dt = document.createElement("dt");
                dt.textContent = attr.name;
                const dd = document.createElement("dd");
                dd.textContent = attr.value;
                dom.attributes.appendChild(dt);
                dom.attributes.appendChild(dd);
            }
        } else {
            const dt = document.createElement("dt");
            dt.textContent = "属性";
            const dd = document.createElement("dd");
            dd.textContent = "なし";
            dom.attributes.appendChild(dt);
            dom.attributes.appendChild(dd);
        }
    }

    function renderPreview(node) {
        switch (node.nodeType) {
        case NODE_TYPES.TEXT_NODE:
            return trimText(node.textContent || "");
        case NODE_TYPES.COMMENT_NODE:
            return `<!-- ${trimText(node.textContent || "")} -->`;
        default:
            const attrs = (node.attributes || [])
                .map(attr => `${attr.name}="${attr.value}"`)
                .join(" ");
            const attrText = attrs ? " " + attrs : "";
            return `<${node.displayName}${attrText}>`;
        }
    }

    function trimText(text, limit = 80) {
        if (!text)
            return "";
        const normalized = text.replace(/\s+/g, " ").trim();
        return normalized.length > limit ? `${normalized.slice(0, limit)}…` : normalized;
    }

    function setSearchTerm(value) {
        const normalized = typeof value === "string" ? value.trim().toLowerCase() : "";
        if (normalized === state.filter)
            return;
        state.filter = normalized;
        applyFilter();
    }

    function applyFilter() {
        if (!state.snapshot || !state.snapshot.root)
            return;
        let matches = 0;
        const term = state.filter;

        function filterNode(node) {
            let nodeMatches = false;
            if (!term) {
                nodeMatches = true;
            } else {
                const label = renderPreview(node).toLowerCase();
                const text = (node.textContent || "").toLowerCase();
                nodeMatches = label.includes(term) || text.includes(term);
            }

            let childMatches = false;
            if (Array.isArray(node.children)) {
                for (const child of node.children) {
                    if (filterNode(child))
                        childMatches = true;
                }
            }

            const shouldShow = nodeMatches || childMatches || !term;
            const element = state.elements.get(node.id);
            if (element)
                element.classList.toggle("is-filtered-out", !shouldShow);

            if (nodeMatches)
                matches += 1;

            return nodeMatches || childMatches;
        }

        filterNode(state.snapshot.root);

        if (term) {
            dom.summary.textContent = `Filter: "${term}" (${matches} 件)`;
        } else {
            dom.summary.textContent = `DOM Nodes: ${state.nodes.size.toLocaleString()}`;
        }
    }

    function collapseAll() {
        state.nodes.forEach((_value, nodeId) => {
            const defaultExpanded = nodeId === state.snapshot?.root?.id;
            setNodeExpanded(nodeId, !!defaultExpanded);
        });
    }

    function expandAll() {
        state.nodes.forEach((_value, nodeId) => {
            setNodeExpanded(nodeId, true);
        });
    }

    function attachEventListeners() {
        if (dom.collapseAll)
            dom.collapseAll.addEventListener("click", collapseAll);
        if (dom.expandAll)
            dom.expandAll.addEventListener("click", expandAll);
        try {
            window.webkit.messageHandlers.webInspector.postMessage({ type: "ready" });
        } catch {
            // ignore
        }
        requestDocument({ preserveState: false }).catch(() => {});
    }

    function setPreferredDepth(depth) {
        if (typeof depth === "number" && depth > 0)
            protocolState.defaultDepth = Math.max(1, depth);
    }

    const webInspectorKit = {
        dispatchMessageFromBackend,
        applyMutationBundle,
        requestDocument,
        setSearchTerm,
        setPreferredDepth,
        __installed: true
    };

    Object.defineProperty(window, "webInspectorKit", {
        value: Object.freeze(webInspectorKit),
        writable: false,
        configurable: false
    });

    document.addEventListener("DOMContentLoaded", attachEventListeners);
})();
