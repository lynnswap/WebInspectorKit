# WebInspector model container and context architecture

- Status: approved design gate (2026-07-12)
- Scope amendment: navigation and DOM-binding epochs separated (2026-07-12)
- Baseline branch: `codex/network-grouped-entries`
- Baseline revision: `bf364dbb43402ace80542ab3826b32e8a22b40d0`
- Toolchain baseline: Swift 6.3, iOS 18.4, macOS 15.4
- Supersedes the DataKit ownership and query decisions in
  `WebInspectorKitsArchitecture.md` and `FetchedResultsActorIsolation.md`

## Decision

WebInspectorDataKit will use the ownership shape shared by SwiftData and Core
Data:

```text
WebInspectorModelContainer
  -> one ProxyKit connection and one canonical Sendable record store
  -> one or more actor-confined WebInspectorModelContext instances
       -> context-local identity registry
       -> context-local Observable model instances
       -> generic fetched-results controllers
```

The values crossing an isolation or context boundary are stable identifiers,
immutable records, snapshots, and deltas. An Observable persistent-model
instance belongs to exactly one model context and never crosses to another
actor or context.

This is a breaking migration. Repository consumers move to the new API in the
same branch. The migration does not retain the current exclusive-context path,
domain-specific fetched-results path, or section-as-Network-row path as
compatibility layers.

## Scope contract

### Outcomes

1. One inspected `WKWebView` has one model container and one ProxyKit model
   feed, while multiple model contexts may independently consume the same
   canonical page state.
2. The built-in UIKit inspector uses a main-actor context. A headless or custom
   consumer asks the same container to vend a context confined to any actor.
   The context has no public initializer independent of its container.
3. The same stable ID resolves to the same object instance for the lifetime of
   one context registration, and to different instances in different contexts.
4. Filtering, sorting, sectioning, grouping, windowing, and difference
   construction run over immutable Sendable query values outside the context
   owner actor.
5. A fetched-results subscription receives one atomic initial snapshot,
   contiguous deltas afterward, and an explicit reset only when continuity is
   lost.
6. The Network list displays one `NetworkEntry` item per logical group. Detail
   resolves every member request ID through its model context and renders all
   requests in the entry.
7. Media preview uses the selected entry's context-owned request models and a
   native player controller. It does not imply that playback creates WebKit
   network traffic.
8. Returning from compact Network Detail converges directly to the list; stale
   selection state cannot briefly repush Detail.

### Primary consumers

- `WebInspectorKit` and the built-in UIKit DOM and Network tabs.
- A custom UI importing `WebInspectorDataKit` and owning an independent model
  context on a non-main actor.
- The external `ContractTests` package, which must build and link using only
  the public `WebInspectorDataKit` product.

### Compatibility

- Source compatibility is not preserved for the current
  `WebInspectorModelContext.attach(to:)`, `NetworkQuery`, `ConsoleQuery`, or
  `WebInspectorFetchedResults` APIs.
- Existing ProxyKit typed command and event APIs remain available.
- The single-consumer `ConnectionModelFeed` remains a ProxyKit invariant. Its
  consumer moves from an individual model context to the model container.
- Existing domain-model behavior is preserved unless this document assigns
  the responsibility to a different owner.

### Non-goals

- Disk persistence, save, rollback, undo, fault fulfillment, CloudKit, or
  cross-process identity.
- A separate general-purpose persistence package. The generic machinery has no
  consumer independent of WebInspectorDataKit.
- AppKit inspector UI work.
- Evaluating a live context-owned model instance from a query actor.
- Transparently accepting every possible `Predicate<Model>` expression by
  falling back to the context owner actor.
- Redesigning ProxyKit's raw protocol command surface beyond the ownership
  changes required to make the container its feed consumer.

## Evidence and baseline findings

### Measured baseline

- DataKit lexical access declarations: 493 `public`, 379 `package`, 3 `open`.
- DataKit imports ProxyKit in 19 source files and has no platform `#if` gates.
- `WebInspectorModelContext.swift` is 3,541 lines and directly owns 26 stored
  properties, including all domain stores, Proxy/feed state, and long-lived
  tasks.
- `NetworkRequestStore.swift` is 1,628 lines; `ConsoleMessageStore.swift` is
  924 lines.
- DataKit contains 53 `NetworkQuery` / `ConsoleQuery` references.
- DataKit contains three `Task.detached` sites.

### Findings

`F1` — `WebInspectorModelContext` owns both connection lifecycle and a semantic
identity graph. Closing one context therefore closes the ProxyKit connection.

`F2` — ProxyKit correctly permits one model-feed consumer per connection, but
the consumer is an individual context. No owner can fan the source out to
multiple contexts.

`F3` — `WebInspectorFetchedResults<Model>` is generic in spelling but contains
`ConcreteQuery.network` and `ConcreteQuery.console`, and only those two model
types have public creation paths.

`F4` — Query-registration state is divided among fetched results, each domain
store, and `WebInspectorQueryIndex`. Network and Console duplicate lifecycle,
candidate, acknowledgement, and delivery logic.

`F5` — Model IDs are documented as stable only within a context. Raw WebKit IDs
and context-local Console ordinals can be reused by another target, document,
page generation, or context.

`F6` — Domain stores eagerly retain and mutate all Observable model objects on
the context owner actor, even when a UI only needs IDs or a few visible models.

`F7` — Current fetched-results transactions carry old and new full snapshots.
Newest-only coalescing is safe only because each transaction also acts as a
recovery snapshot; it is not a complete-delta contract.

