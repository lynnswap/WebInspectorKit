/**
 * DOMTreeViewSupport - UI rendering and interaction support.
 *
 * This module provides:
 * - Node element building and rendering
 * - Selection management
 * - Scroll position handling
 * - Filter/search functionality
 * - Native WebKit notifications
 */

import {
    DOMNode,
    NodeRenderOptions,
    NodeRefreshOptions,
    SelectionOptions,
    ScrollPosition,
    NODE_TYPES,
    TEXT_CONTENT_ATTRIBUTE,
} from "./dom-tree-types";
import {
    dom,
    treeState,
    renderState,
    ensureDomElements,
    childRequestDepth,
    RENDER_BATCH_LIMIT,
    RENDER_TIME_BUDGET,
    protocolState,
} from "./dom-tree-state";
import {
    clampIndentDepth,
    isNodeRendered,
    timeNow,
    trimText,
} from "./dom-tree-utilities";
import {
    isExpectedStaleProtocolResponseError,
    reportInspectorError,
    requestHideHighlight,
    requestHighlightNode,
    requestChildNodes,
} from "./dom-tree-protocol";

// =============================================================================
// Module State
// =============================================================================

let treeEventHandlersInstalled = false;
let treeScrollMetricsObserverInstalled = false;
let hoveredNodeId: number | null = null;
let pendingSelectionRevealNodeId: number | null = null;

type TreeViewportMetrics = {
    top: number;
    left: number;
    width: number;
    height: number;
    safeAreaTop: number;
    safeAreaRight: number;
    safeAreaBottom: number;
    safeAreaLeft: number;
    inlineStartMargin: number;
    blockMargin: number;
};

function treeScrollElement(): HTMLElement {
    if (document.scrollingElement instanceof HTMLElement) {
        return document.scrollingElement;
    }
    if (document.documentElement instanceof HTMLElement) {
        return document.documentElement;
    }
    return document.body;
}

function setRootCSSPixelVariable(name: string, value: number): void {
    document.documentElement.style.setProperty(name, `${Math.max(0, value)}px`);
}

export function syncTreeScrollMetrics(): void {
    setRootCSSPixelVariable("--wi-tree-scroll-left", treeScrollElement().scrollLeft);
}

export function hoverInteractionsEnabled(): boolean {
    if (typeof window.matchMedia !== "function") {
        return true;
    }
    return window.matchMedia("(hover: hover) and (pointer: fine)").matches;
}

function handleTreeViewportScroll(): void {
    syncTreeScrollMetrics();
}

function ensureTreeScrollMetricsObserver(): void {
    if (treeScrollMetricsObserverInstalled) {
        return;
    }
    window.addEventListener("scroll", handleTreeViewportScroll, { passive: true });
    treeScrollMetricsObserverInstalled = true;
}

export function resetTreeInteractionStateForTesting(): void {
    treeEventHandlersInstalled = false;
    if (treeScrollMetricsObserverInstalled) {
        window.removeEventListener("scroll", handleTreeViewportScroll);
        treeScrollMetricsObserverInstalled = false;
    }
    hoveredNodeId = null;
    pendingSelectionRevealNodeId = null;
    document.documentElement.style.removeProperty("--wi-tree-scroll-left");
    (window as Window & {
        __wiLastDOMTreeHoveredNodeId?: number | null;
        __wiLastDOMTreeContextNodeId?: number | null;
    }).__wiLastDOMTreeHoveredNodeId = null;
    (window as Window & {
        __wiLastDOMTreeContextNodeId?: number | null;
    }).__wiLastDOMTreeContextNodeId = null;
}

function cssPixelValue(variableName: string, fallback = 0): number {
    const rawValue = getComputedStyle(document.documentElement).getPropertyValue(variableName).trim();
    if (!rawValue) {
        return fallback;
    }
    const value = Number.parseFloat(rawValue);
    return Number.isFinite(value) ? value : fallback;
}

function viewportMetrics(): TreeViewportMetrics {
    const scrollElement = treeScrollElement();
    const visualViewport = window.visualViewport;
    return {
        top: visualViewport?.pageTop ?? window.scrollY ?? scrollElement.scrollTop ?? 0,
        left: visualViewport?.pageLeft ?? window.scrollX ?? scrollElement.scrollLeft ?? 0,
        width: visualViewport?.width ?? window.innerWidth ?? document.documentElement.clientWidth ?? 0,
        height: visualViewport?.height ?? window.innerHeight ?? document.documentElement.clientHeight ?? 0,
        safeAreaTop: cssPixelValue("--wi-safe-area-top"),
        safeAreaRight: cssPixelValue("--wi-safe-area-right"),
        safeAreaBottom: cssPixelValue("--wi-safe-area-bottom"),
        safeAreaLeft: cssPixelValue("--wi-safe-area-left"),
        inlineStartMargin: cssPixelValue("--wi-selection-reveal-inline-start", 12),
        blockMargin: cssPixelValue("--wi-selection-reveal-block-margin", 8),
    };
}

