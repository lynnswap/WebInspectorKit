import { beforeEach, describe, expect, it, vi } from "vitest";

import {
    completeChildNodeRequest,
    markChildNodesRequestCompleted,
    rejectChildNodeRequest,
    requestChildNodes,
    resetChildNodeRequests,
    updateConfig,
} from "../UI/DOMTree/dom-tree-protocol";
import {
    applyMutationBundle,
    applySubtree,
    completeDocumentRequest,
    rejectDocumentRequest,
    requestDocument,
    requestSnapshotReload,
    setSnapshot
} from "../UI/DOMTree/dom-tree-snapshot";
import { dom, protocolState, renderState, treeState } from "../UI/DOMTree/dom-tree-state";

type WebKitMockHandler = {
    postMessage: ReturnType<typeof vi.fn>;
};

function documentHandler(): WebKitMockHandler {
    return window.webkit?.messageHandlers?.webInspectorDomRequestDocument as WebKitMockHandler;
}

function childNodesHandler(): WebKitMockHandler {
    return window.webkit?.messageHandlers?.webInspectorDomRequestChildren as WebKitMockHandler;
}

function resetDOMTreeState() {
    treeState.snapshot = null;
    treeState.nodes.clear();
    treeState.elements.clear();
    treeState.openState.clear();
    treeState.selectedNodeId = null;
    treeState.styleRevision = 0;
    treeState.filter = "";
    treeState.pendingRefreshRequests.clear();
    treeState.refreshAttempts.clear();
    treeState.selectionChain = [];
    treeState.deferredChildRenders.clear();
    protocolState.snapshotDepth = 4;
    protocolState.subtreeDepth = 3;
    protocolState.pageEpoch = -1;
    protocolState.documentScopeID = 0;
    updateConfig({ pageEpoch: 0 });
    dom.tree = null;
    dom.empty = null;
    if (renderState.frameId !== null) {
        cancelAnimationFrame(renderState.frameId);
    }
    renderState.frameId = null;
    renderState.pendingNodes.clear();
}

function latestPostedPayload(handler: WebKitMockHandler, index = -1): Record<string, unknown> | undefined {
    return handler.postMessage.mock.calls.at(index)?.[0] as Record<string, unknown> | undefined;
}

