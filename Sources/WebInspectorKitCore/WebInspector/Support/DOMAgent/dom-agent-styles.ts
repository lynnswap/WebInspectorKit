import {inspector, type AnyNode} from "./dom-agent-state";
import {resumeSnapshotAutoUpdate, suppressSnapshotAutoUpdate} from "./dom-agent-snapshot";

const DEFAULT_MAX_RULES = Number.MAX_SAFE_INTEGER;
const MAX_SCANNED_RULES = 25000;
const CONTAINER_QUERY_PROBE_PROPERTY = "--webkit-matched-styles-container-query-active";
let containerQueryProbeCounter = 0;

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

type ScopeMatchMode = "same-root" | "host" | "slotted" | "none";

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

function collectAssignedSlotsByScope(element: Element): Map<ShadowRoot, HTMLSlotElement[]> {
    const assignedSlotsByScope = new Map<ShadowRoot, HTMLSlotElement[]>();
    const visitedSlots = new Set<HTMLSlotElement>();
    let currentSlot = (element as Element & { assignedSlot?: HTMLSlotElement | null }).assignedSlot ?? null;

    while (currentSlot && !visitedSlots.has(currentSlot)) {
        visitedSlots.add(currentSlot);
        const slotRoot = currentSlot.getRootNode();
        if (slotRoot instanceof ShadowRoot && slotRoot.mode === "open") {
            const slots = assignedSlotsByScope.get(slotRoot) ?? [];
            slots.push(currentSlot);
            assignedSlotsByScope.set(slotRoot, slots);
        }
        currentSlot = (currentSlot as Element & { assignedSlot?: HTMLSlotElement | null }).assignedSlot ?? null;
    }

    return assignedSlotsByScope;
}

function collectRelevantScopeRoots(
    element: Element,
    assignedSlotsByScope: Map<ShadowRoot, HTMLSlotElement[]>
): Array<Document | ShadowRoot> {
    const roots: Array<Document | ShadowRoot> = [];
    const seen = new Set<Document | ShadowRoot>();
    const ownerDocument = element.ownerDocument || document;
    const elementRoot = element.getRootNode();

    const addRoot = (root: Document | ShadowRoot): void => {
        if (!seen.has(root)) {
            seen.add(root);
            roots.push(root);
        }
    };

    if (elementRoot === ownerDocument) {
        addRoot(ownerDocument);
    } else if (elementRoot instanceof ShadowRoot && elementRoot.mode === "open") {
        addRoot(elementRoot);
    }

    const ownShadowRoot = element.shadowRoot;
    if (ownShadowRoot && ownShadowRoot.mode === "open") {
        addRoot(ownShadowRoot);
    }

    for (const scopeRoot of assignedSlotsByScope.keys()) {
        addRoot(scopeRoot);
    }

    if (roots.length === 0) {
        addRoot(ownerDocument);
    }

    return roots;
}

export function collectStyleSheetsWithScope(
    element: Element,
    assignedSlotsByScope: Map<ShadowRoot, HTMLSlotElement[]> = collectAssignedSlotsByScope(element)
): ScopedStyleSheet[] {
    const seenByScope = new Map<Document | ShadowRoot, Set<CSSStyleSheet>>();
    const output: ScopedStyleSheet[] = [];

    const scopeRoots = collectRelevantScopeRoots(element, assignedSlotsByScope);
    for (const scopeRoot of scopeRoots) {
        addStyleSheetsFromList(scopeRoot.styleSheets, scopeRoot, seenByScope, output);
        addAdoptedStyleSheets(scopeRoot, seenByScope, output);
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

type ParsedParenthesizedArgument = {
    argument: string;
    endIndex: number;
};

function readParenthesizedArgument(selectorText: string, openParenIndex: number): ParsedParenthesizedArgument | null {
    if (selectorText[openParenIndex] !== "(") {
        return null;
    }

    let cursor = openParenIndex + 1;
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
                return {
                    argument: selectorText.slice(argumentStart, cursor - 1),
                    endIndex: cursor
                };
            }
            continue;
        }
        cursor += 1;
    }

    return null;
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

type ParsedSlottedSelector = {
    prefix: string;
    argument: string;
    tail: string;
};

