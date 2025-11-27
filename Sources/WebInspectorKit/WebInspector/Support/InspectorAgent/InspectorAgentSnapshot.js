import {inspector} from "./InspectorAgentState.js";
import {captureDOM, describe, layoutInfoForNode, rememberNode} from "./InspectorAgentDOMCore.js";

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

export function enableAutoSnapshotIfSupported() {
    if (autoSnapshotHandler())
        enableAutoSnapshot();
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

export function suppressSnapshotAutoUpdate(reason) {
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

export function resumeSnapshotAutoUpdate(reason) {
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

export function scheduleSnapshotAutoUpdate(reason) {
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
        var layoutInfo = layoutInfoForNode(record.target);
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
                        name: attrName,
                        layoutFlags: layoutInfo.layoutFlags,
                        isRendered: layoutInfo.isRendered
                    }
                });
            } else {
                events.push({
                    method: "DOM.attributeModified",
                    params: {
                        nodeId: targetId,
                        name: attrName,
                        value: String(attrValue),
                        layoutFlags: layoutInfo.layoutFlags,
                        isRendered: layoutInfo.isRendered
                    }
                });
            }
            break;
        case "characterData":
            events.push({
                method: "DOM.characterDataModified",
                params: {
                    nodeId: targetId,
                    characterData: record.target.textContent || "",
                    layoutFlags: layoutInfo.layoutFlags,
                    isRendered: layoutInfo.isRendered
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
            childCountUpdates.set(targetId, {
                count: record.target.childNodes ? record.target.childNodes.length : 0,
                layoutFlags: layoutInfo.layoutFlags,
                isRendered: layoutInfo.isRendered
            });
            break;
        default:
            break;
        }
        if (!compactMode && events.length > eventLimit)
            compactMode = true;
    }

    if (childCountUpdates.size) {
        childCountUpdates.forEach(function(entry, nodeId) {
            events.push({
                method: "DOM.childNodeCountUpdated",
                params: {
                    nodeId: nodeId,
                    childNodeCount: entry.count,
                    layoutFlags: entry.layoutFlags,
                    isRendered: entry.isRendered
                }
            });
        });
    }

    if (events.length > eventLimit) {
        var compact = [];
        childCountUpdates.forEach(function(entry, nodeId) {
            compact.push({
                method: "DOM.childNodeCountUpdated",
                params: {
                    nodeId: nodeId,
                    childNodeCount: entry.count,
                    layoutFlags: entry.layoutFlags,
                    isRendered: entry.isRendered
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

export function setAutoSnapshotOptions(options) {
    configureAutoSnapshotOptions(options || null);
}

export function enableAutoSnapshot() {
    if (inspector.snapshotAutoUpdateEnabled)
        return true;
    inspector.snapshotAutoUpdateEnabled = true;
    if (!Array.isArray(inspector.pendingMutations))
        inspector.pendingMutations = [];
    connectAutoSnapshotObserver();
    scheduleSnapshotAutoUpdate("initial");
    return inspector.snapshotAutoUpdateEnabled;
}

export function disableAutoSnapshot() {
    if (!inspector.snapshotAutoUpdateEnabled)
        return false;
    inspector.snapshotAutoUpdateEnabled = false;
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
    return inspector.snapshotAutoUpdateEnabled;
}

export function triggerSnapshotUpdate(reason) {
    scheduleSnapshotAutoUpdate(reason || "manual");
}