function clampScrollOffset(offset: number, contentExtent: number, viewportExtent: number): number {
    if (contentExtent > viewportExtent) {
        return Math.min(Math.max(0, offset), contentExtent - viewportExtent);
    }
    return Math.max(0, offset);
}

function syncNodeSelectionState(element: HTMLElement, nodeId: number): void {
    const isSelected = treeState.selectedNodeId === nodeId;
    element.classList.toggle("is-selected", isSelected);
    const row = element.querySelector(":scope > .tree-node__row");
    if (row) {
        row.setAttribute("aria-selected", isSelected ? "true" : "false");
    }
}

function queueSelectionReveal(nodeId: number): void {
    if (!nodeId) {
        return;
    }
    pendingSelectionRevealNodeId = nodeId;
    if (renderState.frameId !== null || renderState.isProcessing) {
        return;
    }
    flushPendingSelectionReveal();
}

function flushPendingSelectionReveal(): void {
    if (
        pendingSelectionRevealNodeId === null ||
        renderState.frameId !== null ||
        renderState.isProcessing
    ) {
        return;
    }
    const nodeId = pendingSelectionRevealNodeId;
    pendingSelectionRevealNodeId = null;
    scheduleSelectionScroll(nodeId);
}

/** Ensure delegated event handlers are installed */
export function ensureTreeEventHandlers(): void {
    if (treeEventHandlersInstalled) {
        ensureTreeScrollMetricsObserver();
        syncTreeScrollMetrics();
        return;
    }
    ensureDomElements();
    if (!dom.tree) {
        return;
    }
    ensureTreeScrollMetricsObserver();
    syncTreeScrollMetrics();
    dom.tree.addEventListener("click", handleTreeClick);
    dom.tree.addEventListener("contextmenu", handleTreeContextMenu);
    dom.tree.addEventListener("mouseover", handleTreeMouseOver);
    dom.tree.addEventListener("mouseout", handleTreeMouseOut);
    dom.tree.addEventListener("mouseleave", handleTreeMouseLeave);
    treeEventHandlersInstalled = true;
}

// =============================================================================
// Scroll Position
// =============================================================================

/** Capture current tree scroll position */
export function captureTreeScrollPosition(): ScrollPosition | null {
    const scrollElement = treeScrollElement();
    return {
        top: scrollElement.scrollTop,
        left: scrollElement.scrollLeft,
    };
}

/** Restore tree scroll position */
export function restoreTreeScrollPosition(position: ScrollPosition | null): void {
    if (!position) {
        return;
    }
    const scrollElement = treeScrollElement();
    scrollElement.scrollTop = position.top;
    scrollElement.scrollLeft = position.left;
    syncTreeScrollMetrics();
}

/** Capture current tree vertical scroll position */
export function captureTreeScrollTop(): number | null {
    return treeScrollElement().scrollTop;
}

/** Restore tree vertical scroll position */
export function restoreTreeScrollTop(top: number | null): void {
    if (top === null) {
        return;
    }
    treeScrollElement().scrollTop = top;
    syncTreeScrollMetrics();
}

// =============================================================================
// Node Element State
// =============================================================================

/** Update rendered state classes on node element */
function updateNodeElementState(element: HTMLElement | null, node: DOMNode): void {
    if (!element) {
        return;
    }
    const rendered = isNodeRendered(node);
    element.classList.toggle("is-rendered", rendered);
    element.classList.toggle("is-unrendered", !rendered);
}

function displayDepthForNode(node: DOMNode): number {
    const rawDepth = typeof node.depth === "number" ? node.depth : 0;
    const snapshotRoot = treeState.snapshot?.root;
    if (snapshotRoot?.nodeType === NODE_TYPES.DOCUMENT_NODE) {
        return Math.max(0, rawDepth - 1);
    }
    return rawDepth;
}

// =============================================================================
// Node Building
// =============================================================================

/** Build a complete node element with row and children container */
export function buildNode(node: DOMNode): HTMLElement {
    const container = document.createElement("div");
    container.className = "tree-node";
    container.dataset.nodeId = String(node.id);
    const displayDepth = displayDepthForNode(node);
    container.style.setProperty("--depth", String(displayDepth));
    container.style.setProperty("--indent-depth", String(clampIndentDepth(displayDepth)));
    updateNodeElementState(container, node);

    const row = createNodeRow(node);
    container.appendChild(row);

    const childrenContainer = document.createElement("div");
    childrenContainer.className = "tree-node__children";
    container.appendChild(childrenContainer);
    treeState.elements.set(node.id, container);
    syncNodeSelectionState(container, node.id);

    const expanded = nodeShouldBeExpanded(node);
    treeState.deferredChildRenders.add(node.id);
    setNodeExpanded(node.id, expanded);

    return container;
}

