import { beforeEach, describe, expect, it, vi } from "vitest";

async function resetEnvironment(): Promise<typeof import("../UI/DOMTree/dom-tree-state")> {
    const state = await import("../UI/DOMTree/dom-tree-state");
    const { protocolState, treeState } = state;
    document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";
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
    protocolState.contextID = 1;
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
        context: { contextID: 1 },
        config: { snapshotDepth: 4, subtreeDepth: 3 },
    };
    (window as Window & { __wiDOMFrontendBootstrap?: unknown }).__wiDOMFrontendBootstrap = bootstrap;
    (window.webInspectorDOMFrontend as { updateBootstrap?: (bootstrap: unknown) => void } | undefined)
        ?.updateBootstrap?.(bootstrap);
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
        }, 1);

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
});
