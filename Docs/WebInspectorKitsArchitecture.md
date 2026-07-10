# WebInspectorProxyKit and WebInspectorDataKit Architecture

- Status: proposed design gate
- Scope: breaking redesign of WebInspectorProxyKit, WebInspectorDataKit, their
  testing products, and the built-in UIKit consumers
- Minimum deployment: iOS 18.4 and macOS 15.4
- Baseline revision: `88865971b78724a4444373e5a83606b3377ad86d`

## Decision

The current APIs are not safe or coherent enough to preserve for source
compatibility. The migration will replace them instead of wrapping them.

The redesign has four governing invariants:

1. A protocol event subscription that causes WebKit domain enablement is
   registered before enable is sent, so that enable-time replay cannot race its
   first subscriber. Later subscribers explicitly start from the current page
   generation and future events; ProxyKit does not invent replay WebKit did not
   send.
2. One connection core owns physical target membership, reply routing, domain
   leases, event buffering, and terminal state. No public handle caches a second
   copy of that state.
3. DataKit exposes one non-`Sendable`, caller-confined model context over stable
   identity models and snapshot-plus-diff query results. The context and every
   identity it vends inherit the actor that stores and uses them; UIKit owns its
   context on MainActor, while a headless consumer may own an independent
   context on any actor. A successful `attach(to:)` means the configured state
   is ready to use.
4. Resources with asynchronous teardown have an explicit scoped or `async`
   close operation. `isolated deinit` is a synchronous backstop, never a
   substitute for deterministic teardown.

These invariants intentionally break the existing `enable()` / `events`,
`WebInspectorContainer` / dynamically checked `WebInspectorContext`, generic
fetch, and duplicate domain-controller APIs.

## Scope Contract

### Outcomes

- A direct ProxyKit consumer can attach, issue typed commands, and consume an
  atomic bounded event stream without understanding target IDs, enable ordering,
  or reference counts.
- A custom UI can attach one DataKit context, observe readiness and failure,
  select only the domains it needs, and use the same DOM, Network, Console,
  Runtime, and CSS state as the built-in UI.
- Navigation and WebKit process replacement retain one logical page handle while
  commands and active capabilities move to the new physical target. Consumers
  receive an ordered reset boundary before any event from the new binding.
- Explicit detach/close waits for stream termination, native detach, and
  inspectability restoration. Retain cycles cannot make cleanup unreachable.
- ProxyKitTesting and DataKitTesting can describe the behaviors above without
  hand-scripting unrelated startup replies or polling readiness.

### Primary consumers

1. The built-in UIKit inspector and Monocly integration.
2. Public-only contract consumers:
   - a custom Console tab receiving a DataKit context;
   - a direct ProxyKit Network event consumer.

The second consumers are contract tests because the repository currently has no
second production consumer of either core product.

### Preserved behavior

- Typed protocol commands and payload DTOs.
- Opaque scoped protocol identifiers and frame-aware routing.
- Identity-preserving DataKit model objects.
- DOM snapshots and incremental tree updates.
- Observable Network collection topology and lazy response-body loading.
- Undoable DOM editing and explicit partial-mutation reporting.
- The UIKit DOM and Network feature set and Monocly's reusable shared-session
  lifecycle.

### Non-goals

- Expanding the supported Web Inspector protocol surface or exposing a raw
  command escape hatch from production ProxyKit. ProxyKitTesting's inverse
  raw-wire peer is a test transport, not a production command API.
- Building a new AppKit inspector UI. ProxyKit and DataKit continue to support
  macOS; the app-facing UI remains UIKit-only.
- Redesigning the visual presentation of the built-in inspector.
- Replacing the native symbol-resolution strategy except where ownership and
  teardown must change.
- Preserving source compatibility with the APIs explicitly deleted below.

## Measured Baseline

The baseline is source-derived and intentionally records lexical counts so the
same commands can be rerun after migration.

| Metric | ProxyKit | DataKit | ProxyKitTesting | UIKit implementation |
| --- | ---: | ---: | ---: | ---: |
| Swift LOC | 10,041 | 12,192 | 757 | 18,508 |
| lexical `public` | 431 | 507 | 45 | 32 |
| lexical `package` | 478 | 145 | 13 | 463 |
| top-level public types | 11 | 53 | 6 | 3 |

Additional coupling signals:

- `WebInspectorContext.swift` is 4,327 lines with 63 source-level stored
  properties (60 outside `DEBUG`).
- DataKit contains 202 `isolated (any Actor)` annotations and 57
  `requireOwner` sites.
- `WebInspectorProxy.pageTarget` has 23 references even though
  `TransportTargetRegistry` already owns the current physical target.
- Current-page versus physical-target routing is decided at nine sites in three
  files.
- Domain activation decisions occur at 13 sites in six files and are split
  between ProxyKit and DataKit.
- There are 58 UIKit platform-gated files. This is a known package/platform
  boundary caused by the UIKit-only product and is excluded from the core
  rearchitecture metric; AppKit UI is a separate project.
- `ContractTests` uses ordinary imports and no `@testable`, so it remains the
  external API gate.

Baseline validation on the branch passed the shared iOS simulator scheme: 467
tests, zero failures, on `iPhone 17` / iOS Simulator 27.0. The result bundle is
recorded outside the repository by Xcode; it is evidence, not a committed
artifact. The public-only ContractTests package also passed its six tests on
macOS.

External source evidence was read at fixed local revisions:

- Swift `9a6fb89946fa748420c87627ac0f892543e53b51`: non-MainActor isolated
  deinitialization availability in `include/swift/AST/RuntimeVersions.def` and
  `test/Concurrency/deinit_isolation_availability.swift`; rejection of isolated
  deinitializers on ordinary classes in `deinit_isolation.swift`; region-based
  transfer diagnostics and caller-executor behavior in the concurrency tests.
- Xcode's SwiftData interface: `ModelContext` is deliberately unavailable for
  `Sendable` conformance, while `ModelActor` supplies a separate actor/executor
  owner. This is the analog for caller confinement, not evidence that an
  ordinary class can acquire a runtime-selected nominal actor isolation.
- WebKit `9d2c43b4dc9d9c47448c510c87e79ecaf40b60a4`: enable-time replay in Runtime
  protocol and Console/Network/CSS/Inspector agents, plus provisional target
  commit ordering in `WebPageInspectorController.cpp`; page-only Inspector and
  `DOM.requestNode` contracts in `Inspector.json` / `DOM.json`, the unsupported
  frame stub in `FrameDOMAgentStubs.cpp`, and main-target picker resolution in
  `InspectorObserver.js` / `DOMManager.js`. In both
  `Source/WebCore/inspector/agents/InspectorDOMAgent.cpp` and
  `Source/WebCore/inspector/agents/frame/FrameDOMAgent.cpp`, `getDocument`
  resets the agent's current node bindings before rebuilding the document root
  at depth two. `setDocument` also resets those bindings and emits
  `documentUpdated` once a previously requested document is ready. This is the
  source evidence for treating every `documentUpdated` as a node-identity epoch
  change and retrying an in-flight bootstrap rather than merging its stale
  reply. In `Source/JavaScriptCore/inspector/agents/InspectorConsoleAgent.cpp`,
  `InspectorConsoleAgent::clearMessages` releases WebKit's internal `"console"`
  object group before dispatching `messagesCleared`. This is the ownership
  evidence for invalidating Console-originated remote objects locally without a
  second `Runtime.releaseObjectGroup` command from DataKit.
- Swift Evolution [SE-0371: Isolated synchronous deinit](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md)
  for the language-level lifecycle contract.

Local Swift 6.3.3 probes were compiled through SIL with strict concurrency, not
only type-checked. They prove that `WebInspectorModelContext` cannot satisfy a
`Sendable` requirement; `nonisolated(nonsending)` async methods preserve the
caller executor; a detached feed task with weak actor/context edges deallocates
its owner; and a fully checked actor bridge cannot transfer the weak
non-Sendable context back to an arbitrary runtime actor. Swift's region rules
cannot reject every deliberate escape hidden behind an actor method, so the
single delivery bridge also preconditions the actor executor bound at attach.
This is why the design permits one narrow private unchecked weak bridge and no
other unchecked model ownership.

## Findings and Broken Invariants

### P0: event subscription is non-atomic

Every public domain currently exposes separate `enable()` and cold `events`.
The stream does not register its subscriber until iteration starts. WebKit may
send initial Runtime contexts, Console backlog, active Network sockets, CSS
style sheets, or pending inspect data before the enable reply. DataKit privately
works around this with `subscribe -> barrier -> reset -> enable`, but direct
ProxyKit consumers cannot do so.

Owner correction: ProxyKit owns subscriber registration and domain enable as one
operation. The workaround and domain reference counts leave DataKit.

The guarantee is deliberately not “every subscriber receives a historical
snapshot.” The first lease receives WebKit's enable-time replay because it was
registered before enable. A subscriber joining an already-enabled capability
receives an initial page-generation marker followed by future events only.
Stateful consumers that require their own snapshot must issue the domain's
explicit snapshot command or own a separate connection; ProxyKit does not cache
protocol history as a second source of truth.

### P0: connection ownership is cyclic and terminal state is split

The current graph contains both:

```text
WebInspectorProxy -> pageTarget -> WebInspectorProxy
TransportSession -> native backend -> bridge callback -> receiver -> TransportSession
```

The first makes the public page cache keep its proxy alive. The second makes
native detach and inspectability restoration unreachable without an explicit
close. Close state also exists independently in the proxy, transport, and fatal
callback logger.

Owner correction: a single connection core owns terminal state. Handles point
to the core, the core never stores handles, and the native callback captures its
receiver weakly.

### P0: the logical page has two sources of truth

`TransportTargetRegistry` is updated for every target message, but
`WebInspectorProxy.pageTarget` changes only while a package-only lifecycle
stream is consumed. `currentPage`, `canReload`, and routing can therefore become
stale as an accidental consequence of consumer behavior.

Owner correction: the transport registry is the only physical membership
owner. A stable logical page resolves its current physical binding through the
core for each operation.

### P0: DataKit readiness is not part of attachment

`WebInspectorContainer.mainContext` returns and starts model setup in an
unstructured task. The public status type has no public producer. A caller can
receive attach success and later encounter a hidden model failure. Network-only
consumers nevertheless pay for Inspector, Runtime, DOM, Console, and Network
startup.

Owner correction: the DataKit context owns an awaited transition and only starts
configured capabilities plus their declared dependencies.

### P0: actor ownership is represented by a retained token and runtime checks

`WebInspectorContext` strongly stores `any Actor`, dynamically checks it at 57
sites, and repeats an isolation parameter across 202 declarations. When that
actor stores the Context, the graph is cyclic before any event task starts:
`owner actor -> context -> stored owner actor`. The token still does not give the
plain class nominal actor isolation or an `isolated deinit`.

Owner correction: the replacement `WebInspectorModelContext` is non-`Sendable`,
never strongly retains its actor, and is confined by the actor that stores it in
the same manner as SwiftData's non-Sendable `ModelContext`. Synchronous model
access needs no isolation argument; async graph operations use caller-executor
semantics. Attachment records one weak actor identity solely to assert the
private feed-application boundary and to install weak event delivery. Heavy
query projection remains behind internal actors, and immutable Sendable
snapshots/deltas are the only supported way to cross between a custom model
actor and UIKit.

### P0: fetched-results setup can permanently miss a topology change

Creating initial `WebInspectorFetchedResults` state and registering it with the
current Context is synchronous on the owner, so the producer boundary is sound.
The public consumer boundary is not: `snapshot` and `transactions` are separate
FRC properties, the relay has no initial element, and a result drops a
transaction when it has no continuation. A mutation between snapshot read and
stream registration is therefore lost permanently. The built-in Network UI
partly avoids the race by subscribing first and later reloading a full snapshot,
but that call-site ordering is not a public contract.

Owner correction: preserve snapshot plus transaction, but make
`WebInspectorFetchedResults` own one atomic subscription that begins with its
current snapshot. Each bounded update remains self-contained so a slow consumer
can replace from the full new snapshot after a revision gap. The zero-state FRC
wrapper is removed.

### P1: collection topology is off-actor but not yet truly incremental

`NetworkRequestIndex` correctly projects compact records and performs query/diff
work away from MainActor, and the UIKit consumer applies transactions instead of
reloading all model identities. However, each mutation still scans and may sort
all records, each queued transaction contains old and new full snapshots, and
the relay is unbounded. Initial fetch and descriptor replacement also build
query state on the owner actor. Console performs its filtering, sorting, and
diffing on the owner for every registered result. There is no 10,000-record or
stalled-subscriber gate.

