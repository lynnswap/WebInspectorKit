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
    seenByScope: Map<Document | ShadowRoot, Set<CSSStyleSheet>>,
    output: ScopedStyleSheet[]
): void {
    if (!styleSheets) {
        return;
    }

    let scopeSeen = seenByScope.get(scopeRoot);
    if (!scopeSeen) {
        scopeSeen = new Set<CSSStyleSheet>();
        seenByScope.set(scopeRoot, scopeSeen);
    }

    const length = Array.isArray(styleSheets) ? styleSheets.length : styleSheets.length;
    for (let index = 0; index < length; index += 1) {
        const styleSheet = Array.isArray(styleSheets)
            ? styleSheets[index]
            : (styleSheets.item(index) as CSSStyleSheet | null);
        if (!styleSheet || scopeSeen.has(styleSheet)) {
            continue;
        }
        scopeSeen.add(styleSheet);
        output.push({styleSheet, scopeRoot});
    }
}

function addAdoptedStyleSheets(
    root: Document | ShadowRoot,
    seenByScope: Map<Document | ShadowRoot, Set<CSSStyleSheet>>,
    output: ScopedStyleSheet[]
): void {
    const candidate = (root as Document & { adoptedStyleSheets?: CSSStyleSheet[] }).adoptedStyleSheets;
    if (!Array.isArray(candidate)) {
        return;
    }
    addStyleSheetsFromList(candidate, root, seenByScope, output);
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
    const seenByScope = new Map<Document | ShadowRoot, Set<CSSStyleSheet>>();
    const output: ScopedStyleSheet[] = [];

    addStyleSheetsFromList(ownerDocument.styleSheets, ownerDocument, seenByScope, output);
    addAdoptedStyleSheets(ownerDocument, seenByScope, output);

    const shadowRoots = collectOpenShadowRoots(ownerDocument);
    for (const shadowRoot of shadowRoots) {
        addStyleSheetsFromList(shadowRoot.styleSheets, shadowRoot, seenByScope, output);
        addAdoptedStyleSheets(shadowRoot, seenByScope, output);
    }

    return output;
}

function splitSelectorList(selectorText: string): string[] {
    const selectors: string[] = [];
    let start = 0;
    let bracketDepth = 0;
    let parenthesisDepth = 0;
    let quoteChar: "\"" | "'" | null = null;
    let escaping = false;

    for (let index = 0; index < selectorText.length; index += 1) {
        const character = selectorText[index];
        if (escaping) {
            escaping = false;
            continue;
        }
        if (character === "\\") {
            escaping = true;
            continue;
        }
        if (quoteChar) {
            if (character === quoteChar) {
                quoteChar = null;
            }
            continue;
        }
        if (character === "\"" || character === "'") {
            quoteChar = character;
            continue;
        }
        if (character === "[") {
            bracketDepth += 1;
            continue;
        }
        if (character === "]" && bracketDepth > 0) {
            bracketDepth -= 1;
            continue;
        }
        if (character === "(") {
            parenthesisDepth += 1;
            continue;
        }
        if (character === ")" && parenthesisDepth > 0) {
            parenthesisDepth -= 1;
            continue;
        }
        if (character === "," && bracketDepth === 0 && parenthesisDepth === 0) {
            const selector = selectorText.slice(start, index).trim();
            if (selector) {
                selectors.push(selector);
            }
            start = index + 1;
        }
    }

    const tail = selectorText.slice(start).trim();
    if (tail) {
        selectors.push(tail);
    }
    return selectors;
}

function hasTopLevelPseudoElement(selectorText: string): boolean {
    let bracketDepth = 0;
    let parenthesisDepth = 0;
    let quoteChar: "\"" | "'" | null = null;
    let escaping = false;

    for (let index = 0; index < selectorText.length; index += 1) {
        const character = selectorText[index];
        if (escaping) {
            escaping = false;
            continue;
        }
        if (character === "\\") {
            escaping = true;
            continue;
        }
        if (quoteChar) {
            if (character === quoteChar) {
                quoteChar = null;
            }
            continue;
        }
        if (character === "\"" || character === "'") {
            quoteChar = character;
            continue;
        }
        if (character === "[") {
            bracketDepth += 1;
            continue;
        }
        if (character === "]" && bracketDepth > 0) {
            bracketDepth -= 1;
            continue;
        }
        if (character === "(") {
            parenthesisDepth += 1;
            continue;
        }
        if (character === ")" && parenthesisDepth > 0) {
            parenthesisDepth -= 1;
            continue;
        }
        if (character === ":"
            && selectorText[index + 1] === ":"
            && bracketDepth === 0
            && parenthesisDepth === 0) {
            return true;
        }
    }

    return false;
}

