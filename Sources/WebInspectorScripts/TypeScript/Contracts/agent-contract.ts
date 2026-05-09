/**
 * Shared contract for DOM bridge payloads.
 */

export const WI_DOM_SNAPSHOT_SCHEMA_VERSION = 2 as const;

export interface WISerializedNodeEnvelopeContract {
    type: "serialized-node-envelope";
    schemaVersion: number;
    node: unknown;
    fallback: unknown;
    selectedNodeId?: number | null;
    selectedNodePath?: number[] | null;
}
