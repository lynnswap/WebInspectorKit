import type { AnyNode } from "./dom-agent-state";

type RenderedElement = Element & {
    offsetWidth?: number;
    offsetHeight?: number;
    getBBox?: () => DOMRect;
};

export function nodeIsRendered(node: AnyNode | null) {
    if (!node) {
        return false;
    }

    switch (node.nodeType) {
    case Node.ELEMENT_NODE:
        return elementIsRendered(node as RenderedElement);
    case Node.TEXT_NODE:
        return textNodeIsRendered(node);
    case Node.DOCUMENT_NODE:
    case Node.DOCUMENT_FRAGMENT_NODE:
        return true;
    default:
        return true;
    }
}

export function elementIsRendered(element: RenderedElement | null) {
    if (!element || !element.isConnected) {
        return false;
    }

    let style: CSSStyleDeclaration | null = null;
    try {
        style = window.getComputedStyle(element);
    } catch {
    }

    if (style && style.display === "none") {
        return false;
    }

    if (element.getClientRects) {
        const rectList = element.getClientRects();
        if (rectList && rectList.length) {
            for (let index = 0; index < rectList.length; index += 1) {
                const rect = rectList[index];
                if (rect && (rect.width || rect.height)) {
                    return true;
                }
            }
        }
    }

    if (element.getBoundingClientRect) {
        const rect = element.getBoundingClientRect();
        if (rect && (rect.width || rect.height)) {
            return true;
        }
    }

    if (typeof element.offsetWidth === "number" || typeof element.offsetHeight === "number") {
        if (element.offsetWidth || element.offsetHeight) {
            return true;
        }
    }

    if (style && (style.position === "fixed" || style.position === "sticky")) {
        return true;
    }

    if (typeof element.getBBox === "function") {
        try {
            const box = element.getBBox();
            if (box && (box.width || box.height)) {
                return true;
            }
        } catch {
        }
    }

    return style ? style.display !== "none" : true;
}

export function textNodeIsRendered(node: AnyNode | null) {
    if (!node || !node.parentNode || !node.nodeValue) {
        return false;
    }
    if (!nodeIsRendered(node.parentNode)) {
        return false;
    }

    const range = document.createRange();
    range.selectNodeContents(node);
    const rect = range.getBoundingClientRect();
    if (range.detach) {
        range.detach();
    }
    return !!rect && !!(rect.width || rect.height);
}

export function computeNodePath(node: AnyNode | null) {
    if (!node) {
        return null;
    }

    const root = document.documentElement || document.body;
    if (!root) {
        return null;
    }

    let current: AnyNode | null = node;
    const path: number[] = [];
    while (current && current !== root) {
        const parent = current.parentNode;
        if (!parent) {
            return null;
        }
        const index = Array.prototype.indexOf.call(parent.childNodes, current);
        if (index < 0) {
            return null;
        }
        path.unshift(index);
        current = parent as AnyNode | null;
    }

    if (current !== root) {
        return null;
    }
    return path;
}

export function rectForNode(node: AnyNode | null) {
    if (!node) {
        return null;
    }
    if (node.nodeType === Node.TEXT_NODE) {
        const range = document.createRange();
        range.selectNodeContents(node);
        const rect = range.getBoundingClientRect();
        if (range.detach) {
            range.detach();
        }
        if (!rect || (!rect.width && !rect.height)) {
            return null;
        }
        return rect;
    }
    if (node.getBoundingClientRect) {
        return node.getBoundingClientRect();
    }
    return null;
}
