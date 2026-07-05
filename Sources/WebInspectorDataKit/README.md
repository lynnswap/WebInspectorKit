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
  and vends the main `WebInspectorContext`.
- `WebInspectorContext`: The identity-preserving model context. It owns the live
  DOM graph, Network request index, Console messages, Runtime contexts/objects,
  CSS style state, page lifecycle, selection, and page highlight lifecycle.
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

let network = context.fetchedResultsController(
    for: WebInspectorFetchDescriptor<NetworkRequest>(
        sortBy: [SortDescriptor(\.requestSentTimestamp, order: .reverse)]
    )
)

for request in network.items {
    print(request.url)
}

let domTree = context.treeController()
render(domTree.snapshot)
```

Close the container when inspection is no longer needed:

```swift
await container.close()
```

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

let results = context.fetchedResults(for: descriptor)
```

Use `WebInspectorFetchRequest` when request construction reads better as a
mutable CoreData-like object:

```swift
let request = WebInspectorFetchRequest<NetworkRequest>()
request.predicate = #Predicate { $0.method == "POST" }
request.sortDescriptors = [SortDescriptor(\.requestSentTimestamp, order: .reverse)]
request.fetchLimit = 1000

let controller = context.fetchedResultsController(for: request)
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

`NetworkMutationBatch` crosses back to the main context as values: inserted IDs,
removed result IDs, moved result IDs, optional reset snapshots, and patches for
existing requests. It must not carry `NetworkRequest` object references across
actor boundaries.

## Fetched Results Transactions

Use `WebInspectorFetchedResultsController` when non-SwiftUI UI code needs ordered
changes instead of only the observable current value:

```swift
let controller = context.fetchedResultsController(
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
- The main context applies patches by mutating the same `NetworkRequest` instance
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

`DOMTreeController` exposes the current document value and update stream:

```swift
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
try await context.highlight(node)
try await context.hideHighlight()
```

Page/document generation changes clear stale page highlights in DataKit. UI code
must not resurrect an old page highlight after navigation.

## Runtime, Console, and CSS

Runtime evaluation, console messages, and CSS state are context-attached model
operations:

```swift
let evaluation = try await context.evaluate("document.title")
let messages = context.fetchedResultsController(
    for: WebInspectorFetchDescriptor<ConsoleMessage>()
)

context.select(node)
context.setStyleHydrationActive(true)
let styles = node.elementStyles
```

Models preserve identity within the context. If the same semantic entity appears
again, DataKit mutates the existing observable object instead of replacing it.

## UI Boundary

WebInspectorDataKit does not import UIKit, AppKit, or SwiftUI for list rendering.
Native UI packages may keep transient render artifacts:

- `NSDiffableDataSourceSnapshot` / `NSDiffableDataSourceSectionSnapshot`
- visible row text/layout caches
- scroll position and expansion state
- selected menu state
- throttled native apply tasks

Those artifacts must be rebuildable from DataKit models or update streams and
must not become semantic state. UI code must not implement Network query
membership, DOM graph ownership, page highlight lifecycle, protocol event
ordering, or Network row-content propagation.

For Network collection views, UI code owns only native topology application and
cell lifecycle:

- Parent list owners apply fetched-results topology transactions.
- Cells observe `NetworkRequest` instances directly and render their own content.
- Content-only request mutations must not call collection-view reload,
  reconfigure, or diffable snapshot apply.
- Result removals and moves are topology changes, not content rendering.
- The model context is responsible for updating observable request models.

## Isolation and Identity

The main context is the UI-facing context, similar to SwiftData's
`ModelContainer.mainContext`. Treat model instances like SwiftData/Core Data
model objects:

- Keep them inside the context that vended them.
- Mutate same-identity objects in place.
- Pass semantic IDs or value DTOs across concurrency domains.
- Do not make UI-owned mirrors of model properties just to observe changes.

The UI-facing `WebInspectorContext` is the model context that owns observable
model identity. Dedicated actors may own Sendable indexes, records, query caches,
and protocol event processors, but they do not own or mutate UI-facing
`@Observable` model objects directly.

The boundary is:

```swift
// Off main actor: Sendable values only.
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

// Main context: observable identity and in-place mutation.
@MainActor
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
batches for the main model context to apply.

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

UI tests should verify native rendering and lifecycle only: diffable apply,
selection presentation, scroll/reveal behavior, hover decoration, throttling, and
hidden-view deferral. Network UI tests should verify that cells update by
observing `NetworkRequest` in place and that content-only changes do not trigger
collection-view reload, reconfigure, or snapshot apply.
