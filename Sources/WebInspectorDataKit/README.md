# WebInspectorDataKit

WebInspectorDataKit provides SwiftData-style observable inspector models on top of
WebInspectorProxyKit.

Use this package when app or UI code needs DOM, Network, Console, Runtime, and
CSS state without rendering directly from WebKit protocol payloads.

This README is the package contract for the rearchitecture. Code in this target
should converge to this surface. UIKit/AppKit rendering, diffable data source
snapshots, and protocol transport internals are outside this package's contract.

## Main Types

- `WebInspectorContainer`: Attaches to a `WKWebView`, owns a `WebInspectorProxy`,
  and vends the primary `WebInspectorContext`.
- `WebInspectorContext`: The identity-preserving model context. It owns the live
  DOM graph, Network request index, Console messages, Runtime contexts/objects,
  CSS style state, page lifecycle, selection, and page highlight lifecycle. It is
  not globally `@MainActor`; UIKit/AppKit renderers are main-actor clients of the
  context, while DataKit may use worker actors for indexing, rewriting, and
  protocol event processing.
- `DOMModelController`, `CSSModelController`, `NetworkModelController`,
  `RuntimeModelController`, `ConsoleModelController`, `PageModelController`:
  Domain operation surfaces vended by `WebInspectorContext`. Package users call
  these typed methods to request inspector side effects.
- `WebInspectorEditHistory`: Undo/redo operation surface for DOM/CSS edits that
  participate in WebKit's inspector undo history.
- `WebInspectorFetchDescriptor`: SwiftData-style value description of predicate,
  sort order, limit, and offset for fetchable inspector models.
- `WebInspectorFetchRequest`: CoreData-style mutable request object for building
  a fetch descriptor before creating fetched results.
- `WebInspectorFetchedResults`: Observable current value for a fetch request.
  It owns `items`, optional `sections`, and transaction emission.
- `WebInspectorFetchedResultsController`: Non-UI fetched-results controller that
  forwards current values from `WebInspectorFetchedResults` and exposes ordered
  topology transactions for UIKit/AppKit list owners.
- `WebInspectorFetchedResultsSnapshot`, `WebInspectorFetchedResultsTransaction`:
  Section and item ID snapshots plus ordered section/item changes suitable for
  conversion to native UI insertion, removal, move, and reset APIs.
- `DOMTreeController`: Current DOM tree value plus document-bound update streams.
- `DOMTreeSnapshot`, `DOMTreeUpdate`, `DOMTreeDelta`: Initial/page-switch DOM
  snapshots and normal DOM event deltas.
- `DOMNode`, `NetworkRequest`, `ConsoleMessage`, `RuntimeContext`,
  `RuntimeObject`, `CSSStyles`: Context-attached observable inspector models.

## Quick Start

```swift
import WebInspectorDataKit
import WebKit

let container = try await WebInspectorContainer(attachingTo: webView)
let context = container.mainContext

let network = context.network.fetchedResultsController(
    for: WebInspectorFetchDescriptor<NetworkRequest>(
        sortBy: [SortDescriptor(\.requestSentTimestamp, order: .reverse)]
    )
)

for request in network.items {
    print(request.url)
}

let domTree = context.dom.treeController()
render(domTree.snapshot)
```

Close the container when inspection is no longer needed:

```swift
await container.close()
```

## Context Isolation and Operation Surfaces

`WebInspectorContext` is a context-bound model owner, not a UI object and not a
global-actor singleton. Attaching to a `WKWebView` may require the caller to be on
the main actor because WebKit view APIs are UI APIs, but once attached, DataKit
operation APIs must not require every caller or every internal pipeline to run on
`MainActor`.

The context exposes domain controllers for user-requested side effects:

```swift
public final class WebInspectorContext {
    public var dom: DOMModelController { get }
    public var css: CSSModelController { get }
    public var network: NetworkModelController { get }
    public var runtime: RuntimeModelController { get }
    public var console: ConsoleModelController { get }
    public var page: PageModelController { get }
    public var editHistory: WebInspectorEditHistory { get }
}
```

Package users should call typed domain methods instead of constructing protocol
payloads, routing targets, or generic action enums:

```swift
try context.dom.select(node.id, reveal: .selectAndScroll)
try await context.dom.setAttribute("class", value: "selected", on: node.id)
try await context.css.setProperty(property.id, enabled: false)
try await context.editHistory.undo()
```

