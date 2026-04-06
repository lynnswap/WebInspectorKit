import {domTraceEnabled, inspector, type AnyNode} from "./dom-agent-state";
import {
    captureDOMEnvelope,
    describe,
    inspectableChildCount,
    layoutInfoForNode,
    mutationTouchesInspectableDOM,
    previousInspectableSibling,
    rememberNode
} from "./dom-agent-dom-core";

const MAX_PENDING_MUTATIONS = 1500;
const MAX_LAYOUT_INFO_RECORDS = 400;
const MAX_LAYOUT_INFO_NODES = 200;
const MIN_LAYOUT_INFO_NODES = 40;
const COMPACT_EVENT_LIMIT = 600;
const COMPACT_SNAPSHOT_DEPTH = 2;

type MessageHandler = {
    postMessage: (message: any) => void;
};

type AutoSnapshotOptions = {
    enabled?: boolean;
    maxDepth?: number;
    debounce?: number;
};

type LayoutInfo = ReturnType<typeof layoutInfoForNode>;

type MutationEvent = {
    method: string;
    params: Record<string, any>;
};

function autoSnapshotHandler(): MessageHandler | null {
    return window?.webkit?.messageHandlers?.webInspectorDOMSnapshot || null;
}

function mutationUpdateHandler(): MessageHandler | null {
    return window?.webkit?.messageHandlers?.webInspectorDOMMutations || null;
}

function domLogHandler(): MessageHandler | null {
    return window?.webkit?.messageHandlers?.webInspectorDOMLog || null;
}

function postDOMTrace(message: string): void {
    if (!domTraceEnabled()) {
        return;
    }
    try {
        domLogHandler()?.postMessage({message});
    } catch {
    }
}

export function enableAutoSnapshotIfSupported() {
    if (autoSnapshotHandler()) {
        postDOMTrace(`enableAutoSnapshotIfSupported handlerPresent=true enabled=${inspector.snapshotAutoUpdateEnabled}`);
        enableAutoSnapshot();
    }
}

