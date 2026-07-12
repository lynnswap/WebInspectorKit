# WebInspector model container and context architecture

- Status: approved design gate (2026-07-12)
- Scope amendment: navigation and DOM-binding epochs separated (2026-07-12)
- Lifecycle amendment: stable container owns attach/detach/reattach (2026-07-12)
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
  -> zero or one adopted ProxyKit connection/feed and one canonical Sendable record store
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

1. One inspection session has one stable model container, at most one adopted
   ProxyKit model feed, and multiple model contexts that independently consume
   the same canonical page state. The container, contexts, and fetched-results
   controllers survive nonterminal detach/reattach transitions.
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
- The built-in UIKit contract that keeps one context and its controllers stable
  across attach/detach/reattach remains supported. Persistent model identities
  from an old attachment do not survive that transition.
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

`F17` — `NetworkRequestStore` combines protocol reduction, canonical request
state, Observable projection, query registration, and command routing. It also
reconstructs query records from mutable Observable models. No single owner can
therefore prove request lifecycle invariants before context-local projection.

`F18` — Supplying and retaining a new full canonical snapshot on every
revision makes copy-on-write cost depend on every slow subscriber. In
particular, retaining an old request dictionary or WebSocket-frame array can
turn otherwise local updates into repeated whole-collection copies.

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
- SwiftData `ResultsObserver` additionally offers `modelContainer:`
  convenience initializers. Each creates a new context from that container and
  exposes it through the observer's `modelContext` property.
- SwiftData exposes identifier-only fetch and context-local
  `model(for:)`/`registeredModel(for:)` operations.

WebInspectorDataKit adopts the context identity, context-local object graph,
identifier-only query, and context-bound results-controller shapes. It is
stricter about context creation: the model container is the only public
factory. Unlike a database coordinator, the container owns an exclusive live
ProxyKit model feed while attached; registration, replacement, detach, and
close must be awaited. A public free-standing context initializer would either
obscure that connection lifecycle and close authority or permit a second
consumer of the single-consumer feed. Contexts therefore come only from
`mainContext`, `makeContext(isolation:)`, or a fetched-results controller that
explicitly asks that same container to create and own its child context.

The container is constructed before native attachment, like a persistent-stack
owner that exists before a store is loaded. This deliberate live-session
difference lets UIKit construct one stable main context and its controllers,
then attach, detach, and reattach the transport without replacing those UI
owners.

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
| Inspection-session attach/detach/reattach | `WebInspectorModelContainer` / its Core actor | The stable container owns every adopted or pending Proxy and feed replacement; only native WKWebView operations are `@MainActor`. |
| Physical targets, replies, capabilities | ProxyKit connection core | One source of transport truth. |
| Structured model-event scope | ProxyKit model feed | Generation, best-available semantic target, protocol-agent target, navigation epoch, and optional exact DOM-, Runtime-, and Console-binding epochs travel separately from raw IDs. |
| Persistent-model and context-resource command admission | `WebInspectorModelContainerCore` command gateway plus ProxyKit connection core | The Core atomically claims owner-valid operations before suspension; ProxyKit revalidates transport-visible binding authority at actual wire admission. |
| Model-feed iteration and final Proxy close | `WebInspectorModelContainerCore` actor | Exactly one feed consumer and close authority. |
| Context creation and registration | `WebInspectorModelContainer` | `mainContext`, `makeContext(isolation:)`, and the FRC container convenience all use the same factory transaction; there is no standalone context initializer. |
| Canonical current records and revision | `WebInspectorModelContainerCore` actor | Owns one pure-value `WebInspectorCanonicalModelStore`; no Observable models. |
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

`WebInspectorModelContainerCore` is the single cross-domain canonical actor.
There is no additional Network/Console/DOM store actor and no second canonical
actor behind it. The core owns a pure Sendable value store composed from domain
reducers, so page reset, target scope, and cross-domain references commit in
one order. A separate actor would add hops and close coordination without
creating parallelism because the Proxy model feed is already totally ordered.
Context query actors remain separate because filtering, sorting, and diffing
are context-local work and can run independently of feed reduction.

## Persistent entities and context resources

`WebInspectorPersistentModel` is reserved for canonical entities represented in
the container store and resolvable by stable ID in every context of that
container. Initially these are `DOMNode`, `NetworkRequest`, `ConsoleMessage`,
and `RuntimeContext`; `NetworkEntry` joins them during the Network migration.

`RuntimeObject` and `CSSStyles` are context-local resources instead:

- `RuntimeObject` is retained by a `RuntimeObjectGroup` or a Console message and
  represents a remote handle whose command lifetime belongs to that context.
  Its resource owner captures the attachment, page generation, Runtime-agent
  target, semantic navigation epoch, ProxyKit-issued Runtime-binding epoch, and
  a command-gateway resource lease. The binding epoch advances on any observed
  navigation that can discard a context owned by that agent and on agent-wide
  execution-context clear; target/page changes establish a new binding. A
  group bound to a `RuntimeContext.ID` also validates that the context is still
  canonical before every command. A Console-owned object additionally captures
  ProxyKit's Console-agent binding epoch and validates its owning
  `ConsoleMessage.ID`; `Console.messagesCleared` advances only that Console
  epoch, so it invalidates Console resources without releasing unrelated
  evaluation groups. Runtime resources never reconstruct command authority
  from an execution-context or object ID.
