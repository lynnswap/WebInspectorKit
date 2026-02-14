import { beforeEach, describe, expect, it } from "vitest";

import { inspector } from "../../Sources/WebInspectorKitCore/WebInspector/Support/DOMAgent/dom-agent-state";
import { matchedStylesForNode } from "../../Sources/WebInspectorKitCore/WebInspector/Support/DOMAgent/dom-agent-styles";

function resetInspectorState(): void {
    inspector.map = new Map();
    inspector.nodeMap = new WeakMap();
    inspector.nextId = 1;
}

function registerNode(node: Node): number {
    if (!inspector.map || !inspector.nodeMap) {
        resetInspectorState();
    }
    const nodeId = inspector.nextId++;
    inspector.map!.set(nodeId, node as never);
    inspector.nodeMap!.set(node as never, nodeId);
    return nodeId;
}

function styleSheetListFromSheets(items: CSSStyleSheet[]): StyleSheetList {
    const list: Record<number, CSSStyleSheet> & {
        length: number;
        item: (index: number) => CSSStyleSheet | null;
    } = {
        length: items.length,
        item: (index: number): CSSStyleSheet | null => items[index] ?? null
    };

    items.forEach((item, index) => {
        list[index] = item;
    });
    return list as unknown as StyleSheetList;
}

describe("dom-agent-styles", () => {
    beforeEach(() => {
        resetInspectorState();
        document.head.innerHTML = "";
        document.body.innerHTML = "";
    });

    it("collects inline and matched author rules", () => {
        document.head.innerHTML = "<style>.match-target { color: red; }</style>";
        document.body.innerHTML = "<div id=\"target\" class=\"match-target\" style=\"display:inline; color: blue !important;\"></div>";
        const target = document.getElementById("target");
        expect(target).not.toBeNull();
        const nodeId = registerNode(target!);

        const payload = matchedStylesForNode(nodeId, { maxRules: 10 });

        expect(payload.nodeId).toBe(nodeId);
        expect(payload.rules.some((rule) => rule.origin === "inline" && rule.selectorText === "element.style")).toBe(true);
        expect(payload.rules.some((rule) => rule.selectorText === ".match-target")).toBe(true);
    });

    it("walks nested group rules and preserves at-rule context", () => {
        document.head.innerHTML = "<style>@media all { .inside-media { padding: 4px; } }</style>";
        document.body.innerHTML = "<div id=\"target\" class=\"inside-media\"></div>";
        const target = document.getElementById("target");
        expect(target).not.toBeNull();
        const nodeId = registerNode(target!);

        const payload = matchedStylesForNode(nodeId, { maxRules: 10 });
        const mediaRule = payload.rules.find((rule) => rule.selectorText === ".inside-media");

        expect(mediaRule).toBeDefined();
        expect(mediaRule?.atRuleContext.length ?? 0).toBeGreaterThan(0);
        expect(mediaRule?.atRuleContext[0]?.startsWith("@media")).toBe(true);
    });

    it("counts blocked stylesheets when cssRules access throws", () => {
        document.head.innerHTML = "<style>.safe-rule { color: green; }</style>";
        document.body.innerHTML = "<div id=\"target\" class=\"safe-rule\"></div>";
        const target = document.getElementById("target");
        expect(target).not.toBeNull();
        const nodeId = registerNode(target!);

        const blockedSheet = {
            href: "https://example.invalid/blocked.css",
            get cssRules(): CSSRuleList {
                throw new DOMException("Blocked", "SecurityError");
            }
        } as unknown as CSSStyleSheet;
        const originalSheets = Array.from(document.styleSheets) as CSSStyleSheet[];
        const descriptor = Object.getOwnPropertyDescriptor(document, "styleSheets");

        Object.defineProperty(document, "styleSheets", {
            configurable: true,
            value: styleSheetListFromSheets([...originalSheets, blockedSheet])
        });

        const payload = matchedStylesForNode(nodeId, { maxRules: 10 });

        if (descriptor) {
            Object.defineProperty(document, "styleSheets", descriptor);
        } else {
            const mutableDocument = document as unknown as { styleSheets?: StyleSheetList };
            delete mutableDocument.styleSheets;
        }

        expect(payload.blockedStylesheetCount).toBe(1);
        expect(payload.rules.some((rule) => rule.selectorText === ".safe-rule")).toBe(true);
    });

    it("marks payload as truncated when maxRules is exceeded", () => {
        document.head.innerHTML = `
            <style>
                .many-rules { color: red; }
                .many-rules { margin: 0; }
                .many-rules { padding: 0; }
            </style>
        `;
        document.body.innerHTML = "<div id=\"target\" class=\"many-rules\" style=\"display:block;\"></div>";
        const target = document.getElementById("target");
        expect(target).not.toBeNull();
        const nodeId = registerNode(target!);

        const payload = matchedStylesForNode(nodeId, { maxRules: 2 });

        expect(payload.truncated).toBe(true);
        expect(payload.rules.length).toBe(2);
    });

    it("does not apply rules from unrelated open shadow roots", () => {
        document.body.innerHTML = "<div id=\"target\" class=\"shadow-only\"></div><section id=\"host\"></section>";
        const target = document.getElementById("target");
        const host = document.getElementById("host");
        expect(target).not.toBeNull();
        expect(host).not.toBeNull();

        const shadowRoot = host!.attachShadow({ mode: "open" });
        shadowRoot.innerHTML = `
            <style>
                .shadow-only { color: red; }
            </style>
            <div class="shadow-only">inside</div>
        `;

        const nodeId = registerNode(target!);
        const payload = matchedStylesForNode(nodeId, { maxRules: 10 });

        expect(payload.rules.some((rule) => rule.selectorText === ".shadow-only")).toBe(false);
    });

    it("does not apply document stylesheets to elements inside shadow root", () => {
        document.head.innerHTML = "<style>.doc-only { color: red; }</style>";
        document.body.innerHTML = "<section id=\"host\"></section>";
        const host = document.getElementById("host");
        expect(host).not.toBeNull();

        const shadowRoot = host!.attachShadow({ mode: "open" });
        shadowRoot.innerHTML = `
            <style>.shadow-only { color: blue; }</style>
            <div id="target" class="doc-only shadow-only"></div>
        `;

        const target = shadowRoot.getElementById("target");
        expect(target).not.toBeNull();
        const nodeId = registerNode(target!);
        const payload = matchedStylesForNode(nodeId, { maxRules: 10 });

        expect(payload.rules.some((rule) => rule.selectorText === ".doc-only")).toBe(false);
    });
});
