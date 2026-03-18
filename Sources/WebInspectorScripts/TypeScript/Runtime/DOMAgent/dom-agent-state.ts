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
    documentURL: string | null;
};

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
    snapshotAutoUpdateDebounce: 600,
    snapshotAutoUpdateMaxDepth: 4,
    snapshotAutoUpdateReason: "mutation",
    pendingMutations: [],
    snapshotAutoUpdateOverflow: false,
    snapshotAutoUpdateSuppressedCount: 0,
    snapshotAutoUpdatePendingWhileSuppressed: false,
    snapshotAutoUpdatePendingReason: null,
    documentURL: null
};
