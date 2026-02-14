import {inspector, type AnyNode} from "./dom-agent-state";

const DEFAULT_MAX_RULES = Number.MAX_SAFE_INTEGER;
const MAX_SCANNED_RULES = 25000;

type MatchedStyleOrigin = "inline" | "author";

type MatchedStylesOptions = {
    maxRules?: number;
};

type MatchedStyleDeclaration = {
    name: string;
    value: string;
    important: boolean;
};

type MatchedStyleRule = {
    origin: MatchedStyleOrigin;
    selectorText: string;
    declarations: MatchedStyleDeclaration[];
    sourceLabel: string;
    atRuleContext: string[];
};

type MatchedStylesPayload = {
    nodeId: number;
    rules: MatchedStyleRule[];
    truncated: boolean;
    blockedStylesheetCount: number;
};

type ScopedStyleSheet = {
    styleSheet: CSSStyleSheet;
    scopeRoot: Document | ShadowRoot;
};

function resolveNode(identifier: number): AnyNode | null {
    const map = inspector.map;
    if (!map || !map.size) {
        return null;
    }
    return map.get(identifier) || null;
}

function resolveElement(identifier: number): Element | null {
    const node = resolveNode(identifier);
    if (!node || node.nodeType !== Node.ELEMENT_NODE) {
        return null;
    }
    return node as unknown as Element;
}

function clampMaxRules(value: unknown): number {
    if (typeof value !== "number" || !Number.isFinite(value)) {
        return DEFAULT_MAX_RULES;
    }
    const integerValue = Math.floor(value);
    if (integerValue <= 0) {
        return DEFAULT_MAX_RULES;
    }
    return integerValue;
}

function trimValue(value: string): string {
    return typeof value === "string" ? value.trim() : "";
}

function serializeDeclarations(style: CSSStyleDeclaration | null | undefined): MatchedStyleDeclaration[] {
    if (!style) {
        return [];
    }

    const declarations: MatchedStyleDeclaration[] = [];
    for (let index = 0; index < style.length; index += 1) {
        const name = style[index];
        if (!name) {
            continue;
        }
        const propertyValue = trimValue(style.getPropertyValue(name));
        const important = style.getPropertyPriority(name) === "important";
        declarations.push({
            name,
            value: propertyValue,
            important
        });
    }

    return declarations;
}

function makeInlineRule(element: Element): MatchedStyleRule | null {
    if (!(element instanceof HTMLElement || element instanceof SVGElement)) {
        return null;
    }

    const declarations = serializeDeclarations(element.style);
    if (!declarations.length) {
        return null;
    }

    return {
        origin: "inline",
        selectorText: "element.style",
        declarations,
        sourceLabel: "<element>",
        atRuleContext: []
    };
}

function addStyleSheetsFromList(
    styleSheets: StyleSheetList | CSSStyleSheet[] | null | undefined,
    scopeRoot: Document | ShadowRoot,
    seen: Set<CSSStyleSheet>,
    output: ScopedStyleSheet[]
): void {
    if (!styleSheets) {
        return;
    }

    const length = Array.isArray(styleSheets) ? styleSheets.length : styleSheets.length;
    for (let index = 0; index < length; index += 1) {
        const styleSheet = Array.isArray(styleSheets)
            ? styleSheets[index]
            : (styleSheets.item(index) as CSSStyleSheet | null);
        if (!styleSheet || seen.has(styleSheet)) {
            continue;
        }
        seen.add(styleSheet);
        output.push({styleSheet, scopeRoot});
    }
}

function addAdoptedStyleSheets(
    root: Document | ShadowRoot,
    seen: Set<CSSStyleSheet>,
    output: ScopedStyleSheet[]
): void {
    const candidate = (root as Document & { adoptedStyleSheets?: CSSStyleSheet[] }).adoptedStyleSheets;
    if (!Array.isArray(candidate)) {
        return;
    }
    addStyleSheetsFromList(candidate, root, seen, output);
}

function collectOpenShadowRoots(root: ParentNode): ShadowRoot[] {
    const roots: ShadowRoot[] = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
    let current = walker.nextNode();

    while (current) {
        if (current instanceof Element) {
            const shadowRoot = current.shadowRoot;
            if (shadowRoot && shadowRoot.mode === "open") {
                roots.push(shadowRoot);
                const nestedRoots = collectOpenShadowRoots(shadowRoot);
                roots.push(...nestedRoots);
            }
        }
        current = walker.nextNode();
    }

    return roots;
}

export function collectStyleSheetsWithScope(element: Element): ScopedStyleSheet[] {
    const ownerDocument = element.ownerDocument || document;
    const seen = new Set<CSSStyleSheet>();
    const output: ScopedStyleSheet[] = [];

    addStyleSheetsFromList(ownerDocument.styleSheets, ownerDocument, seen, output);
    addAdoptedStyleSheets(ownerDocument, seen, output);

    const shadowRoots = collectOpenShadowRoots(ownerDocument);
    for (const shadowRoot of shadowRoots) {
        addStyleSheetsFromList(shadowRoot.styleSheets, shadowRoot, seen, output);
        addAdoptedStyleSheets(shadowRoot, seen, output);
    }

    return output;
}