`F8` — Network grouping uses fetched-results sections as logical list rows.
UIKit then flattens semantic sections back into one UIKit section.

`F9` — The current architecture documents explicitly require one exclusive
context and closed Network/Console queries. They contradict the approved
container/context design.

`F10` — Compact navigation stores a desired Detail target while a pop is in
progress and can replay that stale target after returning to the list.

`F11` — Page navigation and target replacement can surface a model-context
failure as a user-visible network failure because connection lifecycle and
context lifecycle are the same state machine.

`F12` — Network preview depends on UI selection wrappers and section lookup,
rather than one stable semantic entry ID followed by context model resolution.

`F13` — A Network model event carries generation and target but neither a
navigation epoch nor an exact DOM-binding epoch. WebKit does not emit
`DOM.documentUpdated` until `DOM.getDocument` has armed document delivery, so a
Network-only container cannot truthfully provide a DOM-binding epoch without
also constructing the DOM. Navigation scope and DOM-binding scope are distinct
protocol facts and must not be represented by one synthetic epoch.

`F14` — ProxyKit's direct event projection embeds target scope into some raw ID
strings with a separator while leaving main-target IDs unmodified. The model
feed already has a structured target; DataKit must not parse or reuse this
transport encoding as persistent identity.

`F15` — Current Network and Runtime stores accept reuse of a terminal raw ID by
replacing content under the same public ID. WebKit's corresponding ID owners
are monotonic within their scope. Reuse of the same fully scoped ID is a
protocol violation, except that a Network redirect deliberately continues the
same request ID.

`F16` — `WebInspectorModelContext` directly switches over DOM, CSS, Network,
Console, Runtime, target-lifecycle, bootstrap, and command cases. The type is a
domain coordinator rather than a reusable context boundary, so adding or
changing a domain edits context lifecycle code.

### Historical cause

- `61f547f5` removed `WebInspectorFetchedResultsController` while fixing the
  initial-snapshot/subscription race.
- `94750e64` introduced closed `NetworkQuery` and `ConsoleQuery` ownership.
- `eb69e9e6` removed `WebInspectorContainer` and `WebInspectorContext`, and made
  the new model context own an exclusive ProxyKit connection.

The atomic publication, ordered feed, detached driver, and query-index work
added by those commits remain useful. The exclusive owner graph and closed
public query vocabulary do not.

## Apple framework analog and deliberate differences

The installed iOS 26.5 SDK and Xcode Documentation establish these reference
contracts:

- SwiftData declares `ModelContext: Equatable, SendableMetatype` and separately
  declares an unavailable `@unchecked Sendable` conformance with the message
  that contexts cannot be shared across concurrency contexts.
- `ModelContext.init(_ container:)` exists and the context exposes its
  container. `ModelContainer.mainContext` is the default main-actor context.
- Core Data permits low-level `NSManagedObjectContext(concurrencyType:)`
  construction, while `NSPersistentContainer` owns the standard stack and
  vends `viewContext`, `newBackgroundContext()`, and `performBackgroundTask`.
- Both SwiftData `ResultsObserver` and Core Data
  `NSFetchedResultsController` bind one observed result set to a specific model
  context. The context is part of query identity, not a global model cache.
- SwiftData exposes identifier-only fetch and context-local
  `model(for:)`/`registeredModel(for:)` operations.

WebInspectorDataKit adopts the context identity, context-local object graph,
identifier-only query, and context-bound results-controller shapes. It is
stricter about context creation: the model container is the only public
factory. Unlike a database coordinator, the container owns one exclusive live
ProxyKit model feed, so a free-standing context initializer would obscure
which connection, terminal state, and close authority the context belongs to.

It also deliberately does not copy SwiftData's fault behavior. A foreign,
deleted, or stale identifier returns `nil`; DataKit never invents an empty
model whose backing WebKit resource may not exist.

## Target and package graph

No product, target, or package is added.

```text
WebInspectorNativeBridge (@MainActor native WebKit boundary)
  -> WebInspectorProxyKit (connection, routing, one ordered model feed)
       -> WebInspectorDataKit (container, records, contexts, models, queries)
            -> WebInspectorUI* (UIKit rendering and navigation)
                 -> WebInspectorKit (public built-in inspector composition)
```

This is the selected topology because:

- ProxyKit and DataKit already have independent public consumer stories.
- The record/query machinery has no consumer or versioning boundary independent
  of DataKit, so a new package or target would be a file bucket.
- Native bridge and UIKit boundaries already require distinct targets because
  of source language and platform dependencies.
- The existing target graph enforces the required dependency direction.

`WebInspectorDataKit` remains the only owner of the semantic record schema,
context identity graph, and query behavior. `WebInspectorProxyKit` does not
learn about persistent models or queries.

## Owner map

