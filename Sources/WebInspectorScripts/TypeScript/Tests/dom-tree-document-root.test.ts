import { beforeEach, describe, expect, it, vi } from "vitest";

import { setSnapshot } from "../UI/DOMTree/dom-tree-snapshot";
import { dom, renderState, treeState } from "../UI/DOMTree/dom-tree-state";

type WebKitMockHandler = {
    postMessage: ReturnType<typeof vi.fn>;
};

function resetTreeState() {
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
    dom.tree = null;
    dom.empty = null;

    if (renderState.frameId !== null) {
        cancelAnimationFrame(renderState.frameId);
    }
    renderState.frameId = null;
    renderState.pendingNodes.clear();
}

function selectionHandler(): WebKitMockHandler {
    return window.webkit?.messageHandlers?.webInspectorDomSelection as WebKitMockHandler;
}

describe("dom-tree document root rendering", () => {
    beforeEach(() => {
        resetTreeState();
        document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";
    });

    it("keeps document root internal while exposing html as the first visible tree row", () => {
        setSnapshot({
            root: {
                nodeId: 1,
                nodeType: 9,
                nodeName: "#document",
                localName: "",
                childNodeCount: 1,
                children: [{
                    nodeId: 2,
                    nodeType: 1,
                    nodeName: "HTML",
                    localName: "html",
                    attributes: [],
                    childNodeCount: 1,
                    children: [{
                        nodeId: 3,
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body",
                        attributes: [],
                        childNodeCount: 0,
                        children: []
                    }]
                }]
            },
            selectedNodeId: 3,
            selectedNodePath: [0, 0]
        }, { preserveState: false });

        const rootElement = dom.tree?.firstElementChild as HTMLElement | null;
        const htmlElement = rootElement?.querySelector(":scope > .tree-node__children > .tree-node") as HTMLElement | null;
        expect(rootElement?.classList.contains("tree-node--document-root")).toBe(true);
        expect(treeState.snapshot?.root?.id).toBe(1);
        expect(treeState.nodes.get(1)?.depth).toBe(-1);
        expect(treeState.nodes.get(2)?.depth).toBe(0);
        expect(htmlElement?.dataset.nodeId).toBe("2");

        const messagePayload = selectionHandler().postMessage.mock.calls.at(-1)?.[0] as
            | { path?: string[] }
            | undefined;
        expect(messagePayload?.path).toEqual(["<html>", "<body>"]);
    });
});
