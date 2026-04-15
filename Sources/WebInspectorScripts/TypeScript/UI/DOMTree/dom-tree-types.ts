/**
 * Core type definitions for DOMTreeView module.
 */
import { WI_DOM_SNAPSHOT_SCHEMA_VERSION } from "../../Contracts/agent-contract";

export const DOM_SNAPSHOT_SCHEMA_VERSION = WI_DOM_SNAPSHOT_SCHEMA_VERSION;

// =============================================================================
// Node Types
// =============================================================================

/** DOM node type constants matching W3C spec */
export const NODE_TYPES = {
    ELEMENT_NODE: 1,
    TEXT_NODE: 3,
    COMMENT_NODE: 8,
} as const;

export type NodeTypeValue = (typeof NODE_TYPES)[keyof typeof NODE_TYPES];

/** Attribute name-value pair */
export interface NodeAttribute {
    name: string;
    value: string;
}

/** Layout flag indicating rendering state */
export type LayoutFlag = "rendered" | string;

/** Normalized DOM node descriptor */
export interface DOMNode {
    id: number;
    nodeName: string;
    displayName: string;
    nodeType: number;
    attributes: NodeAttribute[];
    textContent: string | null;
    layoutFlags: LayoutFlag[];
    renderedSelf: boolean;
    isRendered: boolean;
    children: DOMNode[];
    childCount: number;
    placeholderParentId: number | null;
    depth?: number;
    parentId?: number | null;
    childIndex?: number;
}

/** Raw node descriptor from protocol (before normalization) */
export interface RawNodeDescriptor {
    nodeId?: number;
    id?: number;
    nodeType?: number;
    nodeName?: string;
    localName?: string;
    attributes?: (string | undefined)[];
    nodeValue?: string;
    documentURL?: string;
    xmlVersion?: string;
    publicId?: string;
    systemId?: string;
    name?: string;
    value?: string;
    childNodeCount?: number;
    childCount?: number;
    children?: RawNodeDescriptor[];
    layoutFlags?: unknown[];
    isRendered?: boolean;
}

/** Private serialized node envelope payload */
export interface SerializedNodeEnvelope {
    type?: "serialized-node-envelope";
    schemaVersion?: number;
    node?: unknown;
    fallback?: RawNodeDescriptor | DOMSnapshotEnvelopePayload | null;
    selectedNodeId?: number | null;
    selectedLocalId?: number | null;
    selectedNodePath?: number[] | null;
}

/** Snapshot payload shape used by protocol and private envelope fallback */
export interface DOMSnapshotEnvelopePayload {
    root?: RawNodeDescriptor | SerializedNodeEnvelope | null;
    selectedNodeId?: number | null;
    selectedLocalId?: number | null;
    selectedNodePath?: number[] | null;
}

/** Snapshot containing the root node */
export interface DOMSnapshot {
    root: DOMNode | null;
    selectedNodeId?: number;
    selectedLocalId?: number;
    selectedNodePath?: number[];
}

export interface DOMSelectionSyncPayload {
    id?: number;
    nodeId?: number;
    localId?: number;
    localID?: number;
    selectedLocalId?: number;
    backendNodeId?: number;
    backendNodeID?: number;
    backendNodeIdIsStable?: boolean;
    selectedBackendNodeId?: number;
    selectedNodePath?: number[] | null;
}

export interface DOMSelectionRestoreTarget {
    selectedLocalId?: number | null;
    selectedBackendNodeId?: number | null;
    selectedNodePath?: number[] | null;
}

// =============================================================================
// Protocol Types
// =============================================================================

/** Protocol state for managing requests and events */
export interface ProtocolState {
    snapshotDepth: number;
    subtreeDepth: number;
    pageEpoch: number;
    documentScopeID: number;
}

export interface DOMDocumentContext {
    pageEpoch?: number;
    documentScopeID?: number;
}

/** Protocol configuration options */
export interface ProtocolConfig {
    snapshotDepth?: number;
    subtreeDepth?: number;
    autoUpdateDebounce?: number;
}

