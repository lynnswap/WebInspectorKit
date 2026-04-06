export type AnyNode = Node & Record<string, any>;

export type CursorBackup = {
    html: string;
    body: string;
};

export type SelectionState = {
    active: boolean;
    latestTarget: AnyNode | null;
    bindings: Array<[string, EventListenerOrEventListenerObject]>;
    cancel?: () => void;
};

export type InitialSnapshotMode = "fresh" | "preserve-ui-state";

export type InspectorState = {
    map: Map<number, AnyNode> | null;
    nodeMap: WeakMap<AnyNode, number> | null;
    overlay: HTMLDivElement | null;
    overlayTarget: AnyNode | null;
    pendingOverlayUpdate: boolean;
    overlayAutoUpdateConfigured: boolean;
    overlayMutationObserver: MutationObserver | null;
    overlayMutationObserverActive: boolean;
    nextId: number;
    pendingSelectionPath: number[] | null;
    selectionState: SelectionState | null;
    cursorBackup: CursorBackup | null;
    windowClickBlockerHandler: ((event: Event) => void) | null;
    windowClickBlockerRemovalTimer: ReturnType<typeof setTimeout> | null;
    windowClickBlockerPendingRelease: boolean;
    snapshotAutoUpdateObserver: MutationObserver | null;
    snapshotAutoUpdateEnabled: boolean;
    snapshotAutoUpdatePending: boolean;
    snapshotAutoUpdateTimer: ReturnType<typeof setTimeout> | null;
    snapshotAutoUpdateFrame: number | null;
    snapshotAutoUpdateDebounce: number;
    snapshotAutoUpdateMaxDepth: number;
    snapshotAutoUpdateReason: string;
    pendingMutations: MutationRecord[];
    snapshotAutoUpdateOverflow: boolean;
    snapshotAutoUpdateSuppressedCount: number;
    snapshotAutoUpdatePendingWhileSuppressed: boolean;
    snapshotAutoUpdatePendingReason: string | null;
    nextInitialSnapshotMode: InitialSnapshotMode | null;
    documentURL: string | null;
    pageEpoch: number;
    documentScopeID: number;
};

export type DOMAgentAutoSnapshotBootstrap = {
    enabled?: boolean;
    maxDepth?: number;
    debounce?: number;
};

export type DOMAgentBootstrapState = {
    pageEpoch?: number;
    documentScopeID?: number;
    traceEnabled?: boolean;
    autoSnapshot?: DOMAgentAutoSnapshotBootstrap;
};

function readFiniteNumber(value: unknown): number | null {
    if (typeof value !== "number" || !Number.isFinite(value)) {
        return null;
    }
    return value;
}

function readPositiveNumber(value: unknown, fallback: number, minimum = 1): number {
    const numericValue = readFiniteNumber(value);
    if (numericValue === null || numericValue < minimum) {
        return fallback;
    }
    return numericValue;
}

export function readDOMAgentBootstrap(): DOMAgentBootstrapState {
    const bootstrap = (window as Window & {
        __wiDOMAgentBootstrap?: DOMAgentBootstrapState;
    }).__wiDOMAgentBootstrap;
    if (!bootstrap || typeof bootstrap !== "object") {
        return {};
    }
    return bootstrap;
}

const initialBootstrap = readDOMAgentBootstrap();
const initialPageEpoch =
    readFiniteNumber(initialBootstrap.pageEpoch)
    ?? (
        typeof window.__wiDOMFrontendInitialPageEpoch === "number"
        && Number.isFinite(window.__wiDOMFrontendInitialPageEpoch)
            ? window.__wiDOMFrontendInitialPageEpoch
            : 0
    );
const initialDocumentScopeID = readFiniteNumber(initialBootstrap.documentScopeID) ?? 0;
const initialAutoSnapshot = initialBootstrap.autoSnapshot;

export const inspector: InspectorState = {
    map: new Map<number, AnyNode>(),
    nodeMap: new WeakMap<AnyNode, number>(),
    overlay: null,
    overlayTarget: null,
    pendingOverlayUpdate: false,
    overlayAutoUpdateConfigured: false,
    overlayMutationObserver: null,
    overlayMutationObserverActive: false,
    nextId: 1,
    pendingSelectionPath: null,
    selectionState: null,
    cursorBackup: null,
    windowClickBlockerHandler: null,
    windowClickBlockerRemovalTimer: null,
    windowClickBlockerPendingRelease: false,
    snapshotAutoUpdateObserver: null,
    snapshotAutoUpdateEnabled: false,
    snapshotAutoUpdatePending: false,
    snapshotAutoUpdateTimer: null,
    snapshotAutoUpdateFrame: null,
    snapshotAutoUpdateDebounce: readPositiveNumber(initialAutoSnapshot?.debounce, 600, 50),
    snapshotAutoUpdateMaxDepth: readPositiveNumber(initialAutoSnapshot?.maxDepth, 4),
    snapshotAutoUpdateReason: "mutation",
    pendingMutations: [],
    snapshotAutoUpdateOverflow: false,
    snapshotAutoUpdateSuppressedCount: 0,
    snapshotAutoUpdatePendingWhileSuppressed: false,
    snapshotAutoUpdatePendingReason: null,
    nextInitialSnapshotMode: "fresh",
    documentURL: null,
    pageEpoch: initialPageEpoch,
    documentScopeID: initialDocumentScopeID
};

export function applyDOMAgentBootstrapContext(bootstrap: DOMAgentBootstrapState | null | undefined): boolean {
    if (!bootstrap || typeof bootstrap !== "object") {
        return false;
    }
    let didApply = false;
    const pageEpoch = readFiniteNumber(bootstrap.pageEpoch);
    if (pageEpoch !== null) {
        if (pageEpoch !== inspector.pageEpoch) {
            inspector.nextInitialSnapshotMode = "fresh";
        }
        inspector.pageEpoch = pageEpoch;
        didApply = true;
    }
    const documentScopeID = readFiniteNumber(bootstrap.documentScopeID);
    if (documentScopeID !== null) {
        if (documentScopeID !== inspector.documentScopeID) {
            inspector.nextInitialSnapshotMode = "fresh";
        }
        inspector.documentScopeID = documentScopeID;
        didApply = true;
    }
    return didApply;
}

export function domTraceEnabled(): boolean {
    if (window.__wiDOMTraceEnabled === true) {
        return true;
    }
    return readDOMAgentBootstrap().traceEnabled === true;
}
