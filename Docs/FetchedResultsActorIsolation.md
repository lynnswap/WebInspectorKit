# Fetched-results actor isolation and grouped Network entries

Status: approved design gate (2026-07-11)

## Scope contract

### Outcome

The built-in Network UI displays one row for each logical initiator group and
shows every request in that group in the Detail surface. Network and Console
query projection, ordering, grouping, windowing, and transaction construction
run on an index actor. A model-context owner, which is `MainActor` for the
built-in UIKit consumer, resolves live identities and publishes already-built
changes without scanning the complete collection or constructing a diff.

### Consumers

- The first consumer is `WebInspectorUINetwork`, which uses a single grouped
  Network query to drive a one-section diffable list and its Detail surface.
- The second consumer is the external package in `ContractTests`, which imports
  the `WebInspectorDataKit` product and builds a custom actor-confined model UI.

### Compatibility

- Preserve `WebInspectorModelContext.networkRequests(matching:)`,
  `consoleMessages(matching:)`, the live model identities, and the atomic
  `.initial` plus bounded `.transaction` update stream.
- Preserve the closed `NetworkQuery` and `ConsoleQuery` vocabularies. Add the
  documented current-query and identity lookup surface that is currently
  missing from the implementation.
- Add initiator grouping as a supported Network query projection. Do not
  restore arbitrary `Predicate<Model>` or `SortDescriptor<Model>` evaluation.
- Adding a public `NetworkSection` case can break a consumer's exhaustive
  switch when it recompiles. Record that source change in the Unreleased
  migration notes; do not hide it behind an untyped or fallback grouping mode.
- Do not restore the zero-state `WebInspectorFetchedResultsController` wrapper.
  `WebInspectorFetchedResults` remains the query registration, current state,
  revision, snapshot, and stream owner.

### Non-goals

- Moving the complete DOM, CSS, Runtime, or Network live identity graph to a
  dedicated semantic actor. These identities remain caller-confined; the
  built-in UIKit session deliberately chooses `MainActor` as that caller.
- Changing `NativeInspectorBridge` isolation. WKWebView attachment, native send,
  and native detach remain `@MainActor`.
- Moving synchronous event decoding out of `ConnectionCore` without a separate
  ordered-decode profile and contract. It is not the observed Main Thread cost.
- Adding a package or target. The existing DataKit target already owns both the
  compact record index and live identity store, and a type boundary is enough to
  enforce their dependency direction.
- Rewriting existing commits or retaining the current UI grouping path as a
  compatibility path.

## Measured findings

The baseline is branch `codex/network-grouped-entries` at `80973d45` using
Xcode 26.6 and Swift 6.3.3. The package uses Swift 6, no default global actor,
strict memory safety, iOS 18.4, and macOS 15.4.

1. The `ci-test-determinism` reference has 202 DataKit occurrences of
   `isolated (any Actor)`; the current tree has 6. Internal actors remain, but
   the caller/executor intent is no longer visible at most API boundaries.
2. Commit `d148ee20` moved Network transaction construction into
   `NetworkRequestIndex`. Commit `94750e64` changed the index output to an
   identity projection and moved the O(n) transaction construction back into
   `WebInspectorFetchedResults.publish`, which runs on the model-context owner.
3. Instruments samples in `/Users/kn/Desktop/1819.txt` and
   `/Users/kn/Desktop/1822.txt` show this owner-side diff together with
   `NetworkPanelModel.displayEntries` consuming most sampled Main Thread time.
4. The Network UI owns two fetched results (`requests` and `allRequests`) and
   rebuilds all groups in `displayEntries`. A cell lookup calls that full
   grouping computation again, producing collection-size work per visible cell.
5. `NetworkRequestIndex.swift` and `ConsoleMessageIndex.swift` duplicate the
   mutation log, sequence waiters, weak registration, candidate replacement,
   acknowledgement, insertion, and delivery machinery. Their diff contains
   only about 145 domain-specific changed lines.