| Responsibility | Owner | Contract |
| --- | --- | --- |
| WKWebView attach/detach | Native bridge / ProxyKit | Only the native WebKit boundary is `@MainActor`. |
| Physical targets, replies, capabilities | ProxyKit connection core | One source of transport truth. |
| Structured model-event scope | ProxyKit model feed | Generation, target, navigation epoch, and optional exact DOM-binding epoch travel separately from raw IDs. |
| Model-feed iteration and final Proxy close | `WebInspectorModelContainer` core | Exactly one feed consumer and close authority. |
| Context creation and registration | `WebInspectorModelContainer` | `mainContext` and `makeContext(isolation:)` are the only public creation paths. |
| Canonical current records and revision | container record-store actor | No Observable models. |
| Context subscription fan-out | container publication broker | Atomic initial snapshot plus ordered delta/reset. |
| Context record mirror and query execution | one context-core actor per context | Immutable Sendable records only. |
| Observable identity graph | `WebInspectorModelContext` owner actor | Same ID returns the same live object in that context. |
| Runtime remote-object resources | `RuntimeObjectGroup` or owning Console model in one context | Remote handles are never persistent/queryable identities. |
| Loaded CSS-style resources | owning `DOMNode` in one context | Load/refresh/failure state is never persistent/queryable membership. |
| Query membership and order | generic query registration in context core | Produces ID snapshots and differences. |
| FRC descriptor/revision/subscribers | `WebInspectorFetchedResultsController` | One lifecycle owner, no domain switch. |
| Network logical grouping | Network record reducer | Produces `NetworkEntry` records and member request IDs. |
| Selection | UIKit panel/navigation model | Stores stable `NetworkEntry.ID`, never a section wrapper. |
| Rendering | UIKit controllers/views | Resolves IDs, observes models, installs native artifacts. |

## Persistent entities and context resources

`WebInspectorPersistentModel` is reserved for canonical entities represented in
the container store and resolvable by stable ID in every context of that
container. Initially these are `DOMNode`, `NetworkRequest`, `ConsoleMessage`,
and `RuntimeContext`; `NetworkEntry` joins them during the Network migration.

`RuntimeObject` and `CSSStyles` are context-local resources instead:

- `RuntimeObject` is retained by a `RuntimeObjectGroup` or a Console message and
  represents a remote handle whose command lifetime belongs to that context.
- `CSSStyles` is loaded on demand by one context and its loading/failure/refresh
  phase belongs to the owning `DOMNode`.

Those resource types remain Observable, identifiable reference types where
their consumers require it, but do not conform to
`WebInspectorPersistentModel`, do not expose `QueryValue`, and are not accepted
by generic fetch or `model(for:)`.

## Stable identity contract

Every public persistent-model ID is an opaque concrete value conforming to
`WebInspectorPersistentIdentifier`.

```swift
public protocol WebInspectorPersistentIdentifier: Hashable, Sendable {
    associatedtype Model: WebInspectorPersistentModel
}

public protocol WebInspectorPersistentModel:
    AnyObject,
    Observable,
    Hashable,
    Identifiable,
    SendableMetatype
where
    ID: WebInspectorPersistentIdentifier,
    ID.Model == Self,
    QueryValue: Identifiable & Sendable,
    QueryValue.ID == ID
{
    associatedtype QueryValue
    nonisolated var id: ID { get }
}
```

The internal identity key includes the domain-specific scopes required to
prevent aliasing and reject stale commands:

- model-container/store identity;
- page generation;
- physical target where the WebKit ID is target-local;
- exact DOM-binding epoch for DOM/CSS identities;
- the domain's canonical raw identity or canonical container-assigned ordinal.

The concrete persistent identities are scoped as follows:

| Model | Identity scope after container/store ID |
| --- | --- |
| `DOMNode` | page generation, physical target, exact DOM-binding epoch, raw node ID |
| `NetworkRequest` | page generation, physical target, raw request ID |
| `ConsoleMessage` | canonical container-assigned message ordinal |
| `RuntimeContext` | page generation, physical target, raw execution-context ID |
| `NetworkEntry` | canonical container-assigned entry ID |

ProxyKit supplies a structured model-event scope instead of encoding target
scope into raw IDs:

```swift
package struct ModelEventScope: Sendable {
    let generation: WebInspectorPage.Generation
    let target: ModelTarget
    let navigationEpoch: ModelNavigationEpoch
    let domBindingEpoch: ModelDOMBindingEpoch?
}
```

ProxyKit maintains the navigation epoch from its Page observation lease for
every configured model feed. A new loader advances the epoch for the affected
target. ProxyKit maintains the exact DOM-binding epoch from
`DOM.documentUpdated` only while DOM delivery is armed; DOM/CSS records require
that value. It does not issue a hidden `DOM.getDocument` merely to manufacture
a DOM epoch for Network, Console, or Runtime.

This distinction follows WebKit's own agent contracts. `Page.frameNavigated`
reports that a frame is associated with a new loader. By contrast,
`InspectorDOMAgent::setDocument` and `FrameDOMAgent::setDocument` suppress
`DOM.documentUpdated` until `DOM.getDocument` has marked the document as
requested. Treating either signal as the other would invent state that the
producer did not publish.

The model feed establishes initial authority in this order:

```text
reset(generation)
-> target snapshot containing each target's current navigation/DOM scope
-> per-domain replay or authoritative bootstrap boundary
-> synchronization complete after every configured domain is authoritative
```

This is not permission to reduce every live event before an asynchronous
bootstrap finishes. DOM and CSS are snapshot domains. ProxyKit suppresses live
domain deltas until it publishes the authoritative bootstrap snapshot at
sequence `S`; that snapshot represents state through `S`, and only events
ordered after `S` are delivered as deltas. DOM authority is tracked per target,
so one ready target need not wait for another. CSS authority is page-wide: any
relevant DOM invalidation returns CSS to awaiting state and triggers a fresh
`CSS.getAllStyleSheets` snapshot before later CSS deltas are delivered.

Network, Console, and Runtime are replay-only domains. They have no later
snapshot that can overwrite already delivered state, so their ordered events
after the target-snapshot fence remain authoritative. Their
`replayComplete(through:)` marker closes the enable/replay boundary; it does not
replace those events. `synchronizationComplete` is published only after every
configured domain has established the appropriate boundary.

