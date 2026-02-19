import type { MutationBundle } from "./dom-tree-types";
import { safeParseJSON } from "./dom-tree-utilities";

function toBytes(payload: unknown): Uint8Array | null {
    if (!payload) {
        return null;
    }
    if (payload instanceof Uint8Array) {
        return payload;
    }
    if (payload instanceof ArrayBuffer) {
        return new Uint8Array(payload);
    }
    if (typeof DataView !== "undefined" && payload instanceof DataView) {
        return new Uint8Array(payload.buffer, payload.byteOffset, payload.byteLength);
    }
    if (ArrayBuffer.isView(payload)) {
        const view = payload as ArrayBufferView;
        return new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
    }
    return null;
}

function decodeText(payload: unknown): string | null {
    if (typeof payload === "string") {
        return payload;
    }
    const bytes = toBytes(payload);
    if (!bytes) {
        return null;
    }
    if (typeof TextDecoder === "function") {
        try {
            return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
        } catch {
        }
    }
    let result = "";
    for (let index = 0; index < bytes.length; index += 1) {
        result += String.fromCharCode(bytes[index]);
    }
    return result;
}

export function applyMutationBundlesFromBuffer(bufferName: string): MutationBundle[] | null {
    if (!bufferName) {
        return null;
    }
    const buffers = (window.webkit as unknown as { buffers?: Record<string, unknown> } | undefined)?.buffers;
    if (!buffers || typeof buffers !== "object") {
        return null;
    }

    const payload = buffers[bufferName];
    const decoded = decodeText(payload);
    if (!decoded) {
        return null;
    }

    const parsed = safeParseJSON<unknown>(decoded);
    if (!parsed) {
        return null;
    }
    if (Array.isArray(parsed)) {
        return parsed as MutationBundle[];
    }
    if (typeof parsed === "object") {
        return [parsed as MutationBundle];
    }
    return null;
}
