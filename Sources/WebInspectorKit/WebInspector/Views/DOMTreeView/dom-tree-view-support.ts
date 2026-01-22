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
} from "./dom-tree-state";
import {
    clampIndentDepth,
    isNodeRendered,
    timeNow,
    trimText,
} from "./dom-tree-utilities";
import { sendCommand, reportInspectorError } from "./dom-tree-protocol";

// =============================================================================
// Module State
// =============================================================================

let selectorRequestToken = 0;
let treeEventHandlersInstalled = false;
let hoveredNodeId: number | null = null;

/** Ensure delegated event handlers are installed */
export function ensureTreeEventHandlers(): void {
    if (treeEventHandlersInstalled) {
        return;
    }
    ensureDomElements();
    if (!dom.tree) {
        return;
    }
    dom.tree.addEventListener("click", handleTreeClick);
    dom.tree.addEventListener("keydown", handleTreeKeydown);
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
    if (!dom.tree) {
        return null;
    }
    return {
        top: dom.tree.scrollTop,
        left: dom.tree.scrollLeft,
    };
}

/** Restore tree scroll position */
export function restoreTreeScrollPosition(position: ScrollPosition | null): void {
    if (!position || !dom.tree) {
        return;
    }
    dom.tree.scrollTop = position.top;
    dom.tree.scrollLeft = position.left;
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

// =============================================================================
// Node Building
// =============================================================================

/** Build a complete node element with row and children container */
export function buildNode(node: DOMNode): HTMLElement {
    const container = document.createElement("div");
    container.className = "tree-node";
    container.dataset.nodeId = String(node.id);
    container.style.setProperty("--depth", String(node.depth || 0));
    container.style.setProperty("--indent-depth", String(clampIndentDepth(node.depth || 0)));
    updateNodeElementState(container, node);

    const row = createNodeRow(node);
    container.appendChild(row);

    const childrenContainer = document.createElement("div");
    childrenContainer.className = "tree-node__children";
    container.appendChild(childrenContainer);
    treeState.elements.set(node.id, container);

    const expanded = nodeShouldBeExpanded(node);
    if (expanded) {
        renderChildren(childrenContainer, node, { initialRender: true });
        treeState.deferredChildRenders.delete(node.id);
    } else {
        treeState.deferredChildRenders.add(node.id);
    }

    setNodeExpanded(node.id, expanded);

    return container;
}

/** Create the row element for a node */
function createNodeRow(node: DOMNode, options: NodeRenderOptions = {}): HTMLElement {
    const { modifiedAttributes = null } = options;
    const row = document.createElement("div");
    row.className = "tree-node__row";
    row.setAttribute("role", "treeitem");
    row.setAttribute("aria-level", String((node.depth || 0) + 1));

    const hasChildren = Array.isArray(node.children) && node.children.length > 0;
    const isPlaceholder = node.nodeType === 0 && node.childCount > 0;

    if (hasChildren) {
        const disclosure = document.createElement("button");
        disclosure.className = "tree-node__disclosure";
        disclosure.type = "button";
        disclosure.setAttribute("aria-label", "Expand or collapse child nodes");
        row.appendChild(disclosure);
    } else {
        const spacer = document.createElement("span");
        spacer.className = "tree-node__disclosure-spacer";
        spacer.setAttribute("aria-hidden", "true");
        row.appendChild(spacer);
    }

    const label = document.createElement("div");
    label.className = "tree-node__label";

    if (isPlaceholder) {
        row.classList.add("tree-node__row--placeholder");

        const placeholderButton = document.createElement("button");
        placeholderButton.type = "button";
        placeholderButton.className = "tree-node__placeholder-button";
        placeholderButton.dataset.role = "load-placeholder";
        placeholderButton.textContent = `… ${node.childCount} more nodes`;
        placeholderButton.setAttribute("aria-label", `Load remaining ${node.childCount} nodes`);

        label.appendChild(placeholderButton);
    } else {
        label.appendChild(createPrimaryLabel(node, { modifiedAttributes }));
    }
    row.appendChild(label);

    return row;
}

/** Create placeholder element for loading more nodes */
function createPlaceholderElement(node: DOMNode): HTMLElement {
    const wrapper = document.createElement("div");
    wrapper.className = "tree-node__placeholder";
    wrapper.style.padding = "0 16px 16px 16px";

    const placeholderButton = document.createElement("button");
    placeholderButton.textContent = "Load";
    placeholderButton.className = "control-button";
    placeholderButton.style.width = "auto";
    placeholderButton.dataset.role = "load-placeholder";

    wrapper.appendChild(placeholderButton);
    return wrapper;
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

    const isPlaceholder = node.nodeType === 0 && node.childCount > 0;
    if (isPlaceholder) {
        container.replaceChildren(createPlaceholderElement(node));
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

    container.querySelectorAll(":scope > .tree-node__placeholder").forEach((element) =>
        element.remove()
    );

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

    element.dataset.nodeId = String(node.id);
    element.style.setProperty("--depth", String(node.depth || 0));
    element.style.setProperty("--indent-depth", String(clampIndentDepth(node.depth || 0)));
    updateNodeElementState(element, node);

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
        if (expanded) {
            renderChildren(childrenContainer, node);
            treeState.deferredChildRenders.delete(node.id);
        } else {
            treeState.deferredChildRenders.add(node.id);
        }
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
    renderState.frameId = requestAnimationFrame(() => processPendingNodeRenders());
}

/** Process pending node renders */
export function processPendingNodeRenders(): void {
    renderState.frameId = null;
    const pending = Array.from(renderState.pendingNodes.values());
    renderState.pendingNodes.clear();

    if (!pending.length) {
        return;
    }

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
        renderState.frameId = requestAnimationFrame(() => processPendingNodeRenders());
    }
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
    return (node.depth || 0) <= 1;
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
    treeState.openState.set(nodeId, expanded);
    const element = treeState.elements.get(nodeId);
    if (!element) {
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
        const node = treeState.nodes.get(nodeId);
        const childrenContainer = element.querySelector(":scope > .tree-node__children") as HTMLElement | null;
        if (node && childrenContainer) {
            renderChildren(childrenContainer, node);
        }
        treeState.deferredChildRenders.delete(nodeId);
    }
}

/** Toggle node expansion state */
export function toggleNode(nodeId: number): void {
    const node = treeState.nodes.get(nodeId);
    if (!node) {
        return;
    }
    const current = nodeShouldBeExpanded(node);
    setNodeExpanded(nodeId, !current);
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

    const placeholderButton = target.closest("[data-role='load-placeholder']");
    if (placeholderButton) {
        event.stopPropagation();
        const node = resolveNodeFromElement(placeholderButton);
        if (node) {
            void requestChildren(node);
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

/** Handle delegated placeholder keyboard activation */
function handleTreeKeydown(event: KeyboardEvent): void {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) {
        return;
    }
    const placeholderButton = target.closest("[data-role='load-placeholder']");
    if (!placeholderButton) {
        return;
    }
    if (event.key !== "Enter" && event.key !== " ") {
        return;
    }
    event.preventDefault();
    const node = resolveNodeFromElement(placeholderButton);
    if (node) {
        void requestChildren(node);
    }
}

/** Handle delegated row hover */
function handleTreeMouseOver(event: MouseEvent): void {
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
    handleRowHover(node);
}

/** Handle delegated row leave */
function handleTreeMouseOut(event: MouseEvent): void {
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
    handleRowLeave();
}

/** Handle leaving the tree container */
function handleTreeMouseLeave(): void {
    hoveredNodeId = null;
    handleRowLeave();
}

/** Handle row click */
function handleRowClick(event: MouseEvent, node: DOMNode): void {
    if (node.nodeType === 0 && node.childCount > 0) {
        requestChildren(node);
        return;
    }
    selectNode(node.id);
}

/** Send highlight command to backend */
async function sendHighlight(nodeId: number): Promise<void> {
    if (!nodeId || nodeId <= 0) {
        return;
    }
    const node = treeState.nodes.get(nodeId);
    if (node && !isNodeRendered(node)) {
        clearPageHighlight();
        return;
    }
    try {
        await sendCommand("DOM.highlightNode", { nodeId });
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
        await sendCommand("Overlay.hideHighlight", {});
    } catch {
        // noop
    }
}

/** Handle row hover */
function handleRowHover(node: DOMNode): void {
    if (node.id > 0) {
        sendHighlight(node.id);
    }
}

/** Handle row leave */
function handleRowLeave(): void {
    clearPageHighlight();
}

// =============================================================================
// Selection
// =============================================================================

/** Schedule selection scroll */
function scheduleSelectionScroll(nodeId: number): void {
    if (!nodeId || !dom.tree) {
        return;
    }
    requestAnimationFrame(() => {
        scrollSelectionIntoView(nodeId);
    });
}

/** Scroll selection into view */
export function scrollSelectionIntoView(nodeId: number): boolean {
    const container = dom.tree;
    const element = treeState.elements.get(nodeId);
    if (!container || !element) {
        return false;
    }
    if (treeState.selectedNodeId !== nodeId) {
        return true;
    }

    const row = element.querySelector(".tree-node__row") || element;
    const containerRect = container.getBoundingClientRect();
    const targetRect = row.getBoundingClientRect();
    const margin = 8;
    const relativeTop = targetRect.top - containerRect.top;
    const relativeBottom = targetRect.bottom - containerRect.top;
    const relativeLeft = targetRect.left - containerRect.left;
    const relativeRight = targetRect.right - containerRect.left;

    const viewportHeight = window.visualViewport?.height ?? window.innerHeight;
    const viewportWidth = window.visualViewport?.width ?? window.innerWidth;
    const visibleHeight = Math.max(
        1,
        Math.min(containerRect.bottom, viewportHeight) - Math.max(0, containerRect.top)
    );
    const visibleWidth = Math.max(
        1,
        Math.min(containerRect.right, viewportWidth) - Math.max(0, containerRect.left)
    );

    const contentTop = container.scrollTop + relativeTop;
    const contentBottom = container.scrollTop + relativeBottom;
    const contentLeft = container.scrollLeft + relativeLeft;
    const contentRight = container.scrollLeft + relativeRight;

    const visibleTop = container.scrollTop;
    const visibleBottom = container.scrollTop + visibleHeight;
    const visibleLeft = container.scrollLeft;
    const visibleRight = container.scrollLeft + visibleWidth;

    const isContainerScrollableV = Math.abs(container.scrollHeight - container.clientHeight) > 1;
    const isContainerScrollableH = Math.abs(container.scrollWidth - container.clientWidth) > 1;
    const visibleInViewportV = targetRect.bottom > margin && targetRect.top < viewportHeight - margin;
    const visibleInViewportH = targetRect.right > margin && targetRect.left < viewportWidth - margin;
    const verticallyVisible = contentBottom > visibleTop + margin && contentTop < visibleBottom - margin;
    const horizontallyVisible = contentRight > visibleLeft + margin && contentLeft < visibleRight - margin;

    if (verticallyVisible && horizontallyVisible) {
        return true;
    }

    let nextTop = container.scrollTop;
    if (!verticallyVisible) {
        if (isContainerScrollableV) {
            const desiredTop = contentTop - visibleHeight / 3;
            const maxTop = Math.max(0, container.scrollHeight - visibleHeight);
            nextTop = Math.min(Math.max(0, desiredTop), maxTop);
        } else if (!visibleInViewportV) {
            const desiredPageTop = (window.scrollY || 0) + targetRect.top - viewportHeight / 3;
            window.scrollTo({ top: Math.max(0, desiredPageTop), behavior: "auto" });
        }
    }

    let nextLeft = container.scrollLeft;
    if (!horizontallyVisible) {
        if (isContainerScrollableH) {
            const desiredLeft = contentLeft - visibleWidth / 5;
            const maxLeft = Math.max(0, container.scrollWidth - visibleWidth);
            nextLeft = Math.min(Math.max(0, desiredLeft), maxLeft);
        } else if (!visibleInViewportH) {
            const desiredPageLeft = (window.scrollX || 0) + targetRect.left - viewportWidth / 5;
            window.scrollTo({ left: Math.max(0, desiredPageLeft), behavior: "auto" });
        }
    }

    const alreadyAtTarget =
        Math.abs(container.scrollTop - nextTop) < 0.5 &&
        Math.abs(container.scrollLeft - nextLeft) < 0.5;
    if (alreadyAtTarget) {
        return true;
    }
    container.scrollTo({ top: nextTop, left: nextLeft, behavior: "auto" });
    return false;
}

/** Select a node by ID */
export function selectNode(nodeId: number, options: SelectionOptions = {}): boolean {
    if (!treeState.nodes.has(nodeId)) {
        return false;
    }

    const { shouldHighlight = true, autoScroll = false } = options;
    revealAncestors(nodeId);

    const previous = treeState.elements.get(treeState.selectedNodeId ?? -1);
    if (previous) {
        previous.classList.remove("is-selected");
    }

    const element = treeState.elements.get(nodeId);
    if (element) {
        element.classList.add("is-selected");
    }

    treeState.selectedNodeId = nodeId;
    setNodeExpanded(nodeId, true);
    const node = treeState.nodes.get(nodeId);
    updateDetails(node ?? null);
    updateSelectionChain(nodeId);

    if (nodeId > 0 && shouldHighlight) {
        sendHighlight(nodeId);
    }

    if (autoScroll) {
        scheduleSelectionScroll(nodeId);
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
    if (!node.placeholderParentId && node.id > 0) {
        try {
            await sendCommand("DOM.requestChildNodes", { nodeId: node.id, depth: childRequestDepth() });
        } catch (error) {
            reportInspectorError("requestChildNodes", error);
        }
        return;
    }
    const parent = node.placeholderParentId || node.parentId || node.id;
    try {
        await sendCommand("DOM.requestChildNodes", { nodeId: parent, depth: childRequestDepth() });
    } catch (error) {
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

    const tag = document.createElement("span");
    tag.className = "tree-node__name";
    tag.textContent = `<${node.displayName}`;
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
          }
        : null;
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

/** Notify native code of selector path */
async function notifyNativeSelectorPath(node: DOMNode | null): Promise<void> {
    const handler = window.webkit?.messageHandlers?.webInspectorDomSelector;
    if (!handler || typeof handler.postMessage !== "function") {
        return;
    }
    const nodeId = node && typeof node.id === "number" ? node.id : null;
    const currentToken = ++selectorRequestToken;

    if (!nodeId) {
        handler.postMessage({ id: null, selectorPath: "" });
        return;
    }

    try {
        const result = await sendCommand<{ selectorPath?: string }>("DOM.getSelectorPath", { nodeId });
        if (currentToken !== selectorRequestToken) {
            return;
        }
        const selectorPath = result && typeof result.selectorPath === "string" ? result.selectorPath : "";
        handler.postMessage({ id: nodeId, selectorPath });
    } catch {
        if (currentToken !== selectorRequestToken) {
            return;
        }
        handler.postMessage({ id: nodeId, selectorPath: "" });
    }
}

/** Update details panel (notifies native) */
export function updateDetails(node: DOMNode | null): void {
    notifyNativeSelection(node || null);
    notifyNativeSelectorPath(node || null);
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
        default: {
            const attrs = (node.attributes || [])
                .map((attr) => `${attr.name}="${attr.value}"`)
                .join(" ");
            const attrText = attrs ? " " + attrs : "";
            return `<${node.displayName}${attrText}>`;
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