The final model feed carries raw protocol IDs unchanged; ProxyKit's direct
typed event APIs retain their existing target-prefixed projection as a separate
consumer contract. During migration, structured scope lands before prefix
removal. A domain stops receiving projected IDs only in the same change that
makes its DataKit reducer construct persistent IDs from structured scope.

A Network initiator node becomes a resolvable `DOMNode.ID` only when its event
scope carries an exact DOM-binding epoch. Otherwise the Network reducer may use
an internal opaque grouping key made from generation, target, navigation epoch,
and raw node ID, but it must not manufacture a persistent DOM identity or pass
that key to `model(for:)`. The canonical store never decodes a target prefix
from a raw protocol ID.

Navigation epoch is not part of `NetworkRequest.ID`: WebKit request IDs are
monotonic within their generation/target scope and redirects deliberately keep
the same ID. The epoch is an event-validity and opaque-related-resource
boundary. Exact DOM-binding epoch remains part of `DOMNode.ID` even though the
current WebKit node counter is monotonic, because document replacement is the
command-validity boundary.

Runtime clearing is likewise a membership boundary, not a new identity scope.
Current WebKit's `InjectedScriptManager::discardInjectedScripts()` clears its
maps without resetting `m_nextInjectedScriptId`, and the current Runtime
protocol publishes only context creation. ProxyKit may decode legacy
destroy/clear events, but a later reuse of the same execution-context ID within
one generation and physical target is still a protocol violation. A target or
page-generation change already produces a distinct `RuntimeContext.ID`.

Consequences:

- Two contexts from one container receive equal IDs for the same entity.
- Those contexts materialize different object instances.
- A second call in one context returns the existing instance.
- IDs from another container or an expired generation do not resolve.
- Context reset/delete unregisters the model. Existing external references are
  stale and cannot be used for commands.
- Console ordinals are assigned by the canonical store, not independently by
  each context.
- Reuse of one fully scoped DOM, Network, Runtime-context, or remote-object raw
  identity fails fast at the reducer boundary. A Network redirect is an update
  to the existing scoped request, not reuse.

The context strongly retains materialized active models until deletion,
generation reset, or context close. This makes same-context identity an actual
contract rather than a weak-cache accident.

## Public API sketch

The sketch is the intended source surface. Exact isolation spellings are
subject to the compiler proof described below, but the ownership contract is
not.

```swift
public final class WebInspectorModelContainer: Equatable, Sendable {
    public struct Domain: Hashable, Sendable {
        public static let dom: Domain
        public static let network: Domain
        public static let console: Domain
        public static let runtime: Domain
        public static let css: Domain
    }

    public struct Configuration: Sendable {
        public var domains: Set<Domain>
        public init(
            domains: Set<Domain> = [
                .dom, .network, .console, .runtime, .css,
            ]
        )
    }

    @MainActor
    public init(
        attachingTo webView: WKWebView,
        configuration: Configuration = .init(),
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws

    @MainActor
    public let mainContext: WebInspectorModelContext

    public func makeContext(
        isolation: isolated (any Actor) = #isolation
    ) async throws -> WebInspectorModelContext

    public func close() async
}

public final class WebInspectorModelContext: Equatable, SendableMetatype {
    public nonisolated static func == (
        lhs: WebInspectorModelContext,
        rhs: WebInspectorModelContext
    ) -> Bool

    public func registeredModel<ID>(for id: ID) -> ID.Model?
    where ID: WebInspectorPersistentIdentifier

    public func model<ID>(for id: ID) -> ID.Model?
    where ID: WebInspectorPersistentIdentifier

    public nonisolated(nonsending) func fetchIdentifiers<Model>(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> [Model.ID]

    public nonisolated(nonsending) func fetch<Model>(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> [Model]

    public nonisolated(nonsending) func fetchedResultsController<Model>(
        for descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> WebInspectorFetchedResultsController<Model, Never>

    public nonisolated(nonsending) func fetchedResultsController<
        Model,
        SectionName
    >(
        for descriptor: WebInspectorFetchDescriptor<Model>,
        sectionBy: Expression<Model.QueryValue, SectionName>
    ) async throws -> WebInspectorFetchedResultsController<Model, SectionName>
    where SectionName: Hashable & Sendable

    public nonisolated(nonsending) func close() async
}

@available(
    *,
    unavailable,
    message: "contexts cannot be shared across concurrency contexts"
)
extension WebInspectorModelContext: @unchecked Sendable {}
```

`WebInspectorModelContext` equality is reference/context identity (`===`), not
equality of current records. `SendableMetatype` permits its type metadata in
generic schema/query machinery without making an instance transferable. The
unavailable `Sendable` conformance gives the same explicit diagnostic shape as
SwiftData. The instance remains in the caller isolation supplied to the
container factory; its internal context core and record cache are separate
Sendable owners.

The container registers the context subscription atomically before returning
the context. Creation after container close fails. A context retains the
container core, not the public container object; the public container retains
`mainContext`, so this owner graph has no container/context reference cycle.
Custom contexts retain their own subscriptions and may close independently.

One container is one inspection session. Multiple contexts that are intended
to observe the same `WKWebView` use that container and therefore share one
canonical store and feed. A separately attached container is a separate
session with different store identity; its IDs and models never alias.

### Fetch descriptor