function ensureAutoSnapshotObserver(): MutationObserver | null {
    if (inspector.snapshotAutoUpdateObserver) {
        return inspector.snapshotAutoUpdateObserver;
    }
    if (typeof MutationObserver === "undefined") {
        return null;
    }
    inspector.snapshotAutoUpdateObserver = new MutationObserver(function(mutations: MutationRecord[]) {
        if (!mutations || !mutations.length) {
            return;
        }
        var inspectableMutations = mutations.filter(mutationTouchesInspectableDOM);
        if (!inspectableMutations.length) {
            return;
        }
        postDOMTrace(`MutationObserver observed count=${inspectableMutations.length} enabled=${inspector.snapshotAutoUpdateEnabled} pageEpoch=${inspector.pageEpoch} documentScopeID=${inspector.documentScopeID}`);
        var queue = inspector.pendingMutations;
        if (!Array.isArray(queue)) {
            queue = inspector.pendingMutations = [];
        }
        var overflow = false;
        for (var i = 0; i < inspectableMutations.length; ++i) {
            if (queue.length >= MAX_PENDING_MUTATIONS) {
                overflow = true;
                break;
            }
            queue.push(inspectableMutations[i]);
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

export function suppressSnapshotAutoUpdate(reason: string) {
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
    if (inspector.snapshotAutoUpdateFrame !== null) {
        cancelAnimationFrame(inspector.snapshotAutoUpdateFrame);
        inspector.snapshotAutoUpdateFrame = null;
        inspector.snapshotAutoUpdatePendingWhileSuppressed = true;
        inspector.snapshotAutoUpdatePendingReason = inspector.snapshotAutoUpdateReason || reason || "mutation";
    }
    if (inspector.snapshotAutoUpdatePending) {
        inspector.snapshotAutoUpdatePendingWhileSuppressed = true;
        inspector.snapshotAutoUpdatePendingReason = inspector.snapshotAutoUpdateReason || reason || inspector.snapshotAutoUpdatePendingReason || "mutation";
        inspector.snapshotAutoUpdatePending = false;
    }
}

export function resumeSnapshotAutoUpdate(reason: string) {
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

export function scheduleSnapshotAutoUpdate(reason: string) {
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
        queueSnapshotAutoUpdateDispatch(effectiveReason);
    }, delay);
}

function queueSnapshotAutoUpdateDispatch(reason: string) {
    if (!inspector.snapshotAutoUpdateEnabled) {
        return;
    }
    if (inspector.snapshotAutoUpdateFrame !== null) {
        return;
    }
    if (typeof requestAnimationFrame !== "function") {
        sendAutoSnapshotUpdate(reason);
        return;
    }
    inspector.snapshotAutoUpdateFrame = requestAnimationFrame(function() {
        inspector.snapshotAutoUpdateFrame = null;
        if (!inspector.snapshotAutoUpdateEnabled) {
            return;
        }
        sendAutoSnapshotUpdate(reason);
    });
}

function sendFullSnapshot(reason: string, maxDepthOverride?: number) {
    var handler = autoSnapshotHandler();
    if (!handler) {
        postDOMTrace(`sendFullSnapshot skipped missingHandler reason=${reason}`);
        return;
    }
    try {
        var maxDepth = inspector.snapshotAutoUpdateMaxDepth || 4;
        if (typeof maxDepthOverride === "number" && maxDepthOverride > 0) {
            maxDepth = Math.min(maxDepth, maxDepthOverride);
        }
        var snapshot = captureDOMEnvelope(maxDepth, { consumeInitialSnapshotMode: false });
        var payload = {
            version: 1,
            kind: "snapshot",
            reason: reason || inspector.snapshotAutoUpdateReason || "mutation",
            snapshotMode: inspector.nextInitialSnapshotMode || undefined,
            depth: maxDepth,
            documentURL: document.URL || "",
            snapshot: snapshot,
            pageEpoch: inspector.pageEpoch,
            documentScopeID: inspector.documentScopeID
        };
        handler.postMessage({
            pageEpoch: inspector.pageEpoch,
            documentScopeID: inspector.documentScopeID,
            bundle: payload
        });
        postDOMTrace(`sendFullSnapshot posted reason=${payload.reason} depth=${maxDepth} pageEpoch=${inspector.pageEpoch} documentScopeID=${inspector.documentScopeID} documentURL=${document.URL || ""}`);
    } catch (error) {
        postDOMTrace(`sendFullSnapshot failed reason=${reason} error=${String(error)}`);
        console.error("auto snapshot failed", error);
    } finally {
        inspector.nextInitialSnapshotMode = null;
    }
}

function buildDomMutationEvents(records: MutationRecord[], maxDepth: number): { events: MutationEvent[]; compactTriggered: boolean } {
    if (!Array.isArray(records) || !records.length) {
        return {events: [], compactTriggered: false};
    }
    var events: MutationEvent[] = [];
    var attributeUpdates = new Map<number, Map<string, string | null>>();
    var characterDataUpdates = new Map<number, string>();
    var childCountUpdates = new Map<number, { count: number }>();
    var nodeCache = new Map<number, AnyNode>();
    var layoutInfoCache = new Map<number, LayoutInfo>();
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

    function cacheNode(nodeId: number, node: AnyNode) {
        if (!nodeCache.has(nodeId)) {
            nodeCache.set(nodeId, node);
        }
    }

    function getLayoutInfo(nodeId: number): LayoutInfo | null {
        if (layoutInfoCache.has(nodeId)) {
            return layoutInfoCache.get(nodeId) || null;
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

    function appendLayoutInfo(params: Record<string, any>, layoutInfo: LayoutInfo | null) {
        if (!layoutInfo) {
            return params;
        }
        params.layoutFlags = layoutInfo.layoutFlags;
        params.isRendered = layoutInfo.isRendered;
        return params;
    }
    for (var i = 0; i < records.length; ++i) {
        var record = records[i];
        if (!record || !record.target || !mutationTouchesInspectableDOM(record)) {
            continue;
        }
        var targetId = rememberNode(record.target as AnyNode);
        if (!targetId) {
            continue;
        }
        cacheNode(targetId, record.target as AnyNode);
        switch (record.type) {
        case "attributes": {
            var attrName = record.attributeName || "";
            if (!attrName) {
                break;
            }
            var attrValue = (record.target as Element).getAttribute(attrName);
            var nodeAttributes = attributeUpdates.get(targetId);
            if (!nodeAttributes) {
                nodeAttributes = new Map<string, string | null>();
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
            var hadInspectableChildMutation = false;
            if (record.removedNodes && record.removedNodes.length) {
                for (var r = 0; r < record.removedNodes.length; ++r) {
                    var removedNode = record.removedNodes[r] as AnyNode;
                    var removedNodeId = rememberNode(removedNode);
                    if (!removedNodeId) {
                        continue;
                    }
                    hadInspectableChildMutation = true;
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
                var referenceNode = previousInspectableSibling(record.previousSibling);
                for (var a = 0; a < record.addedNodes.length; ++a) {
                    var addedNode = record.addedNodes[a];
                    var descriptor = describe(addedNode as AnyNode, 0, descriptorDepth, null);
                    if (!descriptor) {
                        continue;
                    }
                    hadInspectableChildMutation = true;
                    var previousNodeId = referenceNode ? rememberNode(referenceNode as AnyNode) : 0;
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
            if (!hadInspectableChildMutation) {
                break;
            }
            if (!childCountUpdates.has(targetId)) {
                if (bumpEventCount()) {
                    return {events: [], compactTriggered: true};
                }
            }
            childCountUpdates.set(targetId, {
                count: inspectableChildCount(record.target)
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

function sendAutoSnapshotUpdate(reasonOverride?: string) {
    var mutationHandler = mutationUpdateHandler();
    if (!mutationHandler) {
        postDOMTrace("sendAutoSnapshotUpdate missing mutation handler; detaching");
        const webInspectorDOM = window.webInspectorDOM as { detach?: () => void } | undefined;
        webInspectorDOM?.detach?.();
        return;
    }

    var pending = Array.isArray(inspector.pendingMutations) ? inspector.pendingMutations.slice() : [];
    inspector.pendingMutations = [];
    var overflow = inspector.snapshotAutoUpdateOverflow === true;
    inspector.snapshotAutoUpdateOverflow = false;
    var mapSize = inspector.map?.size || 0;
    var initialSnapshotMode = inspector.nextInitialSnapshotMode;
    postDOMTrace(`sendAutoSnapshotUpdate reason=${reasonOverride || inspector.snapshotAutoUpdateReason} pending=${pending.length} overflow=${overflow} mapSize=${mapSize} enabled=${inspector.snapshotAutoUpdateEnabled} pageEpoch=${inspector.pageEpoch} documentScopeID=${inspector.documentScopeID}`);
    if (initialSnapshotMode || !mapSize) {
        sendFullSnapshot("initial");
        if (initialSnapshotMode === "fresh") {
            pending = [];
            return;
        }
        mapSize = inspector.map?.size || 0;
        if (!pending.length) {
            return;
        }
    }
    
    if (overflow) {
        sendFullSnapshot("overflow", COMPACT_SNAPSHOT_DEPTH);
        return;
    }

    var reason = reasonOverride || inspector.snapshotAutoUpdateReason || "mutation";
    if (!pending.length) {
        if (reason === "initial") {
            sendFullSnapshot("initial");
        }
        return;
    }
    var result = buildDomMutationEvents(pending, 0);
    var messages = result.events;
    if (result.compactTriggered) {
        sendFullSnapshot("compact", COMPACT_SNAPSHOT_DEPTH);
        return;
    }
    if (!messages.length) {
        return;
    }
    var chunkSize = 200;
    try {
        for (var offset = 0; offset < messages.length; offset += chunkSize) {
            var payload = {
                version: 1,
                kind: "mutation",
                reason: reason,
                events: messages.slice(offset, offset + chunkSize),
                pageEpoch: inspector.pageEpoch,
                documentScopeID: inspector.documentScopeID
            };
            mutationHandler.postMessage({
                pageEpoch: inspector.pageEpoch,
                documentScopeID: inspector.documentScopeID,
                bundle: payload
            });
            postDOMTrace(`sendAutoSnapshotUpdate posted mutation chunkSize=${payload.events.length} pageEpoch=${inspector.pageEpoch} documentScopeID=${inspector.documentScopeID}`);
        }
    } catch (error) {
        postDOMTrace(`sendAutoSnapshotUpdate failed error=${String(error)}`);
        console.error("mutation update failed", error);
        sendFullSnapshot("post-error");
    }
}

function configureAutoSnapshotOptions(options: AutoSnapshotOptions | null) {
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

export function configureAutoSnapshot(options: AutoSnapshotOptions | null) {
    if (!options || typeof options !== "object") {
        return;
    }
    postDOMTrace(`configureAutoSnapshot enabled=${String(options.enabled)} maxDepth=${String(options.maxDepth)} debounce=${String(options.debounce)}`);
    configureAutoSnapshotOptions(options);
    if (options.enabled === true) {
        enableAutoSnapshot();
    }
    if (options.enabled === false) {
        disableAutoSnapshot();
    }
}

export function setAutoSnapshotOptions(options: AutoSnapshotOptions | null) {
    configureAutoSnapshotOptions(options || null);
}

export function enableAutoSnapshot() {
    if (inspector.snapshotAutoUpdateEnabled) {
        postDOMTrace(`enableAutoSnapshot noop alreadyEnabled=true pageEpoch=${inspector.pageEpoch} documentScopeID=${inspector.documentScopeID}`);
        return true;
    }
    inspector.snapshotAutoUpdateEnabled = true;
    if (!Array.isArray(inspector.pendingMutations)) {
        inspector.pendingMutations = [];
    }
    inspector.snapshotAutoUpdateOverflow = false;
    if (!inspector.nextInitialSnapshotMode) {
        inspector.nextInitialSnapshotMode = "preserve-ui-state";
    }
    connectAutoSnapshotObserver();
    scheduleSnapshotAutoUpdate("initial");
    postDOMTrace(`enableAutoSnapshot activated debounce=${inspector.snapshotAutoUpdateDebounce} maxDepth=${inspector.snapshotAutoUpdateMaxDepth} pageEpoch=${inspector.pageEpoch} documentScopeID=${inspector.documentScopeID}`);
    return inspector.snapshotAutoUpdateEnabled;
}

export function disableAutoSnapshot() {
    if (!inspector.snapshotAutoUpdateEnabled) {
        postDOMTrace("disableAutoSnapshot noop alreadyDisabled=true");
        return false;
    }
    inspector.snapshotAutoUpdateEnabled = false;
    if (inspector.snapshotAutoUpdateTimer) {
        clearTimeout(inspector.snapshotAutoUpdateTimer);
        inspector.snapshotAutoUpdateTimer = null;
    }
    if (inspector.snapshotAutoUpdateFrame !== null) {
        cancelAnimationFrame(inspector.snapshotAutoUpdateFrame);
        inspector.snapshotAutoUpdateFrame = null;
    }
    inspector.pendingMutations = [];
    inspector.snapshotAutoUpdatePending = false;
    inspector.snapshotAutoUpdateOverflow = false;
    inspector.snapshotAutoUpdateSuppressedCount = 0;
    inspector.snapshotAutoUpdatePendingWhileSuppressed = false;
    inspector.snapshotAutoUpdatePendingReason = null;
    if (!inspector.nextInitialSnapshotMode) {
        inspector.nextInitialSnapshotMode = "preserve-ui-state";
    }
    disconnectAutoSnapshotObserver();
    postDOMTrace(`disableAutoSnapshot completed pageEpoch=${inspector.pageEpoch} documentScopeID=${inspector.documentScopeID}`);
    return inspector.snapshotAutoUpdateEnabled;
}

export function triggerSnapshotUpdate(reason: string) {
    scheduleSnapshotAutoUpdate(reason || "manual");
}