6. The architecture document promises `WebInspectorFetchedResults.query` and an
   O(1) identity subscript, but the implementation exposes neither.
7. The current 10,000-record tests verify compact record and identity lookup
   counters but run on `@MainActor` and do not prove where transaction work runs.
8. Compact Network navigation stores a desired `.detail` target while a user
   pop is active. After `didShow` clears selection, it replays the stale target,
   briefly pushes Detail, and then pops again.
9. ProxyKit keeps the native boundary on `MainActor`, routing and reply state in
   `ConnectionCore`, and model delivery in `ConnectionModelFeed`. Synchronous
   decode in `ConnectionCore` can cause actor head-of-line blocking, but it is
   not a MainActor regression and requires a separate ordered-decode change.

Baseline structural measurements:

- DataKit access keywords: 488 `public`, 327 `package`, 3 `open` occurrences.
- DataKit `Task.detached`: 3 occurrences.
- Network UI grouping-related references (`makeEntries`, `displayEntries`,
  `allRequests`): 17 occurrences.
- `WebInspectorModelContext.swift`: 3,395 lines and 16 direct private stored
  properties matching the baseline inventory command.
- `NetworkRequestIndex` and `ConsoleMessageIndex`: nine identical mutable owner
  fields each before generic extraction.

## Broken invariants and owners

1. A query publication crosses from the index actor only after membership,
   order, sections, window, and the transaction from the last acknowledged
   state have been completed. The generic query index owns this invariant.
2. The model-context owner never computes a collection diff. It validates a
   cursor, resolves only newly visible live identities, atomically replaces the
   fetched-results state, and acknowledges the applied state.
3. One logical Network group has one stable identity independent of filtering,
   the representative request, later group members, or UIKit row position. The
   Network query domain owns the identity; the Network store owns live member
   lookup; UIKit only renders it.
4. A compact navigation stack converges to selection at transition completion,
   not to a target calculated during the transition. The navigation controller
   owns that convergence.

## Target owner graph

```text
WKWebView / Native bridge (@MainActor)
    -> TransportReceiver
    -> ConnectionCore actor (ordered routing/replies)
    -> ConnectionModelFeed actor (ordered Sendable records)
    -> detached DataKit feed driver
    -> caller-confined live identity store
       -> compact Sendable record input
       -> WebInspectorQueryIndex<Domain> actor
          - filter / sort / group / window
          - snapshot / transaction / cursor
       -> caller-confined fetched-results publication
          - validate cursor
          - resolve live identities
          - publish atomically
    -> UIKit (@MainActor)
       - apply group-row transaction
       - resolve one group for a cell or Detail
       - render native objects
```

No package or target changes are required. `WebInspectorProxyKit` remains the
transport product, `WebInspectorDataKit` remains the semantic model/query
product, and `WebInspectorUINetwork` remains the UIKit adapter.

## Public API sketch

```swift
public struct NetworkQuery: Sendable, Equatable {
    public var search: String?
    public var resourceCategories: Set<NetworkRequest.ResourceCategory>
    public var methods: Set<String>
    public var sort: NetworkSort
    public var section: NetworkSection?
    public var offset: Int
    public var limit: Int?
}

public enum NetworkSection: Sendable, Equatable {
    case method

    /// One semantic entry per initiator node. Requests without a node are
    /// represented as stable singleton entries.
    case initiatorNode
}

@Observable
public final class WebInspectorFetchedResults<Model: WebInspectorPersistentModel> {
    public var items: [Model] { get }
    public var sections: [WebInspectorFetchSection<Model>] { get }
    public var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID> { get }
    public var revision: UInt64 { get }

    /// O(1) lookup in the current published result.
    public subscript(id id: Model.ID) -> Model? { get }

    /// O(1) lookup of a current published section.
    public subscript(section id: WebInspectorFetchSectionID)
        -> WebInspectorFetchSection<Model>? { get }

    public func updates()
        -> AsyncStream<WebInspectorFetchedResultsUpdate<Model.ID>>
}

public extension WebInspectorFetchedResults where Model == NetworkRequest {
    var query: NetworkQuery { get }
    nonisolated(nonsending) func update(_ query: NetworkQuery) async throws
}

public extension WebInspectorFetchedResults where Model == ConsoleMessage {
    var query: ConsoleQuery { get }
    nonisolated(nonsending) func update(_ query: ConsoleQuery) async throws
}
```