Owner correction: keep and improve the record-index boundary, add the same
boundary for Console, cap queued result state to the newest self-contained
snapshot/delta, and measure the large-record paths. Adding public domain model
facades would not affect this cost.

### P1: DataKit advertises unsupported generic queries

The public fetch protocol permits external conformance, but implementation
branches only support `NetworkRequest` and `ConsoleMessage`. Arbitrary sort and
section key paths trap outside hard-coded lists. `WebInspectorFetchRequest` is
an unused mutable mirror, `WebInspectorStaleModelPolicy` has one unused case,
and `WebInspectorFetchedResultsController` wraps results primarily to expose a
second update stream.

Owner correction: Network and Console own closed, concrete query vocabularies
and preserve the existing `WebInspectorFetchedResults` snapshot-plus-diff
contract. Unsupported requests are unrepresentable, initial state and update
registration become atomic, and slow consumers cannot create an unbounded
transaction backlog.

### P1: domain APIs duplicate operations and disagree on semantics

Context methods, model convenience methods, and computed domain-controller
wrappers provide up to three paths for tree access, selection, child loading,
delete, highlight, picker, reload, evaluate, fetch, clear, and CSS mutation.
The direct tree API throws before root readiness while the domain wrapper
returns an empty live controller. CSS style lookup also mutates global DOM
selection as a side effect.

Owner correction: package-internal domain stores become the sole writers after
the relevant `WebInspectorContext` write sets are moved into them. They are not
new public model wrappers. `WebInspectorModelContext` is the public facade,
while existing identity, tree, fetched-results, history, picker, and remote
resource types remain the public domain-specific values. Cross-domain
dependencies are internal and CSS queries never write DOM selection.

### P1: errors and remote resources are not usable contracts

Some DOM backend failures are swallowed behind throwing facades, stale models
alternate between trap and throw, partial deletion information is package-only,
and CSS mutations can fail in fire-and-forget tasks. Runtime model objects are
retained without a deterministic public object-group lifetime.

Owner correction: expected runtime failures are public typed errors or explicit
partial outcomes. Programmer-contract violations alone use preconditions.
Runtime remote handles belong to explicit object groups with scoped asynchronous
release.

### P1: custom tabs and testing claims are incomplete

Custom tabs receive a UI session whose DataKit context is package-only, so the
documented custom Console story cannot read Console data. The existing
ProxyKitTesting backend is a second semantic implementation: it accepts decoded
typed events, synthetic targets, and preselected routes instead of exercising
the production connection core's raw JSON decoding, sequencing, target
membership, and generation boundaries. DataKit consumers then have to script
unrelated startup behavior and busy-poll private readiness.

Owner correction: UIKit keeps its presentation-only `WebInspectorSession`,
which publicly exposes one DataKit `WebInspectorModelContext` as `model` and is
passed to custom tabs. The root controller, not the session, owns custom content
instances so a tab may retain the session without a cycle. ProxyKitTesting
exposes one raw-wire `WebInspectorTestPeer` below the production connection core
and an explicit `WebInspectorProxyTestRuntime` resource owner. A separate
DataKitTesting product composes that peer into model-level scenarios so its
consumers do not script unrelated startup replies.

## Package and Ownership Design

The target dependency graph remains directional:

```text
WebInspectorNativeBridge
          |
          v
WebInspectorProxyKit <--- WebInspectorProxyKitTesting
          |
          v
WebInspectorDataKit  <--- WebInspectorDataKitTesting
          |
          v
WebInspectorUIBase / UIDOM / UINetwork / UISyntaxBody
          |
          v
WebInspectorUI -> WebInspectorKit
```

`WebInspectorDataKitTesting` may depend on ProxyKitTesting. Production targets
never depend on a testing target. No new general-purpose Core, Shared, Service,
Manager, or Utils target is introduced.

The UIKit `WebInspectorSession` remains a real presentation owner; it is not
moved into DataKit. It stores one MainActor-confined `WebInspectorModelContext`
and exposes it as `public let model`. The umbrella `WebInspectorKit` target
directly depends on and re-exports DataKit as well as the UIKit entry points so
a custom tab can request `session.model.consoleMessages()` with one import.
This preserves `import WebInspectorKit; WebInspectorSession()` while keeping
semantic model state in DataKit and UI-specific state in WebInspectorUI.

### Variation axes and absorption points

| Variation | Absorbed by | Must not leak into |
| --- | --- | --- |
| live native bridge versus raw-wire test peer | transport boundary below the same connection core | domain handles and DataKit models |
| physical target replacement | core target/capability registries and ordered generation boundary | public page handle and UIKit controllers |
| selected DataKit domains | context configuration and capability dependency table | unrelated store startup branches |
| Network/Console filtering and ordering | concrete query value and result owner | generic model protocols or arbitrary key paths |
| attached/detached/closed lifecycle | one context transition state machine | per-domain ad hoc flags |
| document versus binding lifetime | domain-specific epochs driven by the ordered feed | one coarse global stale flag |
| iOS UIKit presentation versus no AppKit UI | existing UI target/file boundary | ProxyKit and DataKit semantic code |
| timeouts and deterministic test scheduling | connection configuration plus package test-support clocks/gates | public protocol DTOs or testing product surface |

The production connection initializer creates the native backend. The public
testing runtime installs a raw-wire peer below the same connection core; package
tests may additionally inject a clock. These are concrete boundaries, not public
backend protocols with an unsupported external-conformance promise.

### Owner map after migration

| State or effect | Sole owner | Allowed writers |
| --- | --- | --- |
| physical target membership and current binding | `ConnectionCore`'s target registry | inbound target lifecycle |
| logical inspected page | immutable `WebInspectorPage` handle | none; resolves through core |
| command IDs, replies, routing, terminal cause | `ConnectionCore` actor | send, inbound receive, close/fail |
| domain/capability reference counts | core capability registry | structured acquire/release and retarget |
| subscriber buffers and ordered model feed | core event broker | decoded inbound events and termination |
| native bridge and detach | `@MainActor NativeAttachment` | attach and deterministic close |
| original inspectability and same-view lease membership | per-web-view `@MainActor InspectabilityCoordinator` | lease acquire/final release |
| model attachment and physical binding generations | caller-confined `WebInspectorModelContext` | owning actor via attach, detach, close, and ordered feed application |
| DOM identity, tree, selection, edits, and node-bound CSS resources | package-internal `DOMStateStore` | DOM/CSS events and awaited DOM/CSS command results |
| Network identity registry and query membership | package-internal `NetworkRequestStore` plus its off-main-actor index | Network events and clear/load operations |
| Console identity registry, query membership, and Console-originated remote-object validity | package-internal `ConsoleMessageStore` plus its off-main-actor index | Console events and clear operations |
| one query projection's snapshot and delta sequence | public `WebInspectorFetchedResults` | its owning internal store only |
| Runtime contexts and remote groups | package-internal `RuntimeStateStore` | Runtime events and scoped evaluation |
| UI tabs and page style | UIKit `WebInspectorSession` and its package interface model | presentation and page-style events only |
| content-controller cache and retirement | root `WebInspectorViewController` | tab selection and root presentation lifecycle |
| tab layout/scroll/render caches | UIKit controllers | presentation events only |

`ConnectionCore` is an implementation actor. The root `WebInspectorProxy` is the
sole direct close owner and strongly retains the core. `WebInspectorPage`,
`WebInspectorTarget`, and every domain endpoint are Sendable weak lifecycle
handles: retaining a child handle does not keep the root connection alive. A
command, generation query, or structured event scope resolves the root for that
operation and fails with `closed` if it has gone away; a cold stream finishes
immediately. Active model use is instead kept alive by its context/session owner.
Dropping the root is only a synchronous local-resource backstop; explicit
`close()` remains the deterministic asynchronous detach contract.

### Native attachment ownership

`NativeAttachment` owns one bridge, its receiver sink, and one token from an
`InspectabilityCoordinator` keyed weakly by `WKWebView`. The coordinator, not an
individual attachment, captures the original `isInspectable` value. It keeps the
view inspectable while any token exists and restores the original value only on
the final release. Closing one of two connections to the same view therefore
cannot disable the other. `NativeAttachment` does not retain a sink that in turn
strongly retains `ConnectionCore`: the receiver-to-core edge is weak and the
bridge callback weakly captures the receiver. Thus the native graph is acyclic;
explicit close rejects new messages, finishes core state, synchronously detaches
the bridge, releases the token, and only then resumes close waiters.

### Apple framework analogs

- The connection follows `URLSession`: it owns transport policy and requires an
  explicit invalidation/close operation after which it is not reusable.
- A structured domain event scope follows task/resource scopes rather than a
  notification singleton: cancellation requests teardown, and completion of the
  scope confirms that teardown has balanced its capability lease.
- The DataKit context follows SwiftData's `ModelContext`: it is deliberately
  non-`Sendable`, belongs to one concurrency context, and exposes stable model
  identities there. UIKit chooses MainActor; a custom actor chooses itself.
  Neither may share the mutable graph with the other.
- Like `URLSessionTask.cancel()`, cancellation may race with already produced
  events. Therefore event-scope return, not the initial cancellation request, is
  the deterministic teardown boundary.

The analogs guide lifecycle and naming; they do not justify mirroring unrelated
framework API surface.

## ProxyKit API Sketch

The exact generic spelling may change to satisfy Swift 6.3 ownership checking,
but the visible concepts and lifecycle are fixed by this gate.

```swift
public final class WebInspectorProxy: Sendable {
    public struct Configuration: Sendable {
        public var responseTimeout: Duration
        public var bootstrapTimeout: Duration

        public init(
            responseTimeout: Duration = .seconds(10),
            bootstrapTimeout: Duration = .seconds(10)
        )
    }

    @MainActor
    public init(
        attachingTo webView: WKWebView,
        configuration: Configuration = .init()
    ) async throws

    public var page: WebInspectorPage { get }
    public func close() async
    public func waitUntilClosed() async throws

    @MainActor
    public static func withAttachment<Result: Sendable>(
        to webView: WKWebView,
        configuration: Configuration = .init(),
        _ operation: @MainActor (WebInspectorProxy) async throws -> Result
    ) async throws -> Result
}

public struct WebInspectorPage: Sendable {
    public struct Generation: Hashable, Sendable { /* opaque */ }

    public var generation: Generation { get async throws }
    public var dom: DOM { get }
    public var css: CSS { get }
    public var network: Network { get }
    public var console: Console { get }
    public var runtime: Runtime { get }
    public var page: Page { get }
}

public enum WebInspectorEventBufferingPolicy: Sendable {
    case bounded(Int)
    case unbounded
}

public enum WebInspectorPageEvent<Element: Sendable>: Sendable {
    case reset(WebInspectorPage.Generation)
    case event(WebInspectorPage.Generation, Element)
}

public struct WebInspectorScopeError: Error {
    public let operationError: any Error
    public let cleanupError: any Error
}

extension Network {
    public func withEvents<Result>(
        buffering: WebInspectorEventBufferingPolicy = .bounded(256),
        isolation: isolated (any Actor)? = #isolation,
        _ operation: (
            AsyncThrowingStream<
                WebInspectorPageEvent<Network.Event>,
                any Error
            >
        ) async throws -> Result
    ) async throws -> Result
}
```

`DOM`, `CSS`, `Network`, `Console`, `Runtime`, and `Page` are concrete,
target-scoped value handles as well as the namespaces for their protocol value
types. There is no nested `Client` layer. A package-only
`WebInspectorDomainHandle` protocol owns command dispatch, and the closed-set
`WebInspectorEventDomainHandle` refinement owns structured event registration
and extraction. These protocols are deliberately not public: ProxyKit does not
support consumer-defined WebKit domains, so public conformance would promise an
extension point the connection core cannot honor. Each concrete event handle
keeps only the thin public `withEvents` forwarder required by Swift access
control.

This is closed-set implementation reuse, not public extensibility. Consumer
code receives concrete struct handles and calls their typed operations directly;
the package protocols and witnesses exist only to keep dispatch and
`withEvents` mechanics identical across the known domains.

Only the outer domain handles change from namespace enums to structs; nested
sum types such as `DOM.Event` and `Network.Event` remain enums. `DOM`, `CSS`,
`Network`, `Console`, and `Runtime` expose the same structured event scope,
while `Page` is command-only. There is
no separate public `enable()`, `disable()`, cold `events`, or subscription
barrier. The closure is the capability lease. DataKit holds capabilities for the
attachment lifetime through the acyclic ordered model-feed driver described
below; direct consumers normally consume a scope inline. The stored driver task
does not strongly capture its context, actor, or domain owners.

