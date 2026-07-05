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
  transactions for UIKit/AppKit list owners.
- `WebInspectorFetchedResultsSnapshot`, `WebInspectorFetchedResultsTransaction`:
  Section and item ID snapshots plus ordered section/item changes suitable for
  conversion to native UI update APIs.
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

Changing a fetch descriptor is a query-boundary operation. It may re-evaluate the
registered model index once and emit an ordered transaction. Normal protocol
events must not re-run every query from scratch.

```swift
var descriptor = controller.fetchDescriptor
descriptor.predicate = #Predicate { $0.statusCode >= 400 }
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

Resource-category classification, search tokens, and query membership belong in
WebInspectorDataKit. The built-in UI can map `NetworkRequest.ResourceCategory`
to localized filter labels such as "CSS", "JS", or "XHR / Fetch", but it must not
own Network query semantics.

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
underlying `WebInspectorFetchedResults`, and transactions are emitted from the
same state updates that mutate those current values.

Snapshots contain section IDs, optional titles, and item IDs only. Convert
`WebInspectorFetchedResultsTransaction` into `UICollectionView`,
`NSCollectionView`, diffable data source, table, or outline updates in the UI
layer.

## Live Network Event Semantics

`WebInspectorContext` owns the Network request index and preserves
`NetworkRequest` identity. When WebKit protocol events arrive:

- A new request inserts one `NetworkRequest` instance into the context index.
- Later events mutate the same `NetworkRequest` instance in place.
- Registered fetched results revalidate only the affected request for normal
  insert/update/delete events.
- A descriptor change may re-evaluate the full local index once.
- Clearing requests is a reset boundary and may emit delete/reset transactions.

The following shape is not allowed on the hot path:

```swift
// Do not do this for every Network event.
let items = currentNetworkRequests()
results.setItems(items, updatedItemIDs: [changedID])
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
membership, DOM graph ownership, page highlight lifecycle, or protocol event
ordering.

## Isolation and Identity

The main context is the UI-facing context, similar to SwiftData's
`ModelContainer.mainContext`. Treat model instances like SwiftData/Core Data
model objects:

- Keep them inside the context that vended them.
- Mutate same-identity objects in place.
- Pass semantic IDs or value DTOs across concurrency domains.
- Do not make UI-owned mirrors of model properties just to observe changes.

Future background contexts or model actors should own their own model instances
and merge by semantic IDs, not share mutable observable model objects across
actors.

## Testing

Test DataKit owners without the built-in UI:

- Fetch descriptor predicates and sort descriptors.
- Network event insert/update/delete/reset transaction behavior.
- Predicate enter/leave and sort-key move behavior for a single changed request.
- Descriptor changes performing one full local requery.
- DOM document/page switch emitting snapshots.
- DOM attribute/text/count/child events emitting deltas.
- Picker inspect selecting, revealing, and restoring highlight for the resolved
  node.
- Page navigation clearing stale highlights.

UI tests should verify native rendering and lifecycle only: diffable apply,
selection presentation, scroll/reveal behavior, hover decoration, throttling, and
hidden-view deferral.