function parseSlottedSelector(selectorText: string): ParsedSlottedSelector | null {
    const slottedMarker = "::slotted";
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
            && selectorText.startsWith(slottedMarker, index)
            && bracketDepth === 0
            && parenthesisDepth === 0) {
            const argumentStart = index + slottedMarker.length;
            const parsedArgument = readParenthesizedArgument(selectorText, argumentStart);
            if (!parsedArgument) {
                return null;
            }
            const argument = parsedArgument.argument.trim();
            if (!argument) {
                return null;
            }
            return {
                prefix: selectorText.slice(0, index).trim(),
                argument,
                tail: selectorText.slice(parsedArgument.endIndex).trim()
            };
        }
    }

    return null;
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
    const parsedArgument = readParenthesizedArgument(selectorText, cursor);
    if (!parsedArgument) {
        return null;
    }
    return {
        argument: parsedArgument.argument.trim(),
        consumedLength: parsedArgument.endIndex
    };
}

type ParsedLeadingFunctionalPseudo = {
    argumentsText: string;
    consumedLength: number;
};

function parseLeadingFunctionalPseudo(selectorText: string): ParsedLeadingFunctionalPseudo | null {
    const marker = selectorText.startsWith(":where(")
        ? ":where"
        : selectorText.startsWith(":is(")
            ? ":is"
            : null;
    if (!marker) {
        return null;
    }

    const parsedArgument = readParenthesizedArgument(selectorText, marker.length);
    if (!parsedArgument) {
        return null;
    }

    return {
        argumentsText: parsedArgument.argument,
        consumedLength: parsedArgument.endIndex
    };
}

function expandLeadingFunctionalSelectors(selectorText: string, depth = 0): string[] {
    if (depth > 8) {
        return [selectorText];
    }

    const parsedLeadingFunctional = parseLeadingFunctionalPseudo(selectorText);
    if (!parsedLeadingFunctional) {
        return [selectorText];
    }

    const expandedSelectors: string[] = [];
    const functionalArguments = splitSelectorList(parsedLeadingFunctional.argumentsText);
    const selectorTail = selectorText.slice(parsedLeadingFunctional.consumedLength);
    for (const argumentSelector of functionalArguments) {
        const trimmedArgumentSelector = argumentSelector.trim();
        if (!trimmedArgumentSelector) {
            continue;
        }
        const nextSelector = `${trimmedArgumentSelector}${selectorTail}`;
        expandedSelectors.push(...expandLeadingFunctionalSelectors(nextSelector, depth + 1));
    }
    return expandedSelectors.length ? expandedSelectors : [selectorText];
}

function selectorContainsHostPseudo(selectorText: string): boolean {
    const selectorList = splitSelectorList(selectorText);
    for (const selector of selectorList) {
        const trimmedSelector = selector.trim();
        if (!trimmedSelector) {
            continue;
        }
        for (const expandedSelector of expandLeadingFunctionalSelectors(trimmedSelector)) {
            const trimmedExpandedSelector = expandedSelector.trim();
            if (!trimmedExpandedSelector) {
                continue;
            }
            if (parseLeadingHostPseudo(trimmedExpandedSelector, "host-context")
                || parseLeadingHostPseudo(trimmedExpandedSelector, "host")) {
                return true;
            }
        }
    }
    return false;
}

function selectorContainsSlottedPseudo(selectorText: string): boolean {
    const selectorList = splitSelectorList(selectorText);
    for (const selector of selectorList) {
        const trimmedSelector = selector.trim();
        if (!trimmedSelector) {
            continue;
        }
        if (parseSlottedSelector(trimmedSelector)) {
            return true;
        }
    }
    return false;
}

function matchesShadowIncludingInclusiveAncestors(element: Element, selectorText: string): boolean {
    let current: Element | null = element;
    while (current) {
        try {
            if (current.matches(selectorText)) {
                return true;
            }
        } catch {
            return false;
        }

        if (current.parentElement) {
            current = current.parentElement;
            continue;
        }
        const rootNode = current.getRootNode();
        if (rootNode instanceof ShadowRoot) {
            current = rootNode.host;
            continue;
        }

        current = null;
    }
    return false;
}

function matchesSelectorRelativeToElement(element: Element, selectorText: string): boolean {
    const trimmedSelector = selectorText.trim();
    if (!trimmedSelector) {
        return true;
    }

    const firstCharacter = trimmedSelector[0];
    const isLeadingCombinator = firstCharacter === ">" || firstCharacter === "+" || firstCharacter === "~" || firstCharacter === "|";
    const normalizedSelector = isLeadingCombinator
        ? `:scope ${trimmedSelector}`
        : trimmedSelector;
    try {
        return element.matches(normalizedSelector);
    } catch {
        return false;
    }
}