/** Create the row element for a node */
function createNodeRow(node: DOMNode, options: NodeRenderOptions = {}): HTMLElement {
    const { modifiedAttributes = null } = options;
    const row = document.createElement("div");
    row.className = "tree-node__row";
    row.setAttribute("role", "treeitem");
    row.setAttribute("aria-level", String(displayDepthForNode(node) + 1));
    row.setAttribute("aria-selected", treeState.selectedNodeId === node.id ? "true" : "false");

    const hasChildren = node.childCount > 0 || (Array.isArray(node.children) && node.children.length > 0);

    if (hasChildren) {
        const disclosure = document.createElement("button");
        disclosure.className = "tree-node__disclosure";
        disclosure.type = "button";
        disclosure.setAttribute("aria-label", "Expand or collapse child nodes");
        row.appendChild(disclosure);
    } else if (node.nodeType !== NODE_TYPES.DOCUMENT_TYPE_NODE) {
        const spacer = document.createElement("span");
        spacer.className = "tree-node__disclosure-spacer";
        spacer.setAttribute("aria-hidden", "true");
        row.appendChild(spacer);
    }

    const label = document.createElement("div");
    label.className = "tree-node__label";
    label.appendChild(createPrimaryLabel(node, { modifiedAttributes }));
    row.appendChild(label);

    return row;
}

// =============================================================================
// Children Rendering
// =============================================================================

/** Render children into a container */
export function renderChildren(
    container: HTMLElement | null,
    node: DOMNode,
    { initialRender = false } = {}
): void {
    if (!container) {
        return;
    }

    if (initialRender) {
        container.innerHTML = "";
        if (Array.isArray(node.children)) {
            for (const child of node.children) {
                container.appendChild(buildNode(child));
            }
        }
        return;
    }

    const existingElements = new Map<number, Element>();
    container.querySelectorAll(":scope > .tree-node").forEach((element) => {
        const id = Number((element as HTMLElement).dataset.nodeId);
        if (!Number.isNaN(id)) {
            existingElements.set(id, element);
        }
    });

    const desiredChildren = Array.isArray(node.children) ? node.children : [];
    const orderedElements: HTMLElement[] = [];

    for (const child of desiredChildren) {
        let childElement = treeState.elements.get(child.id);
        if (!childElement) {
            childElement = buildNode(child);
        }
        orderedElements.push(childElement);
        existingElements.delete(child.id);
    }

    existingElements.forEach((element, id) => {
        element.remove();
        treeState.elements.delete(id);
    });

    let referenceNode = container.firstChild;
    for (const element of orderedElements) {
        if (element === referenceNode) {
            referenceNode = referenceNode ? referenceNode.nextSibling : null;
            continue;
        }
        container.insertBefore(element, referenceNode);
    }
}

// =============================================================================
// Node Refresh
// =============================================================================

/** Refresh a node's element in the DOM */
export function refreshNodeElement(node: DOMNode, options: NodeRefreshOptions = {}): void {
    const { updateChildren = true, modifiedAttributes = null } = options;
    const element = treeState.elements.get(node.id);
    if (!element) {
        return;
    }

    const displayDepth = displayDepthForNode(node);
    element.dataset.nodeId = String(node.id);
    element.style.setProperty("--depth", String(displayDepth));
    element.style.setProperty("--indent-depth", String(clampIndentDepth(displayDepth)));
    updateNodeElementState(element, node);
    syncNodeSelectionState(element, node.id);

    const newRow = createNodeRow(node, { modifiedAttributes });
    const existingRow = element.querySelector(":scope > .tree-node__row");
    if (existingRow) {
        existingRow.replaceWith(newRow);
    } else {
        element.insertBefore(newRow, element.firstChild);
    }

    let childrenContainer = element.querySelector(":scope > .tree-node__children") as HTMLElement | null;
    if (!childrenContainer) {
        childrenContainer = document.createElement("div");
        childrenContainer.className = "tree-node__children";
        element.appendChild(childrenContainer);
    }
    const expanded = nodeShouldBeExpanded(node);
    if (updateChildren) {
        treeState.deferredChildRenders.add(node.id);
    }

    setNodeExpanded(node.id, expanded);
}

// =============================================================================
// Render Scheduling
// =============================================================================

/** Merge modified attributes sets */
function mergeModifiedAttributes(
    current: Set<string | symbol> | null,
    next: Set<string | symbol> | null
): Set<string | symbol> | null {
    const hasCurrent = current instanceof Set && current.size > 0;
    const hasNext = next instanceof Set && next.size > 0;

    if (!hasCurrent && !hasNext) {
        return null;
    }

    const merged = new Set(hasCurrent ? current : next);
    if (hasCurrent && hasNext) {
        next!.forEach((attribute) => {
            merged.add(attribute);
        });
    }
    return merged;
}

