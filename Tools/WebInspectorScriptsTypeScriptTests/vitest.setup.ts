import { afterEach, beforeEach, vi } from "vitest";

type MessageHandler = {
    postMessage: ReturnType<typeof vi.fn>;
};

type MessageHandlers = Record<string, MessageHandler>;

const createMessageHandlers = (): MessageHandlers => ({
    webInspectorLog: { postMessage: vi.fn() },
    webInspectorReady: { postMessage: vi.fn() },
    webInspectorDomSelection: { postMessage: vi.fn() },
    webInspectorDomRequestChildren: { postMessage: vi.fn() },
    webInspectorDomHighlight: { postMessage: vi.fn() },
    webInspectorDomHideHighlight: { postMessage: vi.fn() }
});

beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-01-01T00:00:00.000Z"));

    const handlers = createMessageHandlers();
    Object.defineProperty(window, "webkit", {
        configurable: true,
        writable: true,
        value: {
            messageHandlers: handlers
        }
    });

    const raf = (callback: FrameRequestCallback): number => {
        return window.setTimeout(() => {
            callback(performance.now());
        }, 16);
    };

    Object.defineProperty(window, "requestAnimationFrame", {
        configurable: true,
        writable: true,
        value: raf
    });
    Object.defineProperty(globalThis, "requestAnimationFrame", {
        configurable: true,
        writable: true,
        value: raf
    });
    Object.defineProperty(window, "cancelAnimationFrame", {
        configurable: true,
        writable: true,
        value: (id: number) => window.clearTimeout(id)
    });
    Object.defineProperty(globalThis, "cancelAnimationFrame", {
        configurable: true,
        writable: true,
        value: (id: number) => window.clearTimeout(id)
    });

    Object.defineProperty(window, "scrollTo", {
        configurable: true,
        writable: true,
        value: vi.fn()
    });

    document.body.innerHTML = "";
});

afterEach(() => {
    vi.clearAllTimers();
    vi.useRealTimers();
    document.body.innerHTML = "";
});