Foundation `Predicate`, `Expression`, and `SortDescriptor` are Sendable on the
deployment baseline. They operate on a model's immutable `QueryValue`, never
on its context-owned Observable instance.

```swift
public struct WebInspectorFetchDescriptor<Model>: Sendable
where Model: WebInspectorPersistentModel {
    public var predicate: Predicate<Model.QueryValue>?
    public var sortBy: [SortDescriptor<Model.QueryValue>]
    public var fetchOffset: Int
    public var fetchLimit: Int?

    public init(
        predicate: Predicate<Model.QueryValue>? = nil,
        sortBy: [SortDescriptor<Model.QueryValue>] = []
    )
}
```

The common call site retains SwiftData-like syntax through contextual type
inference:

```swift
let media = NetworkRequest.ResourceCategory.media
let descriptor = WebInspectorFetchDescriptor<NetworkEntry>(
    predicate: #Predicate { entry in
        entry.resourceCategories.contains(media)
    },
    sortBy: [SortDescriptor(\.startedAt)]
)
```

Predicate evaluation errors fail initial registration or terminate that query
registration. They never fall back to evaluating on the model-context actor.

### Fetched-results controller

The controller is the actual query-registration and publication owner, not a
forwarding wrapper.

```swift
@Observable
public final class WebInspectorFetchedResultsController<
    Model,
    SectionName
>
where
    Model: WebInspectorPersistentModel,
    SectionName: Hashable & Sendable
{
    public let modelContext: WebInspectorModelContext
    public private(set) var fetchDescriptor:
        WebInspectorFetchDescriptor<Model>
    public private(set) var revision: UInt64
    public private(set) var snapshot:
        WebInspectorFetchedResultsSnapshot<Model.ID, SectionName>

    public nonisolated(nonsending) func update(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws

    public func updates()
        -> WebInspectorFetchedResultsUpdateSequence<Model.ID, SectionName>

    public nonisolated(nonsending) func close() async
}
```

The controller stores IDs and section names only. A UI resolves a visible or
selected ID with its context.

### Snapshot and delta

```swift
public struct WebInspectorFetchedResultsSnapshot<
    ItemID,
    SectionName
>: Sendable where ItemID: Hashable & Sendable,
                  SectionName: Hashable & Sendable

public enum WebInspectorFetchedResultsUpdate<
    ItemID,
    SectionName
>: Sendable where ItemID: Hashable & Sendable,
                  SectionName: Hashable & Sendable {
    case initial(
        revision: UInt64,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID, SectionName>
    )
    case changes(
        fromRevision: UInt64,
        toRevision: UInt64,
        sectionChanges: [WebInspectorFetchedResultsSectionChange<SectionName>],
        itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>],
        updatedItemIDs: Set<ItemID>
    )
    case reset(
        revision: UInt64,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID, SectionName>
    )
}

public struct WebInspectorFetchedResultsUpdateSequence<
    ItemID,
    SectionName
>: AsyncSequence, Sendable
where ItemID: Hashable & Sendable,
      SectionName: Hashable & Sendable {
    public typealias Element =
        WebInspectorFetchedResultsUpdate<ItemID, SectionName>
    public typealias Failure = any Error
}
```

Each subscriber has a custom synchronized mailbox. If a subscriber has not
consumed its pending change when a later revision arrives, the mailbox
atomically replaces the pending value with one `.reset` containing the latest
snapshot. It does not use two `AsyncStream.yield` calls as an atomic
replacement.

Normal delivery after `.initial` is delta-only. Full snapshots appear only in
`.initial` and `.reset`.

The sequence uses typed throwing iteration. A predicate-evaluation or
registration failure terminates only that controller's sequence; container and
sibling queries remain active. Consumers therefore iterate with
`for try await` and handle query failure separately from container failure.

For an unsectioned controller (`SectionName == Never`), a snapshot contains one
flat `itemIDs` order and no named sections. `Never` is a type-level marker; the
implementation does not fabricate a sentinel section name.

## Consumer usage

### Built-in UIKit consumer

```swift
@MainActor
func attach(to webView: WKWebView) async throws {
    let container = try await WebInspectorModelContainer(
        attachingTo: webView
    )
    let context = container.mainContext
    let controller = try await context.fetchedResultsController(
        for: WebInspectorFetchDescriptor<NetworkEntry>(
            sortBy: [SortDescriptor(\.startedAt)]
        )
    )

    for try await update in controller.updates() {
        apply(update)
    }
}

func configureCell(for id: NetworkEntry.ID) {
    guard let entry = context.model(for: id) else {
        preconditionFailure("A current fetched-results ID must resolve.")
    }
    cell.bind(to: entry)
}
```

The list data source stores `NetworkEntry.ID`. Detail stores the same ID and
resolves `entry.requestIDs` to `NetworkRequest` instances through the same
context.

### Non-main actor consumer

```swift
actor NetworkRecorder {
    private var context: WebInspectorModelContext?

    func start(container: WebInspectorModelContainer) async throws {
        let context = try await container.makeContext(
            isolation: self
        )
        self.context = context

        let descriptor = WebInspectorFetchDescriptor<NetworkRequest>()
        let ids = try await context.fetchIdentifiers(descriptor)
        consume(ids)
    }

    func close() async {
        await context?.close()
        context = nil
    }
}
```

This consumer never touches UIKit and never receives the main context's model
objects.

## Network semantic entry

`NetworkEntry` is a record-backed persistent model representing one logical
row. It is not a fetched-results section or UIKit wrapper.