function requestPendingNodeRenderPass(): void {
    renderState.frameId = requestAnimationFrame(() => processPendingNodeRenders());
    window.setTimeout(() => {
        if (renderState.frameId === null || renderState.isProcessing || renderState.pendingNodes.size === 0) {
            return;
        }
        const pendingFrameId = renderState.frameId;
        renderState.frameId = null;
        if (pendingFrameId !== null) {
            cancelAnimationFrame(pendingFrameId);
        }
        processPendingNodeRenders();
    }, 32);
}

/** Schedule a node for re-rendering */
export function scheduleNodeRender(node: DOMNode, options: NodeRefreshOptions = {}): void {
    if (!node || typeof node.id === "undefined") {
        return;
    }

    const updateChildren = options.updateChildren !== false;
    const modifiedAttributes =
        options.modifiedAttributes instanceof Set ? options.modifiedAttributes : null;

    const existing = renderState.pendingNodes.get(node.id);
    const mergedUpdateChildren = existing ? existing.updateChildren || updateChildren : updateChildren;
    const mergedAttributes = mergeModifiedAttributes(
        existing ? existing.modifiedAttributes : null,
        modifiedAttributes
    );

    renderState.pendingNodes.set(node.id, {
        node,
        updateChildren: mergedUpdateChildren,
        modifiedAttributes: mergedAttributes,
    });

    if (renderState.frameId !== null) {
        return;
    }
    requestPendingNodeRenderPass();
}

/** Process pending node renders */
export function processPendingNodeRenders(): void {
    renderState.frameId = null;
    const pending = Array.from(renderState.pendingNodes.values());
    renderState.pendingNodes.clear();

    if (!pending.length) {
        flushPendingSelectionReveal();
        return;
    }

    renderState.isProcessing = true;
    pending.sort((a, b) => (a.node.depth || 0) - (b.node.depth || 0));

    let index = 0;
    const startedAt = timeNow();

    while (index < pending.length) {
        const item = pending[index];
        index += 1;

        if (!item || !item.node) {
            continue;
        }

        refreshNodeElement(item.node, {
            updateChildren: item.updateChildren,
            modifiedAttributes: item.modifiedAttributes,
        });

        const elapsed = timeNow() - startedAt;
        if (index >= RENDER_BATCH_LIMIT || elapsed >= RENDER_TIME_BUDGET) {
            break;
        }
    }

    if (index < pending.length) {
        for (; index < pending.length; ++index) {
            const item = pending[index];
            if (!item || !item.node) {
                continue;
            }
            const existing = renderState.pendingNodes.get(item.node.id);
            const mergedUpdateChildren = existing
                ? existing.updateChildren || item.updateChildren
                : item.updateChildren;
            const mergedAttributes = mergeModifiedAttributes(
                existing ? existing.modifiedAttributes : null,
                item.modifiedAttributes
            );
            renderState.pendingNodes.set(item.node.id, {
                node: item.node,
                updateChildren: mergedUpdateChildren,
                modifiedAttributes: mergedAttributes,
            });
        }
        renderState.isProcessing = false;
        requestPendingNodeRenderPass();
        return;
    }

    renderState.isProcessing = false;
    flushPendingSelectionReveal();
}

// =============================================================================
// Node Expansion
// =============================================================================

/** Determine if a node should be expanded by default */
export function nodeShouldBeExpanded(node: DOMNode): boolean {
    if (treeState.openState.has(node.id)) {
        return treeState.openState.get(node.id)!;
    }
    if (shouldCollapseByDefault(node)) {
        return false;
    }
    return (node.depth || 0) <= 2;
}

/** Check if node should be collapsed by default (e.g., head element) */
function shouldCollapseByDefault(node: DOMNode): boolean {
    if (!node) {
        return false;
    }
    const name = (node.displayName || node.nodeName || "").toLowerCase();
    return name === "head";
}

/** Set node expanded state */
export function setNodeExpanded(nodeId: number, expanded: boolean): void {
    const node = treeState.nodes.get(nodeId);
    treeState.openState.set(nodeId, expanded);
    const element = treeState.elements.get(nodeId);
    if (!element) {
        if (expanded && node && node.childCount > node.children.length) {
            void requestChildren(node);
        }
        return;
    }

    if (expanded) {
        element.classList.remove("is-collapsed");
    } else {
        element.classList.add("is-collapsed");
    }
    element.setAttribute("aria-expanded", expanded ? "true" : "false");

    const row = element.firstElementChild;
    if (row) {
        const disclosure = row.querySelector(".tree-node__disclosure");
        if (disclosure) {
            disclosure.setAttribute("aria-expanded", expanded ? "true" : "false");
        }
    }

    if (expanded && treeState.deferredChildRenders.has(nodeId)) {
        const childrenContainer = element.querySelector(":scope > .tree-node__children") as HTMLElement | null;
        if (node && childrenContainer) {
            renderChildren(childrenContainer, node);
        }
        treeState.deferredChildRenders.delete(nodeId);
        if (treeState.filter) {
            applyFilter();
        }
    }

    if (expanded && node && node.childCount > node.children.length) {
        void requestChildren(node);
    }
}

