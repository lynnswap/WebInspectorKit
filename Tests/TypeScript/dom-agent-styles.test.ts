import { beforeEach, describe, expect, it } from "vitest";

import { inspector } from "../../Sources/WebInspectorKitCore/WebInspector/Support/DOMAgent/dom-agent-state";
import {
    collectStyleSheetsWithScope,
    matchedStylesForNode
} from "../../Sources/WebInspectorKitCore/WebInspector/Support/DOMAgent/dom-agent-styles";

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

function cssRuleListFromRules(items: CSSRule[]): CSSRuleList {
    const list: Record<number, CSSRule> & {
        length: number;
        item: (index: number) => CSSRule | null;
    } = {
        length: items.length,
        item: (index: number): CSSRule | null => items[index] ?? null
    };

    items.forEach((item, index) => {
        list[index] = item;
    });
    return list as unknown as CSSRuleList;
}

type MockDeclaration = [name: string, value: string, important?: boolean];

function styleDeclarationFromEntries(entries: MockDeclaration[]): CSSStyleDeclaration {
    const names = entries.map(([name]) => name);
    const valueByName = new Map(entries.map(([name, value]) => [name, value]));
    const priorityByName = new Map(entries.map(([name, _value, important]) => [name, important ? "important" : ""]));
    const declaration: Record<number | string, unknown> & {
        length: number;
        getPropertyValue: (name: string) => string;
        getPropertyPriority: (name: string) => string;
    } = {
        length: names.length,
        getPropertyValue: (name: string): string => valueByName.get(name) ?? "",
        getPropertyPriority: (name: string): string => priorityByName.get(name) ?? ""
    };

    names.forEach((name, index) => {
        declaration[index] = name;
    });
    return declaration as unknown as CSSStyleDeclaration;
}

