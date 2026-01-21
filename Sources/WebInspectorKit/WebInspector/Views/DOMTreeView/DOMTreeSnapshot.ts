(function(scope) {
    const {
        ensureDomElements,
        clearRenderState,
        dom,
        protocolState,
        treeState: state
    } = scope.DOMTreeState;
    const {safeParseJSON} = scope.DOMTreeUtilities;
    const {
        dispatchMessageFromBackend,
        onProtocolEvent,
        reportInspectorError,
        sendCommand,
        setRequestChildNodesHandler
    } = scope.DOMTreeProtocol;
    const {
        domTreeUpdater,
        domUpdateEvents,
        requestNodeRefresh,
        setReloadHandler
    } = scope.DOMTreeUpdates;
    const {
        indexNode,
        mergeNodeWithSource,
        normalizeNodeDescriptor,
        preserveExpansionState
    } = scope.DOMTreeModel;
    const {
        applyFilter,
        buildNode,
        captureTreeScrollPosition,
        reopenSelectionAncestors,
        restoreTreeScrollPosition,
        scheduleNodeRender,
        selectNode,
        selectNodeByPath,
        setNodeExpanded,
        updateDetails
    } = scope.DOMTreeViewSupport;

    async function requestDocument(options: { depth?: number; preserveState?: boolean } = {}) {
        const depth = typeof options.depth === "number" ? options.depth : protocolState.snapshotDepth;
        protocolState.snapshotDepth = depth;
        const preserveState = !!options.preserveState;
        try {
            const result = await sendCommand("DOM.getDocument", {depth});
            if (result && result.root) {
                setSnapshot(result, {preserveState});
            }
        } catch (error) {
            reportInspectorError("DOM.getDocument", error);
        }
    }

    function applyMutationBundle(bundle) {
        if (!bundle) {
            return;
        }
        let preserveState = true;
        let payload = bundle;
        if (typeof bundle === "object" && bundle.bundle !== undefined) {
            preserveState = bundle.preserveState !== false;
            payload = bundle.bundle;
        }
        const parsed = safeParseJSON(payload);
        if (!parsed || typeof parsed !== "object") {
            return;
        }
        if (typeof parsed.version === "number" && parsed.version !== 1) {
            return;
        }
        if (parsed.kind === "snapshot") {
            if (parsed.snapshot) {
                setSnapshot(parsed.snapshot, {preserveState});
            }
            return;
        }
        if (parsed.kind === "mutation") {
            const events = Array.isArray(parsed.events) ? parsed.events : [];
            events.forEach(message => dispatchMessageFromBackend(message));
        }
    }

    function applyMutationBundles(bundles) {
        if (!bundles) {
            return;
        }
        if (!Array.isArray(bundles)) {
            applyMutationBundle(bundles);
            return;
        }
        for (const entry of bundles) {
            applyMutationBundle(entry);
        }
    }

    function setSnapshot(payload, options: { preserveState?: boolean } = {}) {
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
            clearRenderState();
            dom.tree.innerHTML = "";

            if (!snapshot || !snapshot.root) {
                dom.empty.hidden = false;
                updateDetails(null);
                return;
            }

            dom.empty.hidden = true;

            const normalizedRoot = normalizeNodeDescriptor(snapshot.root);
            if (!normalizedRoot) {
                return;
            }
            snapshot.root = normalizedRoot;
            indexNode(normalizedRoot, 0, null);
            dom.tree.appendChild(buildNode(normalizedRoot));

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
            const selectionChanged = hasSelectionCandidate && selectionCandidateId !== null && selectionCandidateId !== previousSelectionId;
            const shouldPreferSnapshotSelection = !preserveState || selectionChanged;
            const shouldAutoScrollSelection = hasSelectionCandidate && shouldPreferSnapshotSelection;
            const selectionOptions = {shouldHighlight: false, autoScroll: shouldAutoScrollSelection};

            const selectSnapshotCandidate = () => {
                if (typeof selectionCandidateId === "number" && selectionCandidateId > 0) {
                    return selectNode(selectionCandidateId, selectionOptions);
                }
                if (Array.isArray(selectionCandidatePath)) {
                    return selectNodeByPath(selectionCandidatePath, selectionOptions);
                }
                return false;
            };

            let didSelect = false;
            if (shouldPreferSnapshotSelection) {
                didSelect = selectSnapshotCandidate();
            }

            if (!didSelect && preserveState && typeof previousSelectionId === "number") {
                didSelect = selectNode(previousSelectionId, selectionOptions);
            }

            if (!didSelect && !shouldPreferSnapshotSelection) {
                didSelect = selectSnapshotCandidate();
            }

            if (!didSelect) {
                updateDetails(null);
                reopenSelectionAncestors();
            }
            state.selectedNodeId = didSelect ? state.selectedNodeId : null;
            if (preservedScrollPosition) {
                restoreTreeScrollPosition(preservedScrollPosition);
            }
        } catch (error) {
            reportInspectorError("setSnapshot", error);
            throw error;
        }
    }

    function applySubtree(payload) {
        try {
            ensureDomElements();
            if (!payload) {
                return;
            }
            let subtree = null;
            try {
                subtree = typeof payload === "string" ? JSON.parse(payload) : payload;
            } catch (error) {
                console.error("failed to parse subtree", error);
                reportInspectorError("parse-subtree", error);
                return;
            }
            const targetId = subtree && typeof subtree === "object"
                ? (typeof subtree.nodeId === "number" ? subtree.nodeId : (typeof subtree.id === "number" ? subtree.id : null))
                : null;
            const parentRendered = (() => {
                if (typeof targetId !== "number") {
                    return true;
                }
                const existing = state.nodes.get(targetId);
                if (!existing || typeof existing.parentId !== "number") {
                    return true;
                }
                const parent = state.nodes.get(existing.parentId);
                return !parent || parent.isRendered !== false;
            })();
            const normalized = normalizeNodeDescriptor(subtree, parentRendered);
            if (!normalized) {
                return;
            }
            const target = state.nodes.get(normalized.id);
            if (!target) {
                return;
            }

            if (state.pendingRefreshRequests.has(normalized.id)) {
                state.pendingRefreshRequests.delete(normalized.id);
            }
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
                if (!selectNode(previousSelectionId, {shouldHighlight: false})) {
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
        if (typeof parentId !== "number" || !Array.isArray(params.nodes)) {
            return;
        }
        const parent = state.nodes.get(parentId);
        if (!parent) {
            requestNodeRefresh(parentId);
            return;
        }
        if (state.pendingRefreshRequests.has(parentId)) {
            state.pendingRefreshRequests.delete(parentId);
        }
        state.refreshAttempts.delete(parentId);

        const normalizedChildren = [];
        const parentRendered = parent.isRendered !== false;
        for (const child of params.nodes) {
            const normalized = normalizeNodeDescriptor(child, parentRendered);
            if (normalized) {
                normalizedChildren.push(normalized);
            }
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
            if (!selectNode(previousSelectionId, {shouldHighlight: false})) {
                state.selectedNodeId = null;
                updateDetails(null);
            }
        } else {
            updateDetails(null);
        }

        applyFilter();
    }

    function requestSnapshotReload(reason) {
        const reloadReason = reason || "dom-sync";
        console.debug("[WebInspectorKit] request reload:", reloadReason);
        void requestDocument({preserveState: true});
    }

    function setPreferredDepth(depth) {
        if (typeof depth === "number") {
            protocolState.snapshotDepth = depth;
        }
    }

    function registerProtocolHandlers() {
        const {domUpdateEvents: events, domTreeUpdater: updater} = scope.DOMTreeUpdates;
        events.forEach(method => {
            onProtocolEvent(method, params => updater.enqueueEvents([{method, params}]));
        });
        onProtocolEvent("DOM.setChildNodes", params => applySetChildNodes(params || {}));
        onProtocolEvent("DOM.documentUpdated", () => requestDocument({preserveState: false}));
        onProtocolEvent("DOM.inspect", params => {
            if (params && typeof params.nodeId === "number") {
                selectNode(params.nodeId, {shouldHighlight: false});
            }
        });
        setRequestChildNodesHandler(applySubtree);
    }

    setReloadHandler(requestSnapshotReload);

    scope.DOMTreeSnapshot = {
        requestDocument,
        applyMutationBundle,
        applyMutationBundles,
        setSnapshot,
        applySubtree,
        applySetChildNodes,
        requestSnapshotReload,
        setPreferredDepth,
        registerProtocolHandlers
    };
})(window.DOMTree || (window.DOMTree = {}));