/** Toggle node expansion state */
export function toggleNode(nodeId: number): void {
    const node = treeState.nodes.get(nodeId);
    if (!node) {
        return;
    }
    const current = nodeShouldBeExpanded(node);
    const next = !current;
    setNodeExpanded(nodeId, next);
}

// =============================================================================
// Row Interaction
// =============================================================================

/** Resolve node for a given event target */
function resolveNodeFromElement(element: Element | null): DOMNode | null {
    if (!element) {
        return null;
    }
    const nodeElement = element.closest(".tree-node") as HTMLElement | null;
    if (!nodeElement) {
        return null;
    }
    const nodeId = Number(nodeElement.dataset.nodeId);
    if (!Number.isFinite(nodeId)) {
        return null;
    }
    return treeState.nodes.get(nodeId) ?? null;
}

/** Handle tree click via event delegation */
function handleTreeClick(event: MouseEvent): void {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) {
        return;
    }

    const disclosure = target.closest(".tree-node__disclosure");
    if (disclosure) {
        event.stopPropagation();
        const node = resolveNodeFromElement(disclosure);
        if (node) {
            toggleNode(node.id);
        }
        return;
    }

    const row = target.closest(".tree-node__row");
    if (!row) {
        return;
    }
    const node = resolveNodeFromElement(row);
    if (!node) {
        return;
    }
    handleRowClick(event, node);
}

/** Keep selection in sync when opening context menu on a row */
function handleTreeContextMenu(event: MouseEvent): void {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) {
        (window as any).__wiLastDOMTreeContextNodeId = null;
        return;
    }
    const row = target.closest(".tree-node__row");
    if (!row) {
        (window as any).__wiLastDOMTreeContextNodeId = null;
        return;
    }
    const node = resolveNodeFromElement(row);
    if (!node) {
        (window as any).__wiLastDOMTreeContextNodeId = null;
        return;
    }
    (window as any).__wiLastDOMTreeContextNodeId = node.id;
    selectNode(node.id);
}

/** Handle delegated row hover */
function handleTreeMouseOver(event: MouseEvent): void {
    if (!hoverInteractionsEnabled()) {
        return;
    }
    const target = event.target instanceof Element ? event.target : null;
    if (!target) {
        return;
    }
    const row = target.closest(".tree-node__row");
    if (!row) {
        return;
    }
    const node = resolveNodeFromElement(row);
    if (!node || hoveredNodeId === node.id) {
        return;
    }
    hoveredNodeId = node.id;
    (window as any).__wiLastDOMTreeHoveredNodeId = node.id;
    handleRowHover(node);
}

/** Handle delegated row leave */
function handleTreeMouseOut(event: MouseEvent): void {
    if (!hoverInteractionsEnabled()) {
        return;
    }
    const target = event.target instanceof Element ? event.target : null;
    if (!target) {
        return;
    }
    const row = target.closest(".tree-node__row");
    if (!row) {
        return;
    }
    const related = event.relatedTarget instanceof Element ? event.relatedTarget : null;
    if (related && row.contains(related)) {
        return;
    }
    hoveredNodeId = null;
    (window as any).__wiLastDOMTreeHoveredNodeId = null;
    handleRowLeave();
}

/** Handle leaving the tree container */
function handleTreeMouseLeave(): void {
    if (!hoverInteractionsEnabled()) {
        return;
    }
    hoveredNodeId = null;
    (window as any).__wiLastDOMTreeHoveredNodeId = null;
    handleRowLeave();
}

/** Handle row click */
function handleRowClick(event: MouseEvent, node: DOMNode): void {
    selectNode(node.id);
}

/** Send highlight command to backend */
async function sendHighlight(nodeId: number, options: { reveal?: boolean } = {}): Promise<void> {
    if (!nodeId || nodeId <= 0) {
        return;
    }
    const node = treeState.nodes.get(nodeId);
    if (node && !isNodeRendered(node)) {
        clearPageHighlight();
        return;
    }
    try {
        requestHighlightNode(nodeId, options);
    } catch {
        // noop
    }
}

/** Clear page highlight */
export function clearPageHighlight(): void {
    void hideHighlight();
}

/** Hide highlight on the page */
async function hideHighlight(): Promise<void> {
    try {
        requestHideHighlight();
    } catch {
        // noop
    }
}

/** Handle row hover */
function handleRowHover(node: DOMNode): void {
    if (node.id > 0) {
        sendHighlight(node.id, { reveal: false });
    }
}

/** Handle row leave */
function handleRowLeave(): void {
    clearPageHighlight();
}

