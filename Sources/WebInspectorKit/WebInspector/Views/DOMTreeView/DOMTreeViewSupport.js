import {
    NODE_TYPES,
    RENDER_BATCH_LIMIT,
    RENDER_TIME_BUDGET,
    TEXT_CONTENT_ATTRIBUTE,
    childRequestDepth,
    dom,
    renderState,
    treeState as state
} from "./DOMTreeState.js";
import {sendCommand, reportInspectorError} from "./DOMTreeProtocol.js";
import {clampIndentDepth, isNodeRendered, timeNow, trimText} from "./DOMTreeUtilities.js";

let selectorRequestToken = 0;

export function captureTreeScrollPosition() {
    if (!dom.tree)
        return null;
    return {
        top: dom.tree.scrollTop,
        left: dom.tree.scrollLeft
    };
}

export function restoreTreeScrollPosition(position) {
    if (!position || !dom.tree)
        return;
    dom.tree.scrollTop = position.top;
    dom.tree.scrollLeft = position.left;
}

function updateNodeElementState(element, node) {
    if (!element)
        return;
    const rendered = isNodeRendered(node);
    element.classList.toggle("is-rendered", rendered);
    element.classList.toggle("is-unrendered", !rendered);
}

export function buildNode(node) {
    const container = document.createElement("div");
    container.className = "tree-node";
    container.dataset.nodeId = node.id;
    container.style.setProperty("--depth", node.depth || 0);
    container.style.setProperty("--indent-depth", clampIndentDepth(node.depth || 0));
    updateNodeElementState(container, node);

    const row = createNodeRow(node);
    container.appendChild(row);

    const childrenContainer = document.createElement("div");
    childrenContainer.className = "tree-node__children";
    container.appendChild(childrenContainer);
    state.elements.set(node.id, container);

    renderChildren(childrenContainer, node, {initialRender: true});

    const expanded = nodeShouldBeExpanded(node);
    setNodeExpanded(node.id, expanded);

    return container;
}

function createNodeRow(node, options = {}) {
    const {modifiedAttributes = null} = options;
    const row = document.createElement("div");
    row.className = "tree-node__row";
    row.setAttribute("role", "treeitem");
    row.setAttribute("aria-level", (node.depth || 0) + 1);
    row.addEventListener("click", event => handleRowClick(event, node));
    row.addEventListener("mouseenter", () => handleRowHover(node));
    row.addEventListener("mouseleave", handleRowLeave);

    const hasChildren = Array.isArray(node.children) && node.children.length > 0;
    const isPlaceholder = node.nodeType === 0 && node.childCount > 0;

    if (hasChildren) {
        const disclosure = document.createElement("button");
        disclosure.className = "tree-node__disclosure";
        disclosure.type = "button";
        disclosure.setAttribute("aria-label", "Expand or collapse child nodes");
        disclosure.addEventListener("click", event => {
            event.stopPropagation();
            toggleNode(node.id);
        });
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

        const loadPlaceholder = event => {
            if (event)
                event.stopPropagation();
            requestChildren(node);
        };

        const placeholderButton = document.createElement("button");
        placeholderButton.type = "button";
        placeholderButton.className = "tree-node__placeholder-button";
        placeholderButton.textContent = `… ${node.childCount} more nodes`;
        placeholderButton.setAttribute("aria-label", `Load remaining ${node.childCount} nodes`);
        placeholderButton.addEventListener("click", loadPlaceholder);
        placeholderButton.addEventListener("keydown", event => {
            if (event.key !== "Enter" && event.key !== " ")
                return;
            event.preventDefault();
            loadPlaceholder(event);
        });

        label.appendChild(placeholderButton);
    } else {
        label.appendChild(createPrimaryLabel(node, {modifiedAttributes}));
    }
    row.appendChild(label);

    return row;
}

function createPlaceholderElement(node) {
    const wrapper = document.createElement("div");
    wrapper.className = "tree-node__placeholder";
    wrapper.style.padding = "0 16px 16px 16px";

    const placeholderButton = document.createElement("button");
    placeholderButton.textContent = "Load";
    placeholderButton.className = "control-button";
    placeholderButton.style.width = "auto";
    placeholderButton.addEventListener("click", event => {
        event.stopPropagation();
        requestChildren(node);
    });

    wrapper.appendChild(placeholderButton);
    return wrapper;
}

