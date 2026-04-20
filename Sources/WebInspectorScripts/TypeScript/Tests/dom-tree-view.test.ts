import { beforeEach, describe, expect, it, vi } from "vitest";

let nextContextID = 1;

async function resetEnvironment(): Promise<typeof import("../UI/DOMTree/dom-tree-state")> {
    const state = await import("../UI/DOMTree/dom-tree-state");
    const { dom, protocolState, treeState } = state;
    const contextID = nextContextID;
    nextContextID += 1;
    const frontend =
        window.webInspectorDOMFrontend as ({ updateBootstrap?: (bootstrap: unknown) => void } | undefined);
    document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";
    dom.tree = null;
    dom.empty = null;
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
    treeState.selectionRecoveryRequestKeys.clear();
    protocolState.snapshotDepth = 4;
    protocolState.subtreeDepth = 3;
    if (!frontend?.updateBootstrap) {
        protocolState.contextID = contextID;
    }
    window.webkit = {
        messageHandlers: {
            webInspectorReady: { postMessage: vi.fn() },
            webInspectorDomRequestChildren: { postMessage: vi.fn() },
            webInspectorDomHighlight: { postMessage: vi.fn() },
            webInspectorDomHideHighlight: { postMessage: vi.fn() },
            webInspectorDomSelection: { postMessage: vi.fn() },
            webInspectorLog: { postMessage: vi.fn() },
        },
    } as never;
    const bootstrap = {
        context: { contextID },
        config: { snapshotDepth: 4, subtreeDepth: 3 },
    };
    (window as Window & { __wiDOMFrontendBootstrap?: unknown }).__wiDOMFrontendBootstrap = bootstrap;
    frontend?.updateBootstrap?.(bootstrap);
    return state;
}