function makeStyleRule(selectorText: string, declarations: MockDeclaration[]): CSSStyleRule {
    return {
        type: CSSRule.STYLE_RULE,
        selectorText,
        style: styleDeclarationFromEntries(declarations)
    } as unknown as CSSStyleRule;
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

    it("matches ::slotted rules for assigned light-dom nodes", () => {
        document.body.innerHTML = "<section id=\"host\"><span id=\"target\" slot=\"entry\" class=\"slot-target\"></span></section>";
        const host = document.getElementById("host");
        const target = document.getElementById("target");
        expect(host).not.toBeNull();
        expect(target).not.toBeNull();

        const shadowRoot = host!.attachShadow({ mode: "open" });
        const slotElement = document.createElement("slot");
        slotElement.setAttribute("name", "entry");
        shadowRoot.appendChild(slotElement);
        Object.defineProperty(target as Element & { assignedSlot?: HTMLSlotElement | null }, "assignedSlot", {
            configurable: true,
            value: slotElement
        });

        const shadowStyleSheet = {
            cssRules: cssRuleListFromRules([
                makeStyleRule("::slotted(.slot-target)", [["color", "red"]]),
                makeStyleRule("slot[name=\"entry\"]::slotted(.slot-target)", [["margin", "0"]])
            ])
        } as unknown as CSSStyleSheet;
        Object.defineProperty(shadowRoot as ShadowRoot & { adoptedStyleSheets?: CSSStyleSheet[] }, "adoptedStyleSheets", {
            configurable: true,
            value: [shadowStyleSheet]
        });

        const nodeId = registerNode(target!);
        const payload = matchedStylesForNode(nodeId, { maxRules: 20 });
        const slottedRules = payload.rules.filter((rule) => rule.selectorText.includes("::slotted(.slot-target)"));

        expect(slottedRules.length).toBe(2);
    });

    it("skips inactive media-scoped stylesheets", () => {
        const originalMatchMedia = window.matchMedia;
        const descriptor = Object.getOwnPropertyDescriptor(document, "styleSheets");
        Object.defineProperty(window, "matchMedia", {
            configurable: true,
            value: (query: string): MediaQueryList => ({
                matches: !query.includes("print"),
                media: query,
                onchange: null,
                addListener: () => undefined,
                removeListener: () => undefined,
                addEventListener: () => undefined,
                removeEventListener: () => undefined,
                dispatchEvent: () => false
            })
        });

        try {
            document.body.innerHTML = "<div id=\"target\" class=\"media-target\"></div>";
            const target = document.getElementById("target");
            expect(target).not.toBeNull();
            const nodeId = registerNode(target!);

            const inactiveSheet = {
                media: { mediaText: "print" },
                cssRules: cssRuleListFromRules([
                    makeStyleRule(".media-target", [["color", "red"]])
                ])
            } as unknown as CSSStyleSheet;
            const activeSheet = {
                media: { mediaText: "screen" },
                cssRules: cssRuleListFromRules([
                    makeStyleRule(".media-target", [["color", "blue"]])
                ])
            } as unknown as CSSStyleSheet;
            Object.defineProperty(document, "styleSheets", {
                configurable: true,
                value: styleSheetListFromSheets([inactiveSheet, activeSheet])
            });

            const payload = matchedStylesForNode(nodeId, { maxRules: 20 });
            const matchedRules = payload.rules.filter((rule) => rule.selectorText === ".media-target");

            expect(matchedRules.length).toBe(1);
        } finally {
            if (descriptor) {
                Object.defineProperty(document, "styleSheets", descriptor);
            } else {
                const mutableDocument = document as unknown as { styleSheets?: StyleSheetList };
                delete mutableDocument.styleSheets;
            }
            Object.defineProperty(window, "matchMedia", {
                configurable: true,
                value: originalMatchMedia
            });
        }
    });

    it("skips disabled stylesheets", () => {
        const activeStyle = document.createElement("style");
        activeStyle.textContent = ".disabled-target { color: blue; }";
        document.head.appendChild(activeStyle);

        const disabledStyle = document.createElement("style");
        disabledStyle.textContent = ".disabled-target { color: red; }";
        document.head.appendChild(disabledStyle);

        const disabledSheet = disabledStyle.sheet as (CSSStyleSheet & { disabled?: boolean }) | null;
        if (disabledSheet) {
            Object.defineProperty(disabledSheet, "disabled", {
                configurable: true,
                value: true
            });
        }

        document.body.innerHTML = "<div id=\"target\" class=\"disabled-target\"></div>";
        const target = document.getElementById("target");
        expect(target).not.toBeNull();
        const nodeId = registerNode(target!);

        const payload = matchedStylesForNode(nodeId, { maxRules: 20 });
        const matchedRules = payload.rules.filter((rule) => rule.selectorText === ".disabled-target");

        expect(matchedRules.length).toBe(1);
    });

    it("skips inactive conditional at-rules", () => {
        const globalWithCSS = globalThis as typeof globalThis & {
            CSS?: { supports?: (conditionText: string) => boolean };
        };
        const originalMatchMedia = window.matchMedia;
        const hadCSS = typeof globalWithCSS.CSS !== "undefined";
        const originalCSSObject = globalWithCSS.CSS;
        const originalCSSSupports = originalCSSObject?.supports;

        Object.defineProperty(window, "matchMedia", {
            configurable: true,
            value: (query: string): MediaQueryList => ({
                matches: !query.includes("print"),
                media: query,
                onchange: null,
                addListener: () => undefined,
                removeListener: () => undefined,
                addEventListener: () => undefined,
                removeEventListener: () => undefined,
                dispatchEvent: () => false
            })
        });

        if (!hadCSS) {
            Object.defineProperty(globalWithCSS, "CSS", {
                configurable: true,
                value: {
                    supports: (conditionText: string): boolean => !conditionText.includes("grid")
                }
            });
        } else if (globalWithCSS.CSS) {
            Object.defineProperty(globalWithCSS.CSS, "supports", {
                configurable: true,
                value: (conditionText: string): boolean => !conditionText.includes("grid")
            });
        }

        try {
            document.head.innerHTML = `
                <style>
                    @media print { .conditional-target { color: red; } }
                    @media screen { .conditional-target { color: blue; } }
                    @supports (display: grid) { .conditional-target { border: 1px solid red; } }
                    @supports (display: block) { .conditional-target { margin: 0; } }
                </style>
            `;
            document.body.innerHTML = "<div id=\"target\" class=\"conditional-target\"></div>";
            const target = document.getElementById("target");
            expect(target).not.toBeNull();
            const nodeId = registerNode(target!);

            const payload = matchedStylesForNode(nodeId, { maxRules: 20 });

            const selectors = payload.rules.map((rule) => rule.selectorText);
            expect(selectors.filter((selector) => selector === ".conditional-target").length).toBe(2);
            const hasPrintContext = payload.rules.some((rule) =>
                rule.atRuleContext.some((context) => context.includes("@media print"))
            );
            const hasGridSupportsContext = payload.rules.some((rule) =>
                rule.atRuleContext.some((context) => context.includes("@supports (display: grid)"))
            );
            expect(hasPrintContext).toBe(false);
            expect(hasGridSupportsContext).toBe(false);
        } finally {
            Object.defineProperty(window, "matchMedia", {
                configurable: true,
                value: originalMatchMedia
            });
            if (!hadCSS) {
                Object.defineProperty(globalWithCSS, "CSS", {
                    configurable: true,
                    value: undefined
                });
            } else if (originalCSSObject) {
                Object.defineProperty(originalCSSObject, "supports", {
                    configurable: true,
                    value: originalCSSSupports
                });
            }
        }
    });

    it("includes host selectors when selected element is the shadow host", () => {
        document.body.innerHTML = "<section id=\"host\" class=\"component-host\" data-token=\"a::b\"></section>";
        const host = document.getElementById("host");
        expect(host).not.toBeNull();

        const shadowRoot = host!.attachShadow({ mode: "open" });
        const shadowStyleSheet = {
            cssRules: cssRuleListFromRules([
                makeStyleRule(":host", [["color", "red"]]),
                makeStyleRule(":host(.component-host)", [["display", "block"]]),
                makeStyleRule(":host(:not(.missing))", [["padding", "1px"]]),
                makeStyleRule(":host-context(:not(.outside))", [["border", "1px solid red"]]),
                makeStyleRule(":host[data-token=\"a::b\"]", [["font-size", "12px"]]),
                makeStyleRule(".inside", [["margin", "0"]])
            ])
        } as unknown as CSSStyleSheet;
        Object.defineProperty(shadowRoot as ShadowRoot & { adoptedStyleSheets?: CSSStyleSheet[] }, "adoptedStyleSheets", {
            configurable: true,
            value: [shadowStyleSheet]
        });

        const nodeId = registerNode(host!);
        const payload = matchedStylesForNode(nodeId, { maxRules: 20 });

        expect(payload.rules.some((rule) => rule.selectorText === ":host")).toBe(true);
        expect(payload.rules.some((rule) => rule.selectorText === ":host(.component-host)")).toBe(true);
        expect(payload.rules.some((rule) => rule.selectorText === ":host(:not(.missing))")).toBe(true);
        expect(payload.rules.some((rule) => rule.selectorText === ":host-context(:not(.outside))")).toBe(true);
        expect(payload.rules.some((rule) => rule.selectorText === ":host[data-token=\"a::b\"]")).toBe(true);
        expect(payload.rules.some((rule) => rule.selectorText === ".inside")).toBe(false);
    });

    it("collects stylesheets from relevant scopes only", () => {
        document.body.innerHTML = "<section id=\"host-a\"></section><section id=\"host-b\"></section>";
        const hostA = document.getElementById("host-a");
        const hostB = document.getElementById("host-b");
        expect(hostA).not.toBeNull();
        expect(hostB).not.toBeNull();

        const rootA = hostA!.attachShadow({ mode: "open" });
        const rootB = hostB!.attachShadow({ mode: "open" });
        rootA.innerHTML = "<div class=\"shared-rule\">A</div>";
        rootB.innerHTML = "<div id=\"target\" class=\"shared-rule\">B</div>";

        const sharedStyle = {} as CSSStyleSheet;
        Object.defineProperty(rootA as ShadowRoot & { adoptedStyleSheets?: CSSStyleSheet[] }, "adoptedStyleSheets", {
            configurable: true,
            value: [sharedStyle]
        });
        Object.defineProperty(rootB as ShadowRoot & { adoptedStyleSheets?: CSSStyleSheet[] }, "adoptedStyleSheets", {
            configurable: true,
            value: [sharedStyle]
        });

        const target = rootB.getElementById("target");
        expect(target).not.toBeNull();
        const scopedStyleSheets = collectStyleSheetsWithScope(target!);
        const sharedEntries = scopedStyleSheets.filter((entry) => entry.styleSheet === sharedStyle);

        expect(sharedEntries.length).toBe(1);
        expect(sharedEntries.some((entry) => entry.scopeRoot === rootA)).toBe(false);
        expect(sharedEntries.some((entry) => entry.scopeRoot === rootB)).toBe(true);
    });
});