The low-level implementation registers a bounded subscriber before sending the
first enable command. On scope exit it awaits lease release. A second consumer
increments the count without sending another enable; only the final release
sends disable. Cancellation during enable completes enable, then balances it
with disable before returning.

`withEvents` inherits the caller's actor through its `isolation` parameter; its
nonescaping operation closure is deliberately not `@Sendable`. This permits a
MainActor UI or another actor-owned consumer to use isolated state without
unsafe captures. `.bounded` requires a strictly positive capacity and rejects
zero or negative values as a programmer error.

Scope cleanup follows one rule across domains: body success plus final-disable
failure throws the disable error; body failure plus successful cleanup rethrows
the body error; if both fail, `WebInspectorScopeError` preserves both with the
body error primary. Destruction of the old physical target makes its local lease
release complete without sending disable to the new generation.

Every scope begins with `.reset(currentGeneration)`. If it acquired the first
lease, any enable-time replay is already buffered after that marker before the
operation closure runs. If the capability was already enabled, the scope is
future-only after the marker; it does not receive another consumer's earlier
events. A physical binding change emits a new `.reset` before any event from the
new binding.

DataKit does not infer readiness from the public stream. ProxyKit provides one
package-level ordered model feed whose internal records carry transport sequence,
page generation, physical target identity, and explicit synchronization
boundaries:

```swift
package enum ConnectionModelFeedRecord: Sendable {
    case reset(WebInspectorPage.Generation)
    case targetSnapshot(
        generation: WebInspectorPage.Generation,
        through: UInt64,
        snapshot: ModelTargetSnapshot
    )
    case event(
        generation: WebInspectorPage.Generation,
        sequence: UInt64,
        payload: ModelProtocolEvent
    )
    case domDocumentInvalidated(
        generation: WebInspectorPage.Generation,
        sequence: UInt64,
        target: ModelTarget,
        documentEpoch: ModelDocumentEpoch
    )
    case replayComplete(
        generation: WebInspectorPage.Generation,
        domain: ModelDomain,
        through: UInt64
    )
    case bootstrapSnapshot(
        generation: WebInspectorPage.Generation,
        domain: ModelDomain,
        sequence: UInt64,
        payload: ModelBootstrapSnapshot
    )
    case bootstrapComplete(
        generation: WebInspectorPage.Generation,
        domain: ModelDomain,
        through: UInt64
    )
    case synchronizationComplete(
        generation: WebInspectorPage.Generation,
        through: UInt64
    )
}

package struct ModelTarget: Sendable {
    let id: WebInspectorTarget.ID
    let kind: WebInspectorTarget.Kind
    let frameID: FrameID?
    let parentFrameID: FrameID?
}

package struct ModelTargetSnapshot: Sendable {
    let currentPageID: WebInspectorTarget.ID
    let targets: [ModelTarget]
}

package struct ModelDocumentEpoch: Hashable, Sendable { /* opaque */ }
package enum ModelProtocolEvent: Sendable { /* typed payload except document invalidation */ }
package enum ModelBootstrapSnapshot: Sendable { /* target + epoch + typed snapshot */ }
package enum ModelDomain: Hashable, Sendable { /* configured domains */ }
package enum ConnectionModelFeedError: Error, Sendable {
    case bootstrapFailed(domain: ModelDomain, message: String)
    // exclusive-use, overflow, and consumer-lifecycle cases omitted
}
```

The current transport slice implements the bounded exclusive feed, initial
`reset`/`targetSnapshot`, future target lifecycle deltas, future events for
configured domains, transactional capability leases, enable-replay boundaries
for CSS, Network, Console, and Runtime, DOM snapshot bootstrap, and one
binding-level synchronization boundary. Configuration is normalized once at
registration: CSS implies DOM, while Network alone does not. Capability
acquisition uses that same normalized set in the deterministic domain order
DOM, CSS, Network, Console, Runtime. Completion records remain reply-driven and
may interleave across domains; the single `synchronizationComplete` record is
the only all-domain-ready barrier. DOM's capability lease itself is local and
sends no `DOM.enable`; the separate bootstrap owner sends `DOM.getDocument`.
The feed is registered and its initial records are published before the first
capability await, and `openModelFeed` returns only after every configured
capability is active. An acquisition failure or cancellation releases the
successful prefix in reverse order before returning. For an empty
configured-domain set the feed also emits `synchronizationComplete`.
An inspected target's rejection of a configured domain activation is reported
as `bootstrapFailed` with the `ModelDomain` already owned by the acquisition
loop; Core never recovers that domain by parsing the rejected method string.
Cancellation, page disappearance, protocol violation, and connection/transport
termination keep their existing categories. If rollback cleanup also fails,
`WebInspectorScopeError` retains the typed bootstrap rejection as its operation
error and the independent cleanup error as its cleanup error.

For a successful wire `enable` reply, the connection core publishes one
`replayComplete` for each configured model-domain owner of that physical
capability. Publication is synchronous in reply processing: all earlier inbound
events have already been projected into the feed, the marker uses the reply's
current transport-sequence watermark, and only then can the capability promise
resume `openModelFeed`. Shared leases do not duplicate a model-domain marker,
rejected or superseded operations publish none, and a replacement physical
binding publishes its marker in the replacement generation. Local DOM never
publishes an invented replay boundary.

DOM bootstrap completion and all normalized replay completions are tracked per
binding generation. Only after every configured domain completes does the core
emit one `synchronizationComplete`; a later document epoch or added frame may
emit another DOM bootstrap boundary, but never a second synchronization record
for that generation. Reset and retarget replace the completion state, so a late
reply from an old operation cannot complete the new binding. This distinction
prevents wire replay completion from being mistaken for complete model
readiness.

The target snapshot contains the physical current page first, followed by its
relevant committed frame targets in deterministic parent-before-child order.
Its `through` watermark subsumes target lifecycle events at or before that
sequence; every later lifecycle delta has a strictly greater sequence. If the
feed opens while the page is unavailable, its reset reserves the generation
that the next current-page binding will use. The later target snapshot and
empty-domain synchronization record use that same generation and do not emit a
duplicate same-sequence `targetCreated` delta.

The feed is a bounded, oldest-first, single-consumer sequence. Overflow clears
pending records and immediately poisons both the feed and connection; there is
no silent drop, task relay, or unbounded default. Iterator cancellation or
handle abandonment terminates that mailbox synchronously while retaining the
exclusive connection claim. If the producer later attempts another enqueue to
that terminated mailbox, that enqueue poisons the connection; an explicit
`close()` before another enqueue remains a clean shutdown.
Explicit `ConnectionModelFeed.close()` is the sole feed-close surface. It
releases configured capabilities in reverse acquisition order and releases the
claim only after clean quiescence, allowing a replacement feed. Concurrent and
repeated close calls share that completion. A capability cleanup failure poisons
the mailbox and terminates the connection, because the physical enabled state
cannot safely be reused without a logical owner.
Dropping the handle synchronously finishes its mailbox but intentionally keeps
the connection claimed until connection close. Explicit connection close
finishes the feed normally only after transport close work reaches quiescence;
fatal and protocol termination fail it.

The model feed and direct consumption are mutually exclusive. Direct command
admission, including transport-local `DOM.enable`, claims the connection before
the local/wire split; once a direct command or structured scope is admitted, a
feed cannot reconstruct the missed prefix. While a feed owns the connection,
ordinary direct commands and structured scopes fail with
`WebInspectorProxyError.connectionInUse`. Legacy cold passive streams are
migration-only: starting one while the feed is open is a programmer error, and
they must be deleted rather than adapted around this ownership boundary.

Model code receives a package-only `ConnectionModelCommandAuthorization` from
the ordered feed application boundary. It contains the exact feed identity and
binding generation, plus a physical target/document epoch for document-scoped
work. The authority is propagated as a value through page/domain handles,
command encoding, and the core; the core registration remains the only source
of configured domains and readiness. `Page`, Network, Console, and Runtime
commands wait for binding `synchronizationComplete`. DOM, CSS, and Inspector
picker work additionally waits for that target's latest accepted DOM bootstrap.
An old generation or document epoch fails locally as `staleIdentifier`; a
foreign/closing feed, unconfigured domain, or missing document authorization
fails with a typed package error and never reaches the wire. Binding-only work
deliberately ignores an otherwise stale document field.

Enable/disable, `DOM.getDocument`, and `Inspector.initialized` remain
connection-owned operations and cannot be forged through model authority.
Capability leases and DOM bootstrap tasks are their only owners. Model commands
have Core-owned readiness waiters, tasks, and pending-reply purposes. Retarget
invalidates all old-generation main/frame work without touching a provisional
new-target direct reply; `DOM.documentUpdated` invalidates only DOM/CSS/Inspector
work for the old target epoch while binding-level work continues. Feed close
first rejects admission, drains those waiters/tasks/replies, then releases
capabilities and the exclusive claim. Terminal and overflow teardown perform the
same drain before transport detach.

Core ownership of a task handle does not permit the task's async frame to retain
`ConnectionCore` across readiness or wire suspension. A model-command runner
keeps only a weak Core reference between bounded, non-suspending actor hops.
Each hop validates and commits one Core-owned state transition, then returns a
Sendable decision or effect before the runner awaits an externally owned,
synchronized operation signal or reply promise. It must not bind Core strongly
once and call an actor method that remains suspended until readiness or a wire
reply. Explicit close rejects admission, synchronously signals every operation,
cancels the task handles, and awaits their completion before releasing the feed
claim. Core's isolated deinitializer can only repeat the synchronous
cancellation/signalling backstop; it cannot await those tasks.

The later DataKit feed consumer will apply records serially. Reaching
`replayComplete` therefore proves that every earlier event through that
watermark has been applied to the model, not merely placed in a stream buffer.
After all configured domain boundaries, `synchronizationComplete` proves the
physical binding itself is ready. This explicit record is required for an empty
domain configuration and for unavailable-to-ready rebinding, where no
domain-specific marker can carry readiness. The feed is package-only because
its mixed-domain payload and acknowledgement boundaries are model-adapter
mechanics, not a direct ProxyKit consumer concept.
The feed registers its initial reset and target snapshot before acquiring any
configured capability. Capability acquisition is transactional: if one enable
fails or the task is cancelled, the core releases every capability acquired for
that attempt in reverse order and fails the feed open. If rollback itself cannot
prove quiescence, the core terminates the connection. A DataKit model context
takes exclusive ownership of its Proxy connection, so it is always the first
model-feed subscriber and does not depend on a late subscriber receiving
historical replay.

DOM readiness uses the same ordered feed even though DOM has no enable-time
replay. After the feed is registered, the core issues `DOM.getDocument`
sequentially for the physical current page and each committed relevant frame in
the target snapshot's deterministic order. Its reply arrival sequence becomes
a `bootstrapSnapshot` record; DOM mutation
events at or before that watermark are subsumed by the returned full snapshot,
and later events follow it in sequence order. If `DOM.documentUpdated` advances
the document epoch between request and reply, the snapshot is discarded and
the command is retried. A valid snapshot will be followed by `bootstrapComplete`.
Every configured domain must reach either its replay or bootstrap completion
boundary before ProxyKit emits `synchronizationComplete`; DataKit applies that
final record before attachment or retarget synchronization becomes ready. A
later `DOM.documentUpdated` advances that physical target's DOM epoch and starts
the same ordered snapshot bootstrap again rather than exposing an empty tree as
ready state. A frame added before initial synchronization joins the outstanding
bootstrap set; a destroyed, superseded, or old-epoch reply is stale and cannot
publish. An inspected target's rejection of a required initial or refresh
`DOM.getDocument` is terminal and poisons the package mailbox with
`bootstrapFailed(domain: .dom, message:)`; malformed data and transport or
connection failure remain protocol/connection failures. Bootstrap commands are
Core-owned tasks: close, rollback, retarget, and terminal teardown cancel and
await them, and a failed feed enqueue is an operation-terminal result that
cannot advance to the next target.

For a feed whose normalized configuration includes DOM, every relevant
main-page or frame-target `DOM.documentUpdated` is projected as
`domDocumentInvalidated` after Core advances that target's
`ModelDocumentEpoch`. The record uses the inbound event sequence and is enqueued
before bootstrap starts or any later DOM/CSS delta for that target. It is the
model feed's only document-invalidation projection; an ordinary
`ModelProtocolEvent.dom(.documentUpdated)` is not also published. Public
structured event scopes keep their existing projection, including the
intentional filtering of frame-target `documentUpdated` from the semantic
current-page scope.