Do not expose a broad public `Action` enum as the primary API. Recording,
coalescing, tracing, or testing may use an internal mutation command type, but
public API should stay domain-specific and typed so each operation has a clear
owner, argument model, error behavior, and return type.

Mutation options are shared across domains where they describe the same concern:

```swift
public struct WebInspectorMutationOptions: Sendable, Hashable {
    public static let automatic = WebInspectorMutationOptions(
        undo: .automatic,
        staleModel: .fail
    )

    public var undo: WebInspectorUndoPolicy
    public var staleModel: WebInspectorStaleModelPolicy

    public init(
        undo: WebInspectorUndoPolicy = .automatic,
        staleModel: WebInspectorStaleModelPolicy = .fail
    )
}

public enum WebInspectorUndoPolicy: Sendable, Hashable {
    case automatic
    case disabled
}

public enum WebInspectorStaleModelPolicy: Sendable, Hashable {
    case fail
}
```

`automatic` undo means DataKit records the concrete WebKit target that accepted
the edit and marks the backend undo boundary at the correct time. Stale model
references, stale page generations, missing targets, and impossible protocol
states fail fast. DataKit must not silently reroute edits to a guessed current
page or recreate missing semantic state from UI mirrors.

`WebInspectorEditHistory` is the package-user surface for edits that participate
in WebKit's inspector history:

```swift
public final class WebInspectorEditHistory {
    public func undo() async throws
    public func redo() async throws
}
```

The edit-history owner is DataKit. DOM/CSS operations that use `.automatic` undo
record the concrete target that accepted the mutation. `undo()` and `redo()` use
that target and fail if it is no longer current; they do not blindly dispatch to
whatever page is active at call time.

Internal worker actors may perform expensive or protocol-facing work off the main
actor using Sendable values only:

- Network predicate evaluation, sorting, grouping, and membership diffing.
- CSS declaration text rewriting before `CSS.setStyleText`.
- DOM tree projection, ancestor-chain calculation, and delta batching.
- Protocol event classification and generation checks.

Observable model instances remain owned by the context that vended them. Cross an
actor boundary with IDs, records, patches, snapshots, or deltas, then let the
context apply those values to same-identity observable objects.

## Fetching

Use `WebInspectorFetchDescriptor` when you want SwiftData-style value
configuration:

```swift
let apiSearch = "api"

let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
    predicate: #Predicate { request in
        request.searchableText.localizedStandardContains(apiSearch)
    },
    sortBy: [SortDescriptor(\.requestSentTimestamp, order: .reverse)],
    fetchLimit: 500
)

let results = context.network.fetchedResults(for: descriptor)
```

Use `WebInspectorFetchRequest` when request construction reads better as a
mutable CoreData-like object:

```swift
let request = WebInspectorFetchRequest<NetworkRequest>()
request.predicate = #Predicate { $0.method == "POST" }
request.sortDescriptors = [SortDescriptor(\.requestSentTimestamp, order: .reverse)]
request.fetchLimit = 1000

let controller = WebInspectorFetchedResultsController(
    fetchedResults: context.network.fetchedResults(for: request.fetchDescriptor)
)
```

Changing a fetch descriptor is a query-boundary operation. It re-evaluates the
registered model index once off the main actor and emits a reset transaction for
the new result set. Normal protocol events must not re-run every query from
scratch.

```swift
var descriptor = controller.fetchDescriptor
descriptor.predicate = #Predicate { ($0.statusCode ?? 0) >= 400 }
controller.updateFetchDescriptor(descriptor)
```

## Network Predicates

Network search and filtering are DataKit responsibilities. UI packages may own
labels, menu layout, and selected filter controls, but they must pass the
resulting query as `Predicate<NetworkRequest>` and `SortDescriptor<NetworkRequest>`
values.

Queryable Network fields should be exposed as model properties, not UI helpers:

```swift
extension NetworkRequest {
    public enum ResourceCategory: String, Codable, CaseIterable, Sendable, Hashable {
        case document
        case stylesheet
        case script
        case image
        case font
        case xhrFetch
        case media
        case webSocket
        case other
    }

    public var resourceCategory: ResourceCategory { get }
    public var searchableText: String { get }
    public var statusCode: Int? { get }
}
```

Example:

```swift
let xhrFetch = NetworkRequest.ResourceCategory.xhrFetch
let search = "graphql"

let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
    predicate: #Predicate { request in
        request.resourceCategory == xhrFetch
            && request.searchableText.localizedStandardContains(search)
    },
    sortBy: [SortDescriptor(\.requestSentTimestamp, order: .reverse)]
)
```

