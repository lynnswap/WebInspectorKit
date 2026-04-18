import { beforeEach, describe, expect, it, vi } from "vitest";

async function resetRuntimeState(): Promise<typeof import("../Runtime/DOMAgent/dom-agent-state")> {
    const state = await import("../Runtime/DOMAgent/dom-agent-state");
    const { inspector } = state;
    document.body.innerHTML = "<main id=\"root\"></main>";
    inspector.map?.clear();
    inspector.nodeMap = new WeakMap();
    inspector.overlay = null;
    inspector.overlayTarget = null;
    inspector.pendingOverlayUpdate = false;
    inspector.overlayAutoUpdateConfigured = false;
    inspector.overlayMutationObserver = null;
    inspector.overlayMutationObserverActive = false;
    inspector.nextId = 1;
    inspector.pendingSelectionRestoreTarget = null;
    inspector.selectionState = null;
    inspector.cursorBackup = null;
    inspector.windowClickBlockerHandler = null;
    inspector.windowClickBlockerRemovalTimer = null;
    inspector.windowClickBlockerPendingRelease = false;
    inspector.snapshotAutoUpdateObserver = null;
    inspector.snapshotAutoUpdateEnabled = false;
    inspector.snapshotAutoUpdatePending = false;
    inspector.snapshotAutoUpdateTimer = null;
    inspector.snapshotAutoUpdateFrame = null;
    inspector.snapshotAutoUpdateDebounce = 50;
    inspector.snapshotAutoUpdateMaxDepth = 4;
    inspector.snapshotAutoUpdateReason = "mutation";
    inspector.pendingMutations = [];
    inspector.snapshotAutoUpdateOverflow = false;
    inspector.snapshotAutoUpdateSuppressedCount = 0;
    inspector.snapshotAutoUpdatePendingWhileSuppressed = false;
    inspector.snapshotAutoUpdatePendingReason = null;
    inspector.nextInitialSnapshotMode = "fresh";
    inspector.documentURL = null;
    inspector.contextID = 1;
    window.webkit = {
        messageHandlers: {
            webInspectorDOMSnapshot: { postMessage: vi.fn() },
            webInspectorDOMMutations: { postMessage: vi.fn() },
            webInspectorLog: { postMessage: vi.fn() },
        },
    } as never;
    (window as Window & { __wiDOMAgentBootstrap?: unknown }).__wiDOMAgentBootstrap = undefined;
    return state;
}

describe("dom-agent runtime", () => {
    beforeEach(async () => {
        vi.useRealTimers();
        await resetRuntimeState();
        await import("../Runtime/dom-agent");
    });

    it("bootstraps and updates contextID", async () => {
        const { inspector } = await import("../Runtime/DOMAgent/dom-agent-state");
        const agent = window.webInspectorDOM as {
            bootstrap?: (bootstrap: unknown) => boolean;
            debugStatus?: () => { contextID?: number };
        } | undefined;
        expect(agent?.bootstrap?.({ contextID: 7 })).toBe(true);
        expect(inspector.contextID).toBe(7);
        expect(agent?.debugStatus?.().contextID).toBe(7);
    });

    it("setContextID marks the next snapshot as fresh", async () => {
        const { inspector } = await import("../Runtime/DOMAgent/dom-agent-state");
        inspector.nextInitialSnapshotMode = null;

        expect(window.webInspectorDOM?.setContextID?.(9)).toBe(true);
        expect(inspector.contextID).toBe(9);
        expect(inspector.nextInitialSnapshotMode).toBe("fresh");
    });

    it("auto snapshot payload includes contextID", async () => {
        const { inspector } = await import("../Runtime/DOMAgent/dom-agent-state");
        const agent = window.webInspectorDOM as {
            bootstrap?: (bootstrap: unknown) => boolean;
            triggerSnapshotUpdate?: (reason: string) => void;
        } | undefined;
        agent?.bootstrap?.({
            contextID: 11,
            autoSnapshot: { enabled: true, maxDepth: 4, debounce: 50 },
        });

        agent?.triggerSnapshotUpdate?.("initial");
        await new Promise((resolve) => setTimeout(resolve, 60));

        const handler = window.webkit?.messageHandlers?.webInspectorDOMSnapshot?.postMessage as ReturnType<typeof vi.fn>;
        expect(handler).toHaveBeenCalled();
        expect(handler.mock.calls.at(-1)?.[0]).toMatchObject({
            contextID: 11,
            bundle: { contextID: 11 },
        });
    });
});