The DataKit reducer treats this record as the authoritative per-target boundary.
It immediately invalidates that target's DOM/CSS command authority and identity
state, then ignores target DOM/CSS deltas until a `bootstrapSnapshot` with the
same generation, target, and document epoch is applied. That snapshot atomically
replaces the target document and reauthorizes it; only later-sequence deltas may
mutate the replacement. A stale or skipped invalidation epoch is a protocol
failure rather than a guessed merge.

One-off commands internally acquire their declared prerequisites for the
duration of the command. Long-lived event/model state holds a structured event
scope. Dependency declarations are centralized, for example:

```text
Network events        -> Network
Console events        -> Console
Runtime events        -> Runtime
CSS events/queries    -> DOM + CSS
Element picker        -> DOM + Inspector + inspect-mode lease
```

Console is deliberately independent of the Runtime capability. Console message
remote objects belong to WebKit's internal `"console"` object group, not to a
DataKit-created `RuntimeObjectGroup`. `Console.messagesCleared` is emitted only
after WebKit has released that group. The reducer therefore resets Console
messages and makes their local `RuntimeObject` values stale without acquiring
Runtime or sending `Runtime.releaseObjectGroup`.

Element picking becomes a dedicated scoped operation rather than a Boolean
`DOM.setInspectMode` that cannot represent multiple users:

WebKit owns picker selection on the physical main-page agents. Its `Inspector`
protocol excludes frame targets, `FrameInspectorController` installs no
`InspectorAgent`, and the frame `DOM.requestNode` implementation is an explicit
unsupported stub. Consequently an `Inspector.inspect` payload is always decoded
against the main page, `DOM.requestNode` is sent to that same page DOM agent, and
the returned node identifier remains in the unscoped main-page DOM namespace.
There is no frame-origin fallback or synthetic frame scope. WebKit may emit the
`DOM.setChildNodes` path needed by `requestNode` before its reply; after that
reply the core publishes the picker selection with a new ordered event sequence.

The picker lease registers before `Inspector.enable`, ignores enable-time pending
inspect replay until `DOM.setInspectModeEnabled(true)` succeeds, and becomes
active only after that reply. Release first disables inspect mode and then
balances the Inspector capability. The core sends `Inspector.initialized` once
per Inspector-capable physical page generation, not once per picker lease. A
page generation, DOM document epoch, or picker lease change invalidates an
in-flight resolution instead of retrying it against a different page or
inventing an `unknown` DOM event.

```swift
try await page.dom.withElementPicker { selections in
    for try await item in selections {
        switch item {
        case .reset:
            resetSelectionState()
        case .event(_, let selection):
            consume(selection)
        }
    }
}
```

### Target semantics

`WebInspectorPage` is a logical current-page route that survives navigation and
process replacement. The physical target record and synthetic `.currentPage`
route become package/internal implementation details. Public command DTO IDs
such as `FrameID`, `DOM.Node.ID`, and `Network.Request.ID` remain opaque and
Sendable, but internally carry their originating page generation. Passing an
old scoped ID to a current-generation command fails locally with
`staleIdentifier`; it is never sent to the replacement target.

When no physical page is temporarily committed, a command fails with
`pageUnavailable`; it does not guess a stale target. During commit the core
performs the following ordered transport transition. The current ProxyKit slice
establishes its synchronous reset, physical target snapshot, future-delta
prefix, capability-owner reconciliation onto the new physical target, DOM
bootstrap, wire capability replay watermarks, and the binding-level
synchronization record described above. DataKit application of that feed
remains a later slice:

1. stop admission of new target-scoped commands and increment page generation;
2. publish `.reset(newGeneration)` to public scopes and the package model feed;
3. invalidate old scoped IDs/replies, install the committed registry binding,
   and retarget only pending replies that belong to the committing provisional
   target;
4. reconcile desired logical capability leases against fresh physical
   activation state for that binding while continuing to buffer provisional
   and enable-time events with transport sequence numbers;
5. release the new-generation buffer in original transport order, then publish
   each capability's replay/bootstrap-complete watermark;
6. publish `synchronizationComplete`, mark the binding ready, and resume command
   admission.

No old-generation event can be enqueued after the reset boundary. A destroyed
old target is not sent disable commands through the new binding; its activation
state is discarded by generation. Queue overflow during the transition is a
connection failure, never a partial release. DataKit clears all binding-scoped
state when it applies the reset record and cannot observe new replay before that
clear. If capability reacquisition fails, the connection and model feed fail
instead of exposing a partially ready generation.

The capability registry stores desired logical lease count separately from
physical activation state `(generation, enabling/enabled/disabling)`. Because
an actor can reenter while awaiting enable, completion always reconciles against
the latest desired count and generation. A final release during retarget may
finish an in-flight enable only to balance it with disable; a late acquire joins
the current desired count; completion from an old generation is discarded and
can never mark the new binding enabled.

### Failure and buffering contract

`WebInspectorProxyError` will distinguish at least:

```swift
public enum WebInspectorProxyError: Error, Sendable {
    case closed
    case pageUnavailable
    case staleIdentifier
    case commandRejected(method: String, message: String)
    case protocolViolation(String)
    case eventBufferOverflow(capacity: Int)
    case transportFailure(String)
}
```

- A known event that fails typed decoding terminates the connection with
  `protocolViolation`.
- An unknown method remains representable as `RawEvent` where the existing API
  promises unknown-event delivery.
- Malformed root JSON, ingress overflow, and provisional-target queue overflow
  terminate the connection; they are never silently dropped.
- Protocol event streams use bounded oldest-first buffering. The first drop
  terminates only that subscriber with `eventBufferOverflow`; peer subscribers
  continue.
- The package model feed is also bounded. Overflow currently terminates the feed
  and connection. The later DataKit driver maps that terminal failure to
  `WebInspectorModelContext.Failure.feedBufferOverflow(capacity:)`; a mixed-feed
  drop cannot truthfully attribute the failure to one domain. Neither layer may
  fabricate a full domain resynchronization.
- Coalescible state notifications use newest-one buffering.
- Unexpected disconnect throws from event scopes. Explicit close ends scopes
  normally after all close work completes.
- Unbounded buffering remains explicit opt-in, never the default.

The context reducer owns the overflow transition in every lifecycle phase, and
every overflow puts the context in
`.failed(.feedBufferOverflow(capacity:))`. During attach/synchronization, shared
transition waiters also throw that `Failure`. After attach has returned, state
observation reports the failure; attachment is not retroactively failed. Before
publishing `.failed`, the same reducer invalidates all model command authority,
makes connection-scoped identities/resources stale or terminal, and resets
every store. Existing DOM tree and fetched-results owners publish a full empty
reset through their current identity and remain registered for recovery. New
queries and all subsequent domain operations reject with the recorded `Failure`
while the context is failed; state observation and explicit attach/detach/close
remain available. An explicit attach from `.failed` tears down the poisoned
connection, starts a new attachment generation, and delivers the new
reset/snapshots through those existing result owners.

The implementation uses standard `AsyncThrowingStream<Element, any Error>` and
throws concrete `WebInspectorProxyError` values. A custom typed-failure sequence
is rejected because Swift 6.3's stream construction APIs are restricted to
`Failure == Error` and the extra implementation surface does not improve the
consumer story.

### Proxy consumer migration

```swift
// Before: enable and iteration are separate, so initial replay can be lost.
let target = try await proxy.waitForCurrentPage()
try await target.network.enable()
for await event in target.network.events {
    consume(event)
}

// After: registration, enable, iteration, and disable are one scope.
try await proxy.page.network.withEvents { events in
    for try await item in events {
        switch item {
        case .reset:
            resetNetworkState()
        case .event(_, let event):
            consume(event)
        }
    }
}
```

## DataKit API Sketch

DataKit introduces `WebInspectorModelContext` as a non-`Sendable` semantic model
owner. It may be constructed before entering an actor, but attachment binds its
mutable graph to the actor that calls `attach(to:)`. The UIKit
`WebInspectorSession` stores one such context on MainActor; a custom actor may
store and attach a different context using the same public API.

```swift
public enum WebInspectorModelError: Error, Equatable, Sendable {
    case detached
    case synchronizing
    case domainNotConfigured(WebInspectorModelContext.Domain)
    case staleModel
    case commandRejected(method: String, message: String)
}

@Observable
public final class WebInspectorModelContext {
    public struct PageGeneration: Hashable, Sendable { /* opaque */ }

    public struct Configuration: Sendable {
        public let domains: Set<Domain>
        public init(
            domains: Set<Domain> = [.dom, .network, .console, .runtime, .css]
        )
    }

    public struct Domain: Hashable, Sendable {
        public static let dom: Domain
        public static let network: Domain
        public static let console: Domain
        public static let runtime: Domain
        public static let css: Domain
    }

    public enum ConnectionFailure: Equatable, Sendable {
        case closed
        case pageUnavailable
        case protocolViolation(String)
        case transport(String)
    }

    public enum Failure: Error, Equatable, Sendable {
        case connection(ConnectionFailure)
        case bootstrap(domain: Domain, message: String)
        case feedBufferOverflow(capacity: Int)
    }

    public enum TransitionError: Error, Equatable, Sendable {
        case superseded
        case closed
    }

    public enum State: Equatable, Sendable {
        case detached
        case attaching
        case synchronizing(PageGeneration)
        case attached
        case detaching
        case closed
        case failed(Failure)
    }

    public private(set) var state: State
    public private(set) var attachmentGeneration: UInt64
    public private(set) var pageGeneration: PageGeneration?

    public let configuredDomains: Set<Domain>
    public var domTree: DOMTreeController { get throws }
    public var rootDOMNode: DOMNode? { get throws }
    public var selectedDOMNode: DOMNode? { get throws }
    public var isElementPickerEnabled: Bool { get throws }
    public var runtimeContexts: [RuntimeContext] { get throws }

    public init(configuration: Configuration = .init())

    @MainActor
    public convenience init(
        attachingTo webView: WKWebView,
        configuration: Configuration = .init(),
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws

    public func attach(
        to proxy: WebInspectorProxy,
        isolation: isolated (any Actor) = #isolation
    ) async throws

    public nonisolated(nonsending) func detach() async
    public nonisolated(nonsending) func close() async
    public nonisolated(nonsending) func reload(
        ignoringCache: Bool = false
    ) async throws

    public func domNode(id: DOMNode.ID) throws -> DOMNode?
    public func domTree(rootedAt node: DOMNode) throws -> DOMTreeController
    public nonisolated(nonsending) func requestDOMChildren(
        of node: DOMNode,
        depth: Int = 1
    ) async throws
    public func selectDOMNode(
        _ node: DOMNode?,
        reveal: DOMRevealPolicy = .selectAndScroll
    ) throws
    public nonisolated(nonsending) func copyText(
        _ kind: DOMNode.CopyTextKind,
        for node: DOMNode
    ) async throws -> String
    public func selectorPath(for node: DOMNode) throws -> String
    public func xPath(for node: DOMNode) throws -> String
    public nonisolated(nonsending) func setDOMAttribute(
        _ name: String,
        value: String,
        on node: DOMNode,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome
    public nonisolated(nonsending) func setOuterHTML(
        _ html: String,
        of node: DOMNode,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome
    public nonisolated(nonsending) func removeDOMNodes(
        _ nodes: [DOMNode],
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws
        -> DOMMutationOutcome
    public nonisolated(nonsending) func highlightDOMNode(
        _ node: DOMNode
    ) async throws
    public nonisolated(nonsending) func hideDOMHighlight() async throws
    public nonisolated(nonsending) func setElementPickerEnabled(
        _ enabled: Bool
    ) async throws

    public nonisolated(nonsending) func networkRequests(
        matching query: NetworkQuery = .init()
    )
        async throws -> WebInspectorFetchedResults<NetworkRequest>
    public nonisolated(nonsending) func consoleMessages(
        matching query: ConsoleQuery = .init()
    )
        async throws -> WebInspectorFetchedResults<ConsoleMessage>
    public func networkRequest(id: NetworkRequest.ID) throws -> NetworkRequest?
    public nonisolated(nonsending) func clearNetworkRequests() async
    public nonisolated(nonsending) func clearConsoleMessages() async throws
    public nonisolated(nonsending) func responseBody(
        for request: NetworkRequest
    ) async throws -> NetworkBody

    public func withRuntimeObjectGroup<Result>(
        named: String? = nil,
        isolation: isolated (any Actor) = #isolation,
        _ operation: (RuntimeObjectGroup) async throws -> Result
    ) async throws -> Result

    public nonisolated(nonsending) func cssStyles(
        for node: DOMNode
    ) async throws -> CSSStyles
    public nonisolated(nonsending) func refreshCSSStyles(
        for node: DOMNode
    ) async throws
    public nonisolated(nonsending) func setCSSProperty(
        _ property: CSSStyleProperty,
        enabled: Bool,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability?
    public nonisolated(nonsending) func setCSSDeclarationText(
        _ text: String,
        for property: CSSStyleProperty,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability?
    public nonisolated(nonsending) func setCSSRuleSelector(
        _ selector: String,
        for rule: CSSStyleRule,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability?
    public nonisolated(nonsending) func setCSSStyleSheetText(
        _ text: String,
        for styleSheetID: CSS.StyleSheet.ID,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability?
}
```