/** Clear transient hover state after native pointer disconnect */
export function clearPointerHoverState(): void {
    hoveredNodeId = null;
    (window as Window & { __wiLastDOMTreeHoveredNodeId?: number | null }).__wiLastDOMTreeHoveredNodeId = null;
    handleRowLeave();
}

// =============================================================================
// Selection
// =============================================================================

/** Schedule selection scroll */
function scheduleSelectionScroll(nodeId: number): void {
    if (!nodeId) {
        return;
    }
    requestAnimationFrame(() => {
        scrollSelectionIntoView(nodeId);
    });
}

/** Scroll selection into view */
export function scrollSelectionIntoView(nodeId: number): boolean {
    const element = treeState.elements.get(nodeId);
    if (!element) {
        return false;
    }
    if (treeState.selectedNodeId !== nodeId) {
        return true;
    }

    const row = element.querySelector(".tree-node__row") || element;
    const targetRect = row.getBoundingClientRect();
    const viewport = viewportMetrics();
    const absoluteTop = viewport.top + targetRect.top;
    const absoluteBottom = absoluteTop + targetRect.height;
    const absoluteLeft = viewport.left + targetRect.left;
    const visibleTop = viewport.top + viewport.safeAreaTop + viewport.blockMargin;
    const visibleBottom = viewport.top + viewport.height - viewport.safeAreaBottom - viewport.blockMargin;
    const visibleLeft = viewport.left + viewport.safeAreaLeft + viewport.inlineStartMargin;
    const availableHeight = Math.max(
        0,
        viewport.height - viewport.safeAreaTop - viewport.safeAreaBottom - (viewport.blockMargin * 2)
    );
    let nextTop = viewport.top;
    let nextLeft = viewport.left;
    let needsScroll = false;

    if (absoluteLeft < visibleLeft) {
        nextLeft = absoluteLeft - viewport.safeAreaLeft - viewport.inlineStartMargin;
        needsScroll = true;
    }

    if (targetRect.height >= availableHeight) {
        if (absoluteTop < visibleTop || absoluteBottom > visibleBottom) {
            nextTop = absoluteTop - viewport.safeAreaTop - viewport.blockMargin;
            needsScroll = true;
        }
    } else if (absoluteTop < visibleTop) {
        nextTop = absoluteTop - viewport.safeAreaTop - viewport.blockMargin;
        needsScroll = true;
    } else if (absoluteBottom > visibleBottom) {
        nextTop = absoluteBottom - viewport.height + viewport.safeAreaBottom + viewport.blockMargin;
        needsScroll = true;
    }

    if (!needsScroll) {
        return true;
    }

    const scrollElement = treeScrollElement();
    const maxVerticalExtent = Math.max(
        scrollElement.scrollHeight,
        document.documentElement.scrollHeight,
        document.body.scrollHeight
    );
    const maxHorizontalExtent = Math.max(
        scrollElement.scrollWidth,
        document.documentElement.scrollWidth,
        document.body.scrollWidth
    );
    window.scrollTo({
        top: clampScrollOffset(nextTop, maxVerticalExtent, viewport.height),
        left: clampScrollOffset(nextLeft, maxHorizontalExtent, viewport.width),
        behavior: "auto",
    });
    syncTreeScrollMetrics();
    return false;
}

function materializeSelectionElementIfNeeded(nodeId: number): HTMLElement | null {
    let node = treeState.nodes.get(nodeId);
    while (node) {
        const ancestorElement = treeState.elements.get(node.id);
        if (ancestorElement) {
            refreshNodeElement(node, { updateChildren: true });
            return treeState.elements.get(nodeId) ?? null;
        }
        if (!node.parentId) {
            break;
        }
        node = treeState.nodes.get(node.parentId);
    }
    return null;
}

/** Select a node by ID */
export function selectNode(nodeId: number, options: SelectionOptions = {}): boolean {
    if (!treeState.nodes.has(nodeId)) {
        return false;
    }

    const { shouldHighlight = true, autoScroll = false, notifyNative = true } = options;
    revealAncestors(nodeId);

    const previous = treeState.elements.get(treeState.selectedNodeId ?? -1);
    if (previous) {
        previous.classList.remove("is-selected");
    }

    const element = treeState.elements.get(nodeId) ?? materializeSelectionElementIfNeeded(nodeId);
    if (element) {
        element.classList.add("is-selected");
    }

    treeState.selectedNodeId = nodeId;
    setNodeExpanded(nodeId, true);
    const node = treeState.nodes.get(nodeId);
    if (notifyNative) {
        updateDetails(node ?? null);
    }
    updateSelectionChain(nodeId);

    if (nodeId > 0 && shouldHighlight) {
        sendHighlight(nodeId);
    }

    if (autoScroll) {
        queueSelectionReveal(nodeId);
    }

    return true;
}

