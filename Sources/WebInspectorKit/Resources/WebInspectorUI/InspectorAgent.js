(function() {
    "use strict";

    if (window.webInspectorKit && window.webInspectorKit.__installed)
        return;

    var inspector = {
        map: new Map(),
        nodeMap: new WeakMap(),
        overlay: null,
        overlayTarget: null,
        pendingOverlayUpdate: false,
        overlayAutoUpdateConfigured: false,
        overlayMutationObserver: null,
        overlayMutationObserverActive: false,
        nextId: 1,
        pendingSelectionPath: null,
        selectionState: null,
        cursorBackup: null,
        windowClickBlockerHandler: null,
        windowClickBlockerRemovalTimer: null,
        windowClickBlockerPendingRelease: false,
        snapshotAutoUpdateObserver: null,
        snapshotAutoUpdateEnabled: false,
        snapshotAutoUpdatePending: false,
        snapshotAutoUpdateTimer: null,
        snapshotAutoUpdateDebounce: 600,
        snapshotAutoUpdateMaxDepth: 4,
        snapshotAutoUpdateReason: "mutation",
        pendingMutations: [],
        snapshotAutoUpdateSuppressedCount: 0,
        snapshotAutoUpdatePendingWhileSuppressed: false,
        snapshotAutoUpdatePendingReason: null,
        documentURL: null
    };

    function rememberNode(node) {
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

    function describe(node, depth, maxDepth, selectionPath) {
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
            var limit = 150;
            var selectionIndex = Array.isArray(selectionPath) && selectionPath.length > depth ? selectionPath[depth] : -1;
            for (var childIndex = 0; childIndex < node.childNodes.length; ++childIndex) {
                var childNode = node.childNodes[childIndex];
                var mustInclude = selectionIndex === childIndex;
                if (descriptor.children.length >= limit && !mustInclude)
                    break;
                var childDescriptor = describe(childNode, depth + 1, maxDepth, selectionPath);
                if (childDescriptor)
                    descriptor.children.push(childDescriptor);
            }
        }

        return descriptor;
    }

    function findNodeByPath(tree, path) {
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

    function computeNodePath(node) {
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

    function rectForNode(node) {
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

    function highlightSelectionNode(node) {
        setOverlayTarget(node || null);
    }

    function enableSelectionCursor() {
        if (!inspector.cursorBackup) {
            inspector.cursorBackup = {
                html: document.documentElement ? document.documentElement.style.cursor : "",
                body: document.body ? document.body.style.cursor : ""
            };
        }
        if (document.documentElement)
            document.documentElement.style.cursor = "crosshair";
        if (document.body)
            document.body.style.cursor = "crosshair";
    }

    function restoreSelectionCursor() {
        var backup = inspector.cursorBackup || {};
        if (document.documentElement)
            document.documentElement.style.cursor = backup.html || "";
        if (document.body)
            document.body.style.cursor = backup.body || "";
        inspector.cursorBackup = null;
    }

    function interceptEvent(event) {
        if (!event)
            return;
        if (event.cancelable)
            event.preventDefault();
        event.stopPropagation();
        if (event.stopImmediatePropagation)
            event.stopImmediatePropagation();
    }

    function installWindowClickBlocker() {
        if (inspector.windowClickBlockerHandler)
            return;
        inspector.windowClickBlockerPendingRelease = false;
        var handler = function(event) {
            interceptEvent(event);
            if (!inspector.selectionState && inspector.windowClickBlockerPendingRelease)
                uninstallWindowClickBlocker();
        };
        inspector.windowClickBlockerHandler = handler;
        window.addEventListener("click", handler, true);
    }

    function uninstallWindowClickBlocker() {
        inspector.windowClickBlockerPendingRelease = false;
        if (inspector.windowClickBlockerRemovalTimer) {
            clearTimeout(inspector.windowClickBlockerRemovalTimer);
            inspector.windowClickBlockerRemovalTimer = null;
        }
        if (!inspector.windowClickBlockerHandler)
            return;
        window.removeEventListener("click", inspector.windowClickBlockerHandler, true);
        inspector.windowClickBlockerHandler = null;
    }

    function scheduleWindowClickBlockerRelease() {
        if (!inspector.windowClickBlockerHandler)
            return;
        inspector.windowClickBlockerPendingRelease = true;
        if (inspector.windowClickBlockerRemovalTimer)
            return;
        inspector.windowClickBlockerRemovalTimer = setTimeout(function() {
            uninstallWindowClickBlocker();
        }, 350);
    }

    function suppressSnapshotAutoUpdate(reason) {
        if (!inspector)
            return;
        var nextCount = (inspector.snapshotAutoUpdateSuppressedCount || 0) + 1;
        inspector.snapshotAutoUpdateSuppressedCount = nextCount;
        if (nextCount > 1)
            return;
        if (inspector.snapshotAutoUpdatePending && inspector.snapshotAutoUpdateTimer) {
            clearTimeout(inspector.snapshotAutoUpdateTimer);
            inspector.snapshotAutoUpdateTimer = null;
        }
        if (inspector.snapshotAutoUpdatePending) {
            inspector.snapshotAutoUpdatePendingWhileSuppressed = true;
            inspector.snapshotAutoUpdatePendingReason = inspector.snapshotAutoUpdateReason || reason || inspector.snapshotAutoUpdatePendingReason || "mutation";
            inspector.snapshotAutoUpdatePending = false;
        }
    }

    function resumeSnapshotAutoUpdate(reason) {
        if (!inspector)
            return;
        var current = inspector.snapshotAutoUpdateSuppressedCount || 0;
        if (!current)
            return;
        current -= 1;
        inspector.snapshotAutoUpdateSuppressedCount = current;
        if (current > 0)
            return;
        var pending = inspector.snapshotAutoUpdatePendingWhileSuppressed;
        var pendingReason = inspector.snapshotAutoUpdatePendingReason || reason || inspector.snapshotAutoUpdateReason || "mutation";
        inspector.snapshotAutoUpdatePendingWhileSuppressed = false;
        inspector.snapshotAutoUpdatePendingReason = null;
        if (pending && inspector.snapshotAutoUpdateEnabled)
            scheduleSnapshotAutoUpdate(pendingReason);
    }

    function startElementSelection() {
        cancelElementSelection();
        return new Promise(function(resolve) {
            var state = {
                active: true,
                latestTarget: null,
                bindings: []
            };
            inspector.selectionState = state;

            suppressSnapshotAutoUpdate("selection");
            enableSelectionCursor();
            installWindowClickBlocker();

            var listenerOptions = {capture: true, passive: false};

            function bind(type, handler) {
                document.addEventListener(type, handler, listenerOptions);
                state.bindings.push([type, handler]);
            }

            function removeListeners() {
                for (var i = 0; i < state.bindings.length; ++i) {
                    var binding = state.bindings[i];
                    document.removeEventListener(binding[0], binding[1], listenerOptions);
                }
                state.bindings = [];
            }

            function finish(payload) {
                if (!state.active)
                    return;
                state.active = false;
                removeListeners();
                restoreSelectionCursor();
                scheduleWindowClickBlockerRelease();
                inspector.selectionState = null;
                resumeSnapshotAutoUpdate("selection");
                resolve(payload);
            }

            function cancelSelection() {
                inspector.pendingSelectionPath = null;
                clearHighlight();
                finish({ cancelled: true, requiredDepth: 0 });
            }

            state.cancel = cancelSelection;

            function selectTarget(target) {
                var node = target || state.latestTarget;
                if (!node) {
                    cancelSelection();
                    return;
                }
                var path = computeNodePath(node);
                if (!path) {
                    cancelSelection();
                    return;
                }
                inspector.pendingSelectionPath = path;
                highlightSelectionNode(node);
                finish({ cancelled: false, requiredDepth: path.length });
            }

            function resolveEventTarget(event) {
                if (!event)
                    return null;
                if (event.touches && event.touches.length) {
                    var touch = event.touches[event.touches.length - 1];
                    var candidate = document.elementFromPoint(touch.clientX, touch.clientY);
                    return candidate || event.target || null;
                }
                if (event.changedTouches && event.changedTouches.length) {
                    var changed = event.changedTouches[event.changedTouches.length - 1];
                    var fallback = document.elementFromPoint(changed.clientX, changed.clientY);
                    return fallback || event.target || null;
                }
                if (typeof event.clientX === "number" && typeof event.clientY === "number") {
                    var pointTarget = document.elementFromPoint(event.clientX, event.clientY);
                    return pointTarget || event.target || null;
                }
                return event.target || null;
            }

            function updateLatestTarget(event) {
                var target = resolveEventTarget(event);
                if (!target)
                    return;
                state.latestTarget = target;
                highlightSelectionNode(target);
            }

            function handlePointerLikeMove(event) {
                interceptEvent(event);
                updateLatestTarget(event);
            }

            function handlePointerLikeDown(event) {
                interceptEvent(event);
                updateLatestTarget(event);
            }

            function handlePointerLikeUp(event) {
                interceptEvent(event);
                selectTarget(resolveEventTarget(event));
            }

            function handleTouchCancel(event) {
                interceptEvent(event);
                cancelSelection();
            }

            function handleKeyDown(event) {
                if (event.key === "Escape") {
                    interceptEvent(event);
                    cancelSelection();
                }
            }

            function preventDefaultHandler(event) {
                interceptEvent(event);
            }

            var moveEvents = ["pointermove", "mousemove", "touchmove"];
            var downEvents = ["pointerdown", "mousedown", "touchstart"];
            var upEvents = ["pointerup", "mouseup", "touchend"];
            var blockOnlyEvents = ["click", "contextmenu", "submit", "dragstart"];

            moveEvents.forEach(function(type) { bind(type, handlePointerLikeMove); });
            downEvents.forEach(function(type) { bind(type, handlePointerLikeDown); });
            upEvents.forEach(function(type) { bind(type, handlePointerLikeUp); });
            bind("touchcancel", handleTouchCancel);
            blockOnlyEvents.forEach(function(type) { bind(type, preventDefaultHandler); });
            bind("keydown", handleKeyDown);
        });
    }

    function cancelElementSelection() {
        if (inspector.selectionState && inspector.selectionState.cancel) {
            inspector.selectionState.cancel();
            inspector.selectionState = null;
            return true;
        }
        inspector.pendingSelectionPath = null;
        restoreSelectionCursor();
        uninstallWindowClickBlocker();
        return false;
    }

    function ensureOverlay() {
        var overlay = inspector.overlay;
        if (overlay && overlay.parentNode)
            return overlay;
        overlay = document.createElement("div");
        overlay.style.position = "fixed";
        overlay.style.background = "rgba(0, 122, 255, 0.25)";
        overlay.style.border = "2px solid rgba(0, 122, 255, 0.9)";
        overlay.style.zIndex = 2147483647;
        overlay.style.pointerEvents = "none";
        overlay.style.boxSizing = "border-box";
        overlay.style.display = "none";
        document.documentElement.appendChild(overlay);
        inspector.overlay = overlay;
        return overlay;
    }

    function hideOverlay() {
        var overlay = inspector.overlay;
        if (overlay)
            overlay.style.display = "none";
    }

    function installOverlayAutoUpdateHandlers() {
        if (inspector.overlayAutoUpdateConfigured)
            return;
        inspector.overlayAutoUpdateConfigured = true;

        function handleViewportChange() {
            scheduleOverlayUpdate();
        }

        window.addEventListener("scroll", handleViewportChange, true);
        document.addEventListener("scroll", handleViewportChange, true);
        window.addEventListener("resize", handleViewportChange);
        if (window.visualViewport) {
            window.visualViewport.addEventListener("scroll", handleViewportChange);
            window.visualViewport.addEventListener("resize", handleViewportChange);
        }
    }

    function connectOverlayMutationObserver() {
        if (inspector.overlayMutationObserverActive)
            return;
        if (typeof MutationObserver === "undefined")
            return;
        if (!inspector.overlayMutationObserver) {
            inspector.overlayMutationObserver = new MutationObserver(function() {
                scheduleOverlayUpdate();
            });
        }
        var target = document.documentElement || document.body;
        if (!target)
            return;
        inspector.overlayMutationObserver.observe(target, {attributes: true, childList: true, subtree: true, characterData: true});
        inspector.overlayMutationObserverActive = true;
    }

    function disconnectOverlayMutationObserver() {
        if (!inspector.overlayMutationObserverActive || !inspector.overlayMutationObserver)
            return;
        inspector.overlayMutationObserver.disconnect();
        inspector.overlayMutationObserverActive = false;
    }

    function autoSnapshotHandler() {
        if (!window.webkit || !window.webkit.messageHandlers)
            return null;
        return window.webkit.messageHandlers.webInspectorSnapshotUpdate || null;
    }

    function mutationUpdateHandler() {
        if (!window.webkit || !window.webkit.messageHandlers)
            return null;
        return window.webkit.messageHandlers.webInspectorMutationUpdate || null;
    }

    function ensureAutoSnapshotObserver() {
        if (inspector.snapshotAutoUpdateObserver)
            return inspector.snapshotAutoUpdateObserver;
        if (typeof MutationObserver === "undefined")
            return null;
        inspector.snapshotAutoUpdateObserver = new MutationObserver(function(mutations) {
            if (!mutations || !mutations.length)
                return;
            var queue = inspector.pendingMutations;
            if (!Array.isArray(queue))
                queue = inspector.pendingMutations = [];
            for (var i = 0; i < mutations.length; ++i)
                queue.push(mutations[i]);
            scheduleSnapshotAutoUpdate("mutation");
        });
        return inspector.snapshotAutoUpdateObserver;
    }

    function connectAutoSnapshotObserver() {
        var observer = ensureAutoSnapshotObserver();
        if (!observer)
            return;
        var target = document.documentElement || document.body;
        if (!target)
            return;
        observer.observe(target, {childList: true, subtree: true, attributes: true, characterData: true});
    }

    function disconnectAutoSnapshotObserver() {
        var observer = inspector.snapshotAutoUpdateObserver;
        if (!observer)
            return;
        observer.disconnect();
    }

    function scheduleSnapshotAutoUpdate(reason) {
        if (!inspector.snapshotAutoUpdateEnabled)
            return;
        var effectiveReason = reason || inspector.snapshotAutoUpdateReason || "mutation";
        inspector.snapshotAutoUpdateReason = effectiveReason;
        if ((inspector.snapshotAutoUpdateSuppressedCount || 0) > 0) {
            inspector.snapshotAutoUpdatePendingWhileSuppressed = true;
            inspector.snapshotAutoUpdatePendingReason = effectiveReason;
            return;
        }
        if (inspector.snapshotAutoUpdatePending)
            return;
        inspector.snapshotAutoUpdatePending = true;
        var delay = inspector.snapshotAutoUpdateDebounce;
        if (typeof delay !== "number" || delay < 50)
            delay = 50;
        inspector.snapshotAutoUpdateTimer = setTimeout(function() {
            inspector.snapshotAutoUpdatePending = false;
            inspector.snapshotAutoUpdateTimer = null;
            if (!inspector.snapshotAutoUpdateEnabled)
                return;
            sendAutoSnapshotUpdate();
        }, delay);
    }

    function sendFullSnapshot(reason) {
        var handler = autoSnapshotHandler();
        if (!handler)
            return;
        try {
            var snapshot = captureDOM(inspector.snapshotAutoUpdateMaxDepth || 4);
            handler.postMessage({
                snapshot: snapshot,
                reason: reason || inspector.snapshotAutoUpdateReason || "mutation"
            });
        } catch (error) {
            console.error("auto snapshot failed", error);
        }
    }

    function buildDomMutationEvents(records, maxDepth) {
        if (!Array.isArray(records) || !records.length)
            return [];
        var events = [];
        var childCountUpdates = new Map();
        var descriptorDepth = Math.min(1, Math.max(0, typeof maxDepth === "number" ? maxDepth : 1));
        var eventLimit = 600;
        var compactMode = false;
        for (var i = 0; i < records.length; ++i) {
            var record = records[i];
            if (!record || !record.target)
                continue;
            var targetId = rememberNode(record.target);
            if (!targetId)
                continue;
            switch (record.type) {
            case "attributes":
                var attrName = record.attributeName || "";
                if (!attrName)
                    break;
                var attrValue = record.target.getAttribute(attrName);
                if (attrValue === null || typeof attrValue === "undefined") {
                    events.push({
                        method: "DOM.attributeRemoved",
                        params: {
                            nodeId: targetId,
                            name: attrName
                        }
                    });
                } else {
                    events.push({
                        method: "DOM.attributeModified",
                        params: {
                            nodeId: targetId,
                            name: attrName,
                            value: String(attrValue)
                        }
                    });
                }
                break;
            case "characterData":
                events.push({
                    method: "DOM.characterDataModified",
                    params: {
                        nodeId: targetId,
                        characterData: record.target.textContent || ""
                    }
                });
                break;
            case "childList":
                if (!compactMode && record.removedNodes && record.removedNodes.length) {
                    for (var r = 0; r < record.removedNodes.length; ++r) {
                        var removedNodeId = rememberNode(record.removedNodes[r]);
                        if (!removedNodeId)
                            continue;
                        events.push({
                            method: "DOM.childNodeRemoved",
                            params: {
                                parentNodeId: targetId,
                                nodeId: removedNodeId
                            }
                        });
                    }
                }
                if (!compactMode && record.addedNodes && record.addedNodes.length) {
                    var referenceNode = record.previousSibling || null;
                    for (var a = 0; a < record.addedNodes.length; ++a) {
                        var addedNode = record.addedNodes[a];
                        var descriptor = describe(addedNode, 0, descriptorDepth, null);
                        if (!descriptor)
                            continue;
                        var previousNodeId = referenceNode ? rememberNode(referenceNode) : 0;
                        events.push({
                            method: "DOM.childNodeInserted",
                            params: {
                                parentNodeId: targetId,
                                previousNodeId: previousNodeId || 0,
                                node: descriptor
                            }
                        });
                        referenceNode = addedNode;
                    }
                }
                childCountUpdates.set(targetId, record.target.childNodes ? record.target.childNodes.length : 0);
                break;
            default:
                break;
            }
            if (!compactMode && events.length > eventLimit)
                compactMode = true;
        }

        if (childCountUpdates.size) {
            childCountUpdates.forEach(function(count, nodeId) {
                events.push({
                    method: "DOM.childNodeCountUpdated",
                    params: {
                        nodeId: nodeId,
                        childNodeCount: count
                    }
                });
            });
        }

        if (events.length > eventLimit) {
            var compact = [];
            childCountUpdates.forEach(function(count, nodeId) {
                compact.push({
                    method: "DOM.childNodeCountUpdated",
                    params: {
                        nodeId: nodeId,
                        childNodeCount: count
                    }
                });
            });
            for (var e = 0; e < events.length; ++e) {
                var event = events[e];
                if (!event)
                    continue;
                if (event.method === "DOM.childNodeInserted" || event.method === "DOM.childNodeRemoved" || event.method === "DOM.childNodeCountUpdated")
                    continue;
                compact.push(event);
            }
            return compact;
        }

        return events;
    }

    function sendAutoSnapshotUpdate() {
        var handler = mutationUpdateHandler();
        var pending = Array.isArray(inspector.pendingMutations) ? inspector.pendingMutations.slice() : [];
        inspector.pendingMutations = [];
        if (!handler) {
            sendFullSnapshot("handler-missing");
            return;
        }
        if (!pending.length) {
            sendFullSnapshot("mutation");
            return;
        }
        var messages = buildDomMutationEvents(pending, 0);
        if (!messages.length) {
            sendFullSnapshot("fallback");
            return;
        }
        var reason = inspector.snapshotAutoUpdateReason || "mutation";
        var chunkSize = 200;
        try {
            for (var offset = 0; offset < messages.length; offset += chunkSize) {
                var payload = {
                    type: "protocolEvents",
                    reason: reason,
                    messages: messages.slice(offset, offset + chunkSize)
                };
                handler.postMessage({
                    bundle: JSON.stringify(payload)
                });
            }
        } catch (error) {
            console.error("mutation update failed", error);
            sendFullSnapshot("post-error");
        }
    }

    function configureAutoSnapshotOptions(options) {
        if (!options)
            return;
        if (typeof options.maxDepth === "number" && options.maxDepth > 0)
            inspector.snapshotAutoUpdateMaxDepth = options.maxDepth;
        if (typeof options.debounce === "number" && options.debounce >= 50)
            inspector.snapshotAutoUpdateDebounce = options.debounce;
    }

    function setAutoSnapshotEnabled(enabled, options) {
        configureAutoSnapshotOptions(options || null);
        var shouldEnable = !!enabled;
        if (shouldEnable === inspector.snapshotAutoUpdateEnabled)
            return inspector.snapshotAutoUpdateEnabled;
        inspector.snapshotAutoUpdateEnabled = shouldEnable;
        if (shouldEnable) {
            if (!Array.isArray(inspector.pendingMutations))
                inspector.pendingMutations = [];
            connectAutoSnapshotObserver();
            scheduleSnapshotAutoUpdate("initial");
        } else {
            if (inspector.snapshotAutoUpdateTimer) {
                clearTimeout(inspector.snapshotAutoUpdateTimer);
                inspector.snapshotAutoUpdateTimer = null;
            }
            inspector.pendingMutations = [];
            inspector.snapshotAutoUpdatePending = false;
            inspector.snapshotAutoUpdateSuppressedCount = 0;
            inspector.snapshotAutoUpdatePendingWhileSuppressed = false;
            inspector.snapshotAutoUpdatePendingReason = null;
            disconnectAutoSnapshotObserver();
        }
        return inspector.snapshotAutoUpdateEnabled;
    }

    function triggerSnapshotUpdate(reason) {
        scheduleSnapshotAutoUpdate(reason || "manual");
    }

    function updateOverlayForCurrentTarget() {
        var target = inspector.overlayTarget;
        if (!target) {
            hideOverlay();
            return;
        }
        if (!document.contains(target)) {
            inspector.overlayTarget = null;
            hideOverlay();
            disconnectOverlayMutationObserver();
            return;
        }
        var overlay = ensureOverlay();
        var rect = rectForNode(target);
        if (!rect) {
            hideOverlay();
            return;
        }
        overlay.style.display = "block";
        overlay.style.left = rect.left + "px";
        overlay.style.top = rect.top + "px";
        overlay.style.width = rect.width + "px";
        overlay.style.height = rect.height + "px";
    }

    function scheduleOverlayUpdate() {
        if (!inspector.overlayTarget)
            return;
        if (inspector.pendingOverlayUpdate)
            return;
        inspector.pendingOverlayUpdate = true;
        requestAnimationFrame(function() {
            inspector.pendingOverlayUpdate = false;
            updateOverlayForCurrentTarget();
        });
    }

    function setOverlayTarget(node) {
        if (inspector.overlayTarget === node) {
            scheduleOverlayUpdate();
            return;
        }
        inspector.overlayTarget = node || null;
        inspector.pendingOverlayUpdate = false;
        if (inspector.overlayTarget) {
            installOverlayAutoUpdateHandlers();
            connectOverlayMutationObserver();
            updateOverlayForCurrentTarget();
        } else {
            disconnectOverlayMutationObserver();
            hideOverlay();
        }
    }

    function captureDOM(maxDepth) {
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

    function captureDOMSubtree(identifier, maxDepth) {
        var map = inspector.map;
        if (!map || !map.size)
            return "";
        var node = map.get(identifier);
        if (!node)
            return "";
        var tree = describe(node, 0, maxDepth || 4, null);
        return JSON.stringify(tree);
    }

    function viewportMetrics() {
        var vv = window.visualViewport;
        var top = vv ? vv.pageTop : (window.scrollY || 0);
        var left = vv ? vv.pageLeft : (window.scrollX || 0);
        var width = vv ? vv.width : (window.innerWidth || document.documentElement.clientWidth || 0);
        var height = vv ? vv.height : (window.innerHeight || document.documentElement.clientHeight || 0);
        return {top: top, left: left, width: width, height: height};
    }

    function scrollRectIntoViewIfNeeded(rect) {
        if (!rect)
            return false;
        var margin = 8;
        var viewport = viewportMetrics();
        var rectTop = rect.top + viewport.top;
        var rectLeft = rect.left + viewport.left;
        var rectBottom = rectTop + rect.height;
        var rectRight = rectLeft + rect.width;
        var visibleTop = viewport.top + margin;
        var visibleLeft = viewport.left + margin;
        var visibleBottom = viewport.top + viewport.height - margin;
        var visibleRight = viewport.left + viewport.width - margin;
        var verticallyVisible = rectBottom > visibleTop && rectTop < visibleBottom;
        var horizontallyVisible = rectRight > visibleLeft && rectLeft < visibleRight;
        if (verticallyVisible && horizontallyVisible)
            return false;

        var targetTop = rectTop - viewport.height / 3;
        var targetLeft = rectLeft - viewport.width / 5;
        var maxTop = Math.max(0, (document.documentElement ? document.documentElement.scrollHeight : 0) - viewport.height);
        var maxLeft = Math.max(0, (document.documentElement ? document.documentElement.scrollWidth : 0) - viewport.width);
        if (isFinite(maxTop))
            targetTop = Math.min(Math.max(0, targetTop), maxTop);
        if (isFinite(maxLeft))
            targetLeft = Math.min(Math.max(0, targetLeft), maxLeft);
        window.scrollTo({top: targetTop, left: targetLeft, behavior: "auto"});
        return true;
    }

    function highlightDOMNode(identifier) {
        var map = inspector.map;
        if (!map || !map.size)
            return false;
        var node = map.get(identifier);
        if (!node)
            return false;
        setOverlayTarget(node);
        var rect = rectForNode(node);
        if (rect)
            scrollRectIntoViewIfNeeded(rect);
        return true;
    }

    function clearHighlight() {
        setOverlayTarget(null);
    }

    var webInspectorKit = {
        captureDOM: captureDOM,
        captureDOMSubtree: captureDOMSubtree,
        startElementSelection: startElementSelection,
        cancelElementSelection: cancelElementSelection,
        highlightDOMNode: highlightDOMNode,
        clearHighlight: clearHighlight,
        setAutoSnapshotEnabled: setAutoSnapshotEnabled,
        triggerSnapshotUpdate: triggerSnapshotUpdate,
        __installed: true
    };
    Object.defineProperty(window, "webInspectorKit", {
        value: Object.freeze(webInspectorKit),
        writable: false,
        configurable: false
    });
})();