describe("dom-tree-view", () => {
    beforeEach(async () => {
        await resetEnvironment();
    });

    it("installs the frontend API", async () => {
        await import("../UI/DOMTree/dom-tree-view");

        expect(window.webInspectorDOMFrontend?.applyFullSnapshot).toBeTypeOf("function");
    });

    it("applies a same-context full snapshot", async () => {
        const { protocolState, treeState } = await import("../UI/DOMTree/dom-tree-state");
        await import("../UI/DOMTree/dom-tree-view");

        window.webInspectorDOMFrontend?.applyFullSnapshot?.({
            root: {
                nodeId: 1,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: ["class", "ready"],
                children: [],
            }
        }, protocolState.contextID);

        expect(treeState.snapshot?.root?.attributes?.find((attribute) => attribute.name === "class")?.value).toBe("ready");
    });

    it("ignores a stale full snapshot", async () => {
        const { treeState } = await import("../UI/DOMTree/dom-tree-state");
        await import("../UI/DOMTree/dom-tree-view");

        window.webInspectorDOMFrontend?.applyFullSnapshot?.({
            root: {
                nodeId: 1,
                nodeType: 1,
                nodeName: "DIV",
                localName: "div",
                attributes: ["class", "ready"],
                children: [],
            }
        }, 999);

        expect(treeState.snapshot).toBeNull();
    });

    it("renders document snapshots without a #document row", async () => {
        const { protocolState, treeState } = await import("../UI/DOMTree/dom-tree-state");
        await import("../UI/DOMTree/dom-tree-view");

        window.webInspectorDOMFrontend?.applyFullSnapshot?.({
            root: {
                nodeId: 1,
                nodeType: 9,
                nodeName: "#document",
                localName: "",
                childNodeCount: 2,
                children: [
                    {
                        nodeId: 10,
                        nodeType: 10,
                        nodeName: "html",
                        localName: "html",
                        nodeValue: "",
                        childNodeCount: 0,
                        children: [],
                    },
                    {
                        nodeId: 2,
                        nodeType: 1,
                        nodeName: "HTML",
                        localName: "html",
                        attributes: ["lang", "ja"],
                        childNodeCount: 2,
                        children: [
                            {
                                nodeId: 3,
                                nodeType: 1,
                                nodeName: "HEAD",
                                localName: "head",
                                childNodeCount: 0,
                                children: [],
                            },
                            {
                                nodeId: 4,
                                nodeType: 1,
                                nodeName: "BODY",
                                localName: "body",
                                childNodeCount: 1,
                                children: [
                                    {
                                        nodeId: 5,
                                        nodeType: 1,
                                        nodeName: "MAIN",
                                        localName: "main",
                                        childNodeCount: 0,
                                        children: [],
                                    },
                                ],
                            },
                        ],
                    },
                ],
            },
        }, protocolState.contextID);

        expect(treeState.snapshot?.root?.nodeName).toBe("#document");
        expect(document.getElementById("dom-tree")?.textContent).not.toContain("#document");
        const names = Array.from(document.querySelectorAll(".tree-node__name"))
            .map((element) => element.textContent);
        expect(names).toContain("<!DOCTYPE html>");
        expect(names).toContain("<html");
        expect(names).toContain("<body");
        expect(names).toContain("<main");
        expect(document.querySelector(".tree-node__attribute")?.textContent).toBe(" lang");
        expect(document.querySelector(".tree-node__value")?.textContent).toBe("=\"ja\"");
        expect(document.querySelector(".tree-node.is-unrendered")).toBeNull();
    });

    it("does not render placeholder rows for partially loaded nodes", async () => {
        const { protocolState } = await import("../UI/DOMTree/dom-tree-state");
        await import("../UI/DOMTree/dom-tree-view");

        window.webInspectorDOMFrontend?.applyFullSnapshot?.({
            root: {
                nodeId: 1,
                nodeType: 9,
                nodeName: "#document",
                localName: "",
                childNodeCount: 1,
                children: [
                    {
                        nodeId: 2,
                        nodeType: 1,
                        nodeName: "HTML",
                        localName: "html",
                        attributes: ["lang", "ja"],
                        childNodeCount: 2,
                        children: [],
                    },
                ],
            },
        }, protocolState.contextID);

        const treeText = document.getElementById("dom-tree")?.textContent ?? "";
        expect(treeText).not.toContain("Load");
        expect(treeText).not.toContain("more nodes");
        expect(document.querySelector("[data-role='load-placeholder']")).toBeNull();

        const disclosure = document.querySelector(".tree-node[data-node-id='2'] .tree-node__disclosure") as HTMLButtonElement | null;
        expect(disclosure).not.toBeNull();

        const { toggleNode } = await import("../UI/DOMTree/dom-tree-view-support");
        toggleNode(2);
        toggleNode(2);

        const requestHandler = window.webkit?.messageHandlers?.webInspectorDomRequestChildren?.postMessage as ReturnType<typeof vi.fn>;
        expect(requestHandler).toHaveBeenCalledWith({
            nodeId: 2,
            depth: 3,
            contextID: protocolState.contextID,
        });
    });

    it("requests children as soon as an incomplete node becomes expanded", async () => {
        const { protocolState, treeState } = await import("../UI/DOMTree/dom-tree-state");
        await import("../UI/DOMTree/dom-tree-view");

        window.webInspectorDOMFrontend?.applyFullSnapshot?.({
            root: {
                nodeId: 1,
                nodeType: 9,
                nodeName: "#document",
                localName: "",
                childNodeCount: 1,
                children: [
                    {
                        nodeId: 2,
                        nodeType: 1,
                        nodeName: "HTML",
                        localName: "html",
                        attributes: ["lang", "ja"],
                        childNodeCount: 1,
                        children: [],
                    },
                ],
            },
        }, protocolState.contextID);

        await Promise.resolve();

        const requestHandler = window.webkit?.messageHandlers?.webInspectorDomRequestChildren?.postMessage as ReturnType<typeof vi.fn>;
        expect(requestHandler).toHaveBeenCalledWith({
            nodeId: 2,
            depth: 3,
            contextID: protocolState.contextID,
        });
    });

    it("drops inspector overlay nodes from the rendered tree", async () => {
        const { protocolState, treeState } = await import("../UI/DOMTree/dom-tree-state");
        await import("../UI/DOMTree/dom-tree-view");

        window.webInspectorDOMFrontend?.applyFullSnapshot?.({
            root: {
                nodeId: 1,
                nodeType: 9,
                nodeName: "#document",
                localName: "",
                childNodeCount: 1,
                children: [
                    {
                        nodeId: 2,
                        nodeType: 1,
                        nodeName: "HTML",
                        localName: "html",
                        childNodeCount: 2,
                        children: [
                            {
                                nodeId: 90,
                                nodeType: 1,
                                nodeName: "DIV",
                                localName: "div",
                                attributes: ["data-web-inspector-overlay", "true"],
                                childNodeCount: 0,
                                children: [],
                            },
                            {
                                nodeId: 3,
                                nodeType: 1,
                                nodeName: "BODY",
                                localName: "body",
                                childNodeCount: 0,
                                children: [],
                            },
                        ],
                    },
                ],
            },
        }, protocolState.contextID);

        expect(treeState.nodes.has(90)).toBe(false);
        expect(document.getElementById("dom-tree")?.textContent).not.toContain("data-web-inspector-overlay");
    });

    it("updates bootstrap by adopting a new context", async () => {
        const { protocolState } = await import("../UI/DOMTree/dom-tree-state");
        await import("../UI/DOMTree/dom-tree-view");

        (window.webInspectorDOMFrontend as { updateBootstrap?: (bootstrap: unknown) => void } | undefined)
            ?.updateBootstrap?.({ context: { contextID: 7 } });

        expect(protocolState.contextID).toBe(7);
    });

    it("re-emits ready when bootstrap updates after install", async () => {
        await import("../UI/DOMTree/dom-tree-view");

        const readyHandler = window.webkit?.messageHandlers?.webInspectorReady?.postMessage as ReturnType<typeof vi.fn>;
        expect(readyHandler).toBeTypeOf("function");
        readyHandler.mockClear();

        (window.webInspectorDOMFrontend as { updateBootstrap?: (bootstrap: unknown) => void } | undefined)
            ?.updateBootstrap?.({ context: { contextID: 9 } });

        expect(readyHandler).toHaveBeenCalledTimes(1);
        expect(readyHandler).toHaveBeenCalledWith({ contextID: 9 });
    });

    it("clears transient hover state when native pointer disconnect is reported", async () => {
        const { protocolState } = await import("../UI/DOMTree/dom-tree-state");
        await import("../UI/DOMTree/dom-tree-view");

        (window as Window & { __wiLastDOMTreeHoveredNodeId?: number | null }).__wiLastDOMTreeHoveredNodeId = 7;
        const hideHighlightHandler = window.webkit?.messageHandlers?.webInspectorDomHideHighlight?.postMessage as ReturnType<typeof vi.fn>;

        window.webInspectorDOMFrontend?.clearPointerHoverState?.();

        expect((window as Window & { __wiLastDOMTreeHoveredNodeId?: number | null }).__wiLastDOMTreeHoveredNodeId).toBeNull();
        expect(hideHighlightHandler).toHaveBeenCalledTimes(1);
        expect(hideHighlightHandler).toHaveBeenCalledWith({ contextID: protocolState.contextID });
    });
});