/** Update selection chain for ancestor tracking */
export function updateSelectionChain(nodeId: number): void {
    const chain: number[] = [];
    let current = treeState.nodes.get(nodeId);
    while (current) {
        chain.unshift(current.id);
        if (!current.parentId) {
            break;
        }
        current = treeState.nodes.get(current.parentId);
    }
    treeState.selectionChain = chain;
}

/** Reopen ancestors in selection chain */
export function reopenSelectionAncestors(): void {
    if (!Array.isArray(treeState.selectionChain) || !treeState.selectionChain.length) {
        return;
    }
    const nextChain: number[] = [];
    for (let index = 0; index < treeState.selectionChain.length; ++index) {
        const nodeId = treeState.selectionChain[index];
        const node = treeState.nodes.get(nodeId);
        if (!node) {
            break;
        }
        nextChain.push(nodeId);
        setNodeExpanded(nodeId, true);
    }
    treeState.selectionChain = nextChain;
}

/** Reveal ancestors by expanding them */
export function revealAncestors(nodeId: number): void {
    let current = treeState.nodes.get(nodeId);
    while (current && current.parentId) {
        setNodeExpanded(current.parentId, true);
        current = treeState.nodes.get(current.parentId);
    }
}

/** Resolve a node by path indices */
export function resolveNodeByPath(path: number[] | null | undefined): DOMNode | null {
    if (!treeState.snapshot || !treeState.snapshot.root) {
        return null;
    }
    if (!Array.isArray(path)) {
        return null;
    }
    let node = treeState.snapshot.root;
    if (!path.length) {
        return node;
    }
    for (const index of path) {
        if (!node.children || index < 0 || index >= node.children.length) {
            return null;
        }
        node = node.children[index];
    }
    return node;
}

/** Select a node by path indices */
export function selectNodeByPath(
    path: number[] | null | undefined,
    options: SelectionOptions = {}
): boolean {
    const target = resolveNodeByPath(path);
    if (!target) {
        return false;
    }
    selectNode(target.id, options);
    return true;
}

// =============================================================================
// Child Loading
// =============================================================================

/** Request children for a node */
export async function requestChildren(node: DOMNode): Promise<void> {
    if (node.id <= 0) {
        return;
    }
    try {
        await requestChildNodes(node.id, childRequestDepth());
    } catch (error) {
        if (isExpectedStaleProtocolResponseError(error)) {
            return;
        }
        reportInspectorError("requestChildNodes", error);
    }
}

// =============================================================================
// Label Rendering
// =============================================================================

/** Create primary label for a node */
function createPrimaryLabel(node: DOMNode, options: NodeRenderOptions = {}): DocumentFragment {
    const { modifiedAttributes = null } = options;
    const highlightClass = "node-state-changed";
    const hasModifiedAttributes = modifiedAttributes instanceof Set && modifiedAttributes.size > 0;
    const textModified = hasModifiedAttributes && modifiedAttributes.has(TEXT_CONTENT_ATTRIBUTE);
    const hasAttributeChanges =
        hasModifiedAttributes &&
        (() => {
            for (const attribute of modifiedAttributes) {
                if (attribute !== TEXT_CONTENT_ATTRIBUTE) {
                    return true;
                }
            }
            return false;
        })();

    function applyFlash(element: HTMLElement | null): void {
        if (!element) {
            return;
        }
        element.classList.remove(highlightClass);
        void element.offsetWidth;
        element.classList.add(highlightClass);
    }

    function shouldHighlightAttribute(name: string): boolean {
        if (!hasModifiedAttributes || typeof name !== "string") {
            return false;
        }
        return modifiedAttributes!.has(name);
    }

    const fragment = document.createDocumentFragment();

    if (node.nodeType === NODE_TYPES.TEXT_NODE) {
        const span = document.createElement("span");
        span.className = "tree-node__text";
        span.textContent = trimText(node.textContent || "");
        if (textModified) {
            applyFlash(span);
        }
        fragment.appendChild(span);
        return fragment;
    }

    if (node.nodeType === NODE_TYPES.COMMENT_NODE) {
        const span = document.createElement("span");
        span.className = "tree-node__text";
        span.textContent = `<!-- ${trimText(node.textContent || "")} -->`;
        if (textModified) {
            applyFlash(span);
        }
        fragment.appendChild(span);
        return fragment;
    }

    if (node.nodeType === NODE_TYPES.DOCUMENT_TYPE_NODE) {
        const span = document.createElement("span");
        span.className = "tree-node__name";
        span.textContent = `<!DOCTYPE ${node.displayName || "html"}>`;
        fragment.appendChild(span);
        return fragment;
    }

    const tagName = (node.displayName || node.nodeName || "").toLowerCase();
    const tag = document.createElement("span");
    tag.className = "tree-node__name";
    tag.textContent = `<${tagName}`;
    fragment.appendChild(tag);

    let didHighlight = false;
    if (Array.isArray(node.attributes)) {
        for (const attr of node.attributes) {
            const attrName = document.createElement("span");
            attrName.className = "tree-node__attribute";
            attrName.textContent = ` ${attr.name}`;
            fragment.appendChild(attrName);

            const attrValue = document.createElement("span");
            attrValue.className = "tree-node__value";
            attrValue.textContent = `="${attr.value}"`;
            fragment.appendChild(attrValue);

            if (shouldHighlightAttribute(attr.name)) {
                applyFlash(attrName);
                applyFlash(attrValue);
                didHighlight = true;
            }
        }
    }

    if (!didHighlight && hasAttributeChanges) {
        applyFlash(tag);
    }

    const closingBracket = document.createElement("span");
    closingBracket.className = "tree-node__name";
    closingBracket.textContent = ">";
    fragment.appendChild(closingBracket);
    if (!didHighlight && hasAttributeChanges) {
        applyFlash(closingBracket);
    }
    return fragment;
}