function hostSelectorVariantMatchesHostElement(selectorText: string, host: Element): boolean {
    const parsedHostContext = parseLeadingHostPseudo(selectorText, "host-context");
    if (parsedHostContext) {
        const contextSelector = parsedHostContext.argument?.trim();
        if (!contextSelector) {
            return false;
        }
        const contextMatched = matchesShadowIncludingInclusiveAncestors(host, contextSelector);
        if (!contextMatched) {
            return false;
        }
        const tail = selectorText.slice(parsedHostContext.consumedLength);
        if (!selectorTailTargetsHost(tail)) {
            return false;
        }
        const tailSelector = tail.trim();
        if (!tailSelector) {
            return true;
        }
        try {
            return host.matches(`*${tailSelector}`);
        } catch {
            return false;
        }
    }

    const parsedHost = parseLeadingHostPseudo(selectorText, "host");
    if (!parsedHost) {
        return false;
    }
    const hostCondition = parsedHost.argument?.trim();
    if (hostCondition) {
        try {
            if (!host.matches(`*${hostCondition}`)) {
                return false;
            }
        } catch {
            return false;
        }
    }
    const tail = selectorText.slice(parsedHost.consumedLength);
    if (!selectorTailTargetsHost(tail)) {
        return false;
    }
    const tailSelector = tail.trim();
    if (!tailSelector) {
        return true;
    }
    try {
        return host.matches(`*${tailSelector}`);
    } catch {
        return false;
    }
}

function hostSelectorMatchesHostElement(selectorText: string, host: Element): boolean {
    const selectorList = splitSelectorList(selectorText);
    for (const selector of selectorList) {
        const trimmedSelector = selector.trim();
        if (!trimmedSelector) {
            continue;
        }
        for (const expandedSelector of expandLeadingFunctionalSelectors(trimmedSelector)) {
            const trimmedExpandedSelector = expandedSelector.trim();
            if (!trimmedExpandedSelector) {
                continue;
            }
            if (hostSelectorVariantMatchesHostElement(trimmedExpandedSelector, host)) {
                return true;
            }
        }
    }
    return false;
}

function slottedPrefixMatchesSlot(prefix: string, slot: HTMLSlotElement): boolean {
    if (!prefix) {
        return true;
    }

    const rootNode = slot.getRootNode();
    const host = rootNode instanceof ShadowRoot ? rootNode.host : null;
    for (const expandedPrefix of expandLeadingFunctionalSelectors(prefix)) {
        const trimmedExpandedPrefix = expandedPrefix.trim();
        if (!trimmedExpandedPrefix) {
            return true;
        }

        const parsedHostContext = parseLeadingHostPseudo(trimmedExpandedPrefix, "host-context");
        if (parsedHostContext) {
            if (!host) {
                continue;
            }
            const contextSelector = parsedHostContext.argument?.trim();
            if (!contextSelector) {
                continue;
            }
            if (!matchesShadowIncludingInclusiveAncestors(host, contextSelector)) {
                continue;
            }

            const remainder = trimmedExpandedPrefix.slice(parsedHostContext.consumedLength);
            if (matchesSelectorRelativeToElement(slot, remainder)) {
                return true;
            }
            continue;
        }

        const parsedHost = parseLeadingHostPseudo(trimmedExpandedPrefix, "host");
        if (parsedHost) {
            if (!host) {
                continue;
            }
            const hostCondition = parsedHost.argument?.trim();
            if (hostCondition && !matchesSelectorRelativeToElement(host, `*${hostCondition}`)) {
                continue;
            }

            const remainder = trimmedExpandedPrefix.slice(parsedHost.consumedLength);
            if (matchesSelectorRelativeToElement(slot, remainder)) {
                return true;
            }
            continue;
        }

        if (matchesSelectorRelativeToElement(slot, trimmedExpandedPrefix)) {
            return true;
        }
    }

    return false;
}

function slottedSelectorMatchesElement(
    selectorText: string,
    element: Element,
    slots: HTMLSlotElement[]
): boolean {
    if (!slots.length) {
        return false;
    }
    const selectorList = splitSelectorList(selectorText);
    for (const selector of selectorList) {
        const trimmedSelector = selector.trim();
        if (!trimmedSelector) {
            continue;
        }
        const parsedSlotted = parseSlottedSelector(trimmedSelector);
        if (!parsedSlotted) {
            continue;
        }
        if (!selectorTailTargetsHost(parsedSlotted.tail)) {
            continue;
        }
        const slottedArgumentSelector = parsedSlotted.tail
            ? `${parsedSlotted.argument}${parsedSlotted.tail}`
            : parsedSlotted.argument;
        let matchesSlottedArgument = false;
        try {
            matchesSlottedArgument = element.matches(slottedArgumentSelector);
        } catch {
            matchesSlottedArgument = false;
        }
        if (!matchesSlottedArgument) {
            continue;
        }

        for (const slot of slots) {
            if (slottedPrefixMatchesSlot(parsedSlotted.prefix, slot)) {
                return true;
            }
        }
    }

    return false;
}