`Domain` is a closed-construction public value: consumers can combine and store
the five known static members but cannot manufacture a domain the model feed
cannot support or enumerate cases through a public conformance. `Page` remains
a ProxyKit command/lifecycle concern and is not a configured DataKit model
domain. The package-only exhaustive `ModelDomain` enum owns normalization,
dependency expansion, ordering, and every switch. A
package-only protocol or witness may share mechanics among those cases, but
DataKit promises neither consumer-defined domains nor public conformances.

`attach(to:)` returns only after every configured domain has acquired its event
scope and the single ordered feed has applied every configured domain's initial
replay or bootstrap completion boundary followed by the binding-level
`synchronizationComplete`. It also establishes the context's owner actor; the
context must already be stored and used on that actor and may not be transferred
after attachment. A second attach to the same proxy while an attach is in flight
joins that transition. A physical retarget moves the state to
`.synchronizing(newGeneration)` until the same readiness condition is met.
Attaching a different proxy supersedes the old transition, makes its waiters
throw `TransitionError.superseded`, awaits complete teardown, and begins the new
attachment. `detach()` is idempotent and leaves the context reusable on the same
actor. Retry is allowed from `.failed`; `close()` is idempotent and terminal.

The supplied Proxy connection is exclusively owned by the context for the model
attachment lifetime. The package model feed must be its first model consumer;
an already claimed feed fails fast instead of manufacturing missing replay.
UIKit creates that Proxy on MainActor before calling the same context API. A
custom actor receives the Sendable Proxy from its MainActor attachment host and
then calls `attach(to:)` on its actor-confined context.

An attach waiter does not own the shared context resource: cancelling one caller
cancels only that wait. Explicit `detach()`/`close()` changes resource state.
Every transition is serialized by one owner-confined state machine despite
actor reentrancy. Failure is carried only by `State.failed`; there is no
separately mutable optional error.

The context never retains its actor. Attachment stores only its weak identity
for a feed-boundary executor precondition and creates one detached feed-driver
task that weakly captures the caller actor plus a private delivery bridge.
The bridge is the sole DataKit `@unchecked Sendable` escape hatch: it owns no
semantic or lifecycle state and holds only a weak context reference. For each
Sendable record, the driver obtains the weak actor, calls
`apply(record:isolation:)` to hop to it, and only then dereferences the weak
context. `detach()` and `close()` cancel and await the driver; ordinary `deinit`
cancels it synchronously. This prevents both
`actor -> context -> actor` and `actor -> context -> task -> actor` cycles.
The bridge's weak context is bound exactly once during first attachment by a
method isolated to the owner actor. Every later method that reads it has the same
isolated actor parameter, and the bridge is private and never escapes the
Context/driver pair. Strict SIL concurrency fixtures and
executor/deallocation tests lock down those unchecked invariants.

Synchronous graph APIs need no owner argument. Async graph APIs are explicitly
`nonisolated(nonsending)` because this package does not enable
`NonisolatedNonsendingByDefault`; they resume on the caller's executor and may
therefore continue to use the non-Sendable graph after suspension. The isolated
parameter is limited to attachment, scoped caller-isolated closures, and the
private delivery hop rather than being repeated through every helper.

A domain not present in the normalized configuration does no startup work. Its
internal store remains reset and facade operations throw
`domainNotConfigured`.
`configuredDomains` is inspectable before attachment, and domain-specific
throwing getters follow the same rule; `nil` from a configured DOM getter means
"no current document/selection", never "this domain was silently disabled".
Semantic dependencies are explicit: CSS includes the DOM model because its
public API consumes `DOMNode`; protocol-only dependencies such as Inspector for
the picker remain private capabilities. In particular, Network-only startup
does not enable DOM, CSS, Console, Runtime, or Inspector, and a Console-only
configuration does not enable Runtime.

One context-wide generation would be too coarse. Each model owns the epoch that
defines its identities:

| Lifetime boundary | Affected owners |
| --- | --- |
| new attachment | every domain; collections start empty |
| physical page binding/process replacement | every domain; old scoped IDs become stale |
| same-binding document navigation / `DOM.documentUpdated` | DOM and CSS document epochs reset before later DOM/CSS events |
| Runtime execution-context clear | Runtime context/remote-object epoch only |
| explicit Network clear | Network collection revision; retained request handles become stale for body lookup |
| ordinary same-binding navigation | Network history remains unless WebKit emits its own clear; new requests append |
| Console clear event or command | Console collection revision and local validity of Console-originated remote objects; WebKit already owns wire release |

The ordered model feed applies each boundary and its affected store resets before
the next event. Public result/resource types may expose read-only revisions for
rendering, but stale validation uses the internal owning store's epoch rather
than the context's attachment counter.

### Internal stores and the public facade

No public `WebInspectorDOMModel`, `WebInspectorNetworkModel`,
`WebInspectorConsoleModel`, `WebInspectorRuntimeModel`, or corresponding
`*Store` type is introduced. Such types would only add a second navigation path
to state already represented by identity models, result snapshots, and scoped
resources.

The package-internal stores in the owner map are justified only by moving whole
write sets out of `WebInspectorContext`:

- `DOMStateStore` owns the node identity registry, document epoch, root,
  selection, tree projection registrations, picker/highlight state, and undo
  binding.
- `NetworkRequestStore` and `ConsoleMessageStore` own canonical identity maps,
  collection epochs, weak fetched-results registrations, and compact Sendable
  records passed to their query indexes.
- `RuntimeStateStore` owns execution-context identity and object-group
  membership.

CSS does not introduce another store. A `CSSStyles` resource is keyed by a
registered `DOMNode`, becomes stale with that node's document epoch, and is
discarded with the node, so its membership and lifetime belong to
`DOMStateStore`. `WebInspectorModelContext` coordinates awaited CSS protocol I/O
and applies each result back through that owner; it does not keep a parallel CSS
identity map or CSS epoch.

They are implementation owners, not observable facade objects. They do not
mirror one another, and a store is not added until the corresponding Context
properties and writers are deleted. `WebInspectorModelContext` forwards public
operations to the sole owner without caching a second copy of domain state.

The existing public resource/result contracts remain the domain surface:

| Domain | Public values/resources retained |
| --- | --- |
| DOM | `DOMNode`, `DOMTreeController`, `DOMTreeSnapshot`, `DOMTreeUpdate`, `DOMTreeDelta`, reveal/reset values |
| Network | identity-preserving `NetworkRequest`, `WebInspectorFetchedResults`, fetched-results snapshot/transaction |
| Console | identity-preserving `ConsoleMessage`, `WebInspectorFetchedResults`, fetched-results snapshot/transaction |
| Runtime | `RuntimeContext`, evaluation values, and scoped `RuntimeObjectGroup` |
| CSS | `CSSStyles`, sections, rules, declarations, properties, and computed properties |

Every mutable identity/resource/result class in this table—including
`DOMNode`, `DOMTreeController`, `NetworkRequest`, `ConsoleMessage`, and
`CSSStyles`—is non-`Sendable` and belongs to its model context's actor. Only its
immutable Sendable snapshot/delta/record values cross to index, transport, or a
different consumer actor. A context owned by a custom actor cannot vend its
identity handles to UIKit; that consumer creates a MainActor-owned context or
passes value snapshots instead.

DOM tree topology therefore also remains snapshot-plus-delta based; it is not
replaced by an observable node array. `model.domTree` is the stable root tree,
and `model.domTree(rootedAt:)` produces a live subtree result. Selection reveal
intent is ordered with tree updates and consumed explicitly by UIKit so
`.none`, `.selectOnly`, and `.selectAndScroll` retain their documented meaning.
Tree subscription continues to register and enqueue its initial snapshot as one
synchronous owner operation. Its update broker becomes bounded: if a subscriber
falls behind, pending deltas coalesce to one current full snapshot (with an
explicit coalescing reset reason) before later deltas, rather than accumulating
an unbounded queue or applying a delta across a gap.

Each Sendable DOM delta is self-contained across actors: it carries base and new
revisions, detached node-value upserts, removals, updated parent/child topology,
the current root and selection, and optional reveal intent. One semantic
mutation publishes one revision. Reveal is not a separately ordered stream.

Every DOM mutation returns a `DOMMutationOutcome` containing applied IDs,
per-node failures, and an optional document-epoch-bound `DOMUndoCapability`.
UIKit registers that capability with `UndoManager`; a custom UI can use the same
public contract. Undo/redo after document replacement throws `staleModel`.
Model identity convenience methods no longer dispatch commands themselves, and
every mutation awaits its protocol result. CSS lookup never changes DOM
selection, CSS mutations return the same optional undo capability, and
fire-and-forget CSS mutation is removed.

`cssStyles(for:)` awaits the initial load and returns the node's stable
`CSSStyles` resource without selecting that node. Later protocol changes mark
the resource `.needsRefresh`; they do not start an invisible background task.
A visible UIKit/custom consumer observes that phase and calls the awaited
`refreshCSSStyles(for:)`. A cached but hidden controller does nothing, and on
its next appearance refreshes once if stale. Thus presentation lifecycle owns
refresh demand without a global hydration Boolean, lease, or retained task.

```swift
public struct DOMMutationFailure: Error, Hashable, Sendable {
    public let nodeID: DOMNode.ID
    public let message: String
}

public struct DOMMutationOutcome {
    public let requestedNodeIDs: [DOMNode.ID]
    public let appliedNodeIDs: [DOMNode.ID]
    public let failures: [DOMMutationFailure]
    public let undo: DOMUndoCapability?
}

public final class DOMUndoCapability {
    public nonisolated(nonsending) func undo() async throws
    public nonisolated(nonsending) func redo() async throws
}

public final class RuntimeObjectGroup {
    public nonisolated(nonsending) func evaluate(
        _ expression: String,
        in context: RuntimeContext? = nil
    ) async throws -> RuntimeEvaluation

    public nonisolated(nonsending) func properties(
        of object: RuntimeObject,
        ownProperties: Bool = true
    ) async throws -> [RuntimeProperty]

    public nonisolated(nonsending) func preview(
        of object: RuntimeObject
    ) async throws -> RuntimeObjectPreview
    public nonisolated(nonsending) func close() async throws
}

public struct WebInspectorRuntimeScopeError: Error {
    public let operationError: any Error
    public let cleanupError: any Error
}
```

### Concrete collection queries

Network and Console queries use closed semantic enums rather than arbitrary key
paths:

```swift
public struct NetworkQuery: Sendable, Equatable {
    public var search: String?
    public var resourceCategories: Set<NetworkRequest.ResourceCategory>
    public var methods: Set<String>
    public var sort: NetworkSort
    public var section: NetworkSection?
    public var offset: Int
    public var limit: Int?

    public init(
        search: String? = nil,
        resourceCategories: Set<NetworkRequest.ResourceCategory> = [],
        methods: Set<String> = [],
        sort: NetworkSort = .requestTimeDescending,
        section: NetworkSection? = nil,
        offset: Int = 0,
        limit: Int? = nil
    )
}

public enum NetworkSort: Sendable, Equatable {
    case requestTimeAscending
    case requestTimeDescending
}

public enum NetworkSection: Sendable, Equatable {
    case method
}

public struct ConsoleQuery: Sendable, Equatable {
    public var levels: Set<Console.Level>
    public var sort: ConsoleSort
    public var section: ConsoleSection?
    public var offset: Int
    public var limit: Int?

    public init(
        levels: Set<Console.Level> = [],
        sort: ConsoleSort = .insertionAscending,
        section: ConsoleSection? = nil,
        offset: Int = 0,
        limit: Int? = nil
    )
}

public enum ConsoleSort: Sendable, Equatable {
    case insertionAscending
    case insertionDescending
}

public enum ConsoleSection: Sendable, Equatable {
    case level
}

public struct WebInspectorFetchSection<Model: Identifiable>: Identifiable {
    public let id: WebInspectorFetchSectionID
    public let title: String?
    public let items: [Model]
}

public struct WebInspectorFetchedResultsTransaction<
    ItemID: Hashable & Sendable
>: Sendable {
    public let oldSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    public let newSnapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    public let isReset: Bool
    public let sectionChanges: [WebInspectorFetchedResultsSectionChange]
    public let itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>]
}

public enum WebInspectorFetchedResultsUpdate<
    ItemID: Hashable & Sendable
>: Sendable {
    case initial(
        revision: UInt64,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    )
    case transaction(
        revision: UInt64,
        transaction: WebInspectorFetchedResultsTransaction<ItemID>,
        reconfigureItemIDs: Set<ItemID>
    )
}

@Observable
public final class WebInspectorFetchedResults<Model: Identifiable>
where Model.ID: Hashable & Sendable {
    public var items: [Model] { get }
    public var sections: [WebInspectorFetchSection<Model>] { get }
    public var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID> { get }
    public var revision: UInt64 { get }
    public subscript(id id: Model.ID) -> Model? { get }

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

Empty Network category/method sets and an empty Console level set mean “all.”
Query initializers normalize an empty or whitespace-only Network search to
`nil`, and fail fast for negative offsets or limits. Unsupported predicates,
sort keys, and sections are unrepresentable.
`WebInspectorFetchedResults` stores items, sections,
snapshot, revision, and its concrete query in one private state value and
replaces that value once per publication. Its public properties are computed
projections, so Observation cannot expose a mixed revision/snapshot state.
`WebInspectorFetchSection` and `WebInspectorFetchedResultsTransaction` change
from the deleted `WebInspectorFetchableModel` constraint to `Identifiable` and
`ItemID` constraints respectively; their existing section/item delta vocabulary
is retained.

`updates()` synchronously registers on the owning actor and enqueues the current
`.initial` value before returning. Subsequent transactions are part of that same
subscription, closing the current public `snapshot`-then-`transactions` gap.
The stream uses newest-one buffering. Every transaction carries both old and
new full identity snapshots plus its delta and revision, so a consumer that
misses an intermediate revision replaces its local diffable snapshot with the
new full snapshot; a contiguous consumer applies the delta. Before first
consumption, coalescing advances the pending `.initial` to the newest complete
snapshot while preserving it as the stream's first element. Thus slow consumers
converge without unbounded backlog or silent stale state.

Identity objects remain stable. A property-only mutation emits updated item IDs
when rendering must refresh; a topology-affecting mutation also emits the
section/item delta. The per-subscriber broker unions `reconfigureItemIDs` from
every dropped update into the newest retained update. Consequently a slow
diffable consumer reconfigures every identity whose property update it skipped,
even when the full topology snapshot itself did not change. The internal stores
retain live results only weakly, so discarding results unregisters them without
keeping the model context alive.
The zero-state `WebInspectorFetchedResultsController` forwarding wrapper is
deleted; the snapshot, transaction, and result types are retained.

Concretely, each subscriber owns one mutex-protected pending update. A
publication resumes a waiting consumer directly; otherwise it atomically
replaces the pending update with the newest revision/snapshot and unions the
still-present IDs from both reconfiguration sets. The resulting revision gap
tells the consumer to use the full newest snapshot, while the union preserves
all applicable cell reconfiguration work. Delivery never relies on a second
`AsyncStream.Continuation.yield` racing to replace an already-visible element.

The existing `NetworkRequestIndex` actor remains the off-owner query/diff owner
and is improved rather than replaced. It consumes compact Sendable record
changes and owns each registered query's filter, membership, order, section,
window, generation, and last mutation sequence. `NetworkRequestStore` owns model
identity resolution and weak result registration; neither the Store nor the
caller actor evaluates a full model graph to create or replace a query.

Store mutations allocate one scalar sequence and submit exactly one replace or
upsert operation. The index drains only the next contiguous
sequence, so cross-actor scheduling cannot create a checkpoint hole. Result
creation first records an initializing `(registrationID, generation)` in the
Store and passes the current minimum mutation sequence to the index. After the
index drains through that sequence, it installs the registration and computes
its initial compact projection in the same actor turn. Later projections that
reach the Store before result creation resumes coalesce to the newest complete
generation/sequence. The Store installs the initial projection plus that
pending state into one `WebInspectorFetchedResults` state value, adds the weak
live registration, and only then returns the result.

Query replacement uses an index-owned two-phase candidate. The old active query
continues receiving mutations while the candidate scans. Cancellation or
supersession before candidate commit discards only the candidate. The Store
commits only its newest requested generation; once the index commits that
generation, the Store completes one atomic result publication even if the
calling task is subsequently cancelled. Mutations between index commit and
owner publication coalesce into that generation's pending complete projection.
Stale generations never publish and no retry-until-stable loop or later
mutation is required for convergence.

Each result owns an immutable registration lifetime token. The Store retains the
result weakly and the index retains the token weakly, so dropping the result
immediately makes the registration inactive without starting an unstructured
cleanup task. Every structured index entry prunes inactive registrations before
query work. Network clear and Console clear/reset are asynchronous boundaries:
they publish an index source-epoch reset and all resulting empty/replacement
states before returning or completing feed application.

Lifecycle transitions split that reset into a synchronous semantic prepare and
an asynchronous index finish. `start` clears the prior Network attachment,
detach clears all attachment-backed state, and a committed-page transition
clears DOM, Runtime, and Console state in the transition's actor turn. Legacy
and concrete results become empty in that same turn; only the compact index
source-epoch reset is awaited afterward. A destroyed current-page route
intentionally keeps its last DOM snapshot visible during the bootstrap grace
period, but clears Runtime and
Console stream state immediately. Once a replacement is obtained, DOM resets
before retarget enablement and the already-cleared streams are not cleared a
second time, so early replacement events cannot be erased.

The facade's result-creation methods are `async` so their first filtered/sorted
snapshot is complete before return without doing that scan on the owner actor.
Console receives the same internal index boundary. Newest-one delivery caps
each result's queued topology state at one self-contained snapshot. Benchmarks
and operation-count tests at 10,000 records guard Network and Console initial
query, live insert/update, query replacement, and a stalled subscriber.

Migration sequencing keeps `WebInspectorFetchDescriptor`, its Context overloads,
and the legacy predicate/key-path planners only while repository consumers move
to these concrete APIs. They remain compatibility build paths in the first query
core and UI commits and are deleted together in the third query commit. During
that compatibility window, a concrete-query result's inherited
`fetchDescriptor` is an inert empty descriptor, not a second query source of
truth. Descriptor-backed results accept only `updateFetchDescriptor`, while
results created by `networkRequests(matching:)` or `consoleMessages(matching:)`
accept only their domain `update(_:)`; both mismatches fail before either owner
mutates. The third query commit removes the descriptor factories, descriptor
update path, inherited descriptor/section properties, mutable request builder,
and legacy planners once repository and Contract consumers no longer reference
any of them. Nonoptional constrained `query` properties shown above are added in
that same deletion commit, when every surviving result has a concrete query
origin.

### Runtime object lifetime

`Runtime.evaluate` in ProxyKit gains an object-group parameter. DataKit
evaluations returning remote handles require a `RuntimeObjectGroup`. The group
has explicit `close() async throws`, and `withObjectGroup` always awaits release
on scope exit. Wire names are unique and include the model attachment and page
generation; a group and every object it returns retain that binding internally.
After target replacement, operations throw `staleModel`, while local close
invalidates the group without sending release to the new target (the old target
has already destroyed its objects).

This explicit lifetime applies only to groups DataKit creates. DataKit never
adopts or releases WebKit's internal `"console"` group. When
`Console.messagesCleared` arrives, `ConsoleMessageStore` invalidates the local
Console-originated `RuntimeObject` ownership and clears its results; it sends no
`Runtime.releaseObjectGroup` because WebKit performed that release before the
event. Releasing again would give two layers authority over one remote resource.

Cleanup errors are never hidden. If the body succeeds and release fails, the
release error is thrown. If the body fails and release succeeds, the original
error is rethrown. If both fail, `WebInspectorRuntimeScopeError` carries both,
with the operation error as primary. No deinitializer launches a task to release
a remote object.

### Observation and UI flow

Semantic identity state is caller-confined `@Observable`; ordered collection
topology uses the retained DOM/fetched-results snapshot-plus-delta contracts.
UIKit creates its context on MainActor, observes identities through
ObservationBridge, and consumes topology updates into diffable/native snapshots.
A custom actor can observe its own context on that actor, but it must explicitly
cancel and release any stored observation token: an isolated callback's metadata
retains the actor even when its closure captures `self` weakly. Sendable update
streams are preferred when publishing out of that actor. Controllers may own
selection presentation, row expansion, scroll position, and render caches, but
may not mirror DOM nodes, Network requests, connection state, or model readiness.

WebInspectorUI keeps a distinct presentation owner:

```swift
@MainActor
@Observable
public final class WebInspectorSession {
    public let model: WebInspectorModelContext
    public private(set) var pageUserInterfaceStyle: UIUserInterfaceStyle

    public init(
        tabs: [WebInspectorTab] = [.dom, .network],
        additionalDomains: Set<WebInspectorModelContext.Domain> = []
    )

    public func attach(to webView: WKWebView) async throws
    public func detach() async
    public func close() async
}

public struct WebInspectorTab: Identifiable {
    public let requiredDomains: Set<WebInspectorModelContext.Domain>

    public init(
        id: ID,
        title: String,
        systemImage: String,
        requiredDomains: Set<WebInspectorModelContext.Domain> = [],
        makeViewController: @escaping @MainActor (WebInspectorSession)
            async throws -> UIViewController
    )
}
```

The UI session owns tab/interface selection and `pageUserInterfaceStyle`
observation. Its model configuration is the union of `additionalDomains` and
every tab's declared requirements: built-in DOM requires DOM + CSS, built-in
Network requires Network, and a custom Console tab declares Console. It
creates a fresh Proxy for the web view, passes it to `model.attach(to:)`, and
does not copy model lifecycle or domain state.

`WebInspectorViewController(session:)` and convenience `init(tabs:)` remain the
public UIKit entry points. Content controllers are retained by tab/session
identity, not page generation. They observe domain epoch/reset updates, replace
only stale semantic resources, and reset only the presentation state whose
lifetime is domain-bound; process replacement does not gratuitously discard
scroll/layout state or recreate a custom tab controller.

Root/custom controller cache identity is independent of semantic resource
generation. An attachment or page epoch is never a reason to evict every cached
controller. Root teardown (and, if tabs later become mutable, explicit
descriptor removal) owns controller eviction. Public DataKit results publish an
epoch reset through their existing identity. Separately, a model/context epoch
may advance an affected root-owned presentation-resource generation; existing
built-in resource hosts render that owner's replacement state in place.

The root `WebInspectorViewController`, not `WebInspectorSession`, owns the
content-controller cache and retirement. A custom controller may strongly retain
the session it receives without forming
`session -> cache -> controller -> session`; the session has no edge back to the
root or cache. Root presentation teardown releases/retires controllers, awaits
picker stop and highlight hide, and optionally awaits model detach. Cleanup
failure is logged at that UI lifecycle boundary rather than swallowed.
Page-style observation is invalidated synchronously by the UI session's isolated
deinitializer.

The built-in Network tab cannot synchronously create its first concrete query:
`NetworkPanelModel.make(context:)` awaits the atomic initial `NetworkQuery`
snapshot and has no empty/default initializer. The root
`PresentationContentStore` therefore owns one Network resource state machine:
`idle`, `loading`, `ready`, or `failed`, together with its context epoch,
generation, task, and revision. Synchronous UIKit selection/layout returns a
native `UIContentUnavailableConfiguration.loading()` container; the same
container replaces loading with ready content or a native failure configuration
in place, so no placeholder model or empty result flashes first.

Resource state and the ready model are shared across compact/regular requests,
but every `UITab` provider receives a fresh container view controller because
UIKit owns that controller identity. A host/layout switch neither closes nor
recreates the resource. A Network semantic-resource generation transition
cancels and awaits the old load/model without clearing the root/custom
controller cache; root `clear()` retires both resources and controllers. A next
resource generation waits for retirement, and a late factory completion is
retired before it can publish.
`InterfaceModel.tabs` is immutable, so there is no runtime tab-removal owner in
this design. If tabs become mutable, ContentKey eviction and awaited resource
retirement must be introduced together instead of treating view disappearance
as resource close.

The Network panel owns its current concrete query. Search/filter mutations form
one latest-wins cancel-and-await chain before calling
`WebInspectorFetchedResults.update(_:)`; clear is a committed operation ordered
in the same chain, and a later query waits for it. Explicit model retirement
cancels and awaits that work. The resource task weakly references the root and
the model's `isolated deinit` synchronously cancels remaining work as a backstop;
explicit root retirement remains the awaited correctness path.

Custom tabs become a real consumer story:

```swift
let tab = WebInspectorTab(
    id: "console",
    title: "Console",
    systemImage: "terminal",
    requiredDomains: [.console]
) { session in
    let messages = try await session.model.consoleMessages()
    return ConsoleViewController(messages: messages)
}
```

The tab receives the UIKit session and reaches canonical DataKit results
through `model`; it does not navigate through a new Console model wrapper.
Reattachment preserves session, root/custom controller, and public
fetched-results owner identities. The result receives its new epoch and reset
snapshot through the existing update contract, so a custom controller needs no
separate replacement signal. The built-in Network presentation owner remains a
distinct case: when its semantic-resource generation changes, it retires the
old panel model and loads the replacement into its existing resource hosts
without evicting the controller cache.

### DataKit consumer migration

```swift
// Before: mainContext starts asynchronously after this property returns.
let container = try await WebInspectorContainer(attachingTo: webView)
let context = container.mainContext
let requests = context.network.fetchedResults(for: descriptor)