// =============================================================================
// Selection Path
// =============================================================================

/** Build selection path for native notification */
function buildSelectionPath(node: DOMNode | null): string[] {
    if (!node) {
        return [];
    }
    const labels: string[] = [];
    let current: DOMNode | undefined = node;
    let guard = 0;
    while (current && guard < 200) {
        labels.unshift(renderPreview(current));
        if (!current.parentId) {
            break;
        }
        current = treeState.nodes.get(current.parentId);
        guard++;
    }
    return labels;
}

// =============================================================================
// Native Notifications
// =============================================================================

/** Notify native code of selection change */
function notifyNativeSelection(node: DOMNode | null): void {
    const handler = window.webkit?.messageHandlers?.webInspectorDomSelection;
    if (!handler || typeof handler.postMessage !== "function") {
        return;
    }
    const payload = node
        ? {
              id: typeof node.id === "number" ? node.id : null,
              preview: renderPreview(node),
              attributes: Array.isArray(node.attributes)
                  ? node.attributes.map((attr) => ({
                        name: attr.name || "",
                        value: attr.value || "",
                    }))
                  : [],
              path: buildSelectionPath(node),
              styleRevision: treeState.styleRevision,
              contextID: protocolState.contextID,
          }
        : {
              id: null,
              preview: "",
              attributes: [],
              path: [],
              styleRevision: treeState.styleRevision,
              contextID: protocolState.contextID,
          };
    try {
        handler.postMessage(payload);
    } catch (error) {
        try {
            window.webkit?.messageHandlers?.webInspectorLog?.postMessage(
                `domSelection: ${error && typeof error === "object" && "message" in error ? (error as Error).message : error}`
            );
        } catch {
            // ignore logging failures
        }
    }
}

/** Update details panel (notifies native) */
export function updateDetails(node: DOMNode | null): void {
    notifyNativeSelection(node || null);
}

// =============================================================================
// Preview Rendering
// =============================================================================

/** Render a text preview of a node */
export function renderPreview(node: DOMNode): string {
    switch (node.nodeType) {
        case NODE_TYPES.TEXT_NODE:
            return trimText(node.textContent || "");
        case NODE_TYPES.COMMENT_NODE:
            return `<!-- ${trimText(node.textContent || "")} -->`;
        case NODE_TYPES.DOCUMENT_TYPE_NODE:
            return `<!DOCTYPE ${node.displayName || "html"}>`;
        default: {
            const attrs = (node.attributes || [])
                .map((attr) => `${attr.name}="${attr.value}"`)
                .join(" ");
            const attrText = attrs ? " " + attrs : "";
            return `<${(node.displayName || node.nodeName || "").toLowerCase()}${attrText}>`;
        }
    }
}

// =============================================================================
// Filter/Search
// =============================================================================

/** Set search term and apply filter */
export function setSearchTerm(value: string): void {
    const normalized = typeof value === "string" ? value.trim().toLowerCase() : "";
    if (normalized === treeState.filter) {
        return;
    }
    treeState.filter = normalized;
    applyFilter();
}

/** Apply current filter to tree */
export function applyFilter(): void {
    if (!treeState.snapshot || !treeState.snapshot.root) {
        return;
    }
    const term = treeState.filter;

    function filterNode(node: DOMNode): boolean {
        let nodeMatches = false;
        if (!term) {
            nodeMatches = true;
        } else {
            const label = renderPreview(node).toLowerCase();
            const text = (node.textContent || "").toLowerCase();
            nodeMatches = label.includes(term) || text.includes(term);
        }

        let childMatches = false;
        if (Array.isArray(node.children)) {
            for (const child of node.children) {
                if (filterNode(child)) {
                    childMatches = true;
                }
            }
        }

        const shouldShow = nodeMatches || childMatches || !term;
        const element = treeState.elements.get(node.id);
        if (element) {
            element.classList.toggle("is-filtered-out", !shouldShow);
        }

        return nodeMatches || childMatches;
    }

    filterNode(treeState.snapshot.root);
}