`NetworkSection.initiatorNode` has these semantics:

1. Form groups from all records. A node-backed request uses a namespaced node
   identity; a request without a node uses a namespaced request identity.
2. A group is visible when any member matches search/category/method filters.
3. A visible group publishes all members, including members that did not match.
4. Members are chronological ascending. A group is ordered by its first member,
   so a later media segment does not move the row.
5. Offset and limit apply to groups, not members.

A group section ID is stable within one Network source epoch. Node-backed and
singleton request identities use different namespaces; later members, filters,
and representative content never change the ID. The raw section value is
opaque to consumers: a singleton section deliberately cannot be decoded as a
DOM node ID.

The specialized `query` property is the last atomically committed and
published query, not an in-flight candidate. Query, items, sections, snapshot,
and revision change in the same `WebInspectorFetchedResults.State` replacement.
Cancellation or supersession before candidate commit leaves all of them
unchanged, so Observation never exposes a new query with old results.

UIKit visually flattens these DataKit sections into items in one UIKit section.
The DataKit section remains a semantic group, not a request for UIKit sectioned
presentation.

## Package implementation contract

```swift
package protocol WebInspectorIndexedQueryDomain {
    associatedtype ItemID: Hashable & Sendable
    associatedtype Input: Identifiable & Sendable where Input.ID == ItemID
    associatedtype Record: Identifiable & Sendable where Record.ID == ItemID
    associatedtype Query: Equatable & Sendable

    static func makeRecord(from input: Input) -> Record
    static func matches(_ record: Record, query: Query) -> Bool
    static func ordersBefore(_ lhs: Record, _ rhs: Record, query: Query) -> Bool
    static func makeSnapshot(
        allItemIDsInSourceOrder: [ItemID],
        matchingItemIDs: [ItemID],
        recordsByID: [ItemID: Record],
        query: Query
    ) -> WebInspectorFetchedResultsSnapshot<ItemID>
}

package struct WebInspectorIndexedQueryCursor: Hashable, Sendable {
    package let sourceEpoch: UInt64
    package let sequence: UInt64
}

package struct WebInspectorIndexedQueryState<ItemID>: Sendable
where ItemID: Hashable & Sendable {
    package let cursor: WebInspectorIndexedQueryCursor
    package let snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
}

package enum WebInspectorIndexedQueryChange<ItemID>: Sendable
where ItemID: Hashable & Sendable {
    case reset
    case transaction(
        base: WebInspectorIndexedQueryCursor,
        WebInspectorFetchedResultsTransaction<ItemID>
    )
}

package struct WebInspectorIndexedQueryPublication<ItemID>: Sendable
where ItemID: Hashable & Sendable {
    package let state: WebInspectorIndexedQueryState<ItemID>
    package let change: WebInspectorIndexedQueryChange<ItemID>
    package let reconfigureItemIDs: Set<ItemID>
}

package actor WebInspectorQueryIndex<Domain: WebInspectorIndexedQueryDomain> {
    // Owns records, contiguous mutation sequence, weak registrations,
    // active/candidate query versions, acknowledged state, and diff creation.
}
```

`allItemIDsInSourceOrder` is the actor-owned unfiltered insertion/source order,
not query-sorted output. A domain that needs an unfiltered projection, such as
Network initiator grouping, derives its member and group order inside
`makeSnapshot`. Other domains continue sorting only their matching subset.