- `CSSStyles` is loaded on demand by one context and its loading/failure/refresh
  phase belongs to the owning `DOMNode`.

Those resource types remain Observable, identifiable reference types where
their consumers require it, but do not conform to
`WebInspectorPersistentModel`, do not expose `QueryValue`, and are not accepted
by generic fetch or `model(for:)`.

Runtime-resource validation is not a preflight followed by an unprotected
`await`. The existing `WebInspectorModelContainerCore` actor's command gateway
validates the resource lease and atomically claims a tokenized command
operation in one actor turn before its first suspension; it is not a second
state actor. Navigation/clear/target invalidation, Console-owner deletion, and
explicit object-group release are serialized through that same Core.
An operation ordered before invalidation may reach transport as the earlier
admission, but its completion remains subject to the owner check below; a later
operation is rejected. Object-group release first invalidates the group token
and then waits for already claimed operations before sending or completing the
backend release.

The claimed operation also carries transport-visible feed, page, agent-target,
semantic-navigation, and Runtime-binding authority in ProxyKit's model-command
authorization, plus Console-binding authority when the object is Console-owned.
The ProxyKit connection core validates that authorization at actual command
admission, closing the gap between the gateway claim and wire dispatch. On
reply, the gateway consumes the operation token and revalidates its owner
before exposing or materializing a result; an invalidated completion is
reported as stale and cannot repopulate context resources.

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
- container-assigned attachment generation;
- ProxyKit page generation;
- physical protocol-agent target where the WebKit ID is allocated;
- semantic target where frame/document content belongs when it differs from
  that agent target;
- exact DOM-binding epoch for DOM/CSS identities;
- the domain's canonical raw identity or canonical container-assigned ordinal.

The concrete persistent identities are scoped as follows:

| Model | Identity scope after container/store ID |
| --- | --- |
| `DOMNode` | attachment generation, Proxy page generation, semantic document target, protocol-agent target, exact DOM-binding epoch, raw node ID |
| `NetworkRequest` | attachment generation, Proxy page generation, protocol-agent target, raw request ID |
| `ConsoleMessage` | attachment generation, canonical container-assigned message ordinal |
| `RuntimeContext` | attachment generation, Proxy page generation, Runtime-agent target, raw execution-context ID |
| `NetworkEntry` | attachment generation, canonical container-assigned entry ID |

ProxyKit supplies a structured model-event scope instead of encoding target
scope into raw IDs:

```swift
package struct ModelEventScope: Sendable {
    let generation: WebInspectorPage.Generation
    // The best semantic target carried by the event. Agent-wide or ID-only
    // events use agentTarget and let the reducer resolve prior membership.
    let target: ModelTarget
    // The physical agent that allocated raw IDs and accepts commands.
    let agentTarget: ModelTarget
    let navigationEpoch: ModelNavigationEpoch
    let domBindingEpoch: ModelDOMBindingEpoch?
    let runtimeBindingEpoch: ModelRuntimeBindingEpoch?
    let consoleBindingEpoch: ModelConsoleBindingEpoch?
}
```

`target` and `agentTarget` are intentionally distinct. For example,
`Runtime.executionContextCreated` can resolve its frame to one semantic target
while the Runtime agent that allocated the context ID is the root page target.
Destroy/clear events do not carry enough frame information to reconstruct that
relationship later. ProxyKit therefore resolves the physical owner as
`sourceTargetID ?? targetID ?? currentMainPageTargetID` before registry
mutation and requires it to be a live model target before publishing. Root
current-page events use that actual physical main-page target, not the direct
API's prefix-omitting compatibility representation. Runtime identity and
command routing use `agentTarget`; frame membership and navigation invalidation
use `target` when the event carries that semantic information. Runtime
destroy/clear events are ID-only or agent-wide, so their `target` is the agent
target and the reducer resolves prior semantic membership from its canonical
agent-target/raw-ID index. A Console message's `networkRequestId` is different:
the protocol carries only the raw cross-domain reference and does not identify
the allocating Network agent. The Console reducer therefore retains that raw
reference, and the canonical Network owner resolves it through its
attachment/page-wide raw-request index to the already scoped request ID. It
never substitutes the Console event's `agentTarget`. A duplicate raw request
ID in two live Network-agent scopes within one attachment/page violates that
cross-domain protocol invariant and fails at the Network index owner. DataKit
never infers either event target from a projected raw ID or from a later event.

For `Network.requestWillBeSent`, the semantic request origin comes from the raw
protocol `targetId` when present, otherwise from its `frameId` mapping, and only
then from the event's best-available target. Later response/data/terminal
events retain that stored membership by the agent-target/request-ID index;
they do not overwrite it with a less specific event target. This matches
WebKit's protocol definition of `targetId` as the context where the load
originated while keeping response-body commands routed to the allocating
Network agent.

`ModelEventScope.generation` is the generation of one Proxy connection. A new
Proxy may reuse the same raw value. On every attach attempt, the Container Core
therefore reserves a monotonically increasing attachment generation and never
reuses it, including after failure or supersession. The canonical scope combines
that attachment generation with ProxyKit's event scope before constructing a
persistent ID. Detach clears membership, while a later attach necessarily
creates identities in a different attachment scope.