function selectorTailTargetsHost(tail: string): boolean {
    if (!tail) {
        return true;
    }
    const firstCharacter = tail[0];
    if (/\s/.test(firstCharacter)) {
        return false;
    }
    if (firstCharacter === ">" || firstCharacter === "+" || firstCharacter === "~" || firstCharacter === "|") {
        return false;
    }
    return !hasTopLevelPseudoElement(tail);
}

type ParsedLeadingHostPseudo = {
    argument: string | null;
    consumedLength: number;
};

function parseLeadingHostPseudo(selectorText: string, pseudoName: "host" | "host-context"): ParsedLeadingHostPseudo | null {
    const prefix = `:${pseudoName}`;
    if (!selectorText.startsWith(prefix)) {
        return null;
    }
    let cursor = prefix.length;
    if (selectorText[cursor] !== "(") {
        if (pseudoName === "host") {
            const nextCharacter = selectorText[cursor];
            if (typeof nextCharacter === "undefined") {
                return {
                    argument: null,
                    consumedLength: cursor
                };
            }
            if (nextCharacter === "-") {
                return null;
            }
            if (/\s/.test(nextCharacter)
                || nextCharacter === ","
                || nextCharacter === ">"
                || nextCharacter === "+"
                || nextCharacter === "~"
                || nextCharacter === "|"
                || nextCharacter === ":"
                || nextCharacter === "["
                || nextCharacter === "#"
                || nextCharacter === ".") {
                return {
                    argument: null,
                    consumedLength: cursor
                };
            }
            return null;
        }
        return null;
    }

    cursor += 1;
    const argumentStart = cursor;
    let depth = 1;
    let quoteChar: "\"" | "'" | null = null;
    let escaping = false;

    while (cursor < selectorText.length) {
        const character = selectorText[cursor];
        if (escaping) {
            escaping = false;
            cursor += 1;
            continue;
        }
        if (character === "\\") {
            escaping = true;
            cursor += 1;
            continue;
        }
        if (quoteChar) {
            if (character === quoteChar) {
                quoteChar = null;
            }
            cursor += 1;
            continue;
        }
        if (character === "\"" || character === "'") {
            quoteChar = character;
            cursor += 1;
            continue;
        }
        if (character === "(") {
            depth += 1;
            cursor += 1;
            continue;
        }
        if (character === ")") {
            depth -= 1;
            cursor += 1;
            if (depth === 0) {
                const argument = selectorText.slice(argumentStart, cursor - 1).trim();
                return {
                    argument,
                    consumedLength: cursor
                };
            }
            continue;
        }
        cursor += 1;
    }

    return null;
}

function selectorContainsHostPseudo(selectorText: string): boolean {
    const selectorList = splitSelectorList(selectorText);
    for (const selector of selectorList) {
        const trimmedSelector = selector.trim();
        if (!trimmedSelector) {
            continue;
        }
        if (parseLeadingHostPseudo(trimmedSelector, "host-context")
            || parseLeadingHostPseudo(trimmedSelector, "host")) {
            return true;
        }
    }
    return false;
}