```swift
@Observable
public final class NetworkEntry: WebInspectorPersistentModel {
    public struct ID: WebInspectorPersistentIdentifier { ... }

    public struct QueryValue: Identifiable, Sendable {
        public let id: ID
        public let startedAt: Double
        public let resourceCategories:
            Set<NetworkRequest.ResourceCategory>
        public let searchText: String
    }

    public let id: ID
    public private(set) var requestIDs: [NetworkRequest.ID]
}
```

The Network reducer owns entry membership and chronology. Redirect hops that
WebKit reports under one request remain content of that request. Related media
or initiator requests become multiple request IDs in one entry. Filters match
entry query values; they do not mutate membership.

Adding or updating a member updates the existing `NetworkEntry` instance in
place in every context where it has been materialized.

## Data flow and execution

```text
WKWebView operations (@MainActor only)
  -> WebInspectorProxy actor
  -> one ConnectionModelFeed
  -> container detached feed driver
  -> canonical record-store actor
       - decode/reduce domain record changes
       - assign domain-scoped stable IDs
       - advance revision
       - publish context snapshot/delta/reset
  -> context detached subscription driver
  -> context-core actor
       - update synchronized record cache
       - evaluate Predicate<QueryValue>
       - sort/section/window
       - build membership/order differences
  -> context owner actor
       - update only materialized model instances
       - commit FRC ID state
       - notify Observation/UI
```

The context core mirrors the set of materialized IDs. A source transaction
only sends record payloads for those IDs back to the owner actor. Unmaterialized
records remain in the synchronized record cache and query indexes.

`model(for:)` performs one synchronized record lookup and materializes at most
one object on the context owner. It does not scan or sort a collection.

## Lifecycle and streams

| Resource | Acquire | Retaining owner | Close authority | Completion |
| --- | --- | --- | --- | --- |
| Native attachment | container async init | ProxyKit core | container core | `container.close()` awaits native detach |
| Model feed | container core start | container core | container core | feed terminal plus driver Task value |
| Canonical store | container core start | container core | container core | publication broker terminal |
| Context subscription | context init | context core | context | subscription driver Task value |
| Query registration | FRC creation | FRC + context core | FRC/context | unregister acknowledgement |
| Update subscriber | `updates()` | subscriber sequence | iterator/subscriber | mailbox terminal |
| Media player | Network Detail | Detail controller | Detail controller | player teardown on rebind/dismiss |

Container close is idempotent and terminal:

1. reject new contexts and commands;
2. stop/close the model feed and ProxyKit connection;
3. terminate context publication;
4. cancel and await the feed driver;
5. await native detach;
6. enter closed state.

Context close unregisters only that context, terminates its FRCs, cancels and
awaits its driver, invalidates its model registry, and leaves the container and
other contexts running.

Cancellation is a stop signal. Neither container nor context reports closed
until the relevant Tasks and underlying resource completion have been awaited.
`deinit` may synchronously cancel tokens/Tasks as a backstop, but never owns
async close completion.

## Variation axes and absorption points

| Axis | Absorption point | Variant-addition test |
| --- | --- | --- |
| Persistent model type | one `WebInspectorModelSchema<Model>` registration | Add the model/schema file and one registry entry; generic context/FRC code is unchanged. |
| Context-local resource type | its semantic parent (`RuntimeObjectGroup`, Console, or `DOMNode`) | Adding a resource does not edit persistent schema/query code. |
| Protocol domain reduction | domain reducer registry in canonical store | Add one reducer and one registration; container lifecycle is unchanged. |
| Query predicate | `Predicate<Model.QueryValue>` | New predicates require no framework code. |
| Query sorting | `SortDescriptor<Model.QueryValue>` | New sort key paths require no query-engine branch. |
| Optional sectioning | `Expression<Model.QueryValue, SectionName>` | New section expressions require no FRC branch. |
| Live/preview/test source | ProxyKit connection/test peer seam | All modes traverse container -> context -> FRC. |
| UIKit/AppKit | UI target boundary | AppKit can consume DataKit without changing DataKit. |
| Network grouping rule | Network entry reducer | Change grouping without editing generic query/FRC/UI navigation owners. |

## Public-surface plan

New public declarations justified by the consumer code above:

- `WebInspectorModelContainer` and `Configuration` — attach, share, close.
- `WebInspectorModelContext` — container-vended isolated identity graph that
  resolves IDs, fetches, observes, and closes independently.
- `WebInspectorPersistentIdentifier` — type-safe ID-to-model association.
- `WebInspectorPersistentModel.QueryValue` — Sendable query boundary.
- `WebInspectorFetchDescriptor` — generic query value.
- `WebInspectorFetchedResultsController` — query lifecycle and current state.
- Snapshot, update, change, and update-sequence values — UIKit/custom consumer
  application of initial/delta/reset.
- `NetworkEntry` — the semantic Network list item.

Foundation `Predicate`, `Expression`, `SortDescriptor`, and `SortOrder` remain
Foundation contracts; DataKit does not wrap them.

Existing public declarations will be inventoried after migration. A declaration
that cannot be reached from the built-in consumer, custom DataKit consumer, or
direct ProxyKit consumer is lowered to `package`/`internal` or deleted.

## Deletion and consolidation list

