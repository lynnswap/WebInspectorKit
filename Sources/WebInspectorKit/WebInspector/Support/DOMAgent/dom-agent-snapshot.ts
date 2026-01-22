import {inspector} from "./dom-agent-state";
import {captureDOM, describe, layoutInfoForNode, rememberNode} from "./dom-agent-dom-core";

const MAX_PENDING_MUTATIONS = 1500;
const MAX_LAYOUT_INFO_RECORDS = 400;
const MAX_LAYOUT_INFO_NODES = 200;
const MIN_LAYOUT_INFO_NODES = 40;
const COMPACT_EVENT_LIMIT = 600;
const COMPACT_SNAPSHOT_DEPTH = 2;

function autoSnapshotHandler() {
    return window?.webkit?.messageHandlers?.webInspectorDOMSnapshot || null;
}

function mutationUpdateHandler() {
    return window?.webkit?.messageHandlers?.webInspectorDOMMutations || null;
}

export function enableAutoSnapshotIfSupported() {
    if (autoSnapshotHandler()) {
        enableAutoSnapshot();
    }
}

function ensureAutoSnapshotObserver() {
    if (inspector.snapshotAutoUpdateObserver) {
        return inspector.snapshotAutoUpdateObserver;
    }
    if (typeof MutationObserver === "undefined") {
        return null;
    }
    inspector.snapshotAutoUpdateObserver = new MutationObserver(function(mutations) {
        if (!mutations || !mutations.length) {
            return;
        }
        var queue = inspector.pendingMutations;
        if (!Array.isArray(queue)) {
            queue = inspector.pendingMutations = [];
        }
        var overflow = false;
        for (var i = 0; i < mutations.length; ++i) {
            if (queue.length >= MAX_PENDING_MUTATIONS) {
                overflow = true;
                break;
            }
            queue.push(mutations[i]);
        }
        if (overflow) {
            inspector.snapshotAutoUpdateOverflow = true;
        }
        scheduleSnapshotAutoUpdate("mutation");
    });
    return inspector.snapshotAutoUpdateObserver;
}

function connectAutoSnapshotObserver() {
    var observer = ensureAutoSnapshotObserver();
    if (!observer) {
        return;
    }
    var target = document.documentElement || document.body;
    if (!target) {
        return;
    }
    observer.observe(target, {childList: true, subtree: true, attributes: true, characterData: true});
}

function disconnectAutoSnapshotObserver() {
    var observer = inspector.snapshotAutoUpdateObserver;
    if (!observer) {
        return;
    }
    observer.disconnect();
}