export interface DOMFrontendBootstrapState {
    config?: ProtocolConfig;
    context?: DOMDocumentContext;
    preferredDepth?: number;
    pendingDocumentRequest?: RequestDocumentOptions | null;
}

// =============================================================================
// Tree State Types
// =============================================================================

/** Main tree state */
export interface TreeState {
    snapshot: DOMSnapshot | null;
    nodes: Map<number, DOMNode>;
    elements: Map<number, HTMLElement>;
    openState: Map<number, boolean>;
    selectedNodeId: number | null;
    styleRevision: number;
    filter: string;
    pendingRefreshRequests: Set<number>;
    refreshAttempts: Map<number, RefreshAttempt>;
    selectionChain: number[];
    deferredChildRenders: Set<number>;
    selectionRecoveryRequestKeys: Set<string>;
}

/** Refresh attempt tracking */
export interface RefreshAttempt {
    count: number;
    lastRequested: number;
}

/** Render state for batched updates */
export interface RenderState {
    pendingNodes: Map<number, PendingRenderItem>;
    frameId: number | null;
}

/** Pending render item */
export interface PendingRenderItem {
    node: DOMNode;
    updateChildren: boolean;
    modifiedAttributes: Set<string | symbol> | null;
}

// =============================================================================
// DOM Event Types
// =============================================================================

/** DOM element references */
export interface DOMElements {
    tree: HTMLElement | null;
    empty: HTMLElement | null;
}

/** DOM update event entry */
export interface DOMEventEntry {
    method: string;
    params: Record<string, unknown>;
}

/** Child node inserted event params */
export interface ChildNodeInsertedParams {
    parentId?: number;
    parentNodeId?: number;
    previousNodeId?: number;
    node?: RawNodeDescriptor;
}

/** Child node removed event params */
export interface ChildNodeRemovedParams {
    parentId?: number;
    parentNodeId?: number;
    nodeId?: number;
}

/** Attribute modified event params */
export interface AttributeModifiedParams {
    nodeId?: number;
    name?: string;
    value?: string;
    layoutFlags?: unknown[];
    isRendered?: boolean;
}

/** Character data modified event params */
export interface CharacterDataModifiedParams {
    nodeId?: number;
    characterData?: string;
    layoutFlags?: unknown[];
    isRendered?: boolean;
}

/** Child count updated event params */
export interface ChildCountUpdatedParams {
    nodeId?: number;
    childNodeCount?: number;
    childCount?: number;
    layoutFlags?: unknown[];
    isRendered?: boolean;
}

// =============================================================================
// UI Types
// =============================================================================

/** Options for node rendering */
export interface NodeRenderOptions {
    modifiedAttributes?: Set<string | symbol> | null;
}

/** Options for node refresh */
export interface NodeRefreshOptions {
    updateChildren?: boolean;
    modifiedAttributes?: Set<string | symbol> | null;
}

/** Options for node selection */
export interface SelectionOptions {
    shouldHighlight?: boolean;
    autoScroll?: boolean;
    notifyNative?: boolean;
}

/** Scroll position capture */
export interface ScrollPosition {
    top: number;
    left: number;
}

/** Layout state result */
export interface LayoutStateResult {
    changed: boolean;
    isRendered: boolean;
    renderedSelf: boolean;
}

/** Node refresh entry for batch updates */
export interface NodeRefreshEntry {
    node: DOMNode;
    updateChildren: boolean;
}

// =============================================================================
// WebKit Bridge Types
// =============================================================================

/** WebKit message handler interface */
export interface WebKitMessageHandler {
    postMessage(message: unknown): void;
}

/** WebKit message handlers collection */
export interface WebKitMessageHandlers {
    webInspectorDomRequestDocument?: WebKitMessageHandler;
    webInspectorDomRequestChildren?: WebKitMessageHandler;
    webInspectorDomHighlight?: WebKitMessageHandler;
    webInspectorDomHideHighlight?: WebKitMessageHandler;
    webInspectorLog?: WebKitMessageHandler;
    webInspectorReady?: WebKitMessageHandler;
    webInspectorDomSelection?: WebKitMessageHandler;
}