// After on MainActor: the convenience initializer returns a ready context.
let context = try await WebInspectorModelContext(
    attachingTo: webView,
    configuration: .init(domains: [.network])
)
let requests = try await context.networkRequests(
    matching: NetworkQuery(sort: .requestTimeDescending)
)

for await update in requests.updates() {
    apply(update) // initial full snapshot, then self-contained deltas
}

// The same context API can instead belong to a custom actor.
actor NetworkAnalyzer {
    private let context = WebInspectorModelContext(
        configuration: .init(domains: [.network])
    )

    func attach(to proxy: WebInspectorProxy) async throws {
        try await context.attach(to: proxy)
    }

    func currentSnapshot() async throws
        -> WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>
    {
        try await context.networkRequests().snapshot
    }
}

let proxy = try await WebInspectorProxy(attachingTo: webView) // MainActor
let analyzer = NetworkAnalyzer()
try await analyzer.attach(to: proxy)
```

### DataKit testing scenarios

`WebInspectorDataKitTesting` owns only the model-level scenario that a DataKit
consumer needs. It composes `WebInspectorProxyTestRuntime`; it does not inject
model records, sequence numbers, generations, snapshots, or semantic store
state.

```swift
let runtime = try await WebInspectorDataKitTestRuntime.start(
    scenario: .init(
        configuration: .init(domains: [.dom, .network]),
        document: .init(children: [
            .element(id: "button", name: "button")
        ]),
        networkReplay: [
            .init(id: "request-1", url: "https://example.test/")
        ]
    )
)