Each active query version stores its latest state and optional last acknowledged
state. Every incremental transaction is built from that acknowledged snapshot
to the newest snapshot. An acknowledgement carries the state actually applied
by the fetched-results owner, not only a scalar sequence.

Initial registration, source-epoch replacement, and a newly committed candidate
have no acknowledged baseline and publish `.reset`. Candidate commit never
implicitly acknowledges its current snapshot. Until the owner acknowledges the
committed generation, later publications for that generation remain resets.

If a bounded/coalesced delivery reaches an owner whose cursor does not equal the
transaction base, the owner performs the public gap-recovery operation: publish
one reset from its actual current snapshot to the delivered complete snapshot.
It does not rebuild an insert/delete/move diff on the owner actor.

`NetworkRequestRecordInput` contains only the raw immutable values read from the
live model, including redirect values and initiator node identity. Searchable
text and resource classification are derived by the Network domain witness on
the query actor.

## Consumer usage

External DataKit consumer:

```swift
let requests = try await context.networkRequests(matching: NetworkQuery(
    search: "media",
    sort: .requestTimeDescending,
    section: .initiatorNode,
    limit: 100
))

for await update in requests.updates() {
    apply(update)
}

let committedQuery = requests.query
let model = requests[id: requestID]
let group = requests[section: groupID]
```

Built-in UIKit before:

```swift
let visible = requests.items
let all = allRequests.items
let entries = NetworkPanelModel.makeEntries(from: all, visibleRequestIDs: ...)
let members = entries.first { $0.id == rowID }?.requests
```

Built-in UIKit after:

```swift
let rowIDs = requests.snapshot.sectionIDs
let members = requests[section: rowID]?.items
```

## Network selection contract

`NetworkRequestStore` maintains the sole live mapping from semantic group ID to
request IDs and from request ID to group ID. It uses the same namespaced group
identity value placed in each compact index record. This lookup is independent
of a query's current filter, so filtering a selected row out of the list does
not discard its Detail content and does not require a second `allRequests`
registration.

The collection state exposes a source epoch/topology revision to package
consumers. A panel selection captures group ID and source epoch. Filters and
same-group insertions preserve it; clear/source reset invalidates it. A compact
pop commit compares the captured selection token, rather than clearing a newer
selection that happens to have the same group ID.

## UIKit transaction mapping

The semantic snapshot uses section = Network entry and item = request. The
UIKit list uses one `.main` section and item = Network entry.

- semantic section insert/delete/move -> UIKit row insert/delete/move
- semantic section update -> UIKit row reconfigure
- semantic item insert/delete/move -> reconfigure the old/new surviving rows
- `reconfigureItemIDs` -> reconfigure their current rows
- reset or revision gap -> replace from `newSnapshot.sectionIDs`

Pending UIKit snapshot work stores a set of entry IDs to reconfigure and unions
that set when publications arrive during an apply. A Boolean `forceApply` is not
sufficient because it can lose the second group's content invalidation.

Cells resolve one section by ID. They never call a property that scans all
entries. Detail alone observes the selected member identities and content.
Navigation observes selection availability only and does not acquire an
Observation dependency on every selected request property.

## Deletion list

- Duplicate mutation/registration/candidate/acknowledgement machinery in
  `NetworkRequestIndex` and `ConsoleMessageIndex`; retain only domain witnesses
  plus the generic actor.
- Owner-side normal transaction construction in
  `WebInspectorFetchedResults.publish`.
- `NetworkPanelModel.allRequests`, `allEntries`, `displayEntries`,
  `makeEntries`, `hasInitiatorEntries`, and the second query lifecycle.
- `NetworkListViewController`'s second fetched-results task and its grouped
  full-reload branches.
- Representative-request row identity and request-ID selection for grouped
  entries.
- `DeferredStackSync.target`; deferred navigation stores animation intent only.