describe("dom-tree typed backend bridge", () => {
    beforeEach(() => {
        document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";
        window.webkit = {
            messageHandlers: {
                webInspectorDomRequestDocument: { postMessage: vi.fn() },
                webInspectorDomRequestChildren: { postMessage: vi.fn() },
                webInspectorDomHighlight: { postMessage: vi.fn() },
                webInspectorDomHideHighlight: { postMessage: vi.fn() },
                webInspectorLog: { postMessage: vi.fn() },
                webInspectorDomSelection: { postMessage: vi.fn() },
            }
        } as never;
        resetDOMTreeState();
    });

    it("keeps only the latest pending document request while one is in flight", async () => {
        await requestDocument({ depth: 2, mode: "fresh" });
        await requestDocument({ depth: 5, mode: "preserve-ui-state" });

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(latestPostedPayload(documentHandler())?.depth).toBe(2);

        setSnapshot({
            root: {
                nodeId: 2,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: [],
                children: [],
            }
        }, { mode: "fresh" });
        completeDocumentRequest(protocolState.pageEpoch);

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(2);
        expect(latestPostedPayload(documentHandler())?.depth).toBe(5);
        expect(latestPostedPayload(documentHandler())?.mode).toBe("preserve-ui-state");
    });

    it("coalesces identical document requests while a request is in flight", async () => {
        await requestDocument({ depth: 2, mode: "fresh" });
        await requestDocument({ depth: 2, mode: "fresh" });

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);

        setSnapshot({
            root: {
                nodeId: 2,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: [],
                children: [],
            }
        }, { mode: "fresh" });

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(treeState.snapshot?.root?.id).toBe(2);
    });

    it("starts a fresh request stream after the page epoch advances", async () => {
        await requestDocument({ depth: 2, mode: "fresh" });
        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);

        updateConfig({ pageEpoch: 1 });
        await requestDocument({ depth: 7, mode: "fresh", pageEpoch: 1 });

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(2);
        expect(latestPostedPayload(documentHandler())?.pageEpoch).toBe(1);
        expect(latestPostedPayload(documentHandler())?.depth).toBe(7);
    });

    it("ignores stale document request callbacks after documentScopeID changes", async () => {
        await requestDocument({ depth: 2, mode: "fresh" });
        updateConfig({ documentScopeID: 1 });
        await requestDocument({ depth: 2, mode: "fresh" });

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(2);

        completeDocumentRequest(protocolState.pageEpoch, 0);
        await requestDocument({ depth: 2, mode: "fresh" });

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(2);
    });

    it("ignores stale config payloads before mutating depth state", () => {
        updateConfig({ pageEpoch: 1, snapshotDepth: 7, subtreeDepth: 5 });

        updateConfig({ pageEpoch: 0, snapshotDepth: 99, subtreeDepth: 88 });

        expect(protocolState.pageEpoch).toBe(1);
        expect(protocolState.snapshotDepth).toBe(7);
        expect(protocolState.subtreeDepth).toBe(5);
    });

    it("documentUpdated queues a fresh document request behind an in-flight request", async () => {
        await requestDocument({ depth: 2, mode: "preserve-ui-state" });
        await requestChildNodes(11, 2);

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(1);

        applyMutationBundle({
            version: 1,
            kind: "mutation",
            events: [
                {
                    method: "DOM.documentUpdated",
                    params: {},
                },
            ],
            pageEpoch: protocolState.pageEpoch,
        });

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);

        await requestChildNodes(11, 2);
        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(2);

        setSnapshot({
            root: {
                nodeId: 2,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: [],
                children: [],
            }
        }, { mode: "preserve-ui-state" });
        completeDocumentRequest(protocolState.pageEpoch);

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(2);
        expect(latestPostedPayload(documentHandler())?.mode).toBe("fresh");
    });

    it("documentUpdated requeues a fresh snapshot behind an identical in-flight fresh request", async () => {
        await requestDocument({ depth: 2, mode: "fresh" });
        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);

        applyMutationBundle({
            version: 1,
            kind: "mutation",
            events: [
                {
                    method: "DOM.documentUpdated",
                    params: {},
                },
            ],
            pageEpoch: protocolState.pageEpoch,
        });

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);

        setSnapshot({
            root: {
                nodeId: 2,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: [],
                children: [],
            }
        }, { mode: "fresh" });
        completeDocumentRequest(protocolState.pageEpoch);

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(2);
        expect(latestPostedPayload(documentHandler())?.mode).toBe("fresh");
    });

    it("documentUpdated preserves follow-up mutation events in the same batch", async () => {
        setSnapshot({
            root: {
                nodeId: 1,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: ["class", "before"],
                children: [],
            }
        }, { mode: "fresh" });

        applyMutationBundle({
            version: 1,
            kind: "mutation",
            events: [
                {
                    method: "DOM.documentUpdated",
                    params: {},
                },
                {
                    method: "DOM.attributeModified",
                    params: {
                        nodeId: 1,
                        name: "class",
                        value: "after",
                    },
                },
            ],
            pageEpoch: protocolState.pageEpoch,
        });
        vi.advanceTimersByTime(16);
        await Promise.resolve();

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(treeState.snapshot?.root?.attributes?.find((attribute) => attribute.name === "class")?.value).toBe("after");
    });

    it("ignores mutation bundles whose documentScopeID is stale", () => {
        setSnapshot({
            root: {
                nodeId: 1,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: ["class", "before"],
                children: [],
            }
        }, { mode: "fresh" });
        updateConfig({ documentScopeID: 2 });

        applyMutationBundle({
            version: 1,
            kind: "mutation",
            pageEpoch: protocolState.pageEpoch,
            documentScopeID: 1,
            events: [
                {
                    method: "DOM.attributeModified",
                    params: {
                        nodeId: 1,
                        name: "class",
                        value: "stale",
                    },
                },
            ],
        });
        vi.advanceTimersByTime(16);

        expect(treeState.snapshot?.root?.attributes?.find((attribute) => attribute.name === "class")?.value).toBe("before");
    });

    it("snapshot normalization failure still completes the in-flight document request", async () => {
        await requestDocument({ depth: 2, mode: "fresh" });
        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);

        setSnapshot({
            root: {
                nodeId: 2,
            }
        } as never, { mode: "fresh" });

        await requestDocument({ depth: 2, mode: "fresh" });
        expect(documentHandler().postMessage).toHaveBeenCalledTimes(2);
    });

    it("requestSnapshotReload swallows fire-and-forget request errors", async () => {
        const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
        delete (window.webkit?.messageHandlers as Record<string, unknown>)?.webInspectorDomRequestDocument;

        requestSnapshotReload("test");
        await Promise.resolve();
        await Promise.resolve();

        expect(warnSpy).toHaveBeenCalled();
        warnSpy.mockRestore();
    });

    it("page epoch changes clear stale child refresh bookkeeping", () => {
        treeState.pendingRefreshRequests.add(11);
        treeState.refreshAttempts.set(11, { count: 2, lastRequested: 123 });

        updateConfig({ pageEpoch: 1 });

        expect(treeState.pendingRefreshRequests.size).toBe(0);
        expect(treeState.refreshAttempts.size).toBe(0);
    });

    it("coalesces child-node requests and drains the queued depth after completion", async () => {
        await requestChildNodes(11, 2);
        await requestChildNodes(11, 2);
        await requestChildNodes(11, 4);

        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(latestPostedPayload(childNodesHandler())?.depth).toBe(2);

        markChildNodesRequestCompleted(11);

        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(2);
        expect(latestPostedPayload(childNodesHandler())?.depth).toBe(4);
    });

    it("rejectDocumentRequest preserves a queued reload until the next completion signal", async () => {
        await requestDocument({ depth: 2, mode: "preserve-ui-state" });
        await requestDocument({ depth: 5, mode: "fresh" });

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);

        rejectDocumentRequest(protocolState.pageEpoch);

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(1);

        setSnapshot({
            root: {
                nodeId: 2,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: [],
                children: [],
            }
        }, { mode: "preserve-ui-state" });
        completeDocumentRequest(protocolState.pageEpoch);

        expect(documentHandler().postMessage).toHaveBeenCalledTimes(2);
        expect(latestPostedPayload(documentHandler())?.depth).toBe(5);
        expect(latestPostedPayload(documentHandler())?.mode).toBe("fresh");
    });

    it("rejectChildNodeRequest keeps the queued depth pending without draining immediately", async () => {
        await requestChildNodes(11, 2);
        await requestChildNodes(11, 4);

        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(1);
        expect(latestPostedPayload(childNodesHandler())?.depth).toBe(2);

        rejectChildNodeRequest(11, protocolState.pageEpoch);

        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(1);

        completeChildNodeRequest(11, protocolState.pageEpoch);

        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(2);
        expect(latestPostedPayload(childNodesHandler())?.depth).toBe(4);
    });

    it("allows the same child-node request again after an explicit completion signal", async () => {
        await requestChildNodes(11, 2);
        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(1);

        completeChildNodeRequest(11, 0);
        await requestChildNodes(11, 2);

        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(2);
        expect(latestPostedPayload(childNodesHandler())?.nodeId).toBe(11);
        expect(latestPostedPayload(childNodesHandler())?.depth).toBe(2);
    });

    it("ignores stale child-node completion callbacks after documentScopeID changes", async () => {
        await requestChildNodes(11, 2);
        updateConfig({ documentScopeID: 1 });
        await requestChildNodes(11, 2);

        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(2);

        completeChildNodeRequest(11, protocolState.pageEpoch, 0);
        await requestChildNodes(11, 2);

        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(2);
    });

    it("subtree normalization failure completes the active child-node request", async () => {
        await requestChildNodes(11, 2);
        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(1);

        applySubtree({
            nodeId: 11,
        } as never);

        await requestChildNodes(11, 2);
        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(2);
    });

    it("string subtree normalization failure still completes the active child-node request", async () => {
        await requestChildNodes(11, 2);
        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(1);

        applySubtree("{\"nodeId\":11}");

        await requestChildNodes(11, 2);
        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(2);
    });

    it("allows the same child-node request again after a frontend reset", async () => {
        await requestChildNodes(11, 2);
        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(1);

        resetChildNodeRequests();
        await requestChildNodes(11, 2);

        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(2);
        expect(latestPostedPayload(childNodesHandler())?.nodeId).toBe(11);
        expect(latestPostedPayload(childNodesHandler())?.depth).toBe(2);
    });

    it("ignores stale child-node reset callbacks after documentScopeID changes", async () => {
        await requestChildNodes(11, 2);
        updateConfig({ documentScopeID: 1 });
        await requestChildNodes(11, 2);

        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(2);

        resetChildNodeRequests(protocolState.pageEpoch, 0);
        await requestChildNodes(11, 2);

        expect(childNodesHandler().postMessage).toHaveBeenCalledTimes(2);
    });
});
