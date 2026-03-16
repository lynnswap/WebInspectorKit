import { beforeEach, describe, expect, it } from "vitest";

import { applyMutationBundlesFromBuffer } from "../UI/DOMTree/dom-tree-buffer-transport";
import { applyMutationBuffer } from "../UI/DOMTree/dom-tree-snapshot";

describe("dom-tree-buffer-transport", () => {
    beforeEach(() => {
        document.body.innerHTML = "<div id=\"dom-tree\"></div><div id=\"dom-empty\"></div>";
    });

    it("restores mutation bundles from window.webkit.buffers", () => {
        const bundles = [{ kind: "mutation", events: [{ method: "DOM.childNodeCountUpdated", params: { nodeId: 1, childNodeCount: 2 } }] }];
        const encoded = new TextEncoder().encode(JSON.stringify(bundles));
        const webkit = window.webkit as unknown as { buffers?: Record<string, unknown> };
        webkit.buffers = {
            domPayload: encoded
        };

        const restored = applyMutationBundlesFromBuffer("domPayload");
        expect(restored).toEqual(bundles);
    });

    it("returns null when the named buffer is missing", () => {
        const webkit = window.webkit as unknown as { buffers?: Record<string, unknown> };
        webkit.buffers = {};

        const restored = applyMutationBundlesFromBuffer("missing");
        expect(restored).toBeNull();
    });

    it("returns application status from applyMutationBuffer", () => {
        const bundles = [{ kind: "mutation", events: [{ method: "DOM.childNodeCountUpdated", params: { nodeId: 1, childNodeCount: 2 } }] }];
        const encoded = new TextEncoder().encode(JSON.stringify(bundles));
        const webkit = window.webkit as unknown as { buffers?: Record<string, unknown> };
        webkit.buffers = {
            domPayload: encoded
        };

        expect(applyMutationBuffer("domPayload")).toBe(true);
        expect(applyMutationBuffer("missing")).toBe(false);
    });
});