ProxyKit maintains the navigation epoch from its Page observation lease for
every configured model feed. A new loader advances the epoch for the affected
target. ProxyKit maintains the exact DOM-binding epoch from
`DOM.documentUpdated` only while DOM delivery is armed; DOM/CSS records require
that value. It does not issue a hidden `DOM.getDocument` merely to manufacture
a DOM epoch for Network, Console, or Runtime.

ProxyKit maintains one exact `ModelRuntimeBindingEpoch` per Runtime agent when
either Runtime or Console is configured. Console messages can carry Runtime
remote objects even when the public Runtime model domain is not requested, so
`.console` has this Runtime lifecycle observation as an operational transport
dependency; it does not implicitly expose persistent `RuntimeContext` models
or Runtime queries. Agent-wide execution-context clear and any frame
navigation that can discard an execution context owned by that agent advance
the epoch; target/page replacement establishes a new binding. This
conservative agent-wide advance also protects Console remote objects when
their event did not identify a finer semantic frame. Runtime events and Runtime
model-command authorization carry the value. This is transport command
authority, not persistent `RuntimeContext.ID` scope: WebKit's context counter
remains monotonic, while the binding epoch prevents a remote-object command
from crossing a context-destruction boundary.

While Console delivery is armed, ProxyKit similarly maintains one
`ModelConsoleBindingEpoch` per Console agent and advances it before publishing
`Console.messagesCleared`. Console message records and their remote-object
resources capture that exact value. Only Console-owned Runtime command
authorization carries it, so ConnectionCore can reject a command that races
behind backend Console-group release without invalidating independent Runtime
object groups.

This distinction follows WebKit's own agent contracts. `Page.frameNavigated`
reports that a frame is associated with a new loader. By contrast,
`InspectorDOMAgent::setDocument` and `FrameDOMAgent::setDocument` suppress
`DOM.documentUpdated` until `DOM.getDocument` has marked the document as
requested. Treating either signal as the other would invent state that the
producer did not publish.

The model feed establishes initial authority in this order:

```text
reset(generation)
-> target snapshot containing each target's current
   navigation/DOM/Runtime/Console scope
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
scope carries an exact DOM-binding epoch. That identity includes both the
semantic document target and the protocol agent that allocated the raw node
ID. Otherwise the Network reducer may use an internal opaque grouping key made
from generation, both targets, navigation epoch, and raw node ID, but it must
not manufacture a persistent DOM identity or pass that key to `model(for:)`.
`NetworkRequest.ID` independently uses the protocol-agent target. The canonical
store never decodes a target prefix from a raw protocol ID.

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
one generation and Runtime-agent target is still a protocol violation. A target
or page-generation change already produces a distinct `RuntimeContext.ID`.

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

### Network canonical reducer contract

The Network reducer owns request lifecycle semantics before any context sees a
projection. Its canonical record contains protocol fields, immutable logical
start time, current-hop time, redirect history, response metadata, transfer
metrics, WebSocket handshake/content, and a semantic response-body revision.
It contains no Observable object, loaded response body, Task, target handle,
Proxy reference, or query registration.

An initial request inserts a full record. A redirect appends the completed hop
and replaces the current hop under the same scoped request ID. A response-first
event may create a synthetic `GET` request only when the protocol supplies a
URL; otherwise an untracked response, data, or terminal event is an attach race
and is ignored. Memory-cache delivery creates a terminal record. A second live
non-redirect start for the same scoped ID is a protocol violation. A second
WebSocket creation is likewise invalid outside enable/replay; during replay,
only a semantically identical creation is the no-op exception described below.

`loadingFinished` normally makes the request terminal, and a duplicate finish
or fail is invalid. WebKit multipart resources are the deliberate exception:
they can publish later response/data content for the same
`ResourceLoaderIdentifier` after one finish. The reducer accepts that content
as multipart continuation, preserves the finished lifecycle, and advances the
response-body revision; it does not reinterpret it as ID reuse.

Clear keeps request tombstones until generation reset. Late events for a
tombstoned request are ignored, while a new live start for that identity still
fails. During the WebSocket enable/replay window, identical creation is a
no-op, conflicting creation fails, replay fills only missing handshake state,
and close replay preserves the original chronology. Frames and errors are live
append deltas rather than replay state.

The model-feed Console-to-Network reference migrates in the same change as the
Network ID. Console stores the protocol's raw `networkRequestId`; the canonical
Network reducer resolves it through its attachment/page-wide raw-ID index and
publishes the exact `NetworkRequest.ID`, including the allocating Network-agent
scope. A message that arrives before its request keeps an unresolved canonical
reference that the Network insert resolves in the same Core; no context-local
model guesses the route. This mirrors WebKit's session-wide
`NetworkManager._resourceRequestIdentifierMap` and never parses the old target
prefix. ProxyKit's direct typed APIs may keep their independent target-prefixed
compatibility projection.

The context strongly retains materialized active models until deletion,
generation reset, or context close. This makes same-context identity an actual
contract rather than a weak-cache accident.

## Public API sketch

The sketch is the intended source surface. Exact isolation spellings are
subject to the compiler proof described below, but the ownership contract is
not.

```swift
public final class WebInspectorModelContainer: Equatable, Sendable {
    public nonisolated static func == (
        lhs: WebInspectorModelContainer,
        rhs: WebInspectorModelContainer
    ) -> Bool

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