/** WebKit bridge interface */
export interface WebKitBridge {
    createJSHandle?: (value: unknown) => unknown;
    serializeNode?: (node: Node) => unknown;
    buffers?: Record<string, unknown>;
    messageHandlers?: WebKitMessageHandlers;
}

// =============================================================================
// Public API Types
// =============================================================================

/** Mutation bundle for applying updates */
export interface MutationBundle {
    version?: number;
    kind?: "snapshot" | "mutation";
    snapshot?: string | RawNodeDescriptor | SerializedNodeEnvelope | DOMSnapshotEnvelopePayload | null;
    snapshotMode?: RequestDocumentMode;
    events?: DOMEventEntry[];
    bundle?: string | MutationBundle;
    mode?: RequestDocumentMode;
    pageEpoch?: number;
    documentScopeID?: number;
}

export type RequestDocumentMode = "fresh" | "preserve-ui-state";

/** Request document options */
export interface RequestDocumentOptions {
    depth?: number;
    mode?: RequestDocumentMode;
    pageEpoch?: number;
    documentScopeID?: number;
    selectionRestoreTarget?: DOMSelectionRestoreTarget | null;
}

// =============================================================================
// Constants
// =============================================================================

export const INDENT_DEPTH_LIMIT = 6;
export const LAYOUT_FLAG_RENDERED: LayoutFlag = "rendered";
export const TEXT_CONTENT_ATTRIBUTE = Symbol("text-content-attribute");

export const DOM_EVENT_BATCH_LIMIT = 120;
export const DOM_EVENT_TIME_BUDGET = 6;
export const RENDER_BATCH_LIMIT = 180;
export const RENDER_TIME_BUDGET = 8;
export const REFRESH_RETRY_LIMIT = 3;
export const REFRESH_RETRY_WINDOW = 2000;

// =============================================================================
// Global Window Extension
// =============================================================================

// Note: Window interface is extended in WebInspector.d.ts
// We only augment the specific types used by DOMTreeView here

/** Public frontend API */
export interface WebInspectorDOMFrontend {
    applyFullSnapshot(
        snapshot: unknown,
        mode?: RequestDocumentMode,
        pageEpoch?: number,
        documentScopeID?: number
    ): void;
    applySelectionPayload(
        payload: number | DOMSelectionSyncPayload,
        pageEpoch?: number,
        documentScopeID?: number
    ): boolean;
    applySubtreePayload(payload: unknown, pageEpoch?: number, documentScopeID?: number): void;
    completeChildNodeRequest(nodeId: number, pageEpoch?: number, documentScopeID?: number): void;
    rejectChildNodeRequest(nodeId: number, pageEpoch?: number, documentScopeID?: number): void;
    retryQueuedChildNodeRequests(pageEpoch?: number, documentScopeID?: number): void;
    resetChildNodeRequests(pageEpoch?: number, documentScopeID?: number): void;
    resetDocumentRequestState(pageEpoch?: number, documentScopeID?: number): void;
    rejectDocumentRequest(pageEpoch?: number, documentScopeID?: number): void;
    completeDocumentRequest(pageEpoch?: number, documentScopeID?: number): void;
    applyMutationBundle(bundle: string | MutationBundle, pageEpoch?: number): void;
    applyMutationBundles(bundles: string | MutationBundle | MutationBundle[], pageEpoch?: number): void;
    applyMutationBuffer(bufferName: string, pageEpoch?: number): boolean;
    setSearchTerm(value: string): void;
    setPreferredDepth(depth: number, pageEpoch?: number): void;
    updateConfig(partial: ProtocolConfig): void;
    adoptDocumentContext(context: DOMDocumentContext): boolean;
    __installed?: boolean;
}
