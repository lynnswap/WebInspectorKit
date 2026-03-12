import { beforeEach, describe, expect, it } from "vitest";

import { cancelElementSelection, startElementSelection } from "../Runtime/DOMAgent/dom-agent-selection";
import { inspector } from "../Runtime/DOMAgent/dom-agent-state";

function resetInspectorState() {
    inspector.map = new Map();
    inspector.nodeMap = new WeakMap();
    inspector.overlay?.remove();
    inspector.overlay = null;
    inspector.overlayTarget = null;
    inspector.pendingOverlayUpdate = false;
    inspector.overlayMutationObserver?.disconnect();
    inspector.overlayMutationObserver = null;
    inspector.overlayMutationObserverActive = false;
    inspector.overlayAutoUpdateConfigured = false;
    inspector.pendingSelectionPath = null;
    inspector.selectionState = null;
    inspector.cursorBackup = null;
    if (inspector.windowClickBlockerRemovalTimer) {
        clearTimeout(inspector.windowClickBlockerRemovalTimer);
    }
    inspector.windowClickBlockerRemovalTimer = null;
    inspector.windowClickBlockerHandler = null;
    inspector.windowClickBlockerPendingRelease = false;
}

function installBoundingRect(element: Element, rect: Partial<DOMRect> = {}) {
    Object.defineProperty(element, "getBoundingClientRect", {
        configurable: true,
        value: () => ({
            x: rect.x ?? 10,
            y: rect.y ?? 12,
            left: rect.left ?? 10,
            top: rect.top ?? 12,
            width: rect.width ?? 100,
            height: rect.height ?? 30,
            right: rect.right ?? 110,
            bottom: rect.bottom ?? 42,
            toJSON: () => ({}),
        }),
    });
}

describe("dom-agent-selection", () => {
    beforeEach(() => {
        resetInspectorState();
        document.body.innerHTML = "<main id=\"root\"><div id=\"target\">hello</div></main>";
        Object.defineProperty(document, "elementFromPoint", {
            configurable: true,
            value: () => document.getElementById("target"),
        });
    });

    it("shows hover highlight when pointer enters an element during selection mode", async () => {
        const target = document.getElementById("target") as HTMLElement;
        installBoundingRect(target);

        const selectionPromise = startElementSelection();
        target.dispatchEvent(new MouseEvent("mouseover", { bubbles: true, clientX: 20, clientY: 24 }));

        expect(inspector.overlayTarget).toBe(target);
        expect(inspector.overlay?.style.display).toBe("block");

        cancelElementSelection();
        await selectionPromise;
    });

    it("normalizes text-node hover targets to their parent element", async () => {
        const target = document.getElementById("target") as HTMLElement;
        const textNode = target.firstChild as Text;
        installBoundingRect(target, { left: 30, top: 40, width: 80, height: 18, right: 110, bottom: 58 });

        Object.defineProperty(document, "elementFromPoint", {
            configurable: true,
            value: () => textNode,
        });

        const selectionPromise = startElementSelection();
        textNode.dispatchEvent(new MouseEvent("mouseover", { bubbles: true, clientX: 34, clientY: 44 }));

        expect(inspector.overlayTarget).toBe(target);
        expect(inspector.overlay?.style.left).toBe("30px");
        expect(inspector.overlay?.style.top).toBe("40px");

        cancelElementSelection();
        await selectionPromise;
    });

    it("stores inspector-compatible selection paths that ignore whitespace-only text nodes", async () => {
        document.body.innerHTML = "<main id=\"root\">\n  <div id=\"target\">hello</div>\n  <span id=\"other\">later</span>\n</main>";
        const target = document.getElementById("target") as HTMLElement;
        installBoundingRect(target);
        Object.defineProperty(document, "elementFromPoint", {
            configurable: true,
            value: () => target,
        });

        const selectionPromise = startElementSelection();
        target.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, clientX: 20, clientY: 24 }));
        target.dispatchEvent(new MouseEvent("mouseup", { bubbles: true, clientX: 20, clientY: 24 }));

        await selectionPromise;

        expect(Array.isArray(inspector.pendingSelectionPath)).toBe(true);
        expect(inspector.pendingSelectionPath?.at(-1)).toBe(0);
    });
});