function selectorMatchesElement(element: Element, selectorText: string): boolean {
    if (!selectorText) {
        return false;
    }
    try {
        return element.matches(selectorText);
    } catch {
        return false;
    }
}

function sourceLabelForStyleSheet(styleSheet: CSSStyleSheet): string {
    if (typeof styleSheet.href === "string" && styleSheet.href) {
        return styleSheet.href;
    }
    if (styleSheet.ownerNode) {
        return "<style>";
    }
    return "<adopted stylesheet>";
}

function atRuleLabel(rule: CSSRule): string {
    if (typeof rule.cssText !== "string") {
        return "";
    }
    const header = rule.cssText.split("{")[0]?.trim() ?? "";
    return header.startsWith("@") ? header : "";
}

function readNestedRules(rule: CSSRule): CSSRuleList | null {
    if (rule.type === CSSRule.IMPORT_RULE) {
        const importRule = rule as CSSImportRule;
        if (!importRule.styleSheet) {
            return null;
        }
        try {
            return importRule.styleSheet.cssRules;
        } catch {
            return null;
        }
    }

    const grouping = rule as CSSRule & { cssRules?: CSSRuleList };
    if (grouping.cssRules) {
        return grouping.cssRules;
    }
    return null;
}

export function walkRulesRecursively(
    rules: CSSRuleList,
    atRuleContext: string[],
    visitor: (rule: CSSStyleRule, atRuleContext: string[]) => boolean
): boolean {
    for (let index = 0; index < rules.length; index += 1) {
        const rule = typeof rules.item === "function"
            ? rules.item(index)
            : (rules as unknown as Record<number, CSSRule | undefined>)[index] ?? null;
        if (!rule) {
            continue;
        }

        if (rule.type === CSSRule.STYLE_RULE) {
            if (!visitor(rule as CSSStyleRule, atRuleContext)) {
                return false;
            }
            continue;
        }

        const nested = readNestedRules(rule);
        if (!nested) {
            continue;
        }

        const label = atRuleLabel(rule);
        const nextContext = label ? [...atRuleContext, label] : atRuleContext;
        if (!walkRulesRecursively(nested, nextContext, visitor)) {
            return false;
        }
    }

    return true;
}

function scopeCanApplyToElement(scopeRoot: Document | ShadowRoot, element: Element): boolean {
    if (scopeRoot.nodeType === Node.DOCUMENT_NODE) {
        return element.getRootNode() === scopeRoot;
    }
    return element.getRootNode() === scopeRoot;
}

export function matchedStylesForNode(
    identifier: number,
    options: MatchedStylesOptions = {}
): MatchedStylesPayload {
    const maxRules = clampMaxRules(options.maxRules);
    const payload: MatchedStylesPayload = {
        nodeId: identifier,
        rules: [],
        truncated: false,
        blockedStylesheetCount: 0
    };

    const element = resolveElement(identifier);
    if (!element) {
        return payload;
    }

    const inlineRule = makeInlineRule(element);
    if (inlineRule) {
        payload.rules.push(inlineRule);
    }
    if (payload.rules.length >= maxRules) {
        payload.truncated = true;
        return payload;
    }

    const scopedStyleSheets = collectStyleSheetsWithScope(element);
    let scannedRuleCount = 0;

    for (const scopedStyleSheet of scopedStyleSheets) {
        if (!scopeCanApplyToElement(scopedStyleSheet.scopeRoot, element)) {
            continue;
        }

        let cssRules: CSSRuleList;
        try {
            cssRules = scopedStyleSheet.styleSheet.cssRules;
        } catch {
            payload.blockedStylesheetCount += 1;
            continue;
        }

        const didComplete = walkRulesRecursively(cssRules, [], (styleRule, atRuleContext) => {
            scannedRuleCount += 1;
            if (scannedRuleCount > MAX_SCANNED_RULES) {
                payload.truncated = true;
                return false;
            }

            const selectorText = trimValue(styleRule.selectorText);
            if (!selectorText || !selectorMatchesElement(element, selectorText)) {
                return true;
            }

            const declarations = serializeDeclarations(styleRule.style);
            if (!declarations.length) {
                return true;
            }

            if (payload.rules.length >= maxRules) {
                payload.truncated = true;
                return false;
            }

            payload.rules.push({
                origin: "author",
                selectorText,
                declarations,
                sourceLabel: sourceLabelForStyleSheet(scopedStyleSheet.styleSheet),
                atRuleContext
            });

            if (payload.rules.length >= maxRules) {
                payload.truncated = true;
                return false;
            }

            return true;
        });

        if (!didComplete || payload.truncated) {
            break;
        }
    }

    return payload;
}