function scopeMatchModeForElement(
    scopeRoot: Document | ShadowRoot,
    element: Element,
    assignedSlotsByScope: Map<ShadowRoot, HTMLSlotElement[]>
): ScopeMatchMode {
    if (scopeRoot.nodeType === Node.DOCUMENT_NODE) {
        return element.getRootNode() === scopeRoot ? "same-root" : "none";
    }
    const shadowRoot = scopeRoot as ShadowRoot;
    if (element.getRootNode() === shadowRoot) {
        return "same-root";
    }
    if (shadowRoot.host === element) {
        return "host";
    }
    if ((assignedSlotsByScope.get(shadowRoot)?.length ?? 0) > 0) {
        return "slotted";
    }
    return "none";
}

function selectorMatchesElement(
    element: Element,
    selectorText: string,
    scopeRoot: Document | ShadowRoot,
    matchMode: ScopeMatchMode,
    assignedSlotsByScope: Map<ShadowRoot, HTMLSlotElement[]>
): boolean {
    if (!selectorText) {
        return false;
    }
    if (matchMode === "host") {
        return hostSelectorMatchesHostElement(selectorText, element);
    }
    if (matchMode === "slotted") {
        if (!(scopeRoot instanceof ShadowRoot)) {
            return false;
        }
        const slots = assignedSlotsByScope.get(scopeRoot) ?? [];
        return slottedSelectorMatchesElement(selectorText, element, slots);
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

function isStyleSheetMediaActive(styleSheet: CSSStyleSheet): boolean {
    return isMediaQueryActive(styleSheet.media?.mediaText);
}

function isStyleSheetEnabled(styleSheet: CSSStyleSheet): boolean {
    if ((styleSheet as CSSStyleSheet & { disabled?: boolean }).disabled) {
        return false;
    }
    const ownerNode = styleSheet.ownerNode as (HTMLLinkElement | HTMLStyleElement | null);
    if (ownerNode && "disabled" in ownerNode) {
        if ((ownerNode as HTMLLinkElement & { disabled?: boolean }).disabled) {
            return false;
        }
    }
    return true;
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

type RuleConditionContext = {
    element: Element;
    containerRuleActivityByRule: Map<CSSRule, boolean>;
};

function isContainerRule(rule: CSSRule): rule is CSSRule & {
    containerName?: string;
    containerQuery?: string;
    conditionText?: string;
    matches?: boolean;
} {
    const containerRuleType = (CSSRule as typeof CSSRule & { CONTAINER_RULE?: number }).CONTAINER_RULE;
    if (typeof containerRuleType === "number" && rule.type === containerRuleType) {
        return true;
    }

    const candidate = rule as CSSRule & { containerQuery?: unknown };
    if (typeof candidate.containerQuery === "string") {
        return true;
    }

    return rule.cssText.startsWith("@container");
}

function makeContainerProbeClassName(): string {
    containerQueryProbeCounter += 1;
    return `__webkitContainerQueryProbe${containerQueryProbeCounter}`;
}

function evaluateContainerRuleActivityWithProbe(
    element: Element,
    containerName: string,
    containerQuery: string
): boolean {
    const ownerDocument = element.ownerDocument;
    if (!ownerDocument) {
        return true;
    }

    const parentElement = element.parentElement;
    if (!parentElement) {
        return true;
    }

    const rootNode = element.getRootNode();
    const styleHost = rootNode instanceof ShadowRoot
        ? rootNode
        : (ownerDocument.head || ownerDocument.documentElement);
    if (!styleHost) {
        return true;
    }

    const probeClassName = makeContainerProbeClassName();
    const containerPrelude = containerName ? `${containerName} ${containerQuery}` : containerQuery;
    const styleElement = ownerDocument.createElement("style");
    styleElement.textContent = `
        .${probeClassName} {
            ${CONTAINER_QUERY_PROBE_PROPERTY}: 0;
        }
        @container ${containerPrelude} {
            .${probeClassName} {
                ${CONTAINER_QUERY_PROBE_PROPERTY}: 1;
            }
        }
    `;

    const probeElement = ownerDocument.createElement("div");
    probeElement.className = probeClassName;
    probeElement.style.cssText = [
        "position: absolute",
        "visibility: hidden",
        "pointer-events: none",
        "width: 0",
        "height: 0",
        "overflow: hidden"
    ].join("; ");
    probeElement.setAttribute("aria-hidden", "true");

    let didSuppressSnapshotAutoUpdate = false;
    try {
        suppressSnapshotAutoUpdate("matched-styles-container-probe");
        didSuppressSnapshotAutoUpdate = true;
        styleHost.appendChild(styleElement);
        parentElement.insertBefore(probeElement, element.nextSibling);
        const computedStyle = ownerDocument.defaultView?.getComputedStyle(probeElement);
        const probeValue = trimValue(computedStyle?.getPropertyValue(CONTAINER_QUERY_PROBE_PROPERTY) ?? "");
        return probeValue === "1";
    } catch {
        return true;
    } finally {
        probeElement.remove();
        styleElement.remove();
        if (didSuppressSnapshotAutoUpdate) {
            resumeSnapshotAutoUpdate("matched-styles-container-probe");
        }
    }
}

function isContainerRuleActive(rule: CSSRule, element: Element): boolean {
    const containerRule = rule as CSSRule & {
        containerName?: unknown;
        containerQuery?: unknown;
        conditionText?: unknown;
        matches?: unknown;
    };

    if (typeof containerRule.matches === "boolean") {
        return containerRule.matches;
    }

    const containerQuery = typeof containerRule.containerQuery === "string"
        ? containerRule.containerQuery.trim()
        : typeof containerRule.conditionText === "string"
            ? containerRule.conditionText.trim()
            : "";
    if (!containerQuery) {
        return true;
    }

    const containerName = typeof containerRule.containerName === "string"
        ? containerRule.containerName.trim()
        : "";
    return evaluateContainerRuleActivityWithProbe(element, containerName, containerQuery);
}

function isRuleConditionActive(rule: CSSRule, ruleConditionContext: RuleConditionContext | null): boolean {
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

    if (isContainerRule(rule)) {
        if (!ruleConditionContext) {
            return true;
        }
        if (ruleConditionContext.containerRuleActivityByRule.has(rule)) {
            return ruleConditionContext.containerRuleActivityByRule.get(rule) ?? true;
        }
        const isActive = isContainerRuleActive(rule, ruleConditionContext.element);
        ruleConditionContext.containerRuleActivityByRule.set(rule, isActive);
        return isActive;
    }

    return true;
}

export function walkRulesRecursively(
    rules: CSSRuleList,
    atRuleContext: string[],
    visitor: (rule: CSSStyleRule, atRuleContext: string[]) => boolean,
    ruleConditionContext: RuleConditionContext | null = null
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
        if (!isRuleConditionActive(rule, ruleConditionContext)) {
            continue;
        }

        const label = atRuleLabel(rule);
        const nextContext = label ? [...atRuleContext, label] : atRuleContext;
        if (!walkRulesRecursively(nested, nextContext, visitor, ruleConditionContext)) {
            return false;
        }
    }

    return true;
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

    const assignedSlotsByScope = collectAssignedSlotsByScope(element);
    const scopedStyleSheets = collectStyleSheetsWithScope(element, assignedSlotsByScope);
    const ruleConditionContext: RuleConditionContext = {
        element,
        containerRuleActivityByRule: new Map<CSSRule, boolean>()
    };
    let scannedRuleCount = 0;

    for (const scopedStyleSheet of scopedStyleSheets) {
        const scopeMatchMode = scopeMatchModeForElement(
            scopedStyleSheet.scopeRoot,
            element,
            assignedSlotsByScope
        );
        if (scopeMatchMode === "none") {
            continue;
        }
        if (!isStyleSheetEnabled(scopedStyleSheet.styleSheet)) {
            continue;
        }
        if (!isStyleSheetMediaActive(scopedStyleSheet.styleSheet)) {
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
            if (!selectorText) {
                return true;
            }
            if (scopeMatchMode === "host" && !selectorContainsHostPseudo(selectorText)) {
                return true;
            }
            if (scopeMatchMode === "slotted" && !selectorContainsSlottedPseudo(selectorText)) {
                return true;
            }
            if (!selectorMatchesElement(
                element,
                selectorText,
                scopedStyleSheet.scopeRoot,
                scopeMatchMode,
                assignedSlotsByScope
            )) {
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
        }, ruleConditionContext);

        if (!didComplete || payload.truncated) {
            break;
        }
    }

    return payload;
}