## Avoided shapes

- Do not use `Task.detached` per mutation. The index actor is the state and
  ordering owner; arbitrary detached tasks would permit reordering and lose
  structured acknowledgement.
- Do not evaluate an unsupported public predicate against live models on the
  caller actor. Unsupported query states remain unrepresentable.
- Do not add an `allRequests` query, a pinned hidden query, or a UI group cache
  to preserve selection. The Network store owns unfiltered group membership.
- Do not reintroduce a forwarding FRC wrapper or a second update stream.
- Do not repair a cursor mismatch by computing a diff on the model-context
  owner. Publish a reset from the complete delivered snapshot.
- Do not preserve a navigation target calculated before transition commit.
- Do not move native WKWebView work away from `MainActor`.

## Test plan

### Characterization and owner tests

- Preserve contiguous mutation ordering, cancellation of sequence waiters,
  weak registration pruning, candidate supersession, source epochs, clear, and
  atomic initial publication for both Network and Console.
- Verify an active publication's transaction old snapshot equals the last
  acknowledged snapshot even when multiple mutations precede acknowledgement.
- Verify candidate commit has no implicit acknowledgement and converges through
  reset until the owner acknowledges it.
- Verify a stale/base-mismatched publication becomes one reset without invoking
  the normal transaction builder on the owner.

### Grouping tests

- Node-backed groups and uninitiated singleton groups have deterministic stable
  section IDs.
- Any-member filter visibility publishes every member.
- Members and groups have the documented order; offset/limit count groups.
- Same-group insertion preserves section identity and emits item changes.
- A reused request whose initiator changes moves groups.
- Clear/source reset invalidates group lookup and selection epoch.

### UIKit tests

- One UIKit section contains semantic group IDs as rows.
- A member insertion updates the row count without evaluating all entries.
- Pending snapshot updates union reconfigure IDs.
- A selected group survives filtering and receives later same-group members.
- Clear/source replacement invalidates selection without resurrecting an equal
  group ID.
- User pop with a deferred old `.detail` intent stays on the list; interactive
  cancel and selection replacement converge to current selection.

### Performance and product contract

- Retain the 10,000-record Network and Console gates and add assertions for
  actor-produced transactions and bounded identity lookup.
- Add a 1,000-member group characterization to record list-cell and Detail
  behavior. If Detail document construction remains measurable, move raw
  document projection off MainActor in a separately designed change.
- Build and test the external `ContractTests` package using only public DataKit
  surface, including current query and O(1) lookup calls.
- Run the shared `WebInspectorKit` Xcode scheme on the iPhone 17 simulator.

## Finding-to-design mapping

| Finding | Resolution |
| --- | --- |
| 1 | Explicit generic actor/Domain contract and documented caller confinement |
| 2 | Actor-owned acknowledged state and completed transaction publication |
| 3 | Remove owner diff and UI full grouping; performance regression tests |
| 4 | Single grouped query plus store-owned unfiltered group lookup |
| 5 | `WebInspectorQueryIndex<Domain>` and domain witnesses |
| 6 | Implement current `query` and O(1) result/section subscripts |
| 7 | Cursor/transaction behavior tests and external consumer build |
| 8 | Deferred navigation recomputes target after commit |
| 9 | Proxy owner graph documented; ordered decode is an explicit non-goal |

## Migration sequence

1. Extract the behavior-preserving generic query actor and keep all existing
   query tests green.
2. Introduce acknowledged query state and actor-built transactions; remove
   owner-side normal diff construction.
3. Add Network initiator projection and store group lookup.
4. Migrate Network UI to one grouped result and stable group selection; fix
   compact navigation and delete the old grouping path.
5. Update public DocC, architecture/migration docs, and external contract tests.
6. Run targeted tests, the full Xcode scheme, Instruments-equivalent counters,
   and `codex-review`; fix at the owning layer until clean.
