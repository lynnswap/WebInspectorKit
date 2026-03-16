import { beforeEach, describe, expect, it, vi } from "vitest";

import { setSnapshot } from "../UI/DOMTree/dom-tree-snapshot";
import { dom, renderState, treeState } from "../UI/DOMTree/dom-tree-state";
import type { SerializedNodeEnvelope } from "../UI/DOMTree/dom-tree-types";

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

describe("dom-tree-snapshot envelope conversion", () => {
    beforeEach(() => {
        resetTreeState();
        document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";
    });

    it("converts serialized-node envelope into descriptor while preserving fallback ids", () => {
        const section = document.createElement("section");
        section.setAttribute("id", "target");
        const span = document.createElement("span");
        section.appendChild(span);

        const envelope: SerializedNodeEnvelope = {
            type: "serialized-node-envelope",
            node: section,
            fallback: {
                root: {
                    nodeId: 101,
                    nodeType: 1,
                    nodeName: "SECTION",
                    localName: "section",
                    attributes: ["id", "target"],
                    childNodeCount: 3,
                    children: [{
                        nodeId: 102,
                        nodeType: 1,
                        nodeName: "SPAN",
                        localName: "span",
                        attributes: [],
                        childNodeCount: 0,
                        children: []
                    }]
                },
                selectedNodeId: 102,
                selectedNodePath: [0]
            }
        };

        setSnapshot(envelope, { preserveState: false });

        const root = treeState.snapshot?.root;
        expect(root).not.toBeNull();
        expect(root?.id).toBe(101);
        expect(root?.childCount).toBe(3);
        expect(root?.children.at(0)?.id).toBe(102);
        expect(root?.children.at(-1)?.placeholderParentId).toBe(101);
        expect(treeState.selectedNodeId).toBe(102);

        const messagePayload = selectionHandler().postMessage.mock.calls.at(-1)?.[0] as
            | { id?: number | null }
            | undefined;
        expect(messagePayload?.id).toBe(102);
    });

    it("keeps fallback child structure when serialized root is shallower than fallback", () => {
        const section = document.createElement("section");
        section.setAttribute("id", "target");

        const envelope: SerializedNodeEnvelope = {
            type: "serialized-node-envelope",
            node: section,
            fallback: {
                root: {
                    nodeId: 201,
                    nodeType: 1,
                    nodeName: "SECTION",
                    localName: "section",
                    attributes: ["id", "target"],
                    childNodeCount: 1,
                    children: [{
                        nodeId: 202,
                        nodeType: 1,
                        nodeName: "SPAN",
                        localName: "span",
                        attributes: ["class", "leaf"],
                        childNodeCount: 0,
                        children: []
                    }]
                },
                selectedNodeId: 202,
                selectedNodePath: [0]
            }
        };

        setSnapshot(envelope, { preserveState: false });

        const root = treeState.snapshot?.root;
        expect(root).not.toBeNull();
        expect(root?.id).toBe(201);
        expect(root?.children.length).toBe(1);
        expect(root?.children.at(0)?.id).toBe(202);
        expect(treeState.selectedNodeId).toBe(202);

        const messagePayload = selectionHandler().postMessage.mock.calls.at(-1)?.[0] as
            | { id?: number | null }
            | undefined;
        expect(messagePayload?.id).toBe(202);
    });

    it("resolves selection by path when selectedNodeId is missing", () => {
        const section = document.createElement("section");

        const envelope: SerializedNodeEnvelope = {
            type: "serialized-node-envelope",
            node: section,
            fallback: {
                root: {
                    nodeId: 301,
                    nodeType: 1,
                    nodeName: "SECTION",
                    localName: "section",
                    attributes: [],
                    childNodeCount: 1,
                    children: [{
                        nodeId: 302,
                        nodeType: 1,
                        nodeName: "SPAN",
                        localName: "span",
                        attributes: [],
                        childNodeCount: 0,
                        children: []
                    }]
                },
                selectedNodeId: null,
                selectedNodePath: [0]
            }
        };

        setSnapshot(envelope, { preserveState: false });

        expect(treeState.selectedNodeId).toBe(302);

        const messagePayload = selectionHandler().postMessage.mock.calls.at(-1)?.[0] as
            | { id?: number | null }
            | undefined;
        expect(messagePayload?.id).toBe(302);
    });

    it("falls back to descriptor payload when envelope schemaVersion is unsupported", () => {
        const section = document.createElement("section");

        const envelope: SerializedNodeEnvelope = {
            type: "serialized-node-envelope",
            schemaVersion: 999,
            node: section,
            fallback: {
                root: {
                    nodeId: 401,
                    nodeType: 1,
                    nodeName: "SECTION",
                    localName: "section",
                    attributes: ["id", "fallback"],
                    childNodeCount: 0,
                    children: []
                },
                selectedNodeId: 401,
                selectedNodePath: []
            }
        };

        setSnapshot(envelope, { preserveState: false });

        const root = treeState.snapshot?.root;
        expect(root).not.toBeNull();
        expect(root?.id).toBe(401);
        expect(treeState.selectedNodeId).toBe(401);
    });
});