Built-in UI resource filters should map to one or more DataKit categories and
pass that membership as a predicate:

```swift
let mediaCategories: [NetworkRequest.ResourceCategory] = [.image, .media]

let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
    predicate: #Predicate { request in
        mediaCategories.contains(request.resourceCategory)
    },
    sortBy: [SortDescriptor(\.requestSentTimestamp, order: .reverse)]
)
```

Resource-category classification, search tokens, and query membership belong in
WebInspectorDataKit. The built-in UI can map `NetworkRequest.ResourceCategory`
to localized filter labels such as "CSS", "JS", or "XHR / Fetch", but it must not
own Network query semantics.

Network fetch, sort, and filter work runs against Sendable index records, not by
reading UI-facing observable model objects. A model-context-owned worker actor
may keep `NetworkRequestRecord` values for predicate evaluation, sort keys,
section keys, and query membership:

```swift
public actor NetworkRequestIndex {
    public func apply(_ event: NetworkProtocolEvent) async -> NetworkMutationBatch
    public func updateFetchDescriptor(_ descriptor: WebInspectorFetchDescriptor<NetworkRequest>) async -> NetworkMutationBatch
}
```

`NetworkMutationBatch` crosses back to the owning context as values: inserted IDs,
removed result IDs, moved result IDs, optional reset snapshots, and patches for
existing requests. It must not carry `NetworkRequest` object references across
actor boundaries.

## Fetched Results Transactions

Use `WebInspectorFetchedResultsController` when non-SwiftUI UI code needs ordered
changes instead of only the observable current value:

```swift
let controller = context.network.fetchedResultsController(
    for: WebInspectorFetchDescriptor<NetworkRequest>(
        sortBy: [SortDescriptor(\.requestSentTimestamp, order: .reverse)]
    )
)

Task {
    for await transaction in controller.transactions {
        apply(
            oldSnapshot: transaction.oldSnapshot,
            newSnapshot: transaction.newSnapshot,
            sectionChanges: transaction.sectionChanges,
            itemChanges: transaction.itemChanges
        )
    }
}
```

The controller does not fetch or store a second copy of the model graph. Its
`items`, `sections`, `snapshot`, and transactions are forwarded from the
underlying `WebInspectorFetchedResults`.

Snapshots contain section IDs, optional titles, and item IDs only. Convert
`WebInspectorFetchedResultsTransaction` into `UICollectionView`,
`NSCollectionView`, diffable data source, table, or outline topology updates in
the UI layer.

For Network lists, fetched-results transactions are not a content-rendering
mechanism. They represent result membership and ordering only:

- Initial fetch, descriptor changes, page switches, and clears emit reset
  transactions.
- Request creation emits insertion transactions when the request is visible for
  the active descriptor.
- Network request object deletion is not expected during normal protocol event
  handling. If a still-existing request stops matching the active predicate, the
  result set may emit a removal transaction.
- Mutable sort-key, section-key, or grouping-key changes may emit move
  transactions when the request remains visible but its result position or group
  changes. Resource category/grouping changes, such as media grouping, are
  examples of this path.
- Ordinary request content updates mutate the existing `NetworkRequest` object
  and do not cause collection-view item reloads, reconfigures, or snapshot
  applies.

UIKit/AppKit cells should observe the row model directly. A `UICollectionView`
backed by DataKit should update its item topology only when cells are inserted,
removed, moved, or reset:

```swift
final class NetworkRequestCell: UICollectionViewListCell {
    private var observation: PortableObservationTracking.Token?

    func bind(_ request: NetworkRequest) {
        observation?.cancel()
        observation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }

            var content = self.defaultContentConfiguration()
            content.text = request.displayName
            content.secondaryText = request.statusText
            self.contentConfiguration = content
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        observation?.cancel()
        observation = nil
    }
}
```

## Live Network Event Semantics

`WebInspectorContext` owns the UI-facing Network model context and preserves
`NetworkRequest` identity. A dedicated index actor may do protocol classification,
predicate evaluation, sorting, filtering, batching, and descriptor requery work
off the main actor using Sendable records.

When WebKit protocol events arrive:

- A new request inserts one `NetworkRequest` instance into the context index.
- Later events produce patches for the same request ID.
- The owning context applies patches by mutating the same `NetworkRequest` instance
  in place.
