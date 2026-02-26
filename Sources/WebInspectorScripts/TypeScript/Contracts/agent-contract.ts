/**
 * Shared contract for DOM / Network bridge payloads.
 * Keep this file backward compatible across Swift + TypeScript boundaries.
 */

export const WI_DOM_SNAPSHOT_SCHEMA_VERSION = 1 as const;
export const WI_NETWORK_EVENT_SCHEMA_VERSION = 1 as const;

export interface WISerializedNodeEnvelopeContract {
    type: "serialized-node-envelope";
    schemaVersion: number;
    node: unknown;
    fallback: unknown;
    selectedNodeId?: number | null;
    selectedNodePath?: number[] | null;
}

export type WINetworkEventRecord = Record<string, unknown>;

export interface WINetworkEventBatchContract {
    authToken: string;
    version?: number;
    schemaVersion: number;
    sessionId: string;
    seq: number;
    events: WINetworkEventRecord[];
    dropped?: number;
}