let selected = try await runtime.selectElementWithPicker(nodeID: "button")
try await runtime.replacePage(with: .init())
await runtime.close()
```

The scenario driver replies to the configured domain bootstrap, emits replay
before the matching enable reply, and fails unknown commands immediately. Raw
wire tests remain in ProxyKitTesting; DataKitTesting is the ready-model consumer
contract. The runtime and model inherit the actor supplied to `start`, while
fixture values are Sendable.

## Isolation and Deterministic Teardown

The platform floor is iOS 18.4 and macOS 15.4 in the root package, the native
bridge package, ContractTests, and applicable Xcode deployment settings. Those
are the Swift runtime availability boundaries for non-MainActor isolated
deinitialization.

`isolated deinit` is used where static isolation owns synchronous state:

- `ConnectionCore` (a non-MainActor actor): cancel stored task handles, finish
  external synchronized mailboxes/promises and bounded brokers, and assert
  synchronous terminal state.
- Other non-MainActor actor resources introduced by the final implementation:
  cancel actor-owned task handles and synchronously finish only external
  synchronized primitives whose completion does not require another actor hop.
- `WebInspectorTestPeer`: finish its external command mailbox and receiver
  synchronously; `WebInspectorProxyTestRuntime.close()` remains the primary
  awaited connection teardown.
- `@MainActor NativeAttachment`: synchronously detach the bridge if supported
  by the native primitive and release its inspectability token.
- The per-web-view `@MainActor InspectabilityCoordinator`: keep the original
  value and membership; only the final token release restores it exactly once.

The caller-confined `WebInspectorModelContext` and its identity/resource classes
are ordinary non-Sendable classes, not actors or global-actor classes. Swift
6.3 therefore does not permit `isolated deinit` on them, regardless of the
deployment target. Their correctness path is explicit `detach()`/`close()`;
ordinary `deinit` may only cancel a Sendable task handle and finish an external
synchronized primitive that does not retain the context. It cannot drain a
continuation owned by a suspended instance method whose frame retains the
context. The higher platform floor enables isolated deinitialization for the
actual non-MainActor lifecycle actors instead of forcing the entire observable
graph onto MainActor.

An async actor method frame may retain its actor for the entire suspension. A
continuation stored in that actor therefore cannot be made safe by claiming the
actor's isolated deinitializer will eventually drain it: the suspended frame is
itself allowed to keep deinitialization unreachable. Network/Console query-index
waiters must be cancellation-aware and are drained by explicit close or their
normal terminal owner. The same rule applies to reply waiting. The final
migration replaces the current actor-based `ReplyPromise`—whose suspended
`value()` frame can retain that actor—with an external synchronized terminal
primitive. Its wait does not suspend an actor-isolated method on actor-owned
continuation state; pending-reply close, failure, cancellation, or reply
fulfills it exactly once. `ConnectionCore`'s isolated deinitializer may
synchronously finish that external primitive only as a backstop.

It does not perform:

- asynchronous connection close;
- protocol domain disable;
- remote Runtime object/group release;
- work intended to break an existing retain cycle;
- `Task { await self.close() }` or any escaping use of a deinitializing `self`.

An isolated deinitializer may be enqueued after the executor's current work, so
explicit close remains the correctness path. Tests cover both explicit teardown
and the synchronous fallback. The redesign removes the strongly stored
`any Actor`, repeated `requireOwner`, and per-method isolation plumbing. One
defaulted isolated parameter remains at context attachment, and one private
delivery hop applies feed records on that actor.

Every stored long-running task follows the same acyclic rule: owner -> task is
allowed only when the task captures the owner weakly and does not retain it
across the next suspension. A weak capture followed by one long-lived
`guard let self` is not sufficient. Backend callbacks also capture their
receiver weakly. Explicit close cancels and awaits tasks and drains
cancellation-aware waiters; dropping all public handles can therefore reach the
isolated deinitializer even when close was omitted. No deinitializer is expected
to break a cycle or terminate an async frame that retains its actor.

## Access Control

| Surface | Access | Reason |
| --- | --- | --- |
| Proxy, logical page, concrete struct domain handles/DTOs, structured event scopes | `public` | direct ProxyKit consumer story; package-only protocols share known-domain mechanics |
| Physical target records, target registry, routing keys, capability registry | `package` or `internal` | one core owns routing; no external producer story |
| DataKit model context, identity models, existing tree/query/resource types, concrete queries | `public` | caller-confined custom UI/headless story without facade proliferation |
| Domain stores, mutation/event application, generation replacement, protocol adapters | `package` or `internal` | preserve one writer per model; stores are not public navigation API |
| UIKit composition controllers | `package` | built-in implementation detail |
| Inspector root controller and tab descriptor | `public` | app integration story |
| Raw-wire `WebInspectorTestPeer`, `WebInspectorTestJSONObject`, and explicit `WebInspectorProxyTestRuntime` | `public` in ProxyKitTesting | direct test consumer drives the production core and owns close completion |
| Ready model scenarios | `public` in DataKitTesting | DataKit consumer contract |

Public setters are limited to value-type configuration and query values. Model
state uses `public private(set)`. No `open` declarations are introduced.

`WebInspectorTestPeer` exposes raw outbound command correlation and exact-once
reply/failure, raw root/target events, target lifecycle wire helpers, and
connection close/failure. It never accepts decoded semantic events, transport
sequence numbers, model generations, document epochs, or replay markers; the
production core derives all of those. `WebInspectorProxyTestRuntime` owns the
proxy/peer/page tuple and provides explicit async close. Queueing replies,
deferred gates, typed fixture encoding, and command assertions belong to the
package test-support driver and are not product API.

## Deletions and Consolidations

The migration removes rather than deprecates the following surfaces:

- `WebInspectorProxy.currentPage`, `waitForCurrentPage()`, `canReload`, and the
  duplicate proxy-level `reload()`.
- Public `WebInspectorTarget` as a logical-current-page facade, synthetic
  `.currentPage` routing, and `pageBindingID` duplication.
- Domain `enable()`, `disable()`, cold `events`, public EventStream wrappers, and
  DataKit's subscriber barrier/domain enablement registry.
- `WebInspectorContainer`, the strongly owner-retaining `WebInspectorContext`,
  per-domain EventPumps, dynamic `requireOwner`, and public/model
  `@unchecked Sendable` ownership claims. They are replaced by one
  caller-confined `WebInspectorModelContext` and one weak delivery bridge.
- Stateless computed `DOMModelController`, `NetworkModelController`,
  `ConsoleModelController`, `RuntimeModelController`, `CSSModelController`,
  `PageModelController`, and forwarding `WebInspectorEditHistory` wrapper,
  all removed in this slice.
- Duplicate direct Context/model convenience operations after their
  `WebInspectorModelContext` facade operation or scoped-resource equivalent
  exists.
- `WebInspectorFetchableModel`, generic `WebInspectorFetchDescriptor`,
  arbitrary key-path sort/section descriptors,
  `WebInspectorFetchRequest`, `WebInspectorMutationOptions`,
  `WebInspectorStaleModelPolicy`, and
  `WebInspectorFetchedResultsController`.
- The FRC-owned, separately-created transaction stream. Snapshot and delta
  updates remain, but one atomic `WebInspectorFetchedResults.updates()`
  registration owns their ordering and bounded buffering.
- The UI session's `WebInspectorContainer`/detached-context storage and mirrored
  attachment generation; it retains one MainActor-owned DataKit model context
  plus genuine presentation state.
- Fire-and-forget CSS mutations and hidden partial-delete errors.
- DataKit's Console-clear `Runtime.releaseObjectGroup` dispatch and any
  Console-to-Runtime capability dependency; WebKit owns its `"console"` group.
- Unbounded intermediate Transport -> LiveBackend -> Proxy stream layers where
  the core broker can route the decoded value directly.

Protocol DTOs that have a direct typed-command story are not deleted merely
because the built-in UI does not currently call them. Contract tests will cover
the public command surface selected for retention.

## Rejected Shapes

- **Weakening only `WebInspectorTarget.proxy`:** fixes one edge of one cycle and
  gives retained targets surprising invalidation semantics.
- **Always consuming the lifecycle stream in Proxy:** refreshes the cache but
  preserves two target sources of truth.
- **A public subscription barrier:** exports the hidden ordering invariant
  instead of owning it.
- **Caching enable replay for every late subscriber:** makes ProxyKit a second
  semantic state store and cannot reconstruct all protocol domains correctly.
- **Keeping domain leases in DataKit:** direct ProxyKit consumers would still
  disable each other's domains.
- **Compatibility adapters around Context/controllers:** keep duplicate
  semantics and extend the migration indefinitely.
- **An observable wrapper around Context:** adds mirror state without changing
  the state owner.
- **Public per-domain `WebInspector*Model` or `WebInspector*Store` facades:**
  duplicate the context navigation surface and do not improve large-collection
  query cost; internal stores exist only as write owners.
- **Moving UIKit `WebInspectorSession` wholesale into DataKit:** leaks tabs,
  page style, and root-owned content loading/retirement into the model layer.
- **One independent DataKit consumer task per domain:** cannot order a page reset
  ahead of every new-binding event and multiplies task lifetime cycles.
- **Reading a snapshot and then creating an independent cold transaction
  stream:** recreates an atomic registration race at the query/UI boundary. A
  single results-owned registration emits current snapshot plus later deltas.
- **A MainActor-only DataKit graph:** makes UIKit convenient but needlessly
  prevents headless parsing, indexing, and inspection state from belonging to a
  custom actor.
- **Sharing one mutable Context across MainActor and a custom actor:** violates
  the SwiftData-like confinement contract. Separate contexts or immutable
  Sendable snapshots/deltas cross that boundary.
- **Strongly storing `any Actor` and checking every method:** recreates the
  current owner cycle and runtime-only API. Attachment captures the actor once;
  public graph confinement is enforced by non-Sendability and Swift's region
  isolation.
- **Making every model generic over an owner actor:** propagates the generic
  through the full identity graph, still cannot bind a specific actor instance,
  and still cannot give an ordinary class an `isolated deinit`.
- **Requiring the consumer to await a permanent `drive(feed:)` scope:** is the
  fully checked alternative to the weak bridge, but makes attachment never
  return and exports model-feed lifetime composition to every caller. One
  audited private bridge is chosen to preserve an attach-then-use API.
- **Async cleanup launched from deinit:** cannot guarantee completion and risks
  escaping deinitializing `self`.
- **Unbounded protocol/model-feed buffers or silent drop:** these streams have
  no general resynchronization contract. Fetched results are distinct: their
  bounded newest update is explicitly self-contained and can resynchronize by
  replacing the diffable snapshot.
- **Transport-wide backpressure from a slow subscriber:** can block command
  replies and target lifecycle for unrelated consumers.
- **Fallback to a stale target/model:** creates a second source of truth and can
  mutate the wrong page.

## Characterization and Acceptance Tests

Tests are added before each owner is replaced. Required cases:

1. An enable handler emits an event before its reply and the structured scope
   receives it exactly once.
2. A late second scope starts with the current reset marker and future events,
   does not claim historical replay, and still shares one enable lease.
3. Two scopes send one enable; ending one sends no disable; ending the final one
   sends one disable.
4. Cancellation while enabling waits for enable and balances it with disable
   without leaking a waiter; final-disable failure follows the documented
   body/cleanup error precedence.
5. Target destroy/commit updates routing with no external lifecycle consumer.
6. Reset, provisional-message drain, enable replay, domain-complete markers,
   and `synchronizationComplete` preserve transport ordering even when an
   old-generation consumer is slow. An empty-domain feed still receives the
   binding-level completion record.
7. A pending reply for the committing provisional target retargets correctly;
   unrelated old-target replies fail rather than moving generations.
8. A stable logical page sends subsequent commands to the new physical binding
   and active capabilities re-enable there.
9. An old scoped DTO identifier passed to a current command fails locally and is
   never encoded for the new target.
10. Old-generation model identities become stale before new replay is applied,
    and attach/retarget synchronization returns only after every configured
    replay/bootstrap-complete record and the following binding-level
    `synchronizationComplete` are applied.
11. DOM attachment and retarget return with a root snapshot ready; a
    `DOM.documentUpdated` racing `getDocument` discards the stale reply, retries,
    and orders the accepted snapshot before later DOM deltas. A frame-target
    `documentUpdated` that is filtered from the public current-page scope still
    emits `domDocumentInvalidated`; DataKit invalidates only that target's
    DOM/CSS authority, ignores pre-bootstrap deltas, and reauthorizes it only
    from the matching snapshot.
12. A capacity-N stream receiving N+1 pending events throws overflow for that
   subscriber while a peer continues. Separately, mixed model-feed overflow
   fails DataKit with `feedBufferOverflow(capacity:)` and does not fabricate a
   domain attribution. Before attach completion the context enters `.failed`
   and the waiter throws; after attach, the same state transition resets existing
   results and rejects operations. Only an explicit re-attach starts a
   recoverable new generation.
13. A malformed known event and malformed root envelope terminate with protocol
   violation; an unknown method remains a raw event.
14. Native fatal callbacks reach the connection terminal cause.
15. Explicit close terminates pending replies and streams, detaches the native
   bridge, restores inspectability, resumes waiters, and is idempotent.
16. Two attachments to one web view keep it inspectable after the first closes
   and restore its original value only after the final close.
17. After close, weak references prove the proxy/core/backend/receiver graph is
   deallocated.
18. Dropping connection handles without explicit close reaches isolated deinit;
   dropping a caller-confined model context reaches ordinary deinit and cancels
   its driver. Weak references prove neither driver retains its context or
   owner actor.
19. Isolated-deinit fallbacks synchronously cancel actor-owned task handles and
    finish only external synchronized primitives. Native attachment fallback
    detaches/restores exactly once. No fallback launches async work or claims to
    drain an actor-local continuation whose suspended frame retains the actor.
20. DataKit `attach()` exposes startup failure and does not return before the
   configured models and binding-level synchronization record are ready.
21. Same-proxy concurrent attach joins, different-proxy attach supersedes, caller
    cancellation cancels only its wait, detach cancels transition state, a
    same-proxy attach during retarget joins `.synchronizing`, and a failed
    context can retry.
22. Final capability release and late acquire during retarget/enabling reconcile
    desired lease count without leaving a stale enable or disabling a live
    lease.
23. A Network-only configuration sends no DOM, CSS, Console, Runtime, or
   Inspector enable command. A Console-only configuration sends no Runtime
   enable command.
24. Same-binding navigation resets DOM/CSS and Runtime as their events require
   while retaining Network history; physical replacement resets all domains.
   `Console.messagesCleared` empties Console results and makes its local remote
   objects stale without sending `Runtime.releaseObjectGroup`.
25. DOM request failures propagate, partial removal exposes applied and failed
    nodes plus epoch-bound undo capability, stale operations consistently throw,
    and tree consumers retain initial-snapshot-plus-delta behavior. A stalled
    tree consumer coalesces to a full snapshot before later deltas.
26. CSS lookup does not change DOM selection and CSS mutations expose backend
   failure.
27. Runtime object groups receive unique binding-scoped names, never release on
   a replacement target, and expose cleanup failure precedence for success,
   body failure, cancellation, and body-plus-cleanup failure.
28. `WebInspectorFetchedResults.updates()` atomically emits current state and
    later transactions. A mutation at setup cannot be missed; a stalled
    subscriber retains at most one self-contained update and converges by full
    snapshot when its revision skips, with dropped property-update IDs folded
    into the retained reconfiguration set.
29. Network and Console 10,000-record tests cover initial query, live
    insert/update, query replacement, and stalled consumption; live inserts do
    not perform whole-model query evaluation on the context's owner actor.
    Cancellation plus explicit index close drains sequence/query waiters; actor
    deinitialization is not used as waiter completion proof.
30. Discarding Network/Console result objects unregisters their weak live-query
    sinks and does not retain the model context.
31. A custom public-only Console tab declares its required domain, obtains
    `session.model.consoleMessages()`, follows reattachment, and retains its
    controller while result epochs reset. The controller may strongly retain
    its UI session; releasing the root cache still deallocates the entire graph.
32. Concurrent requests join one async custom-tab factory; loading, failure,
    retry, and root-close cancellation follow the root-owned content state
    machine without a root/task cycle.
33. UI presentation retirement awaits picker/highlight cleanup, preserves the
   model connection when configured not to detach, and reports cleanup failure.
34. DataKitTesting creates a ready model context, seeds replay, emits picker and
   target-replacement events, injects attach failure, and closes
   deterministically without raw startup scripting.
35. Existing DOM and Network UIKit behavior, including snapshot-plus-delta
    collection topology, reveal intent, selection, editing, and lazy body
    loading, remains covered.
36. The same public model API runs on MainActor and on a custom actor; feed
    application and Observation callbacks execute on the owning actor. A strict
    concurrency compile-fail fixture proves that the context cannot satisfy a
    `Sendable` requirement, while its Sendable snapshots and deltas can cross
    actors. The delivery bridge preconditions the bound executor at runtime for
    deliberate escapes the region checker cannot reject.

Validation gates:

- root package test suite on the shared `WebInspectorKit` iOS simulator scheme;
- public-only `ContractTests` package;
- package build/test for macOS where supported;
- Monocly build/test for its applicable schemes;
- DocC build and link validation;
- `git diff --check` and a clean self-review.

## Measurable Completion Criteria

- The old `WebInspectorContext`, strongly stored `any Actor`, and
  `requireOwner` counts are zero in DataKit. Isolated parameters remain only at
  caller-binding/scoped boundaries and the single private feed-application hop.
- Public domain `enable`, `disable`, cold `events`, and subscription barrier
  counts are zero.
- DataKit owns no domain enable reference-count registry.
- Physical current-page routing decisions exist only in the connection core;
  no proxy/page cache duplicates registry state.
- Model adaptation consumes one mixed-domain ordered feed with reset,
  enable-replay, DOM bootstrap, and binding synchronization boundaries; DataKit
  has no independent per-domain event pumps.
- Every relevant target document-epoch advance has one ordered
  `domDocumentInvalidated` feed boundary before later DOM/CSS deltas; public
  event projection does not own model invalidation.
- Every target-scoped public DTO ID carries and validates its opaque generation.
- Known decode failures and root-envelope failures have no `try?`/silent-drop or
  `preconditionFailure` path.
- Default ProxyKit protocol event buffers are all bounded and overflow-tested.
- DataKit mixed-feed overflow reports the configured capacity without inventing
  a responsible domain. It puts both an in-flight and an attached context in
  `.failed`, atomically invalidates authority/resets results, and rejects
  operations until explicit re-attachment.
- DataKit contains no `@unchecked Sendable` lifecycle or semantic owner. Its
  sole unchecked type is a private weak delivery bridge with no owned model
  state; strict-concurrency and deallocation tests cover that boundary.
- Stored connection/model tasks weakly reference both contexts and owner actors;
  model-command runners use bounded actor hops plus external synchronized
  signals, and deallocation tests prove no owner-task/async-frame cycle.
- Every public DataKit operation has one semantic owner path; the direct/context,
  controller, and model convenience triplication is gone.
- Public `WebInspectorDOMModel`, `WebInspectorNetworkModel`,
  `WebInspectorConsoleModel`, `WebInspectorRuntimeModel`, `WebInspectorCSSModel`,
  and corresponding public `*Store` types do not exist; package stores are sole
  write owners, not facade wrappers.
- The public generic fetch trap surface is zero; Network and Console contract
  tests compile only supported concrete queries.
- Query results retain their snapshot-plus-delta contract. One results-owned
  atomic update registration supplies current state and bounded self-contained
  later transactions; live-result registries retain results weakly.
- DOM tree projection remains initial-snapshot-plus-delta based and selection
  reveal intent is consumed rather than inferred.
- Network and Console query/index work meets the 10,000-record and stalled
  subscriber gates without unbounded queued snapshots or owner-actor full-model
  evaluation on live insert.
- DOM/CSS, Runtime, Network, and Console stale validation uses their documented
  domain epochs rather than one context-wide generation.
- Console capability acquisition has no Runtime dependency. A Console clear
  invalidates Console-originated remote objects locally and never duplicates
  WebKit's `"console"` group release on the wire.
- One per-web-view inspectability coordinator, not individual attachments, owns
  original-value restoration.
- `WebInspectorSession` owns no controller cache; root-owned custom content may
  strongly retain the session and still deallocates when the root is released.
- Attachment/page epochs never evict the root/custom controller cache. Public
  results reset in place, while affected root-owned presentation-resource
  generations retire and replace their internal content independently.
- The two documented external stories compile and execute using only public
  imports.
- No core source file combines connection routing with model state, or more than
  one DataKit domain's mutable semantic state.
- The 58 UIKit `canImport(UIKit)` gates are tracked but not counted as a failure
  of this core migration because no AppKit UI is in scope.

## Commit and Integration Plan

Commits are kept buildable or intentionally test-red only when the commit is a
clearly labeled characterization test immediately followed by its owner change.
The stack begins with the already-approved platform prerequisite, followed by
the design gate and implementation:

1. `build!: require iOS 18.4 and macOS 15.4`
2. `docs(architecture): define inspector kit ownership`
3. `test(proxy): characterize connection and replay invariants`
4. `refactor(proxy)!: centralize connection and target ownership`
5. `refactor(proxy)!: make domain subscriptions atomic and bounded`
6. `test(data): characterize context and model contracts`
7. `refactor(data)!: replace dynamic context with caller confinement`
8. `refactor(data)!: move DOM and node-bound CSS state to one owner`
9. `refactor(data)!: move Network and Console state to domain owners`
10. `refactor(data)!: scope Runtime resources and concrete queries`
11. `feat(testing): add high-level DataKit scenarios`
12. `refactor(ui)!: expose the model context from the UIKit session`
13. `docs!: publish the new consumer and migration contracts`

Implementation work may split these further when a domain has an independently
reviewable invariant. It must not combine unrelated cleanup merely to reduce the
commit count. Worker commits are reviewed and integrated locally; pushing and a
pull request are separate explicit actions.

## Design Gate

Implementation begins only after explicit approval of this document. Approval
accepts the breaking removals, the SwiftData-like caller-confined DataKit
context/identity graph, retained snapshot-plus-delta tree and fetched-results
contracts, no new public per-domain Model/Store facades, the split between
DataKit's `WebInspectorModelContext` and UIKit's presentation-only
`WebInspectorSession`, structured ProxyKit event scopes, and the explicit-close
plus correctly scoped isolated-deinit lifecycle contract.