- Registered fetched results revalidate only the affected request for normal
  insert/update/classification events in the index actor.
- Content-only patches update the observable model instance and do not emit list
  topology transactions.
- Predicate leave removes the request from a result set without deleting the
  `NetworkRequest` model object.
- Sort, section, or grouping key changes may move the request within a result
  set.
- A descriptor change re-evaluates the full local index once off the main actor
  and then publishes a reset transaction for the new result set.
- Clearing requests is a reset boundary.

The following shape is not allowed on the hot path:

```swift
// Do not do this for every Network event.
let items = currentNetworkRequests()
results.setItems(items, updatedItemIDs: [changedID])
```

The following shape is also not allowed for content-only request updates:

```swift
// Do not drive row content by forcing collection-view updates.
snapshot.reconfigureItems([changedID])
dataSource.apply(snapshot, animatingDifferences: false)
collectionView.reloadItems(at: [indexPath])
```

The allowed content path is:

```swift
let batch = await networkRequestIndex.apply(event)
await context.apply(batch)
// Cells already bound to affected NetworkRequest instances redraw through
// Observation. The collection view is not told about content-only changes.
```

## DOM Tree Updates

DOM tree delivery is not a fetched-results controller. The DOM graph is a
document-owned tree, so the stream shape is:

```swift
public enum DOMTreeUpdate: Sendable, Hashable {
    case snapshot(DOMTreeSnapshot, reason: DOMTreeSnapshotReason)
    case delta(DOMTreeDelta)
}

public enum DOMTreeSnapshotReason: Sendable, Hashable {
    case initialDocument
    case pageChanged
    case documentUpdated
    case reset
}

public enum DOMTreeDelta: Sendable, Hashable {
    case nodeChanged(nodeID: DOMNode.ID)
    case childInserted(parentID: DOMNode.ID, nodeID: DOMNode.ID, previousSiblingID: DOMNode.ID?)
    case childRemoved(parentID: DOMNode.ID, nodeID: DOMNode.ID)
    case childrenReplaced(parentID: DOMNode.ID, childIDs: [DOMNode.ID])
    case childCountChanged(nodeID: DOMNode.ID)
    case selectionChanged(nodeID: DOMNode.ID?)
}
```

Initial document load, page target switching, and document reset emit
`snapshot`. Ordinary DOM mutations emit `delta`. DataKit must not rebuild and
publish a full `DOMTreeSnapshot` for every attribute, text, count, or child
mutation.

`DOMModelController` vends the current tree controller:

```swift
public final class DOMModelController {
    public func treeController() -> DOMTreeController
}

public final class DOMTreeController {
    public var snapshot: DOMTreeSnapshot { get }
    public var updates: AsyncStream<DOMTreeUpdate> { get }
    public var revealRequests: AsyncStream<DOMTreeRevealRequest> { get }
}

public struct DOMTreeRevealRequest: Sendable, Hashable {
    public var nodeID: DOMNode.ID
    public var ancestorNodeIDs: [DOMNode.ID]
    public var shouldSelect: Bool
    public var shouldScroll: Bool
}
```

Expansion state, scroll position, text layout, row diffing, and native highlight
decoration are UI-owned view state. DataKit owns DOM graph materialization,
selection, reveal requests, and page highlight lifecycle.

## DOM Operations

DOM operations are DataKit-owned semantic requests. They validate that the node
belongs to the current context and document generation, choose the correct
`WebInspectorTarget`, dispatch ProxyKit DOM commands, update selection/reveal
state, and rely on DOM protocol events as the source of truth for final graph
changes.

```swift
public final class DOMModelController {
    public func treeController() -> DOMTreeController

    public func requestChildren(of nodeID: DOMNode.ID, depth: Int = 1) async throws

    public func select(
        _ nodeID: DOMNode.ID?,
        reveal: DOMRevealPolicy = .selectAndScroll
    ) throws

    public func setAttribute(
        _ name: String,
        value: String,
        on nodeID: DOMNode.ID,
        options: WebInspectorMutationOptions = .automatic
    ) async throws

    public func setOuterHTML(
        _ html: String,
        of nodeID: DOMNode.ID,
        options: WebInspectorMutationOptions = .automatic
    ) async throws

    public func remove(
        _ nodeIDs: [DOMNode.ID],
        options: WebInspectorMutationOptions = .automatic
    ) async throws -> DOMMutationResult

    public func highlight(_ nodeID: DOMNode.ID) async throws
    public func hideHighlight() async throws
    public func setInspectMode(enabled: Bool) async throws
}

public enum DOMRevealPolicy: Sendable, Hashable {
    case none
    case selectOnly
    case selectAndScroll
}

public struct DOMMutationResult: Sendable, Hashable {
    public var requestedNodeIDs: [DOMNode.ID]
    public var acceptedNodeIDs: [DOMNode.ID]
}
```