    public enum Failure: Error, Sendable {
        case closed
        case attachmentSuperseded
    }

    public nonisolated init(
        configuration: Configuration = .init()
    )

    @MainActor
    public var mainContext: WebInspectorModelContext { get }

    @MainActor
    public convenience init(
        attachingTo webView: WKWebView,
        configuration: Configuration = .init(),
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws

    @MainActor
    public func attach(
        to webView: WKWebView,
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws

    package func attach(
        owning proxy: WebInspectorProxy
    ) async throws

    public func makeContext(
        isolation: isolated (any Actor) = #isolation
    ) async throws -> WebInspectorModelContext

    public func detach() async
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

Container initialization is synchronous and nonisolated. It creates the
Sendable Core and installs the stable main-context registration seed in that
Core's initial empty state; it does not create Observable models or touch
UIKit. The `@MainActor` `mainContext` getter materializes and caches the one
actor-confined context wrapper on first access. This preserves stable identity
without making Container initialization or canonical work main-actor work. If
the getter is first accessed after terminal Container close, it materializes
the same seed as an already closed Context; it never creates a new
registration. If its bounded pre-materialization delivery lost continuity,
the first dequeue asks the Core for one owner-atomic current rebase.

Custom contexts may be created while detached or attached. The container
registers each custom context subscription atomically before returning it.
Creation after container close fails. A context retains the container core,
not the public container object; the public container's actor-isolated cache
retains `mainContext`, so this owner graph has no container/context reference
cycle. Custom contexts retain their own subscriptions and may close
independently.

One container is one reusable inspection session and owns at most one adopted
`WKWebView` attachment, plus any transient pending Proxy whose attempt it must
either adopt or close. Multiple contexts that observe the adopted attachment
use the same container and therefore share one canonical store and feed. Reattaching
the container preserves context/FRC identity but assigns a new attachment
generation, invalidating old persistent IDs. A separately created container is
a separate session with different store identity; its IDs and models never
alias. Container equality is reference/session identity (`===`), not equality
of its configuration, inspected view, or current records.

A context never accepts a `WKWebView`, Proxy, feed, or configuration. Calling
`makeContext(isolation:)` joins the stable container session and atomically
registers one projection subscription; it never creates another native
attachment or feed consumer. `detach()` clears canonical membership but keeps
contexts and FRC sequences alive. Closing the container invalidates every
context it vended, including externally retained context objects. Closing one
custom context only unregisters that child. This makes the container the
unambiguous owner when one inspected view is observed from multiple actors.

Context registration participates in the same Core lifecycle gate. A
`makeContext` ordered before a reset contributes an acknowledgement; one
requested during detach waits and receives the post-detach empty initial
state; one ordered after close fails. Within a context core, FRC registration
is likewise serialized with reset application, so a newly created controller
either acknowledges that reset or starts from its already committed result.

Public `attach(to:)` creates the native Proxy at the `WKWebView` MainActor
boundary only after the Container Core has reserved that attachment attempt,
then transfers ownership to non-main adoption. DataKitTesting uses the same
package ownership-transfer seam with an already connected test Proxy. Feed
bootstrap, canonical reduction, publication, detach, and close all continue in
the Container Core; test composition does not introduce a second lifecycle
implementation.

### Attachment transaction

The Container Core owns a single asynchronous lifecycle-operation chain.
Reservations may invalidate intent immediately, but adoption, detach, and
close side effects enter that chain in order rather than relying on actor
non-reentrancy. A public attach is one tokenized resource transaction:

1. Before native Proxy creation, the Core reserves a monotonically increasing
   attachment generation and registers a Sendable attachment-attempt object.
   That object owns the native-creation Task slot, candidate-Proxy close
   authority, and a quiescence completion. It remains tracked after
   supersession until creation has stopped and any candidate has been closed.
   Reservation invalidates and cancels every older pending attempt while
   retaining its quiescence obligation, and orders the request against
   detach/close while leaving the currently adopted attachment authoritative
   until a token-valid replacement reaches adoption.
2. The attempt installs its owned Task handle before opening a start gate and
   running only native Proxy creation on MainActor. A reservation made during
   detach receives no start permit until detach has completed. Cancellation or
   every path that does not reach adoption resolves the attempt only after
   native creation and candidate cleanup are quiescent.
3. Core adoption takes Proxy ownership at method entry and enqueues one
   lifecycle operation. The operation validates the attempt token before every
   side effect and again after every awaited reset, feed-acquisition, or
   teardown barrier before commit. For a still-current replacement it
   invalidates the old attachment, completes its canonical/context reset and
   Proxy teardown barrier, revalidates, and only then registers the new single
   model-feed consumer. If a newer reservation arrived during any await, the
   operation closes its candidate and exits as superseded without committing
   later stages. A closed, rejected, or bootstrap-failed adoption likewise
   closes and awaits the new Proxy before returning failure.
4. After bootstrap, one final token check and actor turn atomically promote the
   Proxy/feed and publish the new attachment's authoritative initial state.
   This is the attach linearization point. The operation then awaits the
   context-application acknowledgement barrier before the call returns; a
   newer reservation after promotion is a later operation and does not
   retroactively supersede this successful attach.

Every resource produced by an awaited stage remains provisional and
attempt-owned until the following token check promotes it in one actor turn.
If that check fails, the operation tears down the provisional feed/Proxy and
waits for its completion; it does not expose that resource as the current
attachment or publish its records.

A newer reservation makes every older still-pending attempt finish with
`WebInspectorModelContainer.Failure.attachmentSuperseded`; it can never commit
after the newer intent. An older transaction whose adoption and context
acknowledgements already committed remains a successful earlier linearization,
even if its caller resumes later. A native-creation failure completes only its
still-current reservation and leaves the previously adopted attachment
unchanged, or leaves the Container detached when none existed. Detach or close
invalidates all pending tokens, so a Proxy that finishes creation afterward is
closed rather than adopted. Cancellation before adoption likewise preserves
the previous attachment; cancellation after replacement teardown has begun
but before promotion closes the new Proxy and leaves the Container detached.
Those pre-commit cancellations return `CancellationError`, while a token
already invalidated by a newer intent reports `attachmentSuperseded`. After
the promotion linearization point, caller cancellation does not roll back the
adopted resource; the owned operation completes its context acknowledgement
barrier and returns success. Package `attach(owning:)` transfers close
authority at method entry and performs reservation plus adoption through the
same Core transaction. The Core retains superseded attempt records until their
quiescence completions resolve; removing the current token never drops the
cleanup obligation.

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

An empty `sortBy` preserves the canonical model order supplied by the schema.
When explicit descriptors compare equal, that same order is the implicit final
tiebreaker. The query core decorates records with their stable canonical rank;
it does not depend on sort stability or require every model ID to be
`Comparable`. Section names are evaluated after that stable ordering and
sections appear in first-occurrence order, matching SwiftData's
`ResultsObserver` collection semantics without restricting `SectionName` to
`String`.

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

    public convenience init(
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init(),
        modelContext: WebInspectorModelContext,
        isolation: isolated (any Actor) = #isolation
    ) async throws where SectionName == Never

    public convenience init(
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init(),
        modelContainer: WebInspectorModelContainer,
        isolation: isolated (any Actor) = #isolation
    ) async throws where SectionName == Never

    public init(
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy: Expression<Model.QueryValue, SectionName>,
        modelContext: WebInspectorModelContext,
        isolation: isolated (any Actor) = #isolation
    ) async throws

    public convenience init(
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init(),
        sectionBy: Expression<Model.QueryValue, SectionName>,
        modelContainer: WebInspectorModelContainer,
        isolation: isolated (any Actor) = #isolation
    ) async throws

    public nonisolated(nonsending) func update(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws

    public func updates()
        -> WebInspectorFetchedResultsUpdateSequence<Model.ID, SectionName>

    public nonisolated(nonsending) func close() async
}
```

The controller stores IDs and section names only. A UI resolves a visible or
selected ID with `modelContext`. The descriptor and that specific context
together define the registration. A caller that passes `modelContext` retains
context close authority; closing the controller unregisters only its query. A
caller that passes `modelContainer` explicitly asks the controller to create
and own one child context on `isolation`; closing that controller also closes
its child context. In both cases the public `modelContext` property makes model
identity and command ownership observable rather than hidden.

The built-in UIKit inspector passes the stable container `mainContext` so list,
selection, and Detail share one context-local identity graph. The container
convenience is the progressive-disclosure path for an independent observer.
Both shapes follow SwiftData `ResultsObserver`; the explicit-context shape also
matches Core Data `NSFetchedResultsController`. The context itself does not
grow a parallel controller-factory API.

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

Each subscriber has a custom synchronized capacity-one mailbox. If a
subscriber has not consumed its pending initial/change when a later revision
arrives, the mailbox atomically replaces the pending value with one internal
`resetRequired(latestRevision:)` marker. It does not build a snapshot during
publish and does not use two `AsyncStream.yield` calls as an atomic
replacement. The public `.reset` value is created only after the owner-atomic
rebase described below returns its snapshot.

The generic publication primitive does not retain or receive a newly copied
full snapshot on every revision. A normal publish stores and delivers only its
revision and typed delta. Its semantic snapshot owner depends on the edge where
the primitive is used:

| Publication edge | Atomic rebase owner | Snapshot captured with revision |
| --- | --- | --- |
| Container Core → context core | `WebInspectorModelContainerCore` | complete canonical record snapshot |
| context query core → FRC | that context query core | predicate/sort/section/window result plus its source cursor |

The canonical store remains the sole owner of current full records and
supplies a snapshot when it atomically registers a context. It never constructs
an FRC snapshot. A query core independently owns each registration's filtered
and ordered result, so only that query core can rebase a slow FRC subscriber.

If a subscriber already has a pending initial/change, its internal capacity-one
mailbox coalesces later publications into `resetRequired(latestRevision:)`
without a snapshot. Only when the consumer actually dequeues that marker does
it ask that publication edge's owner to rebase its opaque subscription token.
In one owner-actor turn, the owner captures its current revision, snapshot, and
where applicable query source cursor; it then rebases the subscriber to that
revision and returns the snapshot directly. The edge driver exposes the result
as `.initial` if it had not published one yet, or as `.reset` otherwise.
Publications ordered after that owner turn are contiguous with the returned
snapshot.

The two edges do not forward reset markers to one another. A slow FRC can lose
query-update continuity while its context continues to consume every canonical
delta; that FRC therefore rebases only in its query core. Conversely, a slow
context subscription rebases canonical records in the Container Core before
the context query core evaluates later query changes.

This on-demand rebase means a permanently slow subscriber causes no full
snapshot work merely because new events keep arriving. It also prevents a
retained old dictionary or WebSocket-frame array from forcing copy-on-write of
the entire canonical state on each event.

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
final class InspectorOwner {
    let container = WebInspectorModelContainer()

    func attach(to webView: WKWebView) async throws {
        try await container.attach(to: webView)
    }

    func detach() async {
        await container.detach()
    }

    func makeNetworkController() async throws
        -> WebInspectorFetchedResultsController<NetworkEntry, Never>
    {
        let context = container.mainContext
        return try await WebInspectorFetchedResultsController<
            NetworkEntry,
            Never
        >(
            fetchDescriptor: WebInspectorFetchDescriptor<NetworkEntry>(
                sortBy: [SortDescriptor(\.startedAt)]
            ),
            modelContext: context,
            isolation: MainActor.shared
        )
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
        public let searchTexts: [String]
    }

    public let id: ID
    public private(set) var requestIDs: [NetworkRequest.ID]
}
```

The Network reducer owns entry membership and chronology. Redirect hops that
WebKit reports under one request remain content of that request. Related media
or initiator requests become multiple request IDs in one entry. `searchTexts`
stays aligned with those members, so a filter can use `contains(where:)` and
does not rebuild one ever-growing concatenated String on every segment
response. Filters match entry query values; they do not mutate membership.

Adding or updating a member updates the existing `NetworkEntry` instance in
place in every context where it has been materialized.

This follows WebInspectorUI's incremental shape: resources are updated in
place, DOM-node groups use sorted insertion, pending insert/update work is
batched before layout, and query text is cached per resource. The canonical
store likewise updates entry counters and member-local query values
incrementally; normal transfer/frame updates never rescan or resort a group.

## Data flow and execution

```text
WKWebView operations (@MainActor only)
  -> WebInspectorProxy actor
  -> one ConnectionModelFeed
  -> container detached feed driver
  -> WebInspectorModelContainerCore actor
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

Canonical transactions are complete deltas rather than full-store snapshots.
An insert carries the full new record, a delete carries its stable ID, and an
update carries an authoritative typed patch. Append-only content such as a
WebSocket frame is an append patch; replacement metadata and terminal state are
replacement values. `QueryValue` is included only when a query-visible value
changed. Initial and reset publications alone carry a complete record snapshot.
Context projections apply patches mechanically and make no second semantic
decision.

`model(for:)` performs one synchronized record lookup and materializes at most
one object on the context owner. It does not scan or sort a collection.

## Lifecycle and streams

| Resource | Acquire | Retaining owner | Close authority | Completion |
| --- | --- | --- | --- | --- |
| Container session | container init | public container + core | container | terminal `close()` |
| Attachment attempt | Core reservation before native creation | container core, including after token invalidation | attempt/container core | native Task stopped and candidate adopted or close awaited |
| Native creation Task | attachment-attempt start gate | attachment attempt | attempt/container core | Task plus candidate cleanup quiescence |
| Pending native Proxy | successful native creation / package ownership transfer | attachment attempt, then Core at adoption entry | attempt/container core | adopted or close awaited on every failure path |
| Lifecycle operation | adoption, detach, or close enqueue | container core async operation chain | container core | prior operation and all stage acknowledgements complete |
| Native attachment | successful token-validated adoption | ProxyKit core | container core | `detach()` or `close()` awaits native detach |
| Model feed | successful attach | container core | container core | feed terminal plus driver Task value |
| Canonical store | container init | container core | container core | detach reset or close terminal |
| Context subscription | main seed at container init; custom context factory | context core | context/container | subscription driver Task value |
| Context reset acknowledgement | canonical reset/terminal | container core until each obligation completes | context apply or unregister | detach/attach/close barrier |
| Query registration | FRC creation | FRC + context core | FRC/context | unregister acknowledgement; a container-created child context closes with its FRC |
| Update subscriber | `updates()` | subscriber sequence | iterator/subscriber | mailbox terminal |
| Runtime command operation | command-gateway lease claim | container gateway + ProxyKit command task | gateway invalidation or reply | transport admission/reply and stale-result validation complete |
| Runtime object group | context resource creation | owning context model/resource | owning context or explicit release | token invalidated, admitted commands quiesced, backend release completed |
| Media player | Network Detail | Detail controller | Detail controller | player teardown on rebind/dismiss |

Container detach is idempotent and nonterminal:

1. capture and invalidate the active attachment token and every nonquiescent
   current or retired attempt that exists at the detach linearization point,
   then cancel their owned native-creation Tasks without dropping their tracked
   quiescence obligations;
2. enqueue detach after the prior lifecycle operation, then reject old
   feed/command/adoption completions and atomically reset the canonical store
   to empty;
3. publish that reset with one acknowledgement obligation for every currently
   registered context;
4. each materialized context applies the reset through its context core and
   owner actor, removes the old registry membership, marks old models stale,
   and commits every FRC snapshot to empty without terminating its update
   sequence. Closing/unregistering the context satisfies its obligation; an
   unmaterialized main-context seed advances its stored base revision and
   acknowledges without creating an Observable wrapper;
5. stop/close the model feed and ProxyKit connection, then await the feed
   driver/native detach, every context acknowledgement, and every attachment
   attempt captured at step 1's creation/cleanup quiescence;
6. only after all barriers complete, enter detached state and return.

Consequently, after `await container.detach()` returns, synchronous
`model(for:)`/`registeredModel(for:)` lookup cannot resolve an old ID and every
retained FRC's current snapshot is empty. A subscriber may not yet have pulled
its reset sequence element, but the controller state that element describes is
already committed. An attach requested during detach may reserve newer intent,
but its attempt start gate remains closed until this detach and every stale
native-creation cleanup obligation have passed the lifecycle barrier. The Core
then grants native-creation permission only to the newest still-valid queued
attempt; superseded queued attempts complete without creating a Proxy.

Container close is idempotent and terminal:

1. invalidate active and pending attachment tokens, and reject new attach
   operations, contexts, and commands; cancel but retain every tracked attempt;
2. enqueue close after the prior lifecycle operation and stop/close the model
   feed and ProxyKit connection;
3. terminate context publication with one close acknowledgement per registered
   context;
4. invalidate each context registry, terminate its FRCs, and satisfy the
   acknowledgement by completing or unregistering that context;
5. cancel and await the feed driver, every context driver/acknowledgement,
   native detach, and every attachment-attempt creation/cleanup completion;
6. enter closed state only after all barriers complete.

Context close unregisters only that context, terminates and awaits its FRC
unregistration acknowledgements, cancels and awaits its driver, invalidates
its model registry, and leaves the container and other contexts running.

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
- `WebInspectorFetchedResultsController` — query lifecycle and current state,
  with explicit-context and container-created-context initializers.
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

- A Container can be constructed off MainActor without touching a native
  `WKWebView`, Observable model, or UI owner.
- One container creates contexts owned by MainActor and a custom actor.
- `mainContext` is stable, custom contexts compare by context identity, and a
  closed container rejects new context creation.
- First `mainContext` access after Container close returns the closed stable
  registration and does not create a live child.
- An FRC initialized with a container owns and exposes one child context; an
  FRC initialized with an existing context never closes that context.
- Contexts may be created while detached and receive the next attachment's
  initial state through the same registration.
- Detach empties results with reset but does not terminate the same contexts,
  FRC objects, controllers, or update sequences; immediately after detach
  returns, registry lookup is stale and every current FRC snapshot is empty.
- Two concurrent attaches reserve distinct generations; only the newer intent
  may adopt if the older transaction is still pending, that older waiter
  receives `attachmentSuperseded`, and every non-adopted native Proxy is closed
  and awaited exactly once.
- Superseding an adoption while it awaits old reset/teardown makes its
  post-await token check close the candidate; it cannot register a feed or
  publish after the newer intent.
- Detach/close during native creation invalidates that attempt and closes its
  eventual Proxy; cancellation of the current attempt does the same before
  returning `CancellationError`.
- Cancellation after promotion does not roll back the adopted Proxy; the attach
  operation finishes its Context/FRC acknowledgements and reports the already
  committed success.
- Detach/close do not return while a captured native-creation Task is gated or
  delayed; they await its cancellation/completion and candidate cleanup. A new
  attach requested during detach cannot begin native creation until that
  barrier completes.
- Native creation failure preserves the previously adopted attachment (or the
  detached state when none existed). Feed-claim/bootstrap failure after valid
  adoption teardown leaves the Container detached. Neither path leaks a
  pending Proxy or model-feed consumer.
- Successful attach returns only after every registered Context/FRC has
  acknowledged the new authoritative initial state.
- Reattach preserves those owner identities while old model IDs resolve to
  `nil` and new IDs include a distinct attachment generation.
- Two Proxy connections that both report the same raw page-generation value
  cannot produce equal persistent IDs in one container.
- One source event reaches both contexts with equal IDs and distinct model
  object identities.
- Repeated same-context lookup returns the identical object.
- Closing one context leaves the other context and Proxy connection active.
- Public WKWebView attach and package test-Proxy ownership transfer converge on
  the same Core activation/lifecycle path after native Proxy creation.
- Closing the container terminates all context and FRC sequences and awaits all
  owned Tasks.
- A late context receives an atomic current snapshot before later deltas.
- A slow context receives reset rather than a discontinuous delta.
- A slow FRC rebases its query-specific snapshot in the context query core
  without forcing a canonical context reset.
- DOM/CSS deltas preceding their per-target bootstrap boundary are suppressed;
  the first delivered delta is ordered after the authoritative snapshot.
- Network/Console/Runtime replay events remain ordered before their replay
  completion marker and are not overwritten by later bootstrap state.
- A Runtime event whose execution target differs from its agent target retains
  both identities; create/destroy/clear and command routing use the same agent
  target without parsing a projected raw ID.
- A Network request whose protocol `targetId` origin differs from its Network
  agent retains both; later ID-only events preserve the original semantic
  membership and response-body commands use the agent target.
- A DOM node whose semantic document target differs from its allocating agent
  retains both targets in its persistent identity; equal raw IDs from distinct
  agents never alias.
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
- Runtime remote objects are rejected after semantic navigation, execution-
  context clear/destroy, target loss, explicit group release, or attachment
  reset before a command reaches ProxyKit. Console-owned remote objects are
  also rejected after their owning message is cleared.
- Adversarial suspension between Runtime gateway claim and ProxyKit admission
  cannot admit a command behind navigation, Runtime clear, Console clear, or
  explicit group release. An earlier claimed operation either quiesces before
  backend group release or returns a stale completion that cannot materialize
  new resources.
- A `.console`-only configuration still observes Runtime binding invalidation;
  `executionContextsCleared` makes existing Console-owned remote objects stale
  without exposing the persistent Runtime model domain.
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
- Fast, waiting, and merely pending subscribers do not generate full snapshots.
  A slow subscriber generates one only when it consumes `resetRequired` and
  requests an owner-atomic rebase. Container and FRC publication edges exercise
  this contract independently with their respective snapshot owners.
- Closing FRC unregisters immediately and terminates subscribers.

### Network/UI contracts

- A redirect chain is one request with redirect content.
- A multipart response may receive response/data content after its first
  finish without reopening lifecycle or reusing identity; a second finish is
  still invalid.
- Clear tombstones suppress late request/WebSocket events until generation
  reset and reject a new live start with the same scoped identity.
- A Console network-request reference resolves through the canonical Network
  raw-ID index to the same scoped `NetworkRequest.ID` even when the Console and
  Network agents differ, without target-prefix parsing. A live cross-agent raw
  ID collision fails at that index instead of selecting either request.
- Related media/initiator requests form one stable `NetworkEntry`.
- Group membership, member-local `searchTexts`, and category counters update
  incrementally; transfer/WebSocket-frame updates do not rescan the group.
- The Network diffable list has one item per entry and one UIKit section.
- Detail displays all request members in chronological order.
- The player controller is present from initial Detail rendering when preview
  is available.
- Popping compact Detail does not repush it during transition completion.
- Page back/forward does not present a spurious network-unavailable error.

### Performance/isolation contracts

- Container construction, feed reduction, publication, filtering, sorting, and
  difference construction do not require MainActor.
- MainActor owns only the native `WKWebView` attach boundary, the cached
  `mainContext` Observable graph, and UI application.
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
`-strict-concurrency=complete`, `-strict-memory-safety`, and
`-default-isolation nonisolated` against the iOS 26.5 SDK. Provider and consumer
were compiled as separate modules.

The positive probe established that the following declarations compose in one
public surface:

- an ID protocol whose associated model points back to `Model.ID`;
- a persistent model with an associated Sendable `QueryValue`;
- `Predicate<Model.QueryValue>`, `SortDescriptor<Model.QueryValue>`, and
  `Expression<Model.QueryValue, SectionName>`;
- `WebInspectorFetchedResultsController<Model, Never>`;
- context-bound unsectioned and sectioned controller initializers with an
  `isolated (any Actor) = #isolation` parameter;
- a checked-Sendable container with a nonisolated synchronous initializer and
  a stable computed `@MainActor` context property backed by actor-isolated
  cache storage;
- an `Equatable & SendableMetatype` context with unavailable `Sendable`;
- a container factory returning a non-Sendable context into its isolated
  caller parameter;
- `nonisolated(nonsending)` generic fetch/controller methods.

Negative probes rejected both assigning an `@MainActor let mainContext` from a
nonisolated initializer and using `@MainActor lazy var` storage in a checked
`Sendable` class. The selected shape instead creates only a Sendable
registration seed during Container initialization and materializes the
non-Sendable wrapper through the actor-isolated computed getter.

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
| F11 | Container owns attachment generation while Proxy scope supplies page generation; navigation and reattach failure tests. |
| F12 | Detail resolves entry/request IDs; preview tests. |
| F13 | Structured navigation plus optional DOM-binding epochs; Network-only Page observation and opaque-initiator tests. |
| F14 | No persistent-ID parser for target-prefixed raw strings; structured-scope tests. |
| F15 | Reducer duplicate-ID invariant and redirect exception tests. |
| F16 | Domain reducers/schema registry and command gateway; no domain-event switch in the context type. |
| F17 | Pure Network record/reducer in Container Core; projection contains no protocol reducer or query registration. |
| F18 | Snapshot-free publish and layer-owner-supplied on-demand rebase; separate zero-snapshot Container and FRC slow/pending-subscriber tests. |

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
4. **Canonical domain reducers** — introduce the final internal
   `WebInspectorModelContainerCore` actor with a pure value store, then separate
   Network, Console/Runtime, and DOM/CSS records from context-local Observable
   projections. During this stage the existing context forwards validated feed
   records to the core. Migrate each domain to structured IDs and remove its
   dependency on projected raw-ID prefixes in the same step.
5. **Container ownership** — introduce the stable public container, physically
   move attach/detach/reattach and the single adopted Proxy/feed lifecycle into
   the existing core, and restore multiple contexts. Remove public context
   initialization/attach/detach in this step while preserving UIKit's stable
   main-context and controller identity.
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
- The same container/main context/FRC survive detach/reattach, while persistent
  IDs from equal raw Proxy generations do not alias across attachments.
- Attach/detach/close completion is linearizable: superseded/pending Proxies
  are closed, and all retained Context/FRC state has acknowledged the committed
  attachment revision before the lifecycle call returns.
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