function hostSelectorMatchesHostElement(selectorText: string, host: Element): boolean {
    const selectorList = splitSelectorList(selectorText);
    for (const selector of selectorList) {
        const trimmedSelector = selector.trim();
        if (!trimmedSelector || !selectorContainsHostPseudo(trimmedSelector)) {
            continue;
        }

        const parsedHostContext = parseLeadingHostPseudo(trimmedSelector, "host-context");
        if (parsedHostContext) {
            const contextSelector = parsedHostContext.argument?.trim();
            if (!contextSelector) {
                continue;
            }
            let contextMatched = false;
            try {
                contextMatched = host.matches(contextSelector) || host.closest(contextSelector) !== null;
            } catch {
                contextMatched = false;
            }
            if (!contextMatched) {
                continue;
            }
            const tail = trimmedSelector.slice(parsedHostContext.consumedLength);
            if (!selectorTailTargetsHost(tail)) {
                continue;
            }
            const tailSelector = tail.trim();
            if (!tailSelector) {
                return true;
            }
            try {
                if (host.matches(`*${tailSelector}`)) {
                    return true;
                }
            } catch {
                continue;
            }
            continue;
        }

        const parsedHost = parseLeadingHostPseudo(trimmedSelector, "host");
        if (!parsedHost) {
            continue;
        }
        const hostCondition = parsedHost.argument?.trim();
        if (hostCondition) {
            try {
                if (!host.matches(`*${hostCondition}`)) {
                    continue;
                }
            } catch {
                continue;
            }
        }
        const tail = trimmedSelector.slice(parsedHost.consumedLength);
        if (!selectorTailTargetsHost(tail)) {
            continue;
        }
        const tailSelector = tail.trim();
        if (!tailSelector) {
            return true;
        }
        try {
            if (host.matches(`*${tailSelector}`)) {
                return true;
            }
        } catch {
            continue;
        }
    }
    return false;
}

function selectorMatchesElement(
    element: Element,
    selectorText: string,
    scopeRoot: Document | ShadowRoot
): boolean {
    if (!selectorText) {
        return false;
    }
    const isShadowHostScope = scopeRoot.nodeType === Node.DOCUMENT_FRAGMENT_NODE
        && (scopeRoot as ShadowRoot).host === element;
    if (isShadowHostScope && selectorContainsHostPseudo(selectorText)) {
        return hostSelectorMatchesHostElement(selectorText, element);
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

function isMediaQueryActive(mediaText: string | null | undefined): boolean {
    if (!mediaText || !mediaText.trim() || mediaText.trim() === "all") {
        return true;
    }
    if (typeof window.matchMedia !== "function") {
        return true;
    }
    try {
        return window.matchMedia(mediaText).matches;
    } catch {
        return false;
    }
}

function isSupportsConditionActive(conditionText: string | null | undefined): boolean {
    if (!conditionText || !conditionText.trim()) {
        return true;
    }
    if (typeof CSS === "undefined" || typeof CSS.supports !== "function") {
        return true;
    }
    try {
        return CSS.supports(conditionText);
    } catch {
        return false;
    }
}

function isRuleConditionActive(rule: CSSRule): boolean {
    if (rule.type === CSSRule.MEDIA_RULE) {
        const mediaRule = rule as CSSMediaRule;
        return isMediaQueryActive(mediaRule.conditionText || mediaRule.media?.mediaText);
    }

    // TS DOM lib may not always expose CSSSupportsRule, so inspect conditionText dynamically.
    if (typeof (rule as CSSRule & { conditionText?: unknown }).conditionText === "string"
        && (rule.cssText.startsWith("@supports") || rule.type === CSSRule.SUPPORTS_RULE)) {
        const supportsRule = rule as CSSRule & { conditionText: string };
        return isSupportsConditionActive(supportsRule.conditionText);
    }

    if (rule.type === CSSRule.IMPORT_RULE) {
        const importRule = rule as CSSImportRule;
        return isMediaQueryActive(importRule.media?.mediaText);
    }

    return true;
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
        if (!isRuleConditionActive(rule)) {
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
    if (element.getRootNode() === scopeRoot) {
        return true;
    }
    const shadowRoot = scopeRoot as ShadowRoot;
    return shadowRoot.host === element;
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
        const isShadowHostSelection = scopedStyleSheet.scopeRoot.nodeType === Node.DOCUMENT_FRAGMENT_NODE
            && (scopedStyleSheet.scopeRoot as ShadowRoot).host === element;

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
            if (!selectorText) {
                return true;
            }
            if (isShadowHostSelection && !selectorContainsHostPseudo(selectorText)) {
                return true;
            }
            if (!selectorMatchesElement(element, selectorText, scopedStyleSheet.scopeRoot)) {
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