| Delete or consolidate | Finding | Replacement owner |
| --- | --- | --- |
| Context-owned Proxy/feed attach state | F1, F2, F11 | model container core |
| `WebInspectorFetchedResults` | F3, F4, F7 | stateful generic FRC |
| `ConcreteQuery` | F3 | generic descriptor/query value |
| Public `NetworkQuery` / `ConsoleQuery` as primary APIs | F3 | descriptor conveniences only, if still useful |
| Network/Console registration state in domain stores | F4 | generic context query core |
| Per-context Console ordinal generation | F5 | canonical container store |
| Unscoped raw model IDs | F5 | scoped persistent IDs |
| `RuntimeObject` / `CSSStyles` persistent-model conformance | F5, F6 | explicit context-resource ownership |
| Separator-decoded target scope | F13, F14 | navigation/DOM-aware structured feed event scope |
| Raw-ID replacement after terminal state | F15 | reducer protocol-violation failure |
| Eager all-model mutation on owner actor | F6 | record cache plus materialized-ID updates |
| Full old/new snapshot in every transaction | F7 | initial/delta/reset stream |
| Network groups encoded as FRC sections | F8, F12 | `NetworkEntry` model |
| UI group/selection wrapper state | F10, F12 | `NetworkEntry.ID` selection |
| Superseded DataKit decisions in old docs | F9 | this document |

No item above remains as a parallel compatibility path after its replacement is
integrated.

## Avoided shapes

- Do not add a `WebInspectorModelContainer` wrapper that forwards all state to
  the current exclusive `WebInspectorModelContext`. Proxy/feed ownership must
  physically move.
- Do not share one `NetworkRequest`, `DOMNode`, or other Observable instance
  between contexts.
- Do not create detached shadow instances of public persistent-model classes to
  evaluate predicates. Queries evaluate `QueryValue` records.
- Do not retain `NetworkQuery`/`ConsoleQuery` inside a generic FRC.
- Do not add per-domain subclasses or duplicated query-registration state.
- Do not expose a public free-standing model-context initializer; context
  registration and initial state belong to the container factory transaction.
- Do not put protocol-domain event switches or physical command authority in
  `WebInspectorModelContext`; canonical reducers and the container command
  gateway own them.
- Do not publish two stream elements and call them an atomic reset.
- Do not use an unbounded subscriber buffer.
- Do not synthesize an empty/fault model for a foreign or stale ID.
- Do not register `RuntimeObject` or `CSSStyles` in the persistent identity
  registry merely to reuse generic APIs.
- Do not fall back to MainActor predicate/sort/diff work.
- Do not represent one Network row as a fetched-results section.
- Do not add preview/test branches to production model or UI logic; use the
  existing production-path testing products.
- Do not treat Task cancellation or `deinit` as close completion.

## Test plan

### Container/context contracts

- One container creates contexts owned by MainActor and a custom actor.
- `mainContext` is stable, custom contexts compare by context identity, and a
  closed container rejects new context creation.
- One source event reaches both contexts with equal IDs and distinct model
  object identities.
- Repeated same-context lookup returns the identical object.
- Closing one context leaves the other context and Proxy connection active.
- Closing the container terminates all context and FRC sequences and awaits all
  owned Tasks.
- A late context receives an atomic current snapshot before later deltas.
- A slow context receives reset rather than a discontinuous delta.
- DOM/CSS deltas preceding their per-target bootstrap boundary are suppressed;
  the first delivered delta is ordered after the authoritative snapshot.
- Network/Console/Runtime replay events remain ordered before their replay
  completion marker and are not overwritten by later bootstrap state.
- A loader navigation advances that target's navigation epoch without
  surfacing transient context failure; physical current-page replacement
  advances page generation.

### Identity and materialization contracts

- IDs cannot alias across the domain-specific container, target, generation,
  DOM-binding epoch, raw-ID, or canonical-ordinal scopes defined above.
- A Network-only container advances navigation scope without enabling or
  constructing DOM. Its initiator node key is opaque and cannot resolve as a
  `DOMNode`.
- When DOM is configured, a Network initiator node resolves only against the
  exact DOM-binding epoch carried by that event.
- Same-scope terminal Network ID reuse and Runtime-context ID reuse fail fast;
  redirect continuation remains valid.
- Foreign/stale IDs return `nil` from `model(for:)`.
- `registeredModel(for:)` does not materialize.
- `model(for:)` materializes once and applies later record changes in place.
- Deleted/reset models are rejected by command ownership checks.
- Unmaterialized record updates do not mutate the context owner actor.
- Runtime objects and loaded CSS styles are absent from generic fetch and
  `model(for:)` at compile time.

### Generic query/FRC contracts

- The same generic registration path is exercised by Network, Console, and one
  additional model domain.
- Initial registration is atomic with source changes at the registration
  boundary.
- Insert, delete, move, stable-position content update, section insert/delete,
  offset, and limit are correct.
- Descriptor replacement is atomic; cancelled or superseded candidates never
  publish.
- Predicate failure terminates only that registration.
- A fast subscriber receives contiguous deltas without full snapshots.
- A slow subscriber receives exactly one latest reset.
- Closing FRC unregisters immediately and terminates subscribers.

### Network/UI contracts

- A redirect chain is one request with redirect content.
- Related media/initiator requests form one stable `NetworkEntry`.
- The Network diffable list has one item per entry and one UIKit section.
- Detail displays all request members in chronological order.
- The player controller is present from initial Detail rendering when preview
  is available.
- Popping compact Detail does not repush it during transition completion.
- Page back/forward does not present a spurious network-unavailable error.

### Performance/isolation contracts

- A 10,000-record source update performs filter/sort/diff outside MainActor.
- A content-only update visits the changed record and active registrations,
  not the full collection.
- MainActor work is proportional to materialized changed models and applied UI
  IDs, not total records.