export function suppressSnapshotAutoUpdate(reason) {
    if (!inspector) {
        return;
    }
    var nextCount = (inspector.snapshotAutoUpdateSuppressedCount || 0) + 1;
    inspector.snapshotAutoUpdateSuppressedCount = nextCount;
    if (nextCount > 1) {
        return;
    }
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

export function resumeSnapshotAutoUpdate(reason) {
    if (!inspector) {
        return;
    }
    var current = inspector.snapshotAutoUpdateSuppressedCount || 0;
    if (!current) {
        return;
    }
    current -= 1;
    inspector.snapshotAutoUpdateSuppressedCount = current;
    if (current > 0) {
        return;
    }
    var pending = inspector.snapshotAutoUpdatePendingWhileSuppressed;
    var pendingReason = inspector.snapshotAutoUpdatePendingReason || reason || inspector.snapshotAutoUpdateReason || "mutation";
    inspector.snapshotAutoUpdatePendingWhileSuppressed = false;
    inspector.snapshotAutoUpdatePendingReason = null;
    if (pending && inspector.snapshotAutoUpdateEnabled) {
        scheduleSnapshotAutoUpdate(pendingReason);
    }
}

export function scheduleSnapshotAutoUpdate(reason) {
    if (!inspector.snapshotAutoUpdateEnabled) {
        return;
    }
    var effectiveReason = reason || inspector.snapshotAutoUpdateReason || "mutation";
    inspector.snapshotAutoUpdateReason = effectiveReason;
    if ((inspector.snapshotAutoUpdateSuppressedCount || 0) > 0) {
        inspector.snapshotAutoUpdatePendingWhileSuppressed = true;
        inspector.snapshotAutoUpdatePendingReason = effectiveReason;
        return;
    }
    if (inspector.snapshotAutoUpdatePending) {
        return;
    }
    inspector.snapshotAutoUpdatePending = true;
    var delay = inspector.snapshotAutoUpdateDebounce;
    if (typeof delay !== "number" || delay < 50) {
        delay = 50;
    }
    inspector.snapshotAutoUpdateTimer = setTimeout(function() {
        inspector.snapshotAutoUpdatePending = false;
        inspector.snapshotAutoUpdateTimer = null;
        if (!inspector.snapshotAutoUpdateEnabled) {
            return;
        }
        sendAutoSnapshotUpdate();
    }, delay);
}

function sendFullSnapshot(reason, maxDepthOverride) {
    var handler = autoSnapshotHandler();
    if (!handler) {
        return;
    }
    try {
        var maxDepth = inspector.snapshotAutoUpdateMaxDepth || 4;
        if (typeof maxDepthOverride === "number" && maxDepthOverride > 0) {
            maxDepth = Math.min(maxDepth, maxDepthOverride);
        }
        var snapshot = captureDOM(maxDepth);
        var payload = {
            version: 1,
            kind: "snapshot",
            reason: reason || inspector.snapshotAutoUpdateReason || "mutation",
            depth: maxDepth,
            documentURL: document.URL || "",
            snapshot: snapshot
        };
        handler.postMessage({
            bundle: JSON.stringify(payload)
        });
    } catch (error) {
        console.error("auto snapshot failed", error);
    }
}

function buildDomMutationEvents(records, maxDepth) {
    if (!Array.isArray(records) || !records.length) {
        return {events: [], compactTriggered: false};
    }
    var events = [];
    var attributeUpdates = new Map();
    var characterDataUpdates = new Map();
    var childCountUpdates = new Map();
    var nodeCache = new Map();
    var layoutInfoCache = new Map();
    var descriptorDepth = Math.min(1, Math.max(0, typeof maxDepth === "number" ? maxDepth : 1));
    var eventLimit = COMPACT_EVENT_LIMIT;
    var eventCount = 0;
    var layoutInfoBudget = MAX_LAYOUT_INFO_NODES;
    if (records.length > MAX_LAYOUT_INFO_RECORDS) {
        layoutInfoBudget = Math.max(
            MIN_LAYOUT_INFO_NODES,
            Math.floor((MAX_LAYOUT_INFO_NODES * MAX_LAYOUT_INFO_RECORDS) / records.length)
        );
    }

    function bumpEventCount() {
        eventCount += 1;
        return eventCount > eventLimit;
    }

    function cacheNode(nodeId, node) {
        if (!nodeCache.has(nodeId)) {
            nodeCache.set(nodeId, node);
        }
    }

    function getLayoutInfo(nodeId) {
        if (layoutInfoCache.has(nodeId)) {
            return layoutInfoCache.get(nodeId);
        }
        if (layoutInfoBudget <= 0) {
            return null;
        }
        var node = nodeCache.get(nodeId);
        if (!node) {
            return null;
        }
        var info = layoutInfoForNode(node);
        layoutInfoCache.set(nodeId, info);
        layoutInfoBudget -= 1;
        return info;
    }

    function appendLayoutInfo(params, layoutInfo) {
        if (!layoutInfo) {
            return params;
        }
        params.layoutFlags = layoutInfo.layoutFlags;
        params.isRendered = layoutInfo.isRendered;
        return params;
    }
    for (var i = 0; i < records.length; ++i) {
        var record = records[i];
        if (!record || !record.target) {
            continue;
        }
        var targetId = rememberNode(record.target);
        if (!targetId) {
            continue;
        }
        cacheNode(targetId, record.target);
        switch (record.type) {
        case "attributes": {
            var attrName = record.attributeName || "";
            if (!attrName) {
                break;
            }
            var attrValue = record.target.getAttribute(attrName);
            var nodeAttributes = attributeUpdates.get(targetId);
            if (!nodeAttributes) {
                nodeAttributes = new Map();
                attributeUpdates.set(targetId, nodeAttributes);
            }
            if (!nodeAttributes.has(attrName)) {
                if (bumpEventCount()) {
                    return {events: [], compactTriggered: true};
                }
            }
            if (attrValue === null || typeof attrValue === "undefined") {
                nodeAttributes.set(attrName, null);
            } else {
                nodeAttributes.set(attrName, String(attrValue));
            }
            break;
        }
        case "characterData": {
            if (!characterDataUpdates.has(targetId)) {
                if (bumpEventCount()) {
                    return {events: [], compactTriggered: true};
                }
            }
            characterDataUpdates.set(targetId, record.target.textContent || "");
            break;
        }
        case "childList": {
            if (record.removedNodes && record.removedNodes.length) {
                for (var r = 0; r < record.removedNodes.length; ++r) {
                    var removedNodeId = rememberNode(record.removedNodes[r]);
                    if (!removedNodeId) {
                        continue;
                    }
                    events.push({
                        method: "DOM.childNodeRemoved",
                        params: {
                            parentNodeId: targetId,
                            nodeId: removedNodeId
                        }
                    });
                    if (bumpEventCount()) {
                        return {events: [], compactTriggered: true};
                    }
                }
            }
            if (record.addedNodes && record.addedNodes.length) {
                var referenceNode = record.previousSibling || null;
                for (var a = 0; a < record.addedNodes.length; ++a) {
                    var addedNode = record.addedNodes[a];
                    var descriptor = describe(addedNode, 0, descriptorDepth, null);
                    if (!descriptor) {
                        continue;
                    }
                    var previousNodeId = referenceNode ? rememberNode(referenceNode) : 0;
                    events.push({
                        method: "DOM.childNodeInserted",
                        params: {
                            parentNodeId: targetId,
                            previousNodeId: previousNodeId || 0,
                            node: descriptor
                        }
                    });
                    if (bumpEventCount()) {
                        return {events: [], compactTriggered: true};
                    }
                    referenceNode = addedNode;
                }
            }
            if (!childCountUpdates.has(targetId)) {
                if (bumpEventCount()) {
                    return {events: [], compactTriggered: true};
                }
            }
            childCountUpdates.set(targetId, {
                count: record.target.childNodes ? record.target.childNodes.length : 0
            });
            break;
        }
        default:
            break;
        }
    }

    attributeUpdates.forEach(function(attributes, nodeId) {
        attributes.forEach(function(value, name) {
            var layoutInfo = getLayoutInfo(nodeId);
            if (value === null) {
                events.push({
                    method: "DOM.attributeRemoved",
                    params: appendLayoutInfo({
                        nodeId: nodeId,
                        name: name
                    }, layoutInfo)
                });
                return;
            }
            events.push({
                method: "DOM.attributeModified",
                params: appendLayoutInfo({
                    nodeId: nodeId,
                    name: name,
                    value: value
                }, layoutInfo)
            });
        });
    });

    characterDataUpdates.forEach(function(value, nodeId) {
        var layoutInfo = getLayoutInfo(nodeId);
        events.push({
            method: "DOM.characterDataModified",
            params: appendLayoutInfo({
                nodeId: nodeId,
                characterData: value
            }, layoutInfo)
        });
    });

    childCountUpdates.forEach(function(entry, nodeId) {
        var layoutInfo = getLayoutInfo(nodeId);
        events.push({
            method: "DOM.childNodeCountUpdated",
            params: appendLayoutInfo({
                nodeId: nodeId,
                childNodeCount: entry.count
            }, layoutInfo)
        });
    });

    return {events: events, compactTriggered: false};
}

function sendAutoSnapshotUpdate() {
    var mutationHandler = mutationUpdateHandler();
    if (!mutationHandler) {
        window?.webInspectorDOM?.detach();
        return;
    }

    var pending = Array.isArray(inspector.pendingMutations) ? inspector.pendingMutations.slice() : [];
    inspector.pendingMutations = [];
    var overflow = inspector.snapshotAutoUpdateOverflow === true;
    inspector.snapshotAutoUpdateOverflow = false;
    var mapSize = inspector.map?.size || 0;
    if (!mapSize) {
        sendFullSnapshot("initial");
        return;
    }
    
    if (overflow) {
        sendFullSnapshot("overflow", COMPACT_SNAPSHOT_DEPTH);
        return;
    }

    if (!pending.length) {
        sendFullSnapshot("mutation");
        return;
    }
    var result = buildDomMutationEvents(pending, 0);
    var messages = result.events;
    if (!messages.length) {
        sendFullSnapshot("fallback");
        return;
    }
    if (result.compactTriggered) {
        sendFullSnapshot("compact", COMPACT_SNAPSHOT_DEPTH);
        return;
    }
    var reason = inspector.snapshotAutoUpdateReason || "mutation";
    var chunkSize = 200;
    try {
        for (var offset = 0; offset < messages.length; offset += chunkSize) {
            var payload = {
                version: 1,
                kind: "mutation",
                reason: reason,
                events: messages.slice(offset, offset + chunkSize)
            };
            mutationHandler.postMessage({
                bundle: JSON.stringify(payload)
            });
        }
    } catch (error) {
        console.error("mutation update failed", error);
        sendFullSnapshot("post-error");
    }
}

function configureAutoSnapshotOptions(options) {
    if (!options) {
        return;
    }
    if (typeof options.maxDepth === "number" && options.maxDepth > 0) {
        inspector.snapshotAutoUpdateMaxDepth = options.maxDepth;
    }
    if (typeof options.debounce === "number" && options.debounce >= 50) {
        inspector.snapshotAutoUpdateDebounce = options.debounce;
    }
}

export function configureAutoSnapshot(options) {
    if (!options || typeof options !== "object") {
        return;
    }
    configureAutoSnapshotOptions(options);
    if (options.enabled === true) {
        enableAutoSnapshot();
    }
    if (options.enabled === false) {
        disableAutoSnapshot();
    }
}

export function setAutoSnapshotOptions(options) {
    configureAutoSnapshotOptions(options || null);
}

export function enableAutoSnapshot() {
    if (inspector.snapshotAutoUpdateEnabled) {
        return true;
    }
    inspector.snapshotAutoUpdateEnabled = true;
    if (!Array.isArray(inspector.pendingMutations)) {
        inspector.pendingMutations = [];
    }
    inspector.snapshotAutoUpdateOverflow = false;
    connectAutoSnapshotObserver();
    scheduleSnapshotAutoUpdate("initial");
    return inspector.snapshotAutoUpdateEnabled;
}

export function disableAutoSnapshot() {
    if (!inspector.snapshotAutoUpdateEnabled) {
        return false;
    }
    inspector.snapshotAutoUpdateEnabled = false;
    if (inspector.snapshotAutoUpdateTimer) {
        clearTimeout(inspector.snapshotAutoUpdateTimer);
        inspector.snapshotAutoUpdateTimer = null;
    }
    inspector.pendingMutations = [];
    inspector.snapshotAutoUpdatePending = false;
    inspector.snapshotAutoUpdateOverflow = false;
    inspector.snapshotAutoUpdateSuppressedCount = 0;
    inspector.snapshotAutoUpdatePendingWhileSuppressed = false;
    inspector.snapshotAutoUpdatePendingReason = null;
    disconnectAutoSnapshotObserver();
    return inspector.snapshotAutoUpdateEnabled;
}

export function triggerSnapshotUpdate(reason) {
    scheduleSnapshotAutoUpdate(reason || "manual");
}