`setOuterHTML` must not depend on a command result to identify the replacement
node. WebKit reports the actual replacement through DOM removal/insertion events,
so DataKit reconciles the tree from events and emits DOM deltas or reveal
requests after materialization.

Convenience methods on `DOMNode` may forward to `context.dom`, but the owner of
edit routing, stale-model checks, undo marking, and page highlight lifecycle is
`DOMModelController`, not the model object and not the UI layer.

## DOM Selection and Highlight

Picker selection follows this DataKit-owned flow:

1. ProxyKit receives `Inspector.inspect` and projects it into DOM inspection.
2. DataKit resolves/materializes the inspected `DOMNode`.
3. DataKit updates `selectedNode`.
4. DataKit emits a `DOMTreeRevealRequest` containing the selected node and
   ancestor chain.
5. DataKit restores the page highlight for touch-oriented inspector UI.

Tree hover and tree selection should call DataKit highlight APIs:

```swift
try await context.dom.highlight(node.id)
try await context.dom.hideHighlight()
```

Page/document generation changes clear stale page highlights in DataKit. UI code
must not resurrect an old page highlight after navigation.

## CSS Operations

CSS style state is DataKit-owned, observable, and identity-preserving. WebKit has
no `CSS.setPropertyText` or `CSS.toggleProperty` command; property edits rewrite
the owning declaration text and dispatch `CSS.setStyleText`. DataKit owns that
rewrite and validation so package users do not construct CSS protocol payloads.

```swift
public final class CSSModelController {
    public func styles(for nodeID: DOMNode.ID) throws -> CSSStyles
    public func refreshStyles(for nodeID: DOMNode.ID) throws

    public func setProperty(
        _ propertyID: CSS.Property.ID,
        enabled: Bool,
        options: WebInspectorMutationOptions = .automatic
    ) async throws

    public func requestSetProperty(
        _ propertyID: CSS.Property.ID,
        enabled: Bool
    ) -> Bool

    public func setDeclarationText(
        _ text: String,
        for propertyID: CSS.Property.ID,
        options: WebInspectorMutationOptions = .automatic
    ) async throws

    public func setRuleSelector(
        _ selector: String,
        for ruleID: CSS.Rule.ID,
        options: WebInspectorMutationOptions = .automatic
    ) async throws

    public func setStyleSheetText(
        _ text: String,
        for styleSheetID: CSS.StyleSheet.ID,
        options: WebInspectorMutationOptions = .automatic
    ) async throws
}
```

`CSS.setStyleText` returns a new protocol `CSS.Style`, but the returned value is
not the long-lived source of truth by itself. DataKit applies the immediate style
result to the existing `CSSStyles` object for responsive rendering, marks the
style state stale, and refreshes matched, inline, and computed styles from WebKit
events such as `CSS.styleSheetChanged` and `DOM.inlineStyleInvalidated`.

`CSSStyles` and `CSSStyleSection` are observable/readable model surfaces. They may
provide convenience methods that forward to `context.css`, but they must not own
target routing, undo state, or protocol text rewriting across actors.

## Runtime, Console, Page, and Other Operations

Other user-requested side effects follow the same rule: package users call typed
DataKit domain operations; ProxyKit remains a protocol layer; UI code owns only
interaction state.

```swift
let evaluation = try await context.runtime.evaluate("document.title")
let messages = context.console.fetchedResults(
    for: WebInspectorFetchDescriptor<ConsoleMessage>()
)

try context.dom.select(node.id, reveal: .selectAndScroll)
context.css.setStyleHydrationActive(true)
let styles = node.elementStyles
```

Models preserve identity within the context. If the same semantic entity appears
again, DataKit mutates the existing observable object instead of replacing it.

## Package User and UI Boundary

WebInspectorDataKit does not import UIKit, AppKit, or SwiftUI for list rendering.
Package users and native UI packages may keep transient interaction and render
artifacts:

- `NSDiffableDataSourceSnapshot` / `NSDiffableDataSourceSectionSnapshot`
- visible row text/layout caches
- scroll position and expansion state
- selected menu state
- draft text, focus, validation messages, and commit/cancel interaction state
- throttled native apply tasks

Those artifacts must be rebuildable from DataKit models or update streams and
must not become semantic state. UI code must not implement Network query
membership, DOM graph ownership, CSS declaration rewriting, edit undo routing,
page highlight lifecycle, protocol event ordering, or Network row-content
propagation.

For Network collection views, UI code owns only native topology application and
cell lifecycle:

- Parent list owners apply fetched-results topology transactions.
- Cells observe `NetworkRequest` instances directly and render their own content.
- Content-only request mutations must not call collection-view reload,
  reconfigure, or diffable snapshot apply.
- Result removals and moves are topology changes, not content rendering.
- The model context is responsible for updating observable request models.

## Isolation and Identity

The primary context is the UI-facing context, but it is not synonymous with
`MainActor`. Treat model instances like SwiftData/Core Data model objects that
belong to the context that vended them:

- Keep them inside the context that vended them.
- Mutate same-identity objects in place.
- Pass semantic IDs or value DTOs across concurrency domains.
- Do not make UI-owned mirrors of model properties just to observe changes.

`WebInspectorContext` owns observable model identity and serializes application of
model patches to those objects. Dedicated actors may own Sendable indexes,
records, query caches, CSS rewrite contexts, DOM projection state, and protocol
event processors, but they do not own UI-facing `@Observable` model objects and
do not mutate them directly.

UIKit/AppKit code usually observes the context's models from the main actor
because native rendering is main-actor work. That does not make DataKit operation
APIs main-actor-only. A package user may request an edit, fetch, or runtime
operation from another actor by passing IDs and Sendable request values; DataKit
then hops internally to the correct owner for protocol I/O, worker computation,
and context model mutation.

The boundary is:

```swift
// Worker actors and protocol processors: Sendable values only.
public struct NetworkRequestRecord: Sendable, Hashable {
    public var id: NetworkRequest.ID
    public var url: URL
    public var method: String
    public var resourceCategory: NetworkRequest.ResourceCategory
    public var searchableText: String
    public var statusCode: Int?
    public var requestSentTimestamp: Date
}

public struct NetworkRequestPatch: Sendable, Hashable {
    public var id: NetworkRequest.ID
    public var statusCode: Int?
    public var transferSize: Int?
    public var state: NetworkRequest.State?
}

// Context-owned observable identity and in-place mutation.
@Observable
public final class NetworkRequest {
    public let id: ID

    public private(set) var url: URL
    public private(set) var statusCode: Int?
    public private(set) var transferSize: Int
    public private(set) var state: State

    package func apply(_ patch: NetworkRequestPatch)
}
```

Future background contexts or model actors should own their own model instances
and merge by semantic IDs, not share mutable observable model objects across
actors. If an actor performs fetch, sort, or filter work, it returns value
batches for the owning model context to apply.

## Testing

Test DataKit owners without the built-in UI:

- Fetch descriptor predicates and sort descriptors.
- Network event insert/update/move/reset transaction behavior.
- Predicate enter/leave behavior for a single changed request without deleting
  the model object.
- Sort-key, section-key, and grouping-key move behavior for a single changed
  request.
- Descriptor changes performing one full local requery.
- Content-only Network events mutating the same observable `NetworkRequest`
  instance without emitting collection-view topology transactions.
- Off-main Network index work returning Sendable batches and never returning
  observable model objects.
- DOM document/page switch emitting snapshots.
- DOM attribute/text/count/child events emitting deltas.
- Picker inspect selecting, revealing, and restoring highlight for the resolved
  node.
- Page navigation clearing stale highlights.
- DOM mutation operations failing on stale model generations and routing edits to
  the target that owns the node.
- DOM undo/redo using the last successful edit target instead of blindly using
  the current page.
- CSS property toggles and declaration edits rewriting style text off the main
  actor and applying only Sendable command inputs/results across boundaries.
- CSS edit invalidation refreshing matched, inline, and computed styles without
  replacing the `CSSStyles` object.

UI tests should verify native rendering and lifecycle only: diffable apply,
selection presentation, scroll/reveal behavior, hover decoration, throttling, and
hidden-view deferral. Network UI tests should verify that cells update by
observing `NetworkRequest` in place and that content-only changes do not trigger
collection-view reload, reconfigure, or snapshot apply.