export function renderChildren(container, node, {initialRender = false} = {}) {
    if (!container)
        return;

    const isPlaceholder = node.nodeType === 0 && node.childCount > 0;
    if (isPlaceholder) {
        container.replaceChildren(createPlaceholderElement(node));
        return;
    }

    if (initialRender) {
        container.innerHTML = "";
        if (Array.isArray(node.children)) {
            for (const child of node.children)
                container.appendChild(buildNode(child));
        }
        return;
    }

    container.querySelectorAll(":scope > .tree-node__placeholder").forEach(element => element.remove());

    const existingElements = new Map();
    container.querySelectorAll(":scope > .tree-node").forEach(element => {
        const id = Number(element.dataset.nodeId);
        if (!Number.isNaN(id))
            existingElements.set(id, element);
    });

    const desiredChildren = Array.isArray(node.children) ? node.children : [];
    const orderedElements = [];
    for (const child of desiredChildren) {
        let childElement = state.elements.get(child.id);
        if (!childElement) {
            childElement = buildNode(child);
        }
        orderedElements.push(childElement);
        existingElements.delete(child.id);
    }

    existingElements.forEach((element, id) => {
        element.remove();
        state.elements.delete(id);
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

export function refreshNodeElement(node, options = {}) {
    const {
        updateChildren = true,
        modifiedAttributes = null
    } = options;
    const element = state.elements.get(node.id);
    if (!element)
        return;

    element.dataset.nodeId = node.id;
    element.style.setProperty("--depth", node.depth || 0);
    element.style.setProperty("--indent-depth", clampIndentDepth(node.depth || 0));
    updateNodeElementState(element, node);

    const newRow = createNodeRow(node, {modifiedAttributes});
    const existingRow = element.querySelector(":scope > .tree-node__row");
    if (existingRow)
        existingRow.replaceWith(newRow);
    else
        element.insertBefore(newRow, element.firstChild);

    let childrenContainer = element.querySelector(":scope > .tree-node__children");
    if (!childrenContainer) {
        childrenContainer = document.createElement("div");
        childrenContainer.className = "tree-node__children";
        element.appendChild(childrenContainer);
    }
    if (updateChildren)
        renderChildren(childrenContainer, node);

    setNodeExpanded(node.id, nodeShouldBeExpanded(node));
}

function mergeModifiedAttributes(current, next) {
    const hasCurrent = current instanceof Set && current.size;
    const hasNext = next instanceof Set && next.size;
    if (!hasCurrent && !hasNext)
        return null;
    const merged = new Set(hasCurrent ? current : next);
    if (hasCurrent && hasNext) {
        next.forEach(attribute => {
            merged.add(attribute);
        });
    }
    return merged;
}

export function scheduleNodeRender(node, options = {}) {
    if (!node || typeof node.id === "undefined")
        return;
    const updateChildren = options.updateChildren !== false;
    const modifiedAttributes = options.modifiedAttributes instanceof Set ? options.modifiedAttributes : null;
    const existing = renderState.pendingNodes.get(node.id);
    const mergedUpdateChildren = existing ? (existing.updateChildren || updateChildren) : updateChildren;
    const mergedAttributes = mergeModifiedAttributes(existing ? existing.modifiedAttributes : null, modifiedAttributes);
    renderState.pendingNodes.set(node.id, {node, updateChildren: mergedUpdateChildren, modifiedAttributes: mergedAttributes});
    if (renderState.frameId !== null)
        return;
    renderState.frameId = requestAnimationFrame(() => processPendingNodeRenders());
}

export function processPendingNodeRenders() {
    renderState.frameId = null;
    const pending = Array.from(renderState.pendingNodes.values());
    renderState.pendingNodes.clear();
    if (!pending.length)
        return;

    pending.sort((a, b) => (a.node.depth || 0) - (b.node.depth || 0));

    let index = 0;
    const startedAt = timeNow();

    while (index < pending.length) {
        const item = pending[index];
        index += 1;
        if (!item || !item.node)
            continue;
        refreshNodeElement(item.node, {updateChildren: item.updateChildren, modifiedAttributes: item.modifiedAttributes});
        const elapsed = timeNow() - startedAt;
        if (index >= RENDER_BATCH_LIMIT || elapsed >= RENDER_TIME_BUDGET)
            break;
    }

    if (index < pending.length) {
        for (; index < pending.length; ++index) {
            const item = pending[index];
            if (!item || !item.node)
                continue;
            const existing = renderState.pendingNodes.get(item.node.id);
            const mergedUpdateChildren = existing ? (existing.updateChildren || item.updateChildren) : item.updateChildren;
            const mergedAttributes = mergeModifiedAttributes(existing ? existing.modifiedAttributes : null, item.modifiedAttributes);
            renderState.pendingNodes.set(item.node.id, {node: item.node, updateChildren: mergedUpdateChildren, modifiedAttributes: mergedAttributes});
        }
        renderState.frameId = requestAnimationFrame(() => processPendingNodeRenders());
    }
}

export function nodeShouldBeExpanded(node) {
    if (state.openState.has(node.id))
        return state.openState.get(node.id);
    if (shouldCollapseByDefault(node))
        return false;
    return (node.depth || 0) <= 1;
}

function shouldCollapseByDefault(node) {
    if (!node)
        return false;
    const name = (node.displayName || node.nodeName || "").toLowerCase();
    return name === "head";
}

export function setNodeExpanded(nodeId, expanded) {
    state.openState.set(nodeId, expanded);
    const element = state.elements.get(nodeId);
    if (!element)
        return;
    if (expanded)
        element.classList.remove("is-collapsed");
    else
        element.classList.add("is-collapsed");
    element.setAttribute("aria-expanded", expanded ? "true" : "false");
    const row = element.firstElementChild;
    if (row) {
        const disclosure = row.querySelector(".tree-node__disclosure");
        if (disclosure)
            disclosure.setAttribute("aria-expanded", expanded ? "true" : "false");
    }
}

export function toggleNode(nodeId) {
    const node = state.nodes.get(nodeId);
    if (!node)
        return;
    const current = nodeShouldBeExpanded(node);
    setNodeExpanded(nodeId, !current);
}

function handleRowClick(event, node) {
    if (node.nodeType === 0 && node.childCount > 0) {
        requestChildren(node);
        return;
    }
    selectNode(node.id);
}

async function sendHighlight(nodeId) {
    if (!nodeId || nodeId <= 0)
        return;
    const node = state.nodes.get(nodeId);
    if (node && !isNodeRendered(node)) {
        clearPageHighlight();
        return;
    }
    try {
        await sendCommand("DOM.highlightNode", {nodeId});
    } catch {
        // noop
    }
}

export function clearPageHighlight() {
    void hideHighlight();
}

async function hideHighlight() {
    try {
        await sendCommand("Overlay.hideHighlight", {});
    } catch {
        // noop
    }
}

function handleRowHover(node) {
    if (node.id > 0)
        sendHighlight(node.id);
}

function handleRowLeave() {
    clearPageHighlight();
}

function scheduleSelectionScroll(nodeId) {
    if (!nodeId || !dom.tree)
        return;
    requestAnimationFrame(() => {
        scrollSelectionIntoView(nodeId);
    });
}

export function scrollSelectionIntoView(nodeId) {
    const container = dom.tree;
    const element = state.elements.get(nodeId);
    if (!container || !element)
        return false;
    if (state.selectedNodeId !== nodeId)
        return true;
    const row = element.querySelector(".tree-node__row") || element;
    const containerRect = container.getBoundingClientRect();
    const targetRect = row.getBoundingClientRect();
    const margin = 8;
    const relativeTop = targetRect.top - containerRect.top;
    const relativeBottom = targetRect.bottom - containerRect.top;
    const relativeLeft = targetRect.left - containerRect.left;
    const relativeRight = targetRect.right - containerRect.left;

    const viewportHeight = window.visualViewport.height;
    const viewportWidth = window.visualViewport.width;
    const visibleHeight = Math.max(1, Math.min(containerRect.bottom, viewportHeight) - Math.max(0, containerRect.top));
    const visibleWidth = Math.max(1, Math.min(containerRect.right, viewportWidth) - Math.max(0, containerRect.left));

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
    if (verticallyVisible && horizontallyVisible)
        return true;

    let nextTop = container.scrollTop;
    if (!verticallyVisible) {
        if (isContainerScrollableV) {
            const desiredTop = contentTop - visibleHeight / 3;
            const maxTop = Math.max(0, container.scrollHeight - visibleHeight);
            nextTop = Math.min(Math.max(0, desiredTop), maxTop);
        } else if (!visibleInViewportV) {
            const desiredPageTop = (window.scrollY || 0) + targetRect.top - viewportHeight / 3;
            window.scrollTo({top: Math.max(0, desiredPageTop), behavior: "auto"});
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
            window.scrollTo({left: Math.max(0, desiredPageLeft), behavior: "auto"});
        }
    }
    const alreadyAtTarget = Math.abs(container.scrollTop - nextTop) < 0.5 && Math.abs(container.scrollLeft - nextLeft) < 0.5;
    if (alreadyAtTarget)
        return true;
    container.scrollTo({top: nextTop, left: nextLeft, behavior: "auto"});
    return false;
}

export function selectNode(nodeId, options = {}) {
    if (!state.nodes.has(nodeId))
        return false;
    const {shouldHighlight = true, autoScroll = false} = options;
    revealAncestors(nodeId);
    const previous = state.elements.get(state.selectedNodeId);
    if (previous)
        previous.classList.remove("is-selected");

    const element = state.elements.get(nodeId);
    if (element)
        element.classList.add("is-selected");

    state.selectedNodeId = nodeId;
    setNodeExpanded(nodeId, true);
    const node = state.nodes.get(nodeId);
    updateDetails(node);
    updateSelectionChain(nodeId);

    if (nodeId > 0 && shouldHighlight)
        sendHighlight(nodeId);

    if (autoScroll)
        scheduleSelectionScroll(nodeId);

    return true;
}

export function updateSelectionChain(nodeId) {
    const chain = [];
    let current = state.nodes.get(nodeId);
    while (current) {
        chain.unshift(current.id);
        if (!current.parentId)
            break;
        current = state.nodes.get(current.parentId);
    }
    state.selectionChain = chain;
}

export function reopenSelectionAncestors() {
    if (!Array.isArray(state.selectionChain) || !state.selectionChain.length)
        return;
    const nextChain = [];
    for (let index = 0; index < state.selectionChain.length; ++index) {
        const nodeId = state.selectionChain[index];
        const node = state.nodes.get(nodeId);
        if (!node)
            break;
        nextChain.push(nodeId);
        setNodeExpanded(nodeId, true);
    }
    state.selectionChain = nextChain;
}

export function revealAncestors(nodeId) {
    let current = state.nodes.get(nodeId);
    while (current && current.parentId) {
        setNodeExpanded(current.parentId, true);
        current = state.nodes.get(current.parentId);
    }
}

export function resolveNodeByPath(path) {
    if (!state.snapshot || !state.snapshot.root)
        return null;
    if (!Array.isArray(path))
        return null;
    let node = state.snapshot.root;
    if (!path.length)
        return node;
    for (const index of path) {
        if (!node.children || index < 0 || index >= node.children.length)
            return null;
        node = node.children[index];
    }
    return node;
}

export function selectNodeByPath(path, options = {}) {
    const target = resolveNodeByPath(path);
    if (!target)
        return false;
    selectNode(target.id, options);
    return true;
}

export async function requestChildren(node) {
    if (!node.placeholderParentId && node.id > 0) {
        try {
            await sendCommand("DOM.requestChildNodes", {nodeId: node.id, depth: childRequestDepth()});
        } catch (error) {
            reportInspectorError("requestChildNodes", error);
        }
        return;
    }
    const parent = node.placeholderParentId || node.parentId || node.id;
    try {
        await sendCommand("DOM.requestChildNodes", {nodeId: parent, depth: childRequestDepth()});
    } catch (error) {
        reportInspectorError("requestChildNodes", error);
    }
}

function createPrimaryLabel(node, options = {}) {
    const {modifiedAttributes = null} = options;
    const highlightClass = "node-state-changed";
    const hasModifiedAttributes = modifiedAttributes instanceof Set && modifiedAttributes.size > 0;
    const textModified = hasModifiedAttributes && modifiedAttributes.has(TEXT_CONTENT_ATTRIBUTE);
    const hasAttributeChanges = hasModifiedAttributes && (() => {
        for (const attribute of modifiedAttributes) {
            if (attribute !== TEXT_CONTENT_ATTRIBUTE)
                return true;
        }
        return false;
    })();

    function applyFlash(element) {
        if (!element)
            return;
        element.classList.remove(highlightClass);
        void element.offsetWidth;
        element.classList.add(highlightClass);
    }

    function shouldHighlightAttribute(name) {
        if (!hasModifiedAttributes || typeof name !== "string")
            return false;
        return modifiedAttributes.has(name);
    }

    const fragment = document.createDocumentFragment();
    if (node.nodeType === NODE_TYPES.TEXT_NODE) {
        const span = document.createElement("span");
        span.className = "tree-node__text";
        span.textContent = trimText(node.textContent || "");
        if (textModified)
            applyFlash(span);
        fragment.appendChild(span);
        return fragment;
    }
    if (node.nodeType === NODE_TYPES.COMMENT_NODE) {
        const span = document.createElement("span");
        span.className = "tree-node__text";
        span.textContent = `<!-- ${trimText(node.textContent || "")} -->`;
        if (textModified)
            applyFlash(span);
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

    if (!didHighlight && hasAttributeChanges)
        applyFlash(tag);

    const closingBracket = document.createElement("span");
    closingBracket.className = "tree-node__name";
    closingBracket.textContent = ">";
    fragment.appendChild(closingBracket);
    if (!didHighlight && hasAttributeChanges)
        applyFlash(closingBracket);
    return fragment;
}

function buildSelectionPath(node) {
    if (!node)
        return [];
    const labels = [];
    let current = node;
    let guard = 0;
    while (current && guard < 200) {
        labels.unshift(renderPreview(current));
        if (!current.parentId)
            break;
        current = state.nodes.get(current.parentId);
        guard++;
    }
    return labels;
}

function notifyNativeSelection(node) {
    const handler = window.webkit && window.webkit.messageHandlers ? window.webkit.messageHandlers.webInspectorDomSelection : null;
    if (!handler || typeof handler.postMessage !== "function")
        return;
    const payload = node ? {
        id: typeof node.id === "number" ? node.id : null,
        preview: renderPreview(node),
        attributes: Array.isArray(node.attributes) ? node.attributes.map(attr => ({
            name: attr.name || "",
            value: attr.value || ""
        })) : [],
        path: buildSelectionPath(node)
    } : null;
    try {
        handler.postMessage(payload);
    } catch (error) {
        try {
            window.webkit.messageHandlers.webInspectorLog.postMessage(`domSelection: ${error && error.message ? error.message : error}`);
        } catch {
            // ignore logging failures
        }
    }
}

async function notifyNativeSelectorPath(node) {
    const handler = window.webkit && window.webkit.messageHandlers ? window.webkit.messageHandlers.webInspectorDomSelector : null;
    if (!handler || typeof handler.postMessage !== "function") {
        return;
    }
    const nodeId = node && typeof node.id === "number" ? node.id : null;
    const currentToken = ++selectorRequestToken;
    if (!nodeId) {
        handler.postMessage({id: null, selectorPath: ""});
        return;
    }
    try {
        const result = await sendCommand("DOM.getSelectorPath", {nodeId});
        if (currentToken !== selectorRequestToken)
            return;
        const selectorPath = result && typeof result.selectorPath === "string" ? result.selectorPath : "";
        handler.postMessage({id: nodeId, selectorPath});
    } catch {
        if (currentToken !== selectorRequestToken)
            return;
        handler.postMessage({id: nodeId, selectorPath: ""});
    }
}

export function updateDetails(node) {
    notifyNativeSelection(node || null);
    notifyNativeSelectorPath(node || null);
}

export function renderPreview(node) {
    switch (node.nodeType) {
    case NODE_TYPES.TEXT_NODE:
        return trimText(node.textContent || "");
    case NODE_TYPES.COMMENT_NODE:
        return `<!-- ${trimText(node.textContent || "")} -->`;
    default:
        const attrs = (node.attributes || [])
            .map(attr => `${attr.name}="${attr.value}"`)
            .join(" ");
        const attrText = attrs ? " " + attrs : "";
        return `<${node.displayName}${attrText}>`;
    }
}

export function setSearchTerm(value) {
    const normalized = typeof value === "string" ? value.trim().toLowerCase() : "";
    if (normalized === state.filter)
        return;
    state.filter = normalized;
    applyFilter();
}

export function applyFilter() {
    if (!state.snapshot || !state.snapshot.root)
        return;
    const term = state.filter;

    function filterNode(node) {
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
                if (filterNode(child))
                    childMatches = true;
            }
        }

        const shouldShow = nodeMatches || childMatches || !term;
        const element = state.elements.get(node.id);
        if (element)
            element.classList.toggle("is-filtered-out", !shouldShow);

        return nodeMatches || childMatches;
    }

    filterNode(state.snapshot.root);
}