- Compiler/SIL probes verify the selected `#isolation`,
  `nonisolated(nonsending)`, unavailable Sendable conformance, and container
  Sendable surface.

### Validation

```sh
xcodebuild test \
  -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKit \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

The external `ContractTests` package must also build, link, and run against the
public product without `@testable` imports.

### Compiler proof at the design gate

A standalone provider/consumer probe was compiled with the installed Swift
6.3.3 toolchain using `-swift-version 6`,
`-strict-concurrency=complete`, and `-default-isolation nonisolated`.

The positive probe established that the following declarations compose in one
public surface:

- an ID protocol whose associated model points back to `Model.ID`;
- a persistent model with an associated Sendable `QueryValue`;
- `Predicate<Model.QueryValue>`, `SortDescriptor<Model.QueryValue>`, and
  `Expression<Model.QueryValue, SectionName>`;
- `WebInspectorFetchedResultsController<Model, Never>`;
- a Sendable container with a `@MainActor` context property;
- an `Equatable & SendableMetatype` context with unavailable `Sendable`;
- a container factory returning a non-Sendable context into its isolated
  caller parameter;
- `nonisolated(nonsending)` generic fetch/controller methods.

SIL generation reports the fetch methods as
`caller_isolation_inheriting` and includes their hop back to the implicit
caller actor. A separate consumer-module negative probe passes the context to
a generic `T: Sendable` function and fails with the intended unavailable
conformance diagnostic. Repository integration and runtime ownership still
require the implementation-phase tests listed above.

## Findings-to-design mapping

| Finding | Design owner / acceptance evidence |
| --- | --- |
| F1 | Container owns Proxy/feed; context close test. |
| F2 | Container publication broker; two-context test. |
| F3 | Generic descriptor/FRC; Network/Console domain-reference recount. |
| F4 | One context query core; domain-store registration code deleted. |
| F5 | Scoped persistent IDs; cross-context/cross-generation tests. |
| F6 | QueryValue record cache and materialized-ID commit; MainActor counters. |
| F7 | Delta/reset mailbox; slow-consumer tests. |
| F8 | `NetworkEntry`; one-item-per-entry UIKit test. |
| F9 | Old docs marked superseded; this document is canonical. |
| F10 | Selection owner stores entry ID; transition test. |
| F11 | Page generation belongs to container store; navigation failure test. |
| F12 | Detail resolves entry/request IDs; preview tests. |
| F13 | Structured navigation plus optional DOM-binding epochs; Network-only Page observation and opaque-initiator tests. |
| F14 | No persistent-ID parser for target-prefixed raw strings; structured-scope tests. |
| F15 | Reducer duplicate-ID invariant and redirect exception tests. |
| F16 | Domain reducers/schema registry and command gateway; no domain-event switch in the context type. |

## Migration and commit plan

Each step leaves the branch buildable and deletes replaced responsibility in
the same change series.

1. **Design and identity foundation** — establish this contract, typed
   persistent identifiers, and immutable query values.
2. **Publication foundation** — add the bounded atomic initial/delta/reset
   primitive shared by container subscriptions and fetched results.
3. **Structured Proxy scope** — add navigation and optional DOM-binding epochs
   to the model feed while temporarily preserving the existing raw-ID
   projection for the still-unmigrated DataKit consumer.
4. **Canonical domain reducers** — separate Network, Console/Runtime, then
   DOM/CSS Sendable records from context-local Observable projections. Migrate
   each domain to structured IDs and remove its dependency on projected raw-ID
   prefixes in the same step.
5. **Container ownership** — introduce the container/core, physically move the
   single Proxy/feed lifecycle and canonical reducers out of the context, and
   restore multiple contexts. Remove context attach/detach in this step.
6. **Context materialization and generic query controller** — add context-local
   identity registries and record caches; replace domain query registrations
   and `WebInspectorFetchedResults` with the generic descriptor/FRC flow.
7. **Network semantic entry** — replace section-as-row grouping with
   `NetworkEntry` and migrate list/detail selection.
8. **Preview/navigation** — finish native preview binding and compact-pop
   convergence on the new stable-ID flow.
9. **Deletion, surface audit, and validation** — remove projected model-feed
   raw IDs and old paths, lower unused public API, update docs, and run full
   Xcode, external contract, isolation, performance, and Codex review gates.

## Acceptance measurements

- `WebInspectorModelContext` no longer owns Proxy/feed/attachment tasks.
- `WebInspectorModelContext` has no protocol-domain reducer switch or physical
  command authority.
- At least two contexts can share one container in production-path tests.
- No generic fetched-results implementation references `NetworkQuery`,
  `ConsoleQuery`, `NetworkRequest`, or `ConsoleMessage`.
- Network and Console stores no longer own query registrations.
- Every public persistent model ID is scoped and maps back to its model type.
- RuntimeObject and CSSStyles are context resources, not persistent/queryable
  models.
- No full collection filter/sort/diff runs on MainActor.
- Normal FRC updates after initial contain no full snapshot.
- Network UIKit rows use `NetworkEntry.ID`, not section IDs.
- Old exclusive-context and section-row paths are deleted.
- Public declarations match the consumer stories and external product fixture.
- Full validation and Codex review are clean.

## Design gate approval

The user approved this owner model, stable-ID/context-local-model contract,
generic query boundary, and implementation autonomy on 2026-07-12. Any later
change to these public ownership or lifecycle contracts requires updating this
document before implementation; local implementation details within the stated
owners do not require another gate.
