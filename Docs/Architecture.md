# WebInspectorKit architecture

Status: Implemented (fourth-generation architecture)

Design baseline: 765692a1bea093a99b79fa45e90794455a7883ac

Implementation baseline: 38f5170721bc0dc573120604cd1e6d0a199582d8

Scope: WebInspectorProxyKit, WebInspectorDataKitMacros,
WebInspectorDataKit, WebInspectorSwiftUI, and the built-in UIKit inspector

## Decision

WebInspectorKit keeps the Core Data / SwiftData-inspired
ModelContainer → ModelContext → PersistentModel shape, but removes domain work
and physical transport ownership from ModelContext.

The migration has six structural decisions:

1. WebInspectorProxyKit owns only native attachment, physical connection
   ordering, targets, command replies, and ordered protocol event scopes.
2. WebInspectorDataKit owns one feature actor per semantic area. Page/target
   replacement is synchronized inside that owner; an unexpected bootstrap,
   protocol, route, or store failure fails the container attachment.
3. WebInspectorModelContainer owns the physical Proxy handle, the canonical
   record store, feature actors, and all context registrations.
   WebInspectorModelContext owns only its actor-confined identity map and
   fetch registrations.
4. Custom actor contexts use `@WebInspectorModelActor`, which installs one
   stored container-issued binding and retained DispatchSerialQueue. A
   computed protocol getter is not an ownership contract.
5. All list queries use one generic WebInspectorFetchDescriptor and one flat,
   one-type-parameter WebInspectorFetchedResultsController. Sectioning,
   ResultsObserver, owner leases, admission claims, and dual publication paths
   are removed.
6. SwiftUI gets a small WebInspectorSwiftUI overlay with
   @WebInspectorQuery. Its wrapped value is the last successful result and its
   backing storage exposes fetchError. It has no projected loading/ready/failure
   state.

This is a breaking, one-pass migration. The branch does not retain deprecated
wrappers or a second data path.

## Deferred design issue

`WebInspectorProxyOwnership.shared.claim` still enforces one-container-per-proxy
ownership through a process-global runtime registry. A follow-up must make this
exclusivity structural or type-level and remove the duplicate claim/release
lifecycle. This does not reopen feature or transport ownership and must not add
recovery, retry, or a second production data path.

## Consumer stories

### Built-in UIKit inspector

An app creates WebInspectorViewController, attaches it to a WKWebView, and uses
the built-in DOM and Network tabs. The view controller owns presentation only.
Its WebInspectorSession is a MainActor facade over one model container; it is
not a second connection or model owner.

### Custom UIKit or AppKit data UI

An app creates a WebInspectorModelContainer, uses mainContext for UI, creates
flat fetched-results controllers with generic predicates and sort descriptors,
and invokes commands through container.dom, container.network,
container.console, or container.runtime.

### Custom actor consumer

An actor uses `@WebInspectorModelActor`, which synthesizes one stored
container-issued model-actor binding, initializers, and the protocol
conformance. The binding owns one ModelContext and strongly retains the single
DispatchSerialQueue used as that actor's custom executor, so actor methods,
identity-map application, and observable models share one statically declared
serial owner. Each issuance receives separate model object identities with the
same stable IDs and canonical transactions. Initializing two macro-backed
actors with one issued binding intentionally shares that context and queue
while still serializing both actors; it also shares context close fate. The
framework does not add a precondition to forbid that valid ownership choice.

### SwiftUI data UI

A view imports WebInspectorDataKit and WebInspectorSwiftUI, installs a model
container in the environment, and declares @WebInspectorQuery. The wrapper
does not make connection state look like query state.

### Raw protocol consumer

An app uses WebInspectorProxy.page and its typed domain handles directly.
The existing typed command surface remains valid. DataKit no longer inserts a
model-feed state machine into ProxyKit's physical connection actor.

## Scope and compatibility

The migration preserves:

- the WebInspectorKit UIKit quick-start flow;
- WebInspectorProxy.page and typed DOM, Network, Page, Console, Runtime, and
  CSS commands;
- stable persistent IDs and context-local observable object identity;
- the current incremental query index and its 10,000-record performance
  contract;
- atomic initial state, contiguous deltas, and explicit reset after a gap;
- redirects and WebKit-style initiator grouping;
- raw peer and DataKit scenario testing products.

The migration deliberately does not provide:

- fetched-results sections;
- ResultsObserver or a second observation abstraction;
- external custom persistent-model schema registration;
- disk persistence or offline inspection;
- compatibility wrappers for the current owner lease/admission APIs;
- a replacement for all of Web Inspector's frontend behavior;
- a new package for each protocol domain.

Persistent-model generics make the built-in feature models uniform and
type-safe. They are not a promise that an external model conformance can be
registered with the container. Public schema registration can be designed
later if a concrete external feature consumer requires it.

Swift cannot seal a public protocol conformance across modules. The container
therefore owns one immutable built-in model catalog created with its feature
composition root. Every shipped model is registered there; an external type
may satisfy the generic syntax but performFetch/fetch rejects it with
unsupportedModel before creating a query registration. This is an explicit
runtime schema boundary, analogous to using a model type absent from a
container schema, rather than an accidental fallback or partial registration.

## Evidence from the migration baseline

The recorded baseline shape failed at ownership boundaries, not because the product lacked
individual guards.

### Apple framework analogs

The public sketches below follow contracts verified first with Xcode
DocumentationSearch rather than names alone. SDK interfaces and headers are
used only when DocumentationSearch does not expose a required signature,
isolation annotation, or availability detail:

- SwiftData creates `ModelContext` from a `ModelContainer`; the container's
  `mainContext` is MainActor-bound, while `ModelActor.modelContext` serializes
  work on that model actor.
- `PersistentModel` is an observable reference type with stable identity and
  `SendableMetatype`; the model instance itself is not the value sent to a
  background query evaluator.
- SwiftData `ModelContext.model(for:)` may return an unsaved shell for an
  identifier unknown to that context, while `registeredModel(for:)` returns
  only a model already known to it. WebInspectorKit deliberately makes
  `model(for:)` optional: inspector records are read-only live protocol state,
  so fabricating an insertable-looking placeholder would create a second
  source of truth. `registeredModel(for:)` remains the no-materialization
  lookup.
- `FetchDescriptor<T>` owns `Predicate<T>`, `[SortDescriptor<T>]`, limit, and
  offset. The model type is inferred at the use site where context permits.
- `NSFetchedResultsController` is initialized with a fetch request and context,
  then becomes usable after explicit `performFetch()`. It listens to changes in
  that same context and maintains its result set.
- SwiftData `Query` is MainActor-bound. Its wrapped value retains the last
  successful fetch after a later failure, while backing storage exposes
  `fetchError` and `modelContext`. It does not expose a projected
  loading/ready/failure phase.
- SwiftUI calls `DynamicProperty.update()` before evaluating body, and State
  can retain an @Observable reference. WebInspectorQuery therefore performs
  binding reconciliation in update() and makes its public getters pure reads.
- The current SwiftData SDK also exposes ResultsObserver, including section
  support. WebInspectorKit does not copy it: the flat FRC already owns the
  imperative query registration and @WebInspectorQuery directly observes that
  FRC for SwiftUI. A second observer would duplicate the same registration and
  lifecycle without a distinct consumer story.
- SwiftData's `ModelActor` is an Actor with nonisolated modelContainer and
  modelExecutor requirements. Its extension supplies the actor's
  unownedExecutor and isolated modelContext, while DefaultSerialModelExecutor
  owns that context. SwiftData's attached `ModelActor()` macro synthesizes the
  stored members, initializer, and protocol conformance; the protocol getter
  requirements alone do not prove stored executor identity. Swift requires a
  given actor's `unownedExecutor` to return the same executor every time and
  requires retaining the executor for at least the actor's lifetime.
  `DispatchSerialQueue` is itself a system serial executor. WebInspectorKit
  adopts the same macro-backed lifetime and identity shape instead of trying
  to dynamically bind a non-Sendable class to an arbitrary existing actor with
  `#isolation` or trusting a manually written computed binding getter.
- Swift's `#isolation` expression is optional by default and nil in a
  nonisolated context. A dynamic `isolated (any Actor)` factory can be made to
  compile when called after actor initialization, but synchronous actor
  initializers and lazy stored-property initializers cannot establish it. That
  forces two-phase/optional consumer state and an extra context-driver task.
  The ModelActor executor shape gives the owner a complete one-phase
  initializer instead.
- The package floor is iOS 18.4/macOS 15.4. At that floor the same
  DispatchSerialQueue object supplies SerialExecutor and TaskExecutor, so the
  model actor and its finite context drain do not need wrapper executors or a
  dynamic isolation bridge.

WebInspectorKit deliberately names its public issuance object
WebInspectorModelActorBinding rather than copying DefaultSerialModelExecutor.
SwiftData's type is an actual Executor; this binding only couples a context and
lifecycle to the retained system DispatchSerialQueue that is the actual
executor. The distinct name prevents consumers from inferring a false
SerialExecutor conformance or constructing a second executor identity.

A Swift 6.3.2 feasibility probe compiled and verified this public sketch for
iOS 18.4 and macOS 15.4 with strict concurrency, strict memory safety, library
evolution, and interface verification enabled. It confirmed the macro's stored
`nonisolated let`, generated and custom designated initializer forms, protocol
extension executor, and same retained queue at runtime. Negative fixtures
rejected missing/double initialization, computed bindings, and mutable
bindings. Separate strict consumers confirmed ModelContext's metatype-only
Sendability, the FRC's `nonisolated(nonsending)` calls and nonfailing update
sequence, and Query's public backing-storage reads. These probes establish
language and toolchain feasibility; the acceptance tests below remain the
repository contract.

The DocumentationSearch evidence is intentionally recorded as symbol URIs so
implementation review can return to the same SDK contract without broad web or
header searches:

| Decision | DocumentationSearch symbols |
| --- | --- |
| Container-issued context, SwiftUI environment context, and actor-bound context | `/documentation/SwiftData/ModelContainer/mainContext`, `/documentation/SwiftData/ModelContext/init(_:)`, `/documentation/SwiftUI/View/modelContainer(_:)`, `/documentation/SwiftData/ModelActor/modelContext` |
| Persistent model and identity lookup | `/documentation/SwiftData/PersistentModel`, `/documentation/SwiftData/ModelContext/model(for:)`, `/documentation/SwiftData/ModelContext/registeredModel(for:)` |
| Metatype-only concurrency guarantee | `/documentation/Swift/SendableMetatype` |
| Generic predicate/sort fetch | `/documentation/SwiftData/FetchDescriptor` |
| SwiftUI query construction, state, and last-success behavior | `/documentation/SwiftData/Query`, `/documentation/SwiftData/Query/init(_:transaction:)`, `/documentation/SwiftData/Query(filter:sort:transaction:)`, `/documentation/SwiftData/Query/fetchError`, `/documentation/SwiftData/Query/modelContext` |
| Deliberately omitted observer/section layer | `/documentation/SwiftData/ResultsObserver`, `/documentation/SwiftData/ResultsObserver/sections`, `/documentation/SwiftData/ResultsSection` |
| SwiftUI reconciliation and observable storage | `/documentation/SwiftUI/DynamicProperty/update()`, `/documentation/SwiftUI/State#Store-observable-objects` |
| View-owned animation for query results | `/documentation/SwiftUI/View/animation(_:value:)`, `/documentation/SwiftUI/View/transaction(value:_:)` |
| Explicit initial FRC fetch and flat content difference | `/documentation/CoreData/NSFetchedResultsController/performFetch()`, `/documentation/CoreData/NSFetchedResultsController/fetchedObjects`, `/documentation/CoreData/NSFetchedResultsControllerDelegate/controller(_:didChangeContentWith:)-5ullb` |
| Model actor executor ownership and synthesis | `/documentation/SwiftData/ModelActor()`, `/documentation/SwiftData/ModelExecutor`, `/documentation/SwiftData/DefaultSerialModelExecutor`, `/documentation/SwiftData/ModelActor/modelExecutor` |

DocumentationSearch does not expose every declaration conformance. Following
the fallback policy above, the Xcode 27 iPhoneSimulator 27.0
`SwiftData.swiftinterface` was checked only for that missing signature: it
declares `ModelContext: Equatable, SendableMetatype` and a static identity
equality operator. This is the direct analog for the public
`WebInspectorModelContext` conformance below; it does not make context
instances Sendable.

WebInspectorKit adopts those ownership and ergonomics contracts, but not local
disk persistence, Core Data section caches, or evaluation of context-owned
model references on another actor.

### WebKit source evidence

Protocol semantics and frontend behavior were also checked in the read-only
checkout at `/Users/kn/Dev/WebKit/WebKit_latest`. The current audit used clean
`main` at `b42421de79d1c2daf9b4c26119113cf9926f6260` (2026-07-11).
Version continuity was checked from the same object store at
`releases/Apple/Safari-17.6-iOS-17.6`
(`91977c6e5b061969e921e166d6567b8f84a18f70`) and
`releases/Apple/Safari-18-iOS-18.0`
(`f3bebebccb505852506f40ffe2384268bec2c29d`). The separate iOS 18.5 and
iOS 26.5 directories are reduced source checkouts without WebInspectorUI, so
their version files were used for runtime/source mapping while the complete
tagged sources supplied the frontend comparison. Paths below are relative to
the complete checkout and name the owner symbol so a later update can be
re-audited:

| Contract | WebKit source evidence | Local consequence |
| --- | --- | --- |
| `previousNodeId == 0` means no previous sibling | `Source/WebInspectorUI/UserInterface/Controllers/DOMManager.js::_childNodeInserted`; `Models/DOMNode.js::_insertChild` | ID zero maps to null and inserts at the front; it is not a protocol violation. |
| Picker is physically off before selection delivery | `Source/WebCore/inspector/agents/InspectorDOMAgent.cpp::inspect` calls `setSearchingForNode(..., false, ...)` before `focusNode` | receipt of Inspector/DOM inspect moves the backend state to idle before asynchronous node resolution. |
| Resource tree is a current snapshot | `Source/WebCore/inspector/agents/InspectorPageAgent.cpp::getResourceTree` | initial Network state must reconcile this snapshot with ordered events instead of treating either source as complete alone. |
| Network enable has no HTTP-history replay | `Source/WebCore/inspector/agents/InspectorNetworkAgent.cpp::enable` | enable starts instrumentation and replays active WebSockets only, so HTTP history comes from the Page snapshot. |
| Unknown protocol domains and methods use JSON-RPC `-32601` | `Source/JavaScriptCore/inspector/InspectorBackendDispatcher.cpp::dispatch` and `sendPendingErrors` | preserve the reply error code and classify only `MethodNotFound` as static feature non-support; ordinary command errors remain failures. |
| Network is a built-in frontend capability without a retry surface | `Source/WebInspectorUI/UserInterface/Base/Main.js` constructs `WI.networkManager` and includes `WI.NetworkTabContentView` in `productionTabClasses`; `Views/NetworkTabContentView.js` directly constructs its table | remove transient Network retry/unavailable UI. A required method's `-32601` response disables only Network-dependent tabs; unexpected runner failure fails the attachment. |
| Current frontend bootstrap has an event-loss assumption | `Source/WebInspectorUI/UserInterface/Controllers/NetworkManager.js::initializeTarget` and `_processMainFrameResourceTreePayload` | WebKit sends resource-tree and Network enable back-to-back and ignores events while waiting; WebInspectorKit intentionally uses enable-first plus a reply boundary for its stronger lossless-initial contract. |
| The frontend has no Network retry state | `Views/NetworkTabContentView.js` has only its table/content browser. `git log -S'Network Unavailable'` and the Network/retry history search have no matching frontend change | Network has no public/UI retry entry point. An unexpected Network runner failure fails the DataKit attachment; a later explicit attachment creates new runners. |
| Response may arrive without request start | `NetworkManager.js::resourceRequestDidReceiveResponse` | reconcile by frame/URL when unique, otherwise create a request; opening mid-load is normal. |
| Redirect reuses one resource | `NetworkManager.js::resourceRequestWillBeSent` and `Resource.updateForRedirectResponse` | one persistent request/entry owns ordered redirect hops. |
| Initiator grouping is node-based | `Views/NetworkTableContentView.js::_tryLinkResourceToDOMNode`; `Controllers/NetworkManager.js::_initiatorNodeFromPayload`; `Source/WebCore/loader/FrameLoader.cpp::willLoadMediaElementURL` | group by exact scoped initiator node without adding a fetched-results section or resource-type guess. |

WebKit frontend row nesting and its default-off UI setting are not copied.
WebInspectorKit's product requirement is grouping on by default with one flat
NetworkEntry row and all member requests/redirects rendered in its detail.
The direct Network table and absence of a Network-specific retry path
are unchanged in the checked Safari 17.6/iOS 17.6 and Safari 18/iOS 18.0
sources.

### Attachment readiness is not model readiness

At the baseline, WebInspectorModelContainerCore constructed an empty revision-zero
snapshot before attachment. The main context consumes it before
WebInspectorSession attaches the WKWebView. A fetched-results controller can
therefore become ready with an empty pre-attachment projection rather than the
current page snapshot.

Target contract: a context may exist while detached, but a query cannot publish
its first successful result for a model type until that type's feature has
committed a synchronized snapshot for the current attachment generation.

### A semantic reducer can terminate the physical connection

The current model feed is stored in ProxyKit's ConnectionCore. Its consumer
termination and DataKit protocolViolation paths can claim the same terminal
state as native disconnect and close every tab.

Target contract: the DataKit attachment is usable only while every enabled
feature runner can maintain its canonical projection. A known-domain decode,
reducer, route, bootstrap, or store error returns `connectionFailed` from that
runner and fails the attachment. Native fatal/disconnect, an unreadable outer
envelope, and an unroutable Target wrapper use the same terminal boundary.
WebKit commits a replacement with `Target.didCommitProvisionalTarget(old, new)`
before it emits `Target.targetDestroyed` for retired targets. This ordering is
present in the iOS 18.5, iOS 26.5, and latest
`WebPageInspectorController::didCommitProvisionalPage` implementations. The
commit atomically retargets the logical current page; later destruction of the
old physical target must neither clear that binding nor advance its generation.
Document replacement and late events for a retired target remain normal
lifecycle operations. Destruction of the current target without a committed
replacement is instead terminal target loss, not a speculative synchronization
gap, and fails the attachment rather than entering a retry or indefinite wait.

### Fetched results have two delivery owners

The baseline query engine supported raw and controller delivery, each in flat
and sectioned forms. Controller delivery then needs owner IDs, weak routing,
registration leases, admission claims, retirement ownership, and many
preconditions to keep the two paths aligned.

Target contract: ModelContext has one operation queue and one query
registration table. It applies record patches and fetched-result changes in
one owner turn. There is no raw-versus-controller delivery mode inside the
query engine.

### One mutation is split and revalidated

WebInspectorModelSchemaChange already contains a record, patch, query value,
and canonical rank. The current pipeline separates it into record changes and
fetched-results changes, then asserts that their IDs, revisions, and operations
still match.

Target contract: one typed model mutation remains intact from the feature
commit through the canonical store, query index, and context transaction.

### Preconditions are standing in for missing owners

The current preconditions are not one homogeneous class of programmer error.
Representative sites show four different ownership defects that the cutover
must remove rather than rename or wrap:

| Current crash contract | Evidence | Target owner and behavior |
| --- | --- | --- |
| Record, query-value, rank, and operation arrays must remain aligned | `WebInspectorModelSchema.swift`, `WebInspectorModelContextTransaction.swift`, `WebInspectorModelContextQueryEngine.swift` | One typed mutation and one context operation queue make the alignment unrepresentable. No second projection array is checked at publication time. |
| Canonical DOM/Network indexes must happen to agree after an external event | `WebInspectorCanonicalDOMReducer.swift`, `CanonicalNetworkStore.swift` | The feature actor normalizes external payloads before committing one store transaction. Page/document replacement uses its explicit lifecycle path; an unexpected sequence/reducer conflict fails the attachment before a partial projection can publish. |
| A UI task, generation counter, selection, and retired panel must agree across asynchronous callbacks | `DOMPanelModel.swift`, `NetworkPanelModel.swift`, `PresentationContentStore.swift` | One presentation resource enum owns task and route lifetime. Cancellation and late completion are normal stale-token outcomes; commands report typed closed/stale errors and UI event handlers never call `preconditionFailure`. |
| A persistent model also owns command task/lease/context state | `NetworkRequest.swift` (`NetworkBody`) and the CSS/runtime model command paths | Persistent models are context-local observable reads. Stable-ID commands and in-flight coalescing belong to the corresponding feature actor. |
| Model-feed registration, capability leases, bootstrap tasks, and terminal claims must agree | `TransportSession.swift` | ProxyKit owns only connection FIFO, reply routing, target topology, and domain scopes. Feature registration/bootstrap and lifecycle synchronization move to DataKit feature actors, deleting the cross-owner state machine. |

Public misuse remains a typed error. Cancellation, navigation, target loss,
late WebKit events, malformed known-domain payloads, and reentrant UI teardown
are reachable runtime outcomes and therefore never justify a process-ending
precondition. Private assertions may remain only where a single owner and a
closed value type make every reachable transition exhaustive. UIKit/AppKit
`init(coder:)` failures for programmatic-only private view controllers and
finite identifier-space exhaustion are audited separately; they are not used
to excuse external-input or lifecycle crashes.

### ProxyKit is also the model coordinator

At the baseline, TransportSession was 7,639 lines and owned physical FIFO ordering,
reply routing, targets, event scopes, model feed bootstrap, domain capabilities,
DOM/CSS epochs, picker leases, replay, and model-feed terminal policy.

Target contract: TransportSession is split by owner. Model bootstrap, semantic
epochs, grouping, and page/target synchronization move to DataKit feature actors.

### Public contracts are not a build gate

At the recorded baseline, the workspace tests passed, but
`swift test --package-path ContractTests` failed because the import-only
consumer still referenced removed NetworkQuery, ConsoleQuery, section APIs,
and old ModelContext domain methods.

Target contract: the standalone consumer package is part of the required
validation gate and contains only current public consumer stories.

### The existing query core is worth preserving

The current query core applies changed records incrementally, has a
no-filter/no-sort fast path, uses binary insertion for ordered membership, and
only performs a full evaluation for initial registration, descriptor
replacement, or reset. That algorithm is retained and simplified; it is not
replaced with per-event full fetch/filter/sort work.

## Invariants

1. One WebInspectorModelContainer owns exactly zero or one physical
   WebInspectorProxy connection.
   One WKWebView is reserved by at most one container at a time.
2. A WebInspectorModelContext never owns or attaches a Proxy.
3. Each context has a separate observable model identity map.
4. Actor boundaries carry only stable IDs, immutable query values, model
   mutations, snapshots, and deltas.
5. A query's first success is a synchronized current snapshot for its feature
   and attachment generation.
6. Every later query publication is a contiguous delta or an explicit reset.
7. Record patches and query membership changes become visible in the same
   context owner turn.
8. Predicate evaluation, sorting, membership, and difference calculation do
   not execute on MainActor or a model executor.
9. MainActor performs WKWebView/native bridge operations and MainActor-owned
   UI/context application only. Every custom context applies on its issued
   model-actor queue.
10. Every enabled semantic feature is required by the DataKit attachment. An
    unexpected feature bootstrap/protocol/route/store failure terminates that
    attachment through the same container failure boundary as transport loss.
11. Navigation and reattachment normally make old persistent IDs stale; this
    is not a protocol violation.
12. An idle source produces no store commit, query publication, context apply,
    or UI snapshot apply.
13. NetworkEntry is a flat logical list item. Redirects and exact scoped
    initiator grouping are model semantics, not fetched-results sections.
14. User, protocol, navigation, cancellation, and lifecycle failures are typed
    outcomes. They do not call preconditionFailure.
15. User sort descriptors are completed by canonical rank, so every query has
    one deterministic total order before offset and limit are applied.
16. Each supported custom ModelActor is macro-generated with one stored
    binding; it and its context drain use that binding's retained
    DispatchSerialQueue as their only runtime executor identity.

## Owner map

| Responsibility | Sole owner |
| --- | --- |
| WKWebView and native inspector attach/send/disconnect | ProxyKit native attachment on MainActor |
| Inbound byte/message FIFO and reply watermark | ProxyKit connection actor |
| Target membership and command reply routing | ProxyKit connection actor |
| Ordered event scope and bounded buffering | ProxyKit connection actor |
| Physical domain capability/configuration leases | ProxyKit connection actor using domain-owned descriptors |
| WKWebView-to-container attachment reservation | MainActor attachment registry |
| Attachment state and physical Proxy lifetime | WebInspectorModelContainer |
| Page commands that do not own semantic model state | Container-owned Page command facade |
| Page/target/DOM-binding sequence scopes | DataKit model store actor's identity-scope registry |
| DOM/CSS bootstrap, reducer, scope-advance request, picker | DOM feature actor |
| Network bootstrap, redirects, initiator groups, bodies | Network feature actor |
| Console/Runtime bootstrap and remote-object lifetime | Console/Runtime feature actor |
| Canonical records and global container revision | DataKit model store actor |
| Context registration and rebase publication | DataKit model store actor |
| Context-local model objects | MainActor for mainContext; the issued model-actor queue for each custom context |
| Predicate/sort/membership/order | Context query actor |
| Query registration ordering and context application | Context operation queue on MainActor or the issued model-actor queue |
| Context-feed overflow and rebase coalescing | Per-context bounded mailbox |
| FRC update overflow and reset coalescing | Per-subscriber bounded mailbox |
| SwiftUI query lifetime | @WebInspectorQuery storage on MainActor |
| DOM/Network selection and navigation route | The corresponding panel model on MainActor |
| DOM projection revision/cancellation | DOM render coordinator |
| UIKit rendering | View/controller layer on MainActor |

WebInspectorSession retains a container for a presentation lifetime and
observes page appearance. It delegates attach, detach, close, feature commands,
and connection state to the container. It owns no attachment generation,
canonical revision, feature state, or query lifecycle.

## Product and source topology

The package remains one Swift package. Targets are product or dependency
boundaries; folders are responsibility clusters.

~~~text
WebInspectorProxyKit
  NativeAttachment/
  Connection/
  DOM.swift + DOM+WireCoding.swift
  Network.swift + Network+WireCoding.swift
  Page.swift + Page+WireCoding.swift
  ...

WebInspectorDataKitMacros
  WebInspectorModelActorMacro.swift

WebInspectorDataKit
  Container/
  Context/
  Query/
  Observation/
  DOMCSS/
  Network/
  ConsoleRuntime/

WebInspectorSwiftUI
  Environment/
  Query/

WebInspectorUIBase
WebInspectorUIDOM
WebInspectorUINetwork
WebInspectorKit
~~~

The context cluster has one owner type per file:

~~~text
Container/WebInspectorModelContainer.swift
Container/WebInspectorModelContextRegistry.swift
Container/WebInspectorPageCommands.swift
Context/WebInspectorModelContext.swift
Context/WebInspectorModelActorBinding.swift
Context/WebInspectorModelActor.swift
Context/WebInspectorModelContextLifecycle.swift
Context/WebInspectorModelContextIngress.swift
Query/WebInspectorFetchDescriptor.swift
Query/WebInspectorFetchedResultsController.swift
Query/WebInspectorContextQueryIndex.swift
DOMCSS/WebInspectorDOM.swift
DOMCSS/CSSStyles.swift
Network/WebInspectorNetwork.swift
Network/NetworkResponseBodyContent.swift
ConsoleRuntime/WebInspectorRuntime.swift
ConsoleRuntime/WebInspectorRuntimeObjectScope.swift

WebInspectorSwiftUI/Environment/WebInspectorModelContainerEnvironment.swift
WebInspectorSwiftUI/Query/WebInspectorQuery.swift
WebInspectorSwiftUI/Query/WebInspectorQueryStorage.swift

WebInspectorDataKitMacros/WebInspectorModelActorMacro.swift
~~~

ModelContextRegistry owns issuance-versus-container-close admission.
ModelContextLifecycle owns a single context's mailbox, drain, identity map,
registrations, and close completion. ModelContextIngress is the narrow Sendable
store-to-context endpoint; it does not expose the context object. These are
responsibility files, not new targets or alternate data paths.

WebInspectorDataKitMacros is a host compiler-plugin target and a dependency of
WebInspectorDataKit. It owns only the `@WebInspectorModelActor` expansion and
diagnostics, depends on the Swift-6.3-compatible swift-syntax products, and has
no runtime/domain/model ownership. The target boundary is required by SwiftPM
macro loading; it is not a new public library product or a feature layer.

WebInspectorSwiftUI is a separate public product because it owns a distinct
SwiftUI DynamicProperty/environment lifecycle and should not add SwiftUI to
the Foundation/Observation DataKit core or to raw ProxyKit consumers.

The existing WebInspectorKit, DataKit, ProxyKit, and two testing products keep
their product names and consumer stories. WebInspectorSwiftUI is the only new
product in this migration.

The public `WebInspectorKit` product is backed by a real `WebInspectorKit`
target containing `WebInspectorViewController`, `WebInspectorSession`,
`WebInspectorTab`, and their internal shell implementation. The current
two-line umbrella source, the `WebInspectorUI` target, and its underscored
`@_exported import WebInspectorUI` are removed. Internal feature UI targets
remain package implementation boundaries and are not consumer-facing modules.

`import WebInspectorKit` alone is a compiled quick-start and simple custom-tab
story: defaults and inferred tab context are usable without spelling a
dependency type. Consumers that construct fetch descriptors or raw proxy
configuration explicitly import `WebInspectorDataKit` or
`WebInspectorProxyKit`; the UIKit module does not recreate those types or use
an underscored re-export. ContractTests compile both stories.

Feature folders inside DataKit do not become targets merely because they are
domains. A future Sources UI may justify a WebInspectorUISources target because
it owns editor dependencies and a complete tab lifecycle. Storage remains a
folder in an existing UI target until it has an independent dependency or
distribution boundary.

A DataKit feature is a semantic identity/lifecycle owner, not one
protocol domain. DOM+CSS and Console+Runtime intentionally share owners;
future Sources can combine Page+Debugger+Runtime, and Storage/Security can
combine the protocol domains needed by that lifetime.

Existing WebInspectorUISyntaxBody files move to
`WebInspectorUINetwork/Preview`; the WebInspectorUISyntaxBody target is
removed and WebInspectorUINetwork takes its conditional SyntaxEditorUI
dependency. UI feature targets depend on DataKit feature APIs, not directly on
ProxyKit.

The public UIKit surface moves as one unit:

| Current declaration module | Target declaration module |
| --- | --- |
| WebInspectorUI.WebInspectorViewController | WebInspectorKit |
| WebInspectorUI.WebInspectorSession | WebInspectorKit |
| WebInspectorUI.WebInspectorTab | WebInspectorKit |

WebInspectorUIPreviews remains an internal target and depends on the concrete
DOM and Network UI targets. No source imports the removed WebInspectorUI or
WebInspectorUISyntaxBody modules after the migration.

Tests mirror the same owner folders without adding one test target per folder:

~~~text
ProxyKitTests/{Connection,NativeAttachment,DOM,Network,...}
DataKitTests/{Container,Context,Query,DOMCSS,Network,ConsoleRuntime,...}
DataKitMacroTests/{Expansion,Diagnostics}
SwiftUITests/{Environment,Query}
UITests/{Shell,DOM,Network,Sources,Storage}
~~~

`WebInspectorSwiftUITests` is a dedicated test target in the shared
`WebInspectorKit` scheme. `ContractTests` additionally has an import-only
`WebInspectorSwiftUI` consumer target, so the overlay is checked both as an
implementation and as a standalone public product.

`WebInspectorDataKitTesting` vends the container plus deterministic raw-input,
boundary, counter, and lifecycle controls. It no longer vends `runtime.model`,
`makeContext(isolation:)`, or a context-driving Task. A test that needs custom
isolation declares a small `@WebInspectorModelActor` actor, so the testing
product cannot establish a second context ownership model.

## End-to-end data flow

~~~mermaid
flowchart LR
    WK[WKWebView] -->|MainActor native boundary| P[Proxy connection actor]
    P -->|ordered event scope + reply watermark| F[Feature actor]
    F -->|single typed feature transaction| S[Model store actor]
    S -->|initial / delta / rebase| Q[Context operation queue]
    Q -->|immutable mutations| I[Context query actor]
    I -->|IDs + flat differences| Q
    Q -->|one owner turn| C[Context models + FRC]
    C --> U[UIKit / SwiftUI]
~~~

### Attachment

The container lifecycle is one explicit state machine:

~~~text
detached -> attaching(generation) -> attached(generation)
attaching(generation) -> failed(generation, failure)
attached(generation) -> detaching(generation) -> detached
attached(generation) -> failed(generation, failure)
attaching(generation) -- detach --> detached
detaching(generation) -- native disconnect / detach join --> detached
failed(generation, failure) -- detach --> detached
detached / failed -> attaching(nextGeneration)
any nonclosed state -> closing -> closed
closing -- detach / close --> join closing -> closed
closed -- detach / close --> closed
~~~

attach, detach, and close are MainActor entry points because they reserve a
WKWebView and operate the native bridge. MainActor serialization is not used
for feature reduction, query evaluation, or model application in custom
contexts.

An internal MainActor registry reserves WKWebView identity before native
attachment. A second container receives `webViewAlreadyAttached`. Attach while
attaching or detaching throws `attachmentInProgress`; attach while attached to
the same view is a no-op and attach to a different view throws
`alreadyAttached`; attach while closing or after close throws
`containerClosed`. These are typed
attachment errors rather than replacement or traps. A detach during attach
cancels and joins that attempt before becoming detached; a close during attach
or detach cancels and joins the transition before becoming closed. Concurrent
detach callers join the same transition, detach while detached is a no-op, and
detach from failed performs any residual cleanup before becoming detached.
Native disconnect during detaching satisfies the requested teardown and does
not create a new failed state. `detach()` is nonthrowing because its contract is
cancel-and-join cleanup; failures are logged at the native boundary and the
reservation is still released. Close is terminal and idempotent. The
interrupted attach waiter receives cancellation. Detach during closing joins
the close transition and returns with the container closed; detach after close
is a no-op. Concurrent close callers join that same transition rather than
starting another teardown. Reattaching a failed or detached container creates
a new attachment generation. A failed state is published only after the old
Proxy, feature runners, waiters, and reservation have been released or joined,
so a later attachment never overlaps the failed generation.

The app owns the WKWebView. The registry references the view and container
weakly. The container strongly owns the Proxy/native attachment and feature
runtimes until detach, physical failure, or close, then releases the registry
reservation exactly once. Contexts never retain a WKWebView or Proxy.

The one-container-per-WKWebView rule is a WebInspectorDataKit product choice,
not an upstream claim that WebKit can never hold multiple frontend
connections. Two model containers would independently enable domains, control
the picker/highlight, and assign incompatible generations to the same page.
Raw ProxyKit consumers retain its lower-level connection capabilities; the
stateful DataKit model layer permits one owner and any number of contexts under
that owner.

Attachment proceeds as follows:

1. ModelContainer reserves the WKWebView and an attachment generation.
2. Its MainActor attach entry creates WebInspectorProxy for the WKWebView.
3. ProxyKit adopts the physical connection and discovers the current page.
4. Before a feature enables a protocol domain or sends its snapshot command,
   it opens an ordered event scope.
5. Each configured feature bootstraps independently.
6. A successful feature bootstrap commits a feature reset to the model store.
7. Contexts apply that reset; pending queries for the feature receive their
   first successful snapshot.
8. The container reports physical state as attached independently from each
   feature state. Every enabled feature is synchronizing, ready, or statically
   unsupported while that attachment remains usable.

Attach succeeds when the physical connection and feature runtimes are adopted.
JSON-RPC `-32601` from a required feature method proves static non-support and
publishes `unsupported(requirements:)` for only that feature. Any other feature
bootstrap, protocol, route, or store failure returns a connection failure from
its runner. The container joins teardown, publishes failed, and a later
explicit attachment creates all new runners. There is no transient
feature-local unavailable state or retry action.

Container and feature handles expose a lock-protected current state snapshot
and a last-value-first state sequence. State sequences are bounded and may
coalesce intermediate transitions to the newest complete state; they never
carry model deltas. A slow state observer therefore cannot block attachment or
grow memory. WebInspectorSession observes these sequences on MainActor for the
built-in UI.

### Context registration

ModelContext can be created before or after attachment.

The model store atomically opens a context feed with:

- the current global revision;
- current immutable records;
- readiness and generation for each configured feature;
- a continuation for revisions after that boundary.

A detached initial value may be applied to establish an empty identity map, but
it does not satisfy a query's first-success condition. When the relevant
feature commits ready state, the query publishes the real initial result.

Registering a pre-attach fetch records the query and its pending continuation,
then returns the context-processor turn. It never suspends the single operation
queue while waiting for feature readiness, because the future ready/reset
transaction must enter that same queue. A connection failure is owned by the
container lifecycle rather than injected as a query result. A one-shot context
fetch removes its transient registration after success or deterministic query
failure.

### Delta and rebase

The store assigns one monotonically increasing container revision to each
non-empty commit. Context feeds preserve revision order.

That revision is an internal cross-feature transaction boundary, not the
public FRC revision. A context routes a commit only to model types it affects;
an unrelated feature commit causes no query evaluation or publication.
Each controller owns a `WebInspectorFetchedResultsRevision` that advances by
one for its initial result, successful descriptor replacement, structural or
content change, and reset. `fromRevision` is therefore exactly the preceding
publication revision. A source revision gap is handled internally by rebase;
consumers never receive no-op publications merely to mirror global commits.

If a bounded context feed cannot preserve all deltas, it does not fail the
context or connection. The next deliverable value is one atomic rebase
snapshot at a newer revision. Query registrations publish reset and then
continue with contiguous deltas.

Each context feed has one bounded latest-rebase mailbox. While a reset is
pending, newer source values replace its snapshot/revision rather than append
more deltas. Once the context consumes that reset, contiguous delta buffering
resumes. The reset itself is therefore never dropped by a generic AsyncStream
buffering policy. No publisher keeps an unbounded history to avoid rebase.

### Navigation and reattachment

A page or target replacement advances attachment/page generation. Feature
actors cancel commands for the old generation, reset their projections, and
bootstrap the new generation. Old IDs resolve as stale or nil. Context objects
and fetched-results controller objects can remain, but their model membership
is reset to the new generation.

## ProxyKit contract

### MainActor boundary

WebInspectorProxy.init(attachingTo:) remains MainActor because WKWebView and
the private native inspector attachment are UI/runtime objects. Native
send/disconnect also hop to MainActor as required by the bridge.

The native callback copies the message and enqueues it into the connection
FIFO. JSON parsing, target routing, event decoding, feature reduction, model
queries, and sorting run outside MainActor.

Adding another semantic bridge actor does not remove the native MainActor
requirement and is not part of the design.

### Connection responsibilities

ProxyKit keeps:

- exact inbound FIFO order;
- target discovery and replacement;
- typed command dispatch and reply decoding;
- reply watermark/sequence metadata;
- bounded ordered event scopes;
- shape-preserving raw unknown-event preservation as owned JSON Data;
- raw-value domain tokens and domain-handle-owned decoder registration;
- first-wins physical terminal state;
- deterministic close and waiter completion.

ProxyKit removes:

- ConnectionModelFeed and ModelDomain;
- model-feed command authority;
- canonical DOM/Network/Console snapshots;
- model bootstrap and replay state;
- model binding epochs;
- model-feed capability owners;
- picker semantic leases;
- model-feed consumer termination as a physical terminal cause;
- the closed `WebInspectorProxyEvent` domain sum and central domain/decode
  switches.

The existing public page.dom, page.network, page.runtime, page.console,
page.css, and page.page handles remain the raw consumer API. DataKit uses a
package event-scope primitive with sequence and ordered reply-boundary markers;
it does not require a second public protocol client.

The internal routed envelope contains sequence, page generation, semantic and
agent target IDs, the full protocol method such as
`Network.requestWillBeSent`, and owned parameter Data. Domain and short event
name are computed from that one full method instead of stored as a second
source of truth. The contract is semantic JSON fidelity, not byte identity:
explicit null, scalar/array fragments, and objects preserve their top-level
shape and values, while whitespace, object-key order, and number spelling are
not observable. Only an absent params member normalizes to `{}`. Serialization
or outer-envelope failure is not silently replaced by an empty object.

Each typed domain handle supplies a decoder closure against a raw-value domain
token. The connection actor sees only envelope, route, sequence, and Target
control-plane messages; scope consumers perform domain-event decoding from the
owned Data. An unknown method becomes the domain's `.unknown(RawEvent)`. A
known method with malformed parameters fails that scope with domain, method,
and sequence diagnostics. Adding Sources or Storage therefore adds a typed
handle and decoder without editing a central TransportSession event sum.

Page owns typed Page events as well as commands. At minimum these include
frameNavigated, frameDetached, and unknown. They are not projected into Target
lifecycle events. The connection actor alone decodes Target control-plane
wrappers needed to maintain physical routing.

### Event scopes

Opening a scope is atomic with respect to the connection FIFO. The scope exists
before its operation enables a domain or sends a snapshot command.

Scope registration establishes its initial generation without enqueuing a
synthetic reset. The generation carried by a scoped reply or event identifies
that initial page. `WebInspectorPageEvent.reset` is reserved for a current-page
binding generation that advances after registration, including one that
advances while capability acquisition is suspended. `ConnectionCore` owns this
distinction; feature consumers treat every delivered reset as a real target
change and do not suppress a first reset locally.

The package primitive can atomically register multiple domain decoders into
one output enum and one raw FIFO mailbox. Network uses one composite scope for
Page and Network, so cross-domain event order is not reconstructed from two
AsyncSequences after delivery. Public single-domain typed handles are a
specialization of the same primitive.

A snapshot command is dispatched through its scope. When the connection actor
handles that command's reply, it first fixes watermark W, then enqueues a
non-capacity-counting boundary marker carrying the command token and W into
that scope, and only then resumes the command continuation. Events at or before
W therefore precede the marker and later events follow it. Returning a numeric
watermark without this ordered marker is not an atomic-cut contract.

The feature does not run an independent event pump while awaiting a bootstrap
command. `scope.command(...)` returns a ScopedReply containing the reply and
its boundary token only after the marker is queued. The same feature owner then
calls `scope.drain(through:)` and receives the complete FIFO prefix ending at
that token. Marker enqueue-before-continuation is a connection ordering fact;
it does not promise that an unrelated consumer task observes the marker before
the awaiting feature resumes. Overflow, target loss, or scope termination
before drain reaches the token fails the whole cut. A scope permits one
outstanding boundary token, preventing unbounded markers and ambiguous nested
cuts. Live event iteration begins only after the bootstrap prefix commits.

Physical domain capability ownership remains a generic connection concern,
not feature state. A capability key is the resolved physical agent plus an
open domain token and activation-configuration identity. Each domain-owned
descriptor specifies target/agent resolution, dependencies, enable operation,
whether last-release disable is semantically safe, the state that must be
restored after reacquisition, and the single owner of domain-mutating commands.
Network interception, extra headers, cache policy, emulation, and retained
resource data therefore cannot be accidentally erased by a generic disable.
The first equivalent scope lease enables the resolved agent, additional leases
join it, and the last release either performs the descriptor's safe disable or
retains/reconciles that capability according to policy; dependencies acquire
first and release in reverse. Partial acquisition rolls back in reverse order.
Cancellation while enabling joins the enable reply and any required cleanup.
A cleanup failure leaves that physical capability unknown for reconciliation
by the next acquisition and fails the affected scope. A DataKit feature maps
that unexpected scope failure to its container attachment boundary.

An ordered-scope descriptor also owns a target-selection policy: fixed current
page, selected physical agent, or dynamically enrolled descendants filtered by
target kind. Target join/leave, route changes, capability acquisition, and
event delivery are linearized in the same connection FIFO. This is the
extension point for Sources workers and Storage root/page-agent differences;
adding a policy/decoder does not add a central domain switch.

Page/target replacement is delivered as an ordered reset inside the active
scope, so a feature can bootstrap the replacement without releasing and
reacquiring domain capabilities. Overflow terminally stops scope delivery. The
feature closes that scope, returns `connectionFailed`, and the container joins
all feature and Proxy teardown; it does not open a speculative replacement
scope or maintain a retry budget.

Malformed command results fail only that command. A malformed event that can
still be assigned to a domain fails that Proxy scope; a DataKit feature maps
the failure to the attachment. Target destruction resets the affected binding
and late target events are dropped. An unreadable outer transport envelope or
malformed Target control-plane wrapper fails the Proxy connection directly.

## DataKit feature contract

Each feature is a concrete actor with a small common runtime contract:

~~~swift
package protocol WebInspectorModelFeature: Actor {
    static var id: WebInspectorFeatureID { get }

    func run(
        connection: WebInspectorFeatureConnection,
        store: WebInspectorModelStoreSink
    ) async -> WebInspectorFeatureTermination

    func close() async
}

package enum WebInspectorFeatureTermination: Sendable {
    case detached
    case connectionFailed(WebInspectorConnectionFailure)
    case containerClosed
}
~~~

The common protocol owns runner start and close integration only. Event
payloads, bootstrap commands, reducer state, and page/target lifecycle stay in
concrete feature actors. A confirmed replacement is handled inside the running
feature. A required method's JSON-RPC `-32601` reply publishes static
`unsupported` availability and ends only that feature runner normally. Any
unexpected bootstrap, protocol, route, scope, or store error returns a typed
connection termination to the container. There is no central switch over every
command or event.

Feature actors stage a complete reducer result before committing. A failed
reduction cannot partially mutate the canonical store.

### Feature state

~~~swift
public enum WebInspectorFeatureState: Equatable, Sendable {
    case disabled
    case synchronizing(generation: WebInspectorPageGeneration)
    case ready(
        generation: WebInspectorPageGeneration,
        revision: WebInspectorStoreRevision
    )
    case unsupported(requirements: [String])
}

public struct WebInspectorFeatureID: Hashable, Sendable {
    public let name: String

    internal init(name: String)

    public static let dom: Self
    public static let network: Self
    public static let consoleRuntime: Self
}

public struct WebInspectorFailureDescription:
    Error, Equatable, Sendable {
    public let code: String
    public let phase: String
    public let message: String

    public init(code: String, phase: String, message: String)
}

public enum WebInspectorFeatureError: Error, Equatable, Sendable {
    case bootstrap(WebInspectorFailureDescription)
    case eventStream(WebInspectorFailureDescription)
    case command(WebInspectorFailureDescription)
}

public enum WebInspectorConnectionFailure: Error, Equatable, Sendable {
    case native(WebInspectorFailureDescription)
    case transportEnvelope(WebInspectorFailureDescription)
    case targetControlPlane(WebInspectorFailureDescription)
}

public enum WebInspectorElementPickerState: Equatable, Sendable {
    case idle
    case enabling
    case active
    case resolvingSelection
    case disabling
}
~~~

The public error families are typed at their owner boundary:

~~~swift
public enum WebInspectorAttachmentError: Error, Equatable, Sendable {
    case attachmentInProgress
    case alreadyAttached
    case webViewAlreadyAttached
    case containerClosed
    case native(WebInspectorConnectionFailure)
}

public enum WebInspectorFetchError: Error, Equatable, Sendable {
    case invalidLimit(Int)
    case invalidOffset(Int)
    case unsupportedModel(String)
    case featureUnsupported(
        WebInspectorFeatureID,
        requirements: [String]
    )
    case predicateEvaluation(WebInspectorFailureDescription)
    case contextClosed
    case containerClosed
}

public enum WebInspectorModelContextError: Error, Equatable, Sendable {
    case containerClosed
}

public enum WebInspectorCommandError: Error, Equatable, Sendable {
    case staleIdentifier
    case targetChanged
    case connection(WebInspectorConnectionFailure)
    case featureUnsupported(
        WebInspectorFeatureID,
        requirements: [String]
    )
    case rejected(WebInspectorFailureDescription)
    case timedOut
    case containerClosed
}

public enum WebInspectorElementPickerError: Error, Equatable, Sendable {
    case busy
    case targetChanged
    case enableFailed(WebInspectorFailureDescription)
    case disableFailed(WebInspectorFailureDescription)
    case selectionResolutionFailed(WebInspectorFailureDescription)
}

public enum WebInspectorQueryError: Error, Equatable, Sendable {
    case missingModelContext
}
~~~

These error values are immutable, Equatable, and Sendable; they do not retain
arbitrary framework objects. Command/fetch errors describe the operation that
failed. Static required-method non-support is preserved as `featureUnsupported`.
Unexpected runner failures use `WebInspectorConnectionFailure` and are
reflected by the container lifecycle rather than duplicated in feature state.

Feature `run` is started only by the container for an attachment. Each public
DOM, Network, Console, and Runtime facade conforms to
`WebInspectorFeatureHandle`; none exposes public, registry, container-generic,
or UI retry entry points.
Feature `close()` is container-owned, awaited, terminal for that runner, and
completes its command waiters with containerClosed. Detach or physical failure
completes command waiters with cancellation/connection/targetChanged as
appropriate, retains the last successful query result, and leaves query
registrations ready for a later container reattach. Context close completes
pending fetch waiters with contextClosed; container close uses containerClosed
and joins every context registration.

The bootstrap cut may repeat only when its ordered prefix proves that the page,
target, or document changed while the snapshot command was in flight. This is
stabilization of a moving source inside one bootstrap operation, not an error
retry policy. Event gaps, malformed known-domain payloads, route loss, reducer
conflicts, and store failures return `connectionFailed` immediately.

A reducer transition that remains impossible after the external payload has
been decoded and normalized is a programmer error. The closed internal state
type makes such transitions unrepresentable where possible; only the residual
private invariant may assert. External WebKit input errors are surfaced at the
connection boundary rather than converted into preconditions or fallback.

Semantic phase and generation transitions are logged at the feature boundary.
A ready-state refresh that changes only the canonical store revision is
deliberately not logged; otherwise normal DOM commits turn the state log into
an event trace. A malformed event records its method and connection sequence at
the scope failure boundary without logging high-frequency protocol events or
revision churn.

### Canonical model store

The model store owns immutable records, model-type readiness, and global
revision. It does not interpret DOM or Network protocol payloads.

A feature commit contains one ordered collection of model mutations. Each
mutation carries the persistent ID, operation, immutable record/patch, query
value, and canonical rank needed by materialization and the query index. It is
not split into parallel record and query arrays.

The store publishes no transaction when reducer output and feature state are
unchanged.

## ModelContainer and ModelContext API

The public shape follows SwiftData where its ownership model applies.

~~~swift
public protocol WebInspectorPersistentIdentifier: Hashable, Sendable
where Model.ID == Self {
    associatedtype Model: WebInspectorPersistentModel
}

public struct WebInspectorAttachmentGeneration:
    RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64)
    public static func < (lhs: Self, rhs: Self) -> Bool
}

public struct WebInspectorPageGeneration:
    RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64)
    public static func < (lhs: Self, rhs: Self) -> Bool
}

public struct WebInspectorStoreRevision:
    RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64)
    public static func < (lhs: Self, rhs: Self) -> Bool
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

extension WebInspectorPersistentModel {
    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool
    public nonisolated func hash(into hasher: inout Hasher)
}

public struct WebInspectorFetchedResultsRevision:
    RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64)
    public static func < (lhs: Self, rhs: Self) -> Bool
}

public struct WebInspectorStateUpdates<State>: AsyncSequence, Sendable
where State: Sendable {
    public typealias Element = State
    public typealias Failure = Never
    public struct AsyncIterator: AsyncIteratorProtocol {
        public mutating func next() async -> State?
    }
    public func makeAsyncIterator() -> AsyncIterator
}

public final class WebInspectorModelContainer: Equatable, Sendable {
    public struct Configuration: Equatable, Sendable {
        public var enabledFeatures: Set<WebInspectorFeatureID>

        public init(
            enabledFeatures: Set<WebInspectorFeatureID> = [
                .dom, .network, .consoleRuntime,
            ]
        )
    }

    public enum State: Equatable, Sendable {
        case detached
        case attaching(generation: WebInspectorAttachmentGeneration)
        case attached(generation: WebInspectorAttachmentGeneration)
        case detaching(generation: WebInspectorAttachmentGeneration)
        case failed(
            generation: WebInspectorAttachmentGeneration,
            failure: WebInspectorConnectionFailure
        )
        case closing
        case closed
    }

    public let configuration: Configuration
    public var state: State { get }
    public var stateUpdates: WebInspectorStateUpdates<State> { get }

    public static nonisolated func == (
        lhs: WebInspectorModelContainer,
        rhs: WebInspectorModelContainer
    ) -> Bool

    @MainActor
    public var mainContext: WebInspectorModelContext { get }

    public func makeModelActorBinding() throws
        -> WebInspectorModelActorBinding

    public let dom: WebInspectorDOM
    public let network: WebInspectorNetwork
    public let console: WebInspectorConsole
    public let runtime: WebInspectorRuntime
    public let page: WebInspectorPageCommands

    public init(configuration: Configuration = .init())

    @MainActor
    public func attach(
        to webView: WKWebView,
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws

    @MainActor public func detach() async
    @MainActor public func close() async
}

public final class WebInspectorModelContext: Equatable, SendableMetatype {
    public nonisolated let container: WebInspectorModelContainer

    public static nonisolated func == (
        lhs: WebInspectorModelContext,
        rhs: WebInspectorModelContext
    ) -> Bool

    public func model<ID>(for id: ID) -> ID.Model?
        where ID: WebInspectorPersistentIdentifier

    public func registeredModel<ID>(for id: ID) -> ID.Model?
        where ID: WebInspectorPersistentIdentifier

    public nonisolated(nonsending) func fetch<Model>(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> [Model]

    public nonisolated(nonsending) func fetchIdentifiers<Model>(
        _ descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws -> [Model.ID]

    public nonisolated(nonsending) func close() async
}

@available(
    *,
    unavailable,
    message: "contexts cannot be shared across concurrency contexts"
)
extension WebInspectorModelContext: @unchecked Sendable {}

public final class WebInspectorModelActorBinding:
    @unchecked Sendable {
    internal let modelContext: WebInspectorModelContext
    internal let serialQueue: DispatchSerialQueue

    internal init(
        modelContext: WebInspectorModelContext,
        serialQueue: DispatchSerialQueue
    )
}

@attached(
    member,
    names: named(modelActorBinding), named(init)
)
@attached(
    extension,
    conformances: WebInspectorModelActor
)
public macro WebInspectorModelActor() = #externalMacro(
    module: "WebInspectorDataKitMacros",
    type: "WebInspectorModelActorMacro"
)

public protocol WebInspectorModelActor: Actor {
    nonisolated var modelActorBinding:
        WebInspectorModelActorBinding { get }
}

extension WebInspectorModelActor {
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        unsafe modelActorBinding.serialQueue.asUnownedSerialExecutor()
    }

    public var modelContext: WebInspectorModelContext {
        modelActorBinding.modelContext
    }

    public nonisolated var modelContainer: WebInspectorModelContainer {
        modelActorBinding.modelContext.container
    }

    public func closeModelContext() async {
        await modelContext.close()
    }
}

public protocol WebInspectorFeatureHandle: Sendable {
    var state: WebInspectorFeatureState { get }
    var stateUpdates:
        WebInspectorStateUpdates<WebInspectorFeatureState> { get }
}

public final class WebInspectorPageCommands: Sendable {
    public func reload(ignoringCache: Bool = false) async throws
}

public enum DOMTextRepresentation: Hashable, Sendable {
    case html
    case selectorPath
    case xPath
}

public final class DOMUndoCapability: Sendable {
    public func undo() async throws
    public func redo() async throws
}

public struct DOMMutationOutcome: Sendable {
    public let requestedNodeIDs: [DOMNode.ID]
    public let appliedNodeIDs: [DOMNode.ID]
    public let failures: [DOMMutationFailure]
    public let undo: DOMUndoCapability?
}

public final class CSSStyles: WebInspectorPersistentModel {
    public struct ID: WebInspectorPersistentIdentifier {
        public typealias Model = CSSStyles
        package let nodeID: DOMNode.ID

        package init(nodeID: DOMNode.ID)
    }

    public struct QueryValue: Identifiable, Sendable {
        public let id: ID
        public let nodeID: DOMNode.ID
    }

    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case needsRefresh
        case unavailable
        case failed(WebInspectorFeatureError)
    }

    public nonisolated let id: ID
    public let nodeID: DOMNode.ID
    public private(set) var phase: Phase
    public private(set) var sections: [CSSStyleSection]
    public private(set) var computedProperties: [CSSComputedProperty]
}

public final class WebInspectorDOM: WebInspectorFeatureHandle {
    public var state: WebInspectorFeatureState { get }
    public var stateUpdates:
        WebInspectorStateUpdates<WebInspectorFeatureState> { get }
    public var elementPickerState: WebInspectorElementPickerState { get }
    public var elementPickerStateUpdates:
        WebInspectorStateUpdates<WebInspectorElementPickerState> { get }

    public func pickElement() async throws -> DOMNode.ID
    public func cancelElementPicker() async

    public func requestChildren(
        of nodeID: DOMNode.ID,
        depth: Int = 1
    ) async throws
    public func setAttribute(
        _ name: String,
        value: String,
        on nodeID: DOMNode.ID,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome
    public func setOuterHTML(
        _ html: String,
        of nodeID: DOMNode.ID,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome
    public func removeNodes(
        _ nodeIDs: [DOMNode.ID],
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMMutationOutcome
    public func text(
        _ representation: DOMTextRepresentation,
        for nodeID: DOMNode.ID
    ) async throws -> String
    public func highlight(_ nodeID: DOMNode.ID) async throws
    public func hideHighlight() async throws

    public func loadStyles(
        for nodeID: DOMNode.ID
    ) async throws -> CSSStyles.ID
    public func refreshStyles(_ stylesID: CSSStyles.ID) async throws
    public func setProperty(
        _ propertyID: CSSStyleProperty.ID,
        enabled: Bool,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability?
    public func setDeclarationText(
        _ text: String,
        for propertyID: CSSStyleProperty.ID,
        undo: WebInspectorUndoPolicy = .automatic
    ) async throws -> DOMUndoCapability?
}

public struct NetworkResponseBodyContent: Equatable, Sendable {
    public let content: String
    public let isBase64Encoded: Bool
    public let size: Int?
    public let isTruncated: Bool
    public let kind: NetworkBody.Kind
    public let syntaxKind: NetworkBody.SyntaxKind
}

public final class WebInspectorNetwork: WebInspectorFeatureHandle {
    public var state: WebInspectorFeatureState { get }
    public var stateUpdates:
        WebInspectorStateUpdates<WebInspectorFeatureState> { get }

    public func clear() async throws
    public func responseBody(
        for id: NetworkRequest.ID
    ) async throws -> NetworkResponseBodyContent
}

public final class WebInspectorConsole: WebInspectorFeatureHandle {
    public var state: WebInspectorFeatureState { get }
    public var stateUpdates:
        WebInspectorStateUpdates<WebInspectorFeatureState> { get }
}

public struct RuntimeObject: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        private enum Storage: Hashable, Sendable {
            case consoleParameter(
                messageID: ConsoleMessage.ID,
                parameterIndex: Int
            )
            case scope(scopeID: UUID, ordinal: UInt64)
        }

        private let storage: Storage

        package init(
            consoleMessageID: ConsoleMessage.ID,
            parameterIndex: Int
        )
        package init(scopeID: UUID, ordinal: UInt64)
    }

    public struct Property: Sendable {
        public let name: String
        public let value: String?
        public let object: RuntimeObject?
    }

    public struct Entry: Sendable {
        public let key: RuntimeObject?
        public let value: RuntimeObject?
    }

    public let id: ID
    public let kind: Runtime.Kind
    public let subtype: Runtime.Subtype?
    public let className: String?
    public let value: Runtime.JSONValue?
    public let description: String?
    public let size: Int?
    public let preview: Runtime.ObjectPreview?
    public let canRequestProperties: Bool

    public static func == (lhs: RuntimeObject, rhs: RuntimeObject) -> Bool
    public func hash(into hasher: inout Hasher)
}

public typealias RuntimeProperty = RuntimeObject.Property
public typealias RuntimeObjectPreview = Runtime.ObjectPreview

public struct RuntimeEvaluation: Sendable {
    public let object: RuntimeObject
    public let isException: Bool
}

public struct WebInspectorRuntimeScopeError: Error {
    public let operationError: any Error
    public let cleanupError: any Error
}

public final class WebInspectorRuntime: WebInspectorFeatureHandle {
    public var state: WebInspectorFeatureState { get }
    public var stateUpdates:
        WebInspectorStateUpdates<WebInspectorFeatureState> { get }
    public func objectScope(
        named name: String? = nil,
        boundTo contextID: RuntimeContext.ID? = nil
    ) async throws -> WebInspectorRuntimeObjectScope
    public func objectScope(
        claiming objectID: RuntimeObject.ID
    ) async throws -> WebInspectorRuntimeObjectScope
    public func withObjectScope<Output: Sendable>(
        named name: String? = nil,
        boundTo contextID: RuntimeContext.ID? = nil,
        _ operation: @Sendable (
            WebInspectorRuntimeObjectScope
        ) async throws -> Output
    ) async throws -> Output
}

public final class WebInspectorRuntimeObjectScope: Sendable {
    public var isClosed: Bool { get }

    public func evaluate(
        _ expression: String
    ) async throws -> RuntimeEvaluation
    public func properties(
        of objectID: RuntimeObject.ID,
        ownProperties: Bool = true
    ) async throws -> [RuntimeProperty]
    public func preview(
        of objectID: RuntimeObject.ID
    ) async throws -> RuntimeObjectPreview
    public func collectionEntries(
        of objectID: RuntimeObject.ID
    ) async throws -> [RuntimeObject.Entry]
    public func close() async throws
}
~~~

This sketch specifies the changed container/context/query/feature contracts.
The existing concrete persistent models such as DOMNode, NetworkRequest,
NetworkEntry, ConsoleMessage, and their stable ID types remain public domain
declarations. CSSStyles joins that model catalog through the declaration above.
Their full field inventories belong in generated interface/DocC rather than a
second copy in this architecture document. RuntimeObject and its property/entry
types become immutable Sendable graph snapshots, not context-owned persistent
models.

ModelContainer equality is object identity. Its state and state-sequence
registration are synchronized internally; Sendable does not expose mutable
feature/store state without those owners.

ModelContext equality is object identity. Its metatype is Sendable, while an
unavailable Sendable conformance gives an explicit compiler error if an
instance is shared through an API that requires Sendable. Region-based
isolation may still prove a one-way transfer of a disconnected value safe;
the framework does not claim to disable that language feature. Consumers pass
stable IDs and immutable QueryValue values across concurrently used actors,
never a context or model instance.

Persistent model equality is also object identity. `model(for:)` materializes
the context-local observable object when the canonical record currently
exists; `registeredModel(for:)` only returns an object already present in that
context's identity map. Both return nil for an absent or stale Web Inspector
identity rather than inventing an unsaved placeholder.

The context initializer and binding initializer are internal to
WebInspectorDataKit. `makeModelActorBinding()` is the only public custom-context
issuance point. In one synchronous registration-gate operation it checks that
the container is open, creates a context/ingress/close-token pair, registers
the ingress, and returns a concrete binding. Initial store
synchronization may continue asynchronously, but its finite task is retained
and joined by the context lifecycle core; there is no fire-and-forget
registration task. `@WebInspectorModelActor` always synthesizes or validates a
stored `nonisolated let modelActorBinding` and adds the protocol conformance.
For an actor without a custom designated initializer it also supplies
`init(modelContainer:) throws` and `init(modelActorBinding:)`; the latter is
the explicit shared-context story. When the actor declares its own initializer
for additional dependencies, the macro does not synthesize a conflicting
initializer and Swift requires that initializer to assign the macro-owned let
exactly once. A computed binding property is diagnosed. There is no defaulted
`#isolation`, Task.detached delivery hop, weak dynamic actor lookup, or
preconditionIsolated.

The protocol is the expansion contract, not a second hand-written construction
surface. Repository and ContractTests consumers use the macro; a verifier
rejects direct `: WebInspectorModelActor` conformances outside macro-expansion
fixtures. This matches SwiftData's macro-backed supported path and avoids
claiming that a protocol getter alone can enforce stored executor identity.

The public type is an issuance and retention binding, not a second implementation
of Swift's SerialExecutor protocol. It exposes no public members. Internally it
strongly retains the context, lifecycle core, and one DispatchSerialQueue. That
same queue object is the sole runtime identity returned by the model actor's
unownedExecutor and the sole TaskExecutor preference used by the finite context
mailbox drain. The package deployment floor makes both conformances available.
This avoids a wrapper executor and its underlying queue becoming two runtime
identities. The `unsafe` spelling is localized to the standard-library
UnownedSerialExecutor conversion, while the binding's lifetime satisfies its
documented retention requirement.

These fields and the initializer are `internal`, not `package`: package access
would let sibling UI and testing targets extract a non-Sendable context or the
queue outside WebInspectorModelActor. There is no custom scheduler consumer
story in this migration, and Sources/Storage extension does not vary the
context scheduler, so a public executor protocol and context escape hatch are
not added.

Context close is idempotent and awaited. It closes only that context's query
registrations, operation mailbox, and identity map; later operations fail with
the typed `contextClosed` outcome. A context closed by its container instead
reports `containerClosed`. It does not detach or close the container shared by
other contexts, and it cannot clear a binding stored in a model actor's `let`
property.

If multiple actors intentionally store the same issued binding, they share one
context, identity map, serial queue, and close completion. Calling
closeModelContext() from any one of them closes that shared context for all of
them; later operations from every sharer receive contextClosed. Consumers that
need independent close fate request separate bindings.

The retain and close graph is fixed:

| Owner | Strongly retains | Release/join authority |
| --- | --- | --- |
| Container | Proxy, feature runtimes, model store, weak context ingresses, and a weak MainActor-context cache | detach releases attachment; close snapshots live ingresses, joins all work, and closes the physical owner |
| Attachment registry | Weak WKWebView and weak container reservation | detach/failure/close releases once |
| Feature runtime | One finite runner task, current ordered scopes, feature state, and command waiters | container detach/close cancels and joins the runner; the runner awaits every scope release |
| Ordered event scope | Bounded mailbox and acquired physical capability leases | explicit async scope close drains/cancels waiters, then releases and joins leases; stream deinit is only synchronous invalidation |
| Feature state iterator | Its bounded last-value mailbox | iterator cancellation or feature/container close |
| Custom model actor | Its model-actor binding; container is derived from it | actor deinit releases the binding |
| Model-actor binding | Context, lifecycle core, the sole DispatchSerialQueue, and synchronous registration token | context close unregisters and joins the mailbox drain; binding deinit only synchronously cancels unused issuance |
| Custom context | Container, lifecycle core, identity map, and query registrations | context close makes it inert; binding deinit releases it |
| Model store | Weak Sendable context ingress, never the context object | context/container close |
| FRC | Context and its registration token | FRC close unregisters and finishes subscribers |
| Context registry | Weak FRC application endpoint | FRC/context close |
| Update iterator | Its subscriber token/mailbox | iterator cancel or FRC close |
| SwiftUI query storage | Current observable FRC and a short-lived bind/refetch task | context change closes the old FRC; context/container close is deterministic final join |

Contexts strongly retain their container; retaining a model actor/binding or
context can therefore keep an open attachment alive. Only `container.close()`
is the physical stop authority. Context close makes that context inert but does
not pretend to release another owner's binding or container. The built-in
session always closes its container on dismissal; custom owners must either
close the container explicitly or release every context owner.

Container close first rejects new scopes and context issuance, then cancels and
joins feature runners. Each runner explicitly closes its scopes and awaits
capability release before Proxy detach runs; only after Proxy teardown does the
container release the WKWebView reservation. AsyncSequence continuation
termination is a synchronous cleanup signal, not the authority for asynchronous
disable/release completion. A raw WebInspectorPage is a non-owning command
handle and does not keep its Proxy/attachment alive; after owner teardown its
commands fail with the typed closed/connection outcome.

To avoid a container-mainContext retain cycle, an open mainContext is weakly
cached on MainActor. Its object identity is stable for as long as any client
retains it. WebInspectorSession pins it for its presentation lifetime; in
SwiftUI, an active Query storage/FRC binding pins it while the Environment
retains only the container. It uses one bounded MainActor ingress/drain.
Explicitly closing that context unregisters it and evicts the matching
open-cache entry; the next getter while the container remains open issues a
new open context, and the next DynamicProperty.update() rebinds the query.

Container close changes state to closing and snapshots the context registry at
one internal registration gate before it awaits any shutdown work. During
closing or closed, mainContext never consults or populates the open cache; it
returns a weakly cached inert, unregistered context whose operations report
`containerClosed`. It therefore cannot register after close's snapshot during
MainActor reentrancy. Calling `makeModelActorBinding()` while closing or closed
also throws `containerClosed`. Open-check plus ingress registration, and the
closing transition plus live-ingress snapshot, are atomic operations on that
same gate: if issuance wins it is in close's join set; if close wins issuance
is rejected.
Additional open contexts are owned by a container-issued binding installed on
the consumer actor; its retained queue is the actor's custom executor:

~~~swift
@WebInspectorModelActor
actor ExportWorker {
    func matchingRequestIDs() async throws -> [NetworkEntry.ID] {
        try await modelContext.fetchIdentifiers(
            WebInspectorFetchDescriptor<NetworkEntry>()
        )
    }
}

let worker = try ExportWorker(modelContainer: container)
~~~

The binding is retained before the actor can accept jobs, and unownedExecutor
always returns its same retained DispatchSerialQueue. Registration is already
linearized before makeModelActorBinding returns. The lifecycle core owns the
bounded operation mailbox and at most one finite drain task using that same
queue as its TaskExecutor preference. The first fetch waits for initial
synchronization and feature readiness without blocking the mailbox drain.
Model application and the model actor's own jobs therefore use one statically
declared serial owner. A consumer never starts or stores a driver Task.

If an issued binding is discarded before any work starts, its registration
token synchronously invalidates the weak ingress and no drain task is created.
Once work starts, the lifecycle core—not a task closure retaining the
binding/context—owns and joins the finite drain. The store retains only a weak
Sendable ingress, so an abandoned issuance cannot keep a context, container,
or mailbox drain alive. Explicit context/container close remains the
deterministic cancellation and join path.

Domain commands are removed from ModelContext. Examples:

~~~swift
try await container.network.clear()
let bodyContent = try await container.network.responseBody(for: requestID)
let selectedNodeID = try await container.dom.pickElement()
let styleID = try await container.dom.loadStyles(for: nodeID)
try await container.page.reload(ignoringCache: true)
~~~

Commands accept stable IDs, not context-local model references. The caller
resolves returned IDs through its own context. A mutating command returns only
after its canonical store commit has linearized; each context then applies the
same transaction on its own operation queue. A command never reaches into one
particular context to make that context appear synchronously ahead of the
others.

### Domain command cutover

The cutover is one pass. No deprecated forwarding extension remains on
ModelContext, NetworkBody, CSSStyles, or the old RuntimeObjectGroup.

| Current API | Target API | Owner and retained semantics |
| --- | --- | --- |
| `context.domNode(id:)` | `context.model(for:)` | Generic context lookup replaces the domain alias. |
| `requestDOMChildren(of: DOMNode, depth:)` | `container.dom.requestChildren(of: DOMNode.ID, depth:)` | DOM feature actor validates document identity and owns lazy-tree reduction. |
| `setDOMAttribute`, `setOuterHTML` | `container.dom.setAttribute`, `container.dom.setOuterHTML` with `DOMNode.ID` | DOM feature actor commits the mutation and document-bound undo capability. |
| `removeDOMNodes([DOMNode])` | `container.dom.removeNodes([DOMNode.ID])` | Deepest-first ordering and per-node partial failures remain one DOM operation. |
| `copyText`, `selectorPath`, `xPath` | `container.dom.text(_:for: DOMNode.ID)` | One stable-ID representation API replaces three overlapping context APIs. |
| `highlightDOMNode`, `hideDOMHighlight` | `container.dom.highlight`, `container.dom.hideHighlight` | Highlight and picker share the DOM feature owner. |
| `context.reload` | `container.page.reload` | Reload is a Page command and requires no DOM capability. Navigation events drive each semantic feature's reset. |
| `context.cssStyles(for:)` | `container.dom.loadStyles(for: DOMNode.ID) -> CSSStyles.ID` | DOM/CSS actor coalesces the load and commits one persistent CSSStyles record. |
| `refreshCSSStyles(for:)` | `container.dom.refreshStyles(CSSStyles.ID)` | Refresh updates the same persistent identity. |
| `setCSSProperty`, `setCSSDeclarationText` | `container.dom.setProperty`, `container.dom.setDeclarationText` with `CSSStyleProperty.ID` | Property identity includes styles identity and cascade generation, so an old declaration becomes typed stale instead of retargeting. |
| `context.clearNetworkRequests()` | `container.network.clear()` | Network actor commits one clear transaction for every context. |
| `NetworkBody.load()` | `container.network.responseBody(for: NetworkRequest.ID)` | Network actor owns request-revision coalescing, body retrieval, and canonical body commit. |
| `context.withRuntimeObjectGroup` | `container.runtime.withObjectScope` | Runtime actor owns graph admission, drain, and release; no context/model is captured. |
| old RuntimeObjectGroup commands | WebInspectorRuntimeObjectScope commands with RuntimeObject.ID | Inputs are scope-bound stable IDs and outputs are immutable Sendable graph snapshots. |

CSSStyles becomes a WebInspectorPersistentModel whose semantic ID derives from
the document-scoped DOMNode.ID. A refresh keeps that ID and updates every
context-local observable instance. CSSStyleProperty is an immutable Sendable
value; its opaque ID additionally contains the cascade/presentation generation
and backend declaration address. DOM reset invalidates the CSSStyles record;
CSS refresh invalidates old property IDs without changing CSSStyles.ID.

DOMUndoCapability is a Sendable DOM-actor-backed handle containing only an
opaque document-scope token and owner reference. undo and redo after navigation
return a typed stale-scope error. DOMMutationOutcome is Sendable. Neither type
owns the physical Proxy or requires close.

NetworkResponseBodyContent preserves the raw String, base64 flag, size,
truncation, display kind, and syntax hint. Converting it to Data would lose the
distinction between encoded protocol content and decoded bytes. The Network
actor coalesces in-flight requests by persistent request ID plus response
revision, commits the successful value into the canonical NetworkRequest body,
and then returns the same immutable value. Body-command failure affects that
body presentation only; it does not terminate the Network feature. NetworkBody
remains a read-only observable component materialized with NetworkRequest, but
it owns no Task, lease, weak context, command method, or cancellation policy.

WebInspectorRuntimeObjectScope contains only a Runtime feature-owner reference
and opaque scope ID. RuntimeObject, Property, Entry, and RuntimeEvaluation are
immutable Sendable snapshots. RuntimeObject.ID is opaque: a canonical Console
parameter uses its message/parameter identity, while evaluated and descendant
objects use scope-plus-ordinal identity. Every scope command validates that
the supplied ID is claimed by that scope.
Independent scopes drain admitted operations, send Runtime.releaseObjectGroup
exactly once, and invalidate their IDs. A console-parameter scope closes only
its local claim because WebKit owns the shared `console` wire group. Explicit
close is idempotent and awaited. withObjectScope performs cancellation-
insensitive close on success, failure, and cancellation and preserves both the
operation and cleanup errors when both fail. deinit only invalidates admission
synchronously; it cannot own asynchronous wire release.

## Generic fetch API

~~~swift
public struct WebInspectorFetchDescriptor<Model>: Sendable
where Model: WebInspectorPersistentModel {
    public var predicate: Predicate<Model.QueryValue>?
    public var sortBy: [SortDescriptor<Model.QueryValue>]
    public var fetchLimit: Int?
    public var fetchOffset: Int?

    public init(
        predicate: Predicate<Model.QueryValue>? = nil,
        sortBy: [SortDescriptor<Model.QueryValue>] = []
    )
}
~~~

Consumers write the model type once. QueryValue remains an implementation
safety boundary and is inferred:

~~~swift
let descriptor = WebInspectorFetchDescriptor<NetworkEntry>(
    predicate: #Predicate {
        $0.searchTexts.contains {
            $0.localizedStandardContains(searchText)
        }
        && $0.resourceCategories.contains {
            selectedCategories.contains($0)
        }
    },
    sortBy: [
        SortDescriptor(\.startedAt, order: .reverse),
        SortDescriptor(\.insertionOrdinal, order: .reverse),
    ]
)
~~~

Predicate<Model> is not evaluated on a background actor because Model is the
context-owned observable reference. The immutable, Sendable QueryValue mirrors
the queryable fields and is evaluated by the query actor.

Invalid offset, limit, unsupported model type, or predicate evaluation produces
a typed fetch error at fetch/performFetch. Mutable descriptor properties do not
trap.

The query engine evaluates user sort descriptors in order, then uses the
store-assigned canonical rank as an implicit final key. With no user sort,
canonical rank is the order. This makes membership deterministic even when
every requested key compares equal. Offset and limit are applied only after
that total order is established.

## Fetched-results controller

The controller has one generic parameter and flat integer offsets.

~~~swift
@Observable
public final class WebInspectorFetchedResultsController<Model>
where Model: WebInspectorPersistentModel {
    public let modelContext: WebInspectorModelContext
    public var fetchDescriptor: WebInspectorFetchDescriptor<Model> { get }

    public var fetchedObjects: [Model]? { get }
    public var snapshot:
        WebInspectorFetchedResultsSnapshot<Model.ID>? { get }
    public var revision:
        WebInspectorFetchedResultsRevision? { get }
    public var fetchError: (any Error)? { get }

    public init(
        fetchDescriptor: WebInspectorFetchDescriptor<Model> = .init(),
        modelContext: WebInspectorModelContext
    )

    public nonisolated(nonsending) func performFetch() async throws
    public nonisolated(nonsending) func refetch(
        using descriptor: WebInspectorFetchDescriptor<Model>
    ) async throws
    public var updates:
        WebInspectorFetchedResultsUpdateSequence<Model.ID> { get }
    public nonisolated(nonsending) func close() async
}

public struct WebInspectorFetchedResultsSnapshot<ItemID>: Sendable
where ItemID: Hashable & Sendable {
    public let itemIDs: [ItemID]
}

public enum WebInspectorFetchedResultsItemChange<ItemID>: Sendable
where ItemID: Hashable & Sendable {
    case insert(itemID: ItemID, at: Int)
    case delete(itemID: ItemID, at: Int)
    case move(itemID: ItemID, from: Int, to: Int)
}

public enum WebInspectorFetchedResultsUpdate<ItemID>: Sendable
where ItemID: Hashable & Sendable {
    case initial(
        revision: WebInspectorFetchedResultsRevision,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    )
    case changes(
        fromRevision: WebInspectorFetchedResultsRevision,
        toRevision: WebInspectorFetchedResultsRevision,
        itemChanges: [WebInspectorFetchedResultsItemChange<ItemID>],
        updatedItemIDs: Set<ItemID>
    )
    case reset(
        revision: WebInspectorFetchedResultsRevision,
        snapshot: WebInspectorFetchedResultsSnapshot<ItemID>
    )
}

public struct WebInspectorFetchedResultsUpdateSequence<ItemID>:
    AsyncSequence, Sendable
where ItemID: Hashable & Sendable {
    public typealias Element = WebInspectorFetchedResultsUpdate<ItemID>
    public typealias Failure = Never

    public struct AsyncIterator: AsyncIteratorProtocol {
        public mutating func next() async -> Element?
    }

    public func makeAsyncIterator() -> AsyncIterator
}
~~~

Before the first successful performFetch, fetchedObjects, snapshot, and
revision are nil. performFetch is the linearization point for initial
registration. These controller properties are publicly read-only. On success
the context processor updates them atomically on MainActor or the issued model
actor's serial queue.

The accepted/pending/closed enum is the FRC's one Observation-tracked stored
state; fetchedObjects, snapshot, revision, fetchDescriptor, and fetchError are
computed from it. Explicit FRC close or context/container close makes one
terminal transition, clears fetchedObjects/snapshot/revision, records
contextClosed/containerClosed as appropriate, unregisters, and finishes update
iterators normally. Close is not a fetch failure, so last-success retention
does not apply after the owning context is invalid. Because a wrapped-result
getter reads that enum, even an unfetched nil-to-closed transition invalidates
an observing SwiftUI body.

refetch is the only descriptor-replacement API. A successful replacement
commits the descriptor, objects, snapshot, and next controller revision
together. It publishes `initial` when the controller has never accepted a
result, and otherwise publishes one `reset` even when the resulting item IDs
are equal. That explicit publication represents the newly accepted descriptor;
it is not an empty changes update. If replacement fails, all four retain the
last successful values and only fetchError changes, so consumers never see a
new descriptor paired with old results.

On failure, fetchedObjects and snapshot retain the last successful result,
fetchError stores the failure, and the thrown error describes the attempted
fetch. Internally one private closed-enum state value owns the accepted
descriptor/result and any requested replacement; these are not independently
mutable fields.
While a replacement is pending, source deltas may keep the accepted
last-success result current, but they do not clear the requested replacement's
error or make that descriptor appear accepted.

Invalid limit/offset, unsupported model, and predicate-evaluation failures are
deterministic query failures. They are reevaluated only through an explicit
refetch (or a new SwiftUI semantic query ID/context binding). Feature runner
failure is reported by container state, not converted into a query error. A
pre-ready registration remains pending without polling until an authoritative
ready source arrives or its context closes. An ordinary delta/reset evaluated
for a previously accepted descriptor cannot clear a pending replacement error.

An updates subscription created before the first successful fetch waits for
the initial publication. A later subscription starts atomically with the
controller's current successful state and then emits post-apply transactions.
A slow updates consumer receives reset rather than a discontinuous delta. The
controller owns the query registration; the update sequence does not own or
duplicate it.

Each iterator has its own bounded latest-reset mailbox. Insert/delete/move
indices are old-snapshot coordinates for delete/from and new-snapshot
coordinates for insert/to. Content changes are represented only by
`updatedItemIDs`; there is no duplicate `.update` item change. If a member both
moves and changes content, it appears in the move change and in
`updatedItemIDs`. A normal changes publication carries no full snapshot: it is
applied to the immediately preceding revision, while the controller's
read-only snapshot already holds the atomically committed final state. This is
the initial-snapshot-then-complete-deltas contract; it avoids copying the
entire membership for each protocol event. On subscriber overflow, queued
deltas coalesce into one latest reset. While that reset waits, its complete
snapshot/revision is replaced by newer state, so the reset cannot itself be
dropped. Cancelling an iterator removes only that subscriber.
Controller/context close finishes all iterators after their current waiter is
resumed. A deterministic fetch failure does not terminate the sequence; an
explicit successful refetch can publish again.

close is the explicit cancellation and join authority. Deinitialization only
cancels its registration as a best-effort backstop.

An in-flight performFetch or refetch is cancellable until its context
operation reaches the commit linearization point. Cancellation before that
point removes the pending operation and throws CancellationError without
changing controller state. Cancellation after the atomic commit does not undo
the accepted result. close is cancellation-insensitive: it cancels pending
operations and waits until their removal or completed commit has joined.

### Context operation queue

Each context has one operation queue containing:

- source initial/delta/rebase values;
- fetched-results registration;
- descriptor replacement;
- query close;
- context close.

A nonisolated Sendable ingress owns the bounded lock-protected FIFO and the
single drain-scheduled bit. It is the only object retained weakly by the model
store. The context lifecycle core strongly owns that ingress, identity map,
query registrations, close token, and any finite drain task. Enqueuing the
first operation into an idle mailbox schedules exactly one drain; a drain
consumes until empty or until it launches one query evaluation, then relinquishes
the scheduled bit or is resumed by that evaluation's completion. There is no
permanent driver task and no polling loop.

beginClose atomically changes the ingress from open to closing, appends one
terminal operation after all already accepted operations, rejects later work
with contextClosed, and returns one shared close completion. The terminal turn
transitions every registered FRC's observable state to the appropriate closed
case, finishes its iterators, removes query registrations, clears the identity
map, synchronously invalidates the store registration, and completes every
waiter before fulfilling that completion. Explicit mainContext close also
evicts the matching weak container cache entry in this ordered close path, so
completion cannot race a getter that still returns the closing context.
Container close uses the same operation with containerClosed and joins the
same completion; concurrent close callers never start a second terminal turn.

The context operation processor is the only consumer. MainContext drains it on
MainActor; a custom context drains it on the DispatchSerialQueue retained by
its issued model-actor binding. It passes
immutable mutations to the query actor, receives ID/difference results, then
synchronously applies model patches and all affected controller storage in one
processor turn.

The processor may await a query-actor evaluation for a revision already marked
ready; source values accumulate in the bounded context mailbox and are applied
after that linearization point. It never awaits future feature readiness from
inside the queue. Pre-ready registrations and descriptor replacements are
stored as pending operations, the processor turn returns, and a later
ready/close input resumes them. This separation prevents the
future source transaction from waiting behind the continuation it must
complete.

This single queue removes the registration race that otherwise occurs when an
actor is reentered between query registration and a later source revision. It
also replaces the current owner registry, lease, admission, retirement, and
raw/controller publication paths.

## SwiftUI query

WebInspectorSwiftUI contains only the SwiftUI overlay:

~~~swift
@MainActor
@propertyWrapper
public struct WebInspectorQuery<Model>: @MainActor DynamicProperty
where Model: WebInspectorPersistentModel {
    public init(
        filter: Predicate<Model.QueryValue>? = nil,
        sort: [SortDescriptor<Model.QueryValue>] = []
    )

    public init<ID: Hashable>(
        filter: Predicate<Model.QueryValue>? = nil,
        sort: [SortDescriptor<Model.QueryValue>] = [],
        id: ID
    )

    public init(_ descriptor: WebInspectorFetchDescriptor<Model>)

    public init<ID: Hashable>(
        _ descriptor: WebInspectorFetchDescriptor<Model>,
        id: ID
    )

    public var wrappedValue: [Model] { get }
    public var fetchError: (any Error)? { get }
    public var modelContext: WebInspectorModelContext? { get }
    public mutating func update()
}

extension View {
    @MainActor
    public func webInspectorModelContainer(
        _ container: WebInspectorModelContainer
    ) -> some View
}
~~~

SwiftData also offers Query initializers with `transaction` and `animation`.
They are deliberately omitted here. In SwiftData those arguments govern the
transaction in which fetched-result mutations update the UI. In this design,
the context processor owns the observable FRC mutation and Query storage owns
neither a result mirror nor a permanent subscription callback in which it
could honestly apply such a transaction. Merely retaining the argument would
be a fake API; moving a SwiftUI closure into DataKit or adding a result mirror
would violate the owner boundary. A consumer that wants animation applies
`View.animation(_:value:)` or `View.transaction(value:_:)` to stable result IDs
or the FRC revision.

The modifier writes an optional WebInspectorModelContainer into an internal
EnvironmentValues entry. It does not store a non-Sendable ModelContext in the
environment. The environment retains the container for the view hierarchy,
and each MainActor query access resolves container.mainContext. This also
observes explicit main-context close and reissuance instead of pinning the
closed context as an environment value.

Usage:

~~~swift
struct NetworkList: View {
    @WebInspectorQuery private var entries: [NetworkEntry]

    init() {
        let media = NetworkRequest.ResourceCategory.media
        _entries = WebInspectorQuery(
            filter: #Predicate {
                $0.resourceCategories.contains(media)
            },
            sort: [SortDescriptor(\.startedAt, order: .reverse)]
        )
    }

    var body: some View {
        List(entries) { entry in
            Text(entry.url)
        }
    }

    private var queryError: (any Error)? {
        _entries.fetchError
    }
}
~~~

The wrapped value starts empty, becomes the first synchronized result, and
retains the last successful result if a later fetch fails. Missing environment
context is stored by query storage as a bindingError and is exposed as
WebInspectorQueryError.missingModelContext through fetchError; it is not a
precondition failure and does not require a placeholder FRC.

As with SwiftData Query, fetchError and modelContext are backing-storage
properties intended to be read while evaluating body. They are not a second
observable lifecycle API.

Connection and feature lifecycle remain observable through ModelContainer and
feature handles. The query wrapper has no projected value and does not publish
loading/ready/failure.

A SwiftUI body recomputation with unchanged semantic query identity performs
no fetch or publication. A changed identity is serialized through the same
context operation queue as UIKit FRC changes. Within the same context it
performs exactly one refetch(using:) on the existing FRC. A context identity
change closes that FRC and creates a new one; models from the old context are
not returned while the new binding is pending.

`SortDescriptor` is Equatable and Hashable, but `Predicate` is neither and its
captured values have no public semantic-equality contract. The complete fetch
descriptor therefore cannot be compared automatically. The initializer
without `id` treats its descriptor as fixed for the property storage lifetime.
A query whose captured criteria can change uses the `id:` overload and supplies
the complete `Hashable` semantic configuration:

~~~swift
init(criteria: NetworkCriteria) {
    let searchText = criteria.searchText
    _entries = WebInspectorQuery(
        Self.descriptor(searchText: searchText),
        id: criteria
    )
}
~~~

Predicate macro inputs are hoisted to supported local Sendable values before
construction; code does not rely on captured aggregate key paths such as
`criteria.searchText` inside the macro expansion.

An equal ID performs no work; a changed ID performs one serialized refetch.
The wrapper does not reflect predicates, invent a fingerprint, or refetch from
every `DynamicProperty.update()` call.

Query storage tracks two identities with different effects. The
`contextBindingIdentity` is `ObjectIdentifier(modelContext)`; changing it,
including missing-context to present-context and one container's mainContext
to another, closes the old controller, clears its models, and binds a new FRC
even when the caller-supplied query ID is equal. The
`semanticQueryIdentity` is the caller's concrete `ID` type plus value; changing
it while the context identity is unchanged performs one `refetch(using:)` on
that same FRC. The result is empty during an initial bind or context switch.
Last-success retention applies to failed fetches and semantic-ID refetches
within the same context binding, so a failed descriptor replacement can keep
the prior descriptor's result visible without treating the new descriptor as
accepted.

When an explicitly closed mainContext is evicted while its container remains
open, the FRC terminal Observation invalidates a body that reads only
wrappedValue. The following DynamicProperty.update resolves the container's
new mainContext and binds exactly once. Container close produces the same
terminal observation but cannot issue a replacement context, so Query remains
empty with containerClosed and starts no rebind loop.

The DynamicProperty keeps one MainActor @Observable Storage reference in
SwiftUI State. `State(wrappedValue: Storage())` can construct a temporary
Storage before SwiftUI reuses an existing State location when a View value is
recreated, so Storage.init is deliberately inert and cheap: it creates no FRC,
task, registration, or model context. SwiftUI installs the State location and
then calls DynamicProperty.update() before evaluating body; update reads the
installed Storage and submits the desired binding exactly once. The FRC is
itself @Observable, so wrappedValue reads its result directly; there is no
result mirror and no permanent updates-sequence subscription task.
wrappedValue, fetchError, and modelContext are pure reads and never start
lifecycle work while body is being evaluated.

The Swift 6.3 SDK's observable-object lazy State initializer is not public.
Writing a nil `State<Storage?>` from DynamicProperty.update() is also not a
substitute: a real SwiftUI host does not make that object available to the same
body update or retain it as the installed value. The design therefore accepts
discarded inert Storage allocations but forbids them from owning lifecycle
work; only the installed Storage reached by update may bind an FRC.

Storage owns a small bindingError only for failures that occur before an FRC
exists, such as a missing environment container or a context-rebind failure.
It is not a result or lifecycle mirror. Public fetchError reads
`bindingError ?? currentFRC?.fetchError`, and a successful bind clears
bindingError. Observation therefore reports both binding failures and
fetchError-only FRC changes without requiring a second result collection.

Storage owns only the current FRC and a short-lived serialized lifecycle task.
The fixed initializer keeps the descriptor accepted for that State-storage
lifetime. The dynamic initializer identifies a query by both the caller's
Hashable value and its concrete ID type, avoiding cross-type AnyHashable
collisions. An equal context-binding and semantic-query identity performs no
work. A changed semantic ID in the same context attempts one refetch and
records that attempt even if it fails, so body recomputation does not create
an automatic retry loop. A context change or missing context supersedes
pending work, awaits old-FRC close, and then installs the new binding. Every
completion checks a binding token before publishing. Lifecycle tasks do not
strongly retain storage across suspension. Storage records the desired
context binding and last-attempted semantic query identity, not a false
accepted descriptor. The FRC's single internal state remains the authority
for its accepted descriptor and pending requested replacement. A failed
dynamic refetch therefore keeps the error visible while old-descriptor deltas
update the last-success result; only the retry conditions documented in the
FRC contract can accept the requested descriptor.
Storage is an `@MainActor` class with `isolated deinit`. That deinitializer
cancels any short-lived lifecycle task and synchronously invalidates the
current FRC registration token so the registry cannot target dead storage; it
does not await feature or context work. A normal nonisolated deinitializer
cannot read MainActor-isolated `currentFRC` and is not an implementation
option. Deterministic asynchronous joining belongs to explicit
FRC/context/container close. Missing context owns no FRC or subscription task.

## Domain semantics

### DOM, CSS, and picker

The DOM feature actor owns document bootstrap, the DOM reducer, CSS records,
highlight commands, and picker state. For each successful document snapshot it
asks the model store actor to prepare and activate a new binding scope in the
same store command that commits the snapshot. It does not issue, activate, or
mirror the scope ID itself. CSS suboperations may fail independently, while a
DOM reset invalidates DOM-scoped CSS records.

The DOM feature opens its ordered scope before `DOM.getDocument`; the DOM
protocol has no separate enable command. `DOM.getDocument` supplies the
synchronized snapshot and establishes backend node bindings. documentUpdated,
navigation, event gap, or an externally inconsistent live-tree relation
triggers a DOM-only rebootstrap. Known events for an unloaded subtree follow
WebKit's semantics:
they update unloaded child count when possible or are ignored as documented;
they do not synthesize nodes.

For childNodeInserted, `previousNodeId == 0` is the normal WebKit encoding of
"no previous sibling" and inserts at index zero. It is never an invariant
failure. A nonzero previous node that is unknown while the parent's children
are fully loaded is an external tree gap and fails the attachment; for an
incompletely loaded parent the event follows the unloaded-subtree rule instead
of inventing a sibling.

DOM bootstrap uses the same exact-order principle as Network:

~~~text
register ordered DOM scope
-> scope.command(DOM.getDocument(depth: -1)) returns reply + boundary W
-> same feature owner drains that scope through boundary W
-> reconcile the snapshot with the complete pre-W prefix
-> atomically issue/activate a new binding scope and commit the result at W
-> apply buffered DOM events with sequence > W in FIFO order
-> ready
~~~

`setChildNodes`, `childNodeInserted`, `childNodeRemoved`, and attribute/text
events at or before W are represented by the complete snapshot and are not
replayed. The same events after W are deltas. `documentUpdated` before the
snapshot commit invalidates that attempt, discards its snapshot/buffer, and
starts a new `getDocument` cut; after W it resets DOM and starts the next cut.
No bootstrap event mutates the live tree until the snapshot and binding scope
have committed together. Reply-adjacent, mid-bootstrap documentUpdated, and
lazy-child event order are contract-tested against the single Proxy FIFO.

An unexpected same-document event gap or relation conflict fails the
attachment without publishing a guessed or partially reduced tree. Confirmed
`documentUpdated`, target replacement, or attachment-generation change is
different: it invalidates the old document identity and bootstraps the known
new source, so stale records are not presented as the current page.

Picker state is a state machine, not a capability lease:

~~~text
idle -> enabling -> active
active -- Inspector.inspect / DOM.inspect --> resolvingSelection(backendIdle)
resolvingSelection(backendIdle) -> idle
active -- cancel --> disabling -> idle
enabling -- cancel --> cancelPendingEnable -- enable reply --> disabling -> idle
resolvingSelection(backendIdle) -- cancel --> idle
disabling -- cancel --> disabling
enabling / cancelPendingEnable / resolvingSelection / disabling
    -- target reset --> idle
~~~

WebKit's InspectorDOMAgent disables searching before it sends/focuses the
selection. A normal page reports `Inspector.inspect` with a remote object;
augmented contexts can report `DOM.inspect` with a node ID. Receipt of either
event immediately records the backend picker as idle. For `Inspector.inspect`,
the feature then resolves the remote object through `DOM.requestNode` before it
publishes the stable selected node ID. Resolution failure ends this selection
without re-enabling the picker or failing DOM.

Cancellation while enabling records a cancel intent; if enable later succeeds,
the feature sends disable before completing cancellation. Cancellation while
active starts disable, while cancellation during disabling joins the existing
disable. Cancellation during `resolvingSelection(backendIdle)` cancels only
remote-object resolution because WebKit has already disabled the picker; it
must not send a redundant disable. Each path completes its waiter once after
the relevant command or target reset. A generation token makes the latest
enable/disable intent authoritative.

`pickElement()` owns exactly one waiter. A second call while enabling,
cancel-pending, active, resolving, or disabling throws
`WebInspectorElementPickerError.busy`. The UI toggle calls
`cancelElementPicker()`; cancel while idle is a no-op, otherwise it cancels the
owner operation and joins the state-specific completion described above. The
owner task then throws CancellationError. Target replacement throws
targetChanged.
Enable rejection returns enableFailed and returns to idle. Selection resolution
failure returns selectionResolutionFailed after backendIdle and cannot
reactivate the picker.

A failed disable sends no automatic retry. It returns `disableFailed` and
keeps the backend-active state authoritative. A later explicit cancel intent
sends one new disable command; target reset retires the picker with its target.
The UI displays the picker as active until the owner confirms disable and never
assumes success from the button's local state.

The UI observes this one feature state. It does not keep a second
isElementPickerEnabled mirror.

### Page and DOM-binding identity scopes

The model store actor contains the sole identity-scope registry and is the only
issuer and activation owner of `WebInspectorDOMBindingScopeID`, because
attachment/page generation and target binding are facts shared by multiple
semantic features. A successful DOM bootstrap submits its snapshot and reply
watermark to one store operation. That operation issues and activates the next
scope, commits the new DOM snapshot, and invalidates old DOM/CSS records in one
transaction. No pending scope is externally visible before that transaction.
The same actor records the sequence-indexed value containing attachment
generation, page generation, semantic target, agent target, and binding scope
ID.

Network asks the registry for the scope at each initiator event's connection
sequence. Existing NetworkEntry identities are never rewritten when the DOM
document binding advances; later events use the new scope and cannot collide with
old raw node IDs. Pending initiator work at the cut is either reduced under the
scope valid at its sequence or committed ungrouped; it is never guessed or
carried into the new scope. DOM failure does not reset Network, and Network
never reads mutable DOM actor state directly. This explicit immutable scope
handoff is the only DOM-to-Network identity dependency.

### Network bootstrap

Network bootstrap uses one ordered cut:

~~~text
register ordered scope
-> Page.enable
-> Network.enable and receive its reply
-> scope.command(Page.getResourceTree) returns reply + boundary W after the
   reply turn has queued that marker
-> the same Network feature owner drains the scope through boundary W
-> stage the snapshot and reconcile that complete Page/Network FIFO prefix
-> atomically commit that reconciled union at W
-> apply buffered events with sequence > W in FIFO order
-> ready
~~~

`Network.enable` does not replay HTTP history; it only starts later events and
replays currently active WebSockets. `Page.getResourceTree` is the current
frame/resource snapshot. Network is therefore enabled before the snapshot
command; a request that starts while the snapshot is being captured is always
present in the buffered event stream even if the snapshot omits it.

The staged snapshot is not treated as a complete replacement for events at or
before W. The reducer reconciles their union: a uniquely matching
frame/URL/loader snapshot resource keeps its canonical ID when an event later
supplies a raw requestId, while an unmatched or ambiguous event creates its own
canonical request rather than being discarded or guessed into another one.
Request/response/finish fields merge monotonically, so replaying pre-W detail
cannot regress the state already observed in the snapshot. This is the initial
transaction, not a second consumer-visible history.

Page lifecycle events before W are reconciled against the resource tree's
frame and loader identities rather than blindly replayed into it. Events for
the same loader are already represented by the snapshot. An ordered target
reset proves that the reply is stale, so that bootstrap cut is discarded and
repeated against the replacement target. A malformed contradictory payload
fails the attachment rather than creating a Network-local retry state.

WebKit's current frontend sends `getResourceTree` and `Network.enable`
back-to-back in the opposite order and ignores Network events while waiting
for the tree. WebInspectorKit does not copy that incidental scheduling
assumption: the public protocol does not promise that page activity cannot run
between those commands, while this model layer promises a lossless initial
cut. Enable-first plus reconciliation makes that promise explicit.

Using the scope-bound reply marker as this cut is a WebInspectorKit target
contract derived from the single ordered inspector channel and WebKit frontend
behavior, not a guarantee stated by the public Web Inspector protocol.
Contract tests fix reply-adjacent event ordering and require the marker to be
queued before the command continuation resumes; they do not assert a scheduler
race in which another task observes the marker before that continuation.

Opening the inspector during a load is normal. responseReceived without a
known requestWillBeSent first matches the resource-tree entry by frame/URL or
creates an in-flight request, as WebKit's NetworkManager does. Missing
requestWillBeSent is not a protocol violation. Orphan dataReceived and finish
events that cannot be reconciled are dropped; they do not close Network or the
connection.

An event-scope gap makes Network continuity unknowable and fails the attachment.
The runner closes its scope and does not synthesize WebSocket continuity from a
new `Page.getResourceTree`, because that snapshot contains no WebSockets. A
later explicit attachment starts a fresh authoritative bootstrap.

### Redirects and initiator grouping

NetworkRequest has a feature-assigned canonical persistent ID and owns its
ordered redirect hops. A generation-scoped alias map associates raw requestId
values with that ID. A `Page.FrameResource` snapshot has no requestId, so
learning one later updates the alias without changing persistent identity. A
redirect updates the same request and does not create another NetworkEntry
row; group membership remains fixed from the first hop's initiator.

NetworkEntry is one logical, flat list item:

- requests with the same exact scoped initiator DOM node share one entry by
  default; no separate resource-category guess is added;
- byte-range and related media loads remain distinct NetworkRequest models
  inside that entry;
- a request without a groupable initiator has its own entry;
- grouping is scoped by attachment/page generation, semantic target, agent
  target, and DOM binding scope ID;
- descriptor filtering and sorting operate on entry QueryValue;
- no section identity or section fetch API exists.

This matches the behavior behind WebKit's `groupMediaRequestsByDOMNode`
setting: the implementation groups by `initiatorNode` and does not add a
resource-type check. The list shows one row per NetworkEntry. The detail text
view renders every member request and its redirects in order.

NetworkEntry identity is feature-assigned and independent from its display
representative. A standalone entry keeps its ID when later members join it. If
two existing entries merge after initiator resolution, the entry containing
the earliest canonical request rank survives and the other entry is deleted;
no old ID is aliased to a different persistent model. Removing the earliest
member does not change the surviving entry ID. The representative becomes the
earliest remaining member, and the entry is deleted only after its last member
is removed. A group never moves across attachment/page/target/binding scopes.

Display name and primary timing come from that representative; aggregate byte
counts cover all members. Initial media preview chooses the first successful
playable final-hop URL in chronological member order. Other playable members
remain visible in detail and can replace the player item without creating a
new inspector entry.

### Network preview

The Preview mode creates and embeds AVPlayerViewController as soon as a
playable media entry is selected. It does not show a preliminary play button
or a warning that playback creates a new WKWebView request. Playback is owned
by AVPlayer, not the inspected WKWebView.

Text/image response bodies load through container.network using stable request
IDs. Internally each request keeps a body locator: `.network(requestId)` uses
`Network.getResponseBody`, while a snapshot-only
`.page(frameID, url)` uses `Page.getResourceContent`. Body failure affects that
body presentation only; it does not fail the Network feature.

### Console and Runtime

Console/Runtime share a feature actor because console payloads and remote
objects share execution-context and object-group lifetime. Console list
membership still uses the generic query engine. Runtime commands live on
container.runtime, not ModelContext.

`WebInspectorFeatureID.consoleRuntime` is the single configuration and
lifecycle identity for that actor. `container.console` and
`container.runtime` are separate typed command/query facades over the same
feature state; they cannot be enabled or closed independently.

Object-group release, target replacement, and navigation make the associated
RuntimeObject IDs stale without affecting DOM or Network.

## UI ownership

### Session and tab resources

WebInspectorSession remains the public UIKit presentation facade for source
compatibility of the primary UIKit story. It stores:

- one ModelContainer;
- one strong mainContext reference for the presentation lifetime;
- tab configuration;
- page-derived UI appearance observation.

It does not create WebInspectorProxy itself or own a parallel attachment
generation. attach/detach/close delegate directly to ModelContainer.

PresentationContentStore is split so a tab resource owns only its panel,
selection, and controller lifecycle. It does not duplicate container
generation, canonical revision, attach state, or feature state for every tab.

Tab construction uses a registry keyed by tab ID rather than a growing switch
over every built-in feature. Adding Sources or Storage registers a tab factory
without modifying DOM or Network resource owners.

The public custom-tab surface is explicit and validated. It is available only
on UIKit platforms:

~~~swift
#if canImport(UIKit)
@MainActor
public final class WebInspectorSession {
    public let modelContainer: WebInspectorModelContainer
    public var modelContext: WebInspectorModelContext { get }

    public init(modelContainer: WebInspectorModelContainer = .init())
    public func attach(
        to webView: WKWebView,
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws
    public func detach() async
    public func close() async
}

@MainActor
public struct WebInspectorTab: Equatable, Hashable, Identifiable {
    public struct ID: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String)
    }

    public struct Context {
        public let session: WebInspectorSession
        public let modelContainer: WebInspectorModelContainer
        public let modelContext: WebInspectorModelContext
    }

    public let id: ID
    public let title: String
    public let image: UIImage?
    public let requiredFeatures: Set<WebInspectorFeatureID>

    public init(
        id: ID,
        title: String,
        image: UIImage? = nil,
        requiredFeatures: Set<WebInspectorFeatureID> = [],
        makeViewController: @escaping @MainActor (Context) async throws
            -> UIViewController
    )

    public static nonisolated func == (
        lhs: WebInspectorTab,
        rhs: WebInspectorTab
    ) -> Bool

    public nonisolated func hash(into hasher: inout Hasher)

    public static let dom: WebInspectorTab
    public static let network: WebInspectorTab
}

@MainActor
public struct WebInspectorTabCatalog {
    public static let standard: WebInspectorTabCatalog
    public init(_ tabs: [WebInspectorTab]) throws
}

public enum WebInspectorTabCatalogError: Error, Equatable, Sendable {
    case empty
    case duplicateID(WebInspectorTab.ID)
}

@MainActor
public final class WebInspectorViewController: UIViewController {
    public let session: WebInspectorSession

    public init(
        session: WebInspectorSession = .init(),
        catalog: WebInspectorTabCatalog = .standard
    )

    public func attach(to webView: WKWebView) async throws
    public func detach() async
}
#endif
~~~

Catalog construction rejects an empty catalog and duplicate IDs with
`WebInspectorTabCatalogError`; it never traps or silently drops a tab. Equality
and hashing use ID only. The shell waits for required features. Any built-in
feature runner failure arrives through the container terminal state and closes
every presentation resource. Static `unsupported` availability fails only
resources whose tabs require that feature and offers no retry action; the
catalog and sibling resources remain intact. A later explicit attachment
restarts resources closed by a connection failure. The store allows at most
one factory attempt in flight per
session/resource. Concurrent compact and regular requests join that attempt,
and one successful controller is cached for the remaining resource lifetime.
A factory's own failure is not cached, so an explicit retry may invoke the
factory again. Session close/dismissal cancels and joins an in-flight factory,
removes the controller from its parent, and releases the cache. The factory
receives the stable session mainContext and no raw Proxy handle.

### Network navigation

NetworkPanelModel owns one route:

~~~swift
enum NetworkRoute: Equatable {
    case list
    case detail(NetworkEntry.ID)
}
~~~

Row selection sets detail. An interactive or programmatic pop writes list
before the navigation stack is reconciled. Compact and regular layouts derive
their presentation from the same route. There is no independent
selection-plus-navigation mirror that can re-push a detail after pop.

If the selected entry disappears, the panel changes to list in the same FRC
transaction.

### DOM rendering

DOM record reduction and tree queries run off MainActor. Expansion and
selection remain UI state. A render-projection actor receives immutable DOM
query values plus expanded IDs and returns a text/render difference.

The projection input is DataKit-owned semantic data. Frame identity,
pseudo-element kind, and shadow-root kind are represented by DataKit stable
IDs/enums in `DOMNode.QueryValue`; UIDOM does not spell ProxyKit wire types.
The current ModelContext `domTreeUpdates()` and `rebaseDOMTree(_:)` APIs are
removed. The render coordinator observes the generic DOM FRC and submits its
immutable query values directly, so projection lifecycle is not another domain
command or result stream on ModelContext.

MainActor applies the resulting TextKit/UIKit change and selection only. It
does not rebuild or filter the full DOM tree in an Observation feedback loop,
and it performs no work while source and expansion state are unchanged.

One DOM render coordinator owns a monotonically increasing request token plus
attachment/page generation, source revision, and expansion revision. A newer
input cancels or supersedes the older projection request. MainActor accepts a
result only when all four values still match the coordinator's latest request;
an out-of-order completion, navigation result, or stale expansion result is
dropped without changing rows, selection, or highlight. Bursts coalesce to the
latest complete projection, and each accepted revision causes at most one
diffable/TextKit apply.

## Diagnostics, quiescence, and idle proof

Idle performance is proven from owner acknowledgements, not from a sleep that
guesses when startup has ended. A testing-only quiescence checkpoint completes
after the requested ordered feature boundary has drained, the model store has
committed its revision, every registered context and FRC has acknowledged that
revision, and the visible DOM or Network render coordinator has either applied
that revision or confirmed that it requires no UI change. Waiting for this
checkpoint is event-driven and starts no production polling task.

Package-internal monotonic diagnostics counters record:

- feature reductions and canonical store commits;
- context drain schedules and applies;
- query evaluations, full evaluations, publications, and refetches;
- DOM projection builds and UI applies;
- Network diffable snapshot applies; and
- SwiftUI Query FRC binds and lifecycle-task starts.

`WebInspectorDataKitTesting` and the UI test support expose immutable counter
snapshots and checkpoint helpers; these are not production public API. Query
tests also install an executor probe and require predicate, sort, membership,
and difference work to execute outside MainActor even when requested by a
MainActor consumer.

Monocly has a debug/profile-only launch mode used by
`Scripts/run-idle-probe.sh`. It loads a fixed page, selects DOM or Network,
waits for the checkpoint, and emits exactly one structured start and result
record:

~~~text
WIK_IDLE_READY {"tab":"dom","generation":1,"revision":42}
WIK_IDLE_RESULT {"duration":10,"deltas":{...},"pass":true}
~~~

The script records a Release Time Profiler trace only after
`WIK_IDLE_READY`. The deterministic pass criterion is zero counter delta for
an unchanged source over the observation window. The profiler cross-check
requires no recurring WebInspectorKit polling/driver stack, no repeated
context/query/projection/diffable work on the main thread, and less than one
percent WebInspectorKit-attributed main-thread weight in that ready interval.
The log must contain no Observation feedback-loop warning. DOM and Network are
run separately. This is a CLI/log gate; it does not depend on Computer Use or
manual screen interaction.

## Failure boundaries

| Failure | Result | Last successful UI |
| --- | --- | --- |
| Invalid fetch offset/limit | That fetch throws | Retained |
| Missing SwiftUI context | Query fetchError | Empty; retention applies only to a same-binding fetch failure |
| Unsupported/unconfigured model type | That fetch throws | Retained |
| Query predicate evaluation error | That query fails | Retained |
| Stale persistent ID | nil or staleModel | Other models retained |
| Command rejection/timeout | That command throws | Retained |
| Response body failure | That body enters failed | Network retained |
| DOM external tree gap/snapshot conflict | Attachment fails | All presentation resources close |
| Network event gap | Attachment fails | All presentation resources close |
| Any built-in feature bootstrap/route/store failure | Attachment fails | All presentation resources close |
| Event scope consumer cancellation | That scope closes | Connection retained |
| Target destroyed/binding gap/late target event | Target-local reset or drop | Connection retained |
| Native disconnect/explicit close | Container connection fails/closes | Feature queries stop |
| Unreadable outer envelope or unroutable Target wrapper | Physical connection fails | All features stop |

No raw WebKit payload, navigation race, cancellation, stale object, feature
decode error, UI route, or public API misuse reaches preconditionFailure.

Preconditions remain only for locally constructed impossible states after
owner/type consolidation, such as a private enum transition that has no
external or reentrant path. Two parallel collections are not kept in sync by
preconditions; they are replaced by one value.

## Extending the inspector

Adding a first-party Sources feature requires:

1. typed ProxyKit Sources handles plus command/event wire codecs;
2. one concrete Sources semantic feature owner plus its models/schema;
3. one registration in the DataKit composition root;
4. one Sources UI feature plus one built-in tab registration.

Feature, contract, and UI tests accompany those four owners.

It does not require changes to ModelContext, FRC, the query engine,
ConnectionCore/TransportSession switches, DOMPanelModel, or NetworkPanelModel.
A ProxyKit contract fixture proves this before Sources ships: a dummy feature
registers two domain decoders, dynamically enrolls a worker descendant, and
acquires/releases its configured capabilities without editing a central event,
domain, or target-kind switch.

Storage, cookies, certificates, and security details follow the same path.
Network-linked cookies/security can be additional Network feature models;
global storage/cookie inspection can be a Storage/Security feature actor.
The decision is made by lifetime and source-of-truth ownership, not by which
tab displays the value.

## Deletion and consolidation list

The migration deletes or replaces:

- ConnectionModelFeed, ModelDomain, model-feed authority, and model-feed
  terminal causes from ProxyKit;
- the closed `WebInspectorProxyDomain`/`ProtocolDomain` enums, central command
  encoder/decoder, and `ProtocolCommand`/`ProtocolEvent.domain` switches;
- model bootstrap/replay/picker semantic ownership from TransportSession;
- the closed `WebInspectorProxyEvent` sum, central event decoder/domain switch,
  and `modelFeedSequence`;
- the single-domain `ConnectionCapabilityActivationPlan`, event scope
  registry/sink, `withWebInspectorEventScope`, and model-feed capability owner,
  replaced directly by domain descriptors and ordered composite scopes;
- ModelContainer.Domain, `configuration.domains`, the convenience attaching
  initializer, synchronization-checkpoint feed API, `makeContext(isolation:)`,
  and the nested legacy connection/failure/state-sequence types;
- WebInspectorModelOwnerEndpoint and dynamic actor lookup;
- WebInspectorFetchedResultsControllerRegistrationLease;
- owner ID, owner registry, admission claim/gate, and retirement owner;
- raw/controller and flat/sectioned query delivery modes;
- SectionName generic parameters and Never call-site noise;
- WebInspectorFetchedResultsIndexPath and all section change types;
- parallel record/query mutation arrays and their alignment preconditions;
- the canonical store's central domain reducer switch and the old monolithic
  container core/command gateway ownership after responsibilities move to
  semantic feature actors and the generic store sink;
- raw requestId as NetworkRequest persistent identity;
- domain command extensions on ModelContext;
- NetworkBody's weak ModelContext reference, response-fetch Task/lease, and
  public load command;
- CSSStyles as a node-owned command/lifecycle resource and mutable
  CSSStyleProperty reference objects;
- the context-owning RuntimeObjectGroup and context-local mutable RuntimeObject
  graph;
- per-tab copies of attachment generation/revision/feature readiness;
- ModelContext `domTreeUpdates()`/`rebaseDOMTree(_:)` and the UI-owned
  projection stream, replaced by the generic DOM FRC plus one render
  coordinator;
- the selection/navigation mirror in compact Network UI;
- direct ProxyKit dependencies from DOM/Network presentation targets;
- the two-line `WebInspectorKit` umbrella source and underscored re-export;
- the WebInspectorUI target after its three public UIKit types and shell files
  move into the real WebInspectorKit target;
- the WebInspectorUISyntaxBody target after its files and SyntaxEditorUI
  dependency move into WebInspectorUINetwork;
- DataKitTesting's `runtime.model`, `makeContext(isolation:)`, and context
  driver; tests use production ModelActorBinding instead;
- direct UIDOM spellings of ProxyKit frame/pseudo/shadow types, replaced by
  DataKit semantic projection values;
- obsolete contract-test cases and DocC examples, while their consumer stories
  are rewritten for the new API rather than deleted;
- Docs/FetchedResultsActorIsolation.md;
- Docs/WebInspectorKitsArchitecture.md;
- Docs/WebInspectorModelArchitecture.md;
- Sources/WebInspectorUI/README.md and its Package.swift exclude entry.

This gate was approved on 2026-07-15. The first docs commit made
Docs/Architecture.md the sole internal architecture source of truth, deleted
the three superseded documents and old UI README above, and updated the root
README's architecture link. The atomic source cutover then updated the public
README, DocC, Docs/MIGRATION.md, and their compile contracts with the APIs.
That sequence avoided both a mixed internal design source and publication of
unshipped APIs.
Docs/WebKitVersionMapping.md remains a factual upstream reference. README and
DocC describe public usage instead of copying internal contracts.

The WebInspectorUI DocC catalog moves to the public WebInspectorKit target.
DataKit/Testing DocC examples are rewritten for the flat generic API. Public
README and DocC examples are compiled as the same import-only stories in
ContractTests so prose cannot retain removed sections or context domain
methods.

### Cutover dependency graph

The target graph remains acyclic after migration:

~~~text
WebInspectorNativeBridgeObjC + MachOKit -> WebInspectorNativeBridge
WebInspectorNativeBridge -> WebInspectorProxyKit
swift-syntax -> WebInspectorDataKitMacros -> WebInspectorDataKit
WebInspectorProxyKit -> WebInspectorDataKit
WebInspectorProxyKit -> WebInspectorProxyKitTesting
WebInspectorProxyKit + WebInspectorProxyKitTesting
    + WebInspectorDataKit -> WebInspectorDataKitTesting
WebInspectorDataKit -> WebInspectorSwiftUI
WebInspectorDataKit + WebInspectorUIBase + ObservationBridge
    + UIHostingMenu[iOS] -> WebInspectorUIDOM
WebInspectorDataKit + WebInspectorUIBase + ObservationBridge
    + UIHostingMenu[iOS] + SyntaxEditorUI[iOS] -> WebInspectorUINetwork
WebInspectorProxyKit + WebInspectorDataKit + WebInspectorUIBase
    + WebInspectorUIDOM + WebInspectorUINetwork
    + ObservationBridge -> WebInspectorKit
WebInspectorDataKit + WebInspectorDataKitTesting
    + WebInspectorUIDOM + WebInspectorUINetwork
    -> WebInspectorUIPreviews
WebInspectorProxyKit + WebInspectorProxyKitTesting
    -> WebInspectorTestSupport
WebInspectorProxyKit + WebInspectorProxyKitTesting
    + WebInspectorTestSupport -> WebInspectorProxyKitTests
WebInspectorProxyKit + WebInspectorProxyKitTesting
    + WebInspectorDataKit + WebInspectorDataKitTesting
    + WebInspectorTestSupport -> WebInspectorDataKitTests
WebInspectorDataKitMacros + SwiftSyntaxMacrosTestSupport
    -> WebInspectorDataKitMacroTests
WebInspectorDataKit + WebInspectorDataKitTesting
    + WebInspectorSwiftUI -> WebInspectorSwiftUITests
WebInspectorProxyKit + WebInspectorProxyKitTesting
    + WebInspectorDataKit + WebInspectorDataKitTesting
    + WebInspectorUIBase + WebInspectorUIDOM + WebInspectorUINetwork
    + WebInspectorKit + WebInspectorUIPreviews
    + WebInspectorTestSupport + SyntaxEditorUI[iOS]
    -> WebInspectorUITests
public products -> external ContractTests
~~~

Every arrow above points from a direct dependency to its dependent target; it
is not a transitive or conceptual graph. `WebInspectorTestSupport` remains one
internal test-only target for the shared raw-wire driver, transport backend,
fixtures, gate, and timeout controls. It is not absorbed into a production or
testing product and is not exported. The atomic cutover removes its legacy
feed fixtures but retains its direct dependencies on ProxyKit and
ProxyKitTesting.

The `swift-syntax` edge expands to the host products required by the macro
implementation: `SwiftCompilerPlugin`, `SwiftDiagnostics`, `SwiftSyntax`,
`SwiftSyntaxBuilder`, and `SwiftSyntaxMacros`.
`WebInspectorDataKitMacroTests` additionally depends on
`SwiftSyntaxMacrosTestSupport`. These are compiler-host dependencies, not
runtime dependencies of DataKit consumers.

`swift package dump-package` must match those direct production, testing, and
support edges, including platform conditions. It must also prove the forbidden edges:
UIDOM and UINetwork do not depend on ProxyKit; WebInspectorSwiftUI depends only
on DataKit among repository targets; no target depends on the removed
WebInspectorUI or WebInspectorUISyntaxBody; and the host-only macro target is
not linked as a runtime library product. Test-only edges never weaken the
production-edge checks.

The one-pass patch is reviewed as these owner work packages; the middle column
is migration input, not a set of adapters to retain:

| Owner work package | Current sources absorbed/deleted | Target evidence moved with it |
| --- | --- | --- |
| Proxy connection/wire | `TransportSession`, `ConnectionEventScopeRegistry`, `ConnectionEventProjection`, `ConnectionModelFeed`, backend/event decoder, `StructuredEventScopes`, domain files | ordered/composite scope and raw-shape tests in `WebInspectorProxyKitTests` |
| Container/context lifecycle | `WebInspectorModelContainer*`, `WebInspectorModelContext*`, owner admission and record gate | container/context/close-race tests plus ModelActorBinding compile contracts |
| ModelActor synthesis | new compiler-plugin target; direct hand-written actor conformances are not carried forward | macro expansion/diagnostic tests plus repeated-binding/executor-identity ContractTests |
| Generic query/FRC | fetch descriptor, current query engine, transaction, FRC/publication/update sequence | flat initial/delta/reset, refetch, slow-subscriber, 10,000-record, and confinement tests |
| DOM/CSS/picker | canonical DOM/CSS reducers, DOM/CSS command gateway, element picker, old DOM tree projection stream | DOM feature actor, persistent CSS records, picker state-machine and scoped-bootstrap tests |
| Network | canonical Network records/store, context Network commands, body loading | Network feature actor, flat grouped entries, body routing, scoped-bootstrap, and fail-fast tests |
| Console/Runtime | canonical Console/Runtime records/store, runtime command gateway and object group | Console/Runtime feature actor, Sendable object scopes and release-order tests |
| SwiftUI query | new target; no legacy observation wrapper is carried forward | `WebInspectorSwiftUITests` and import-only ContractTests |
| DOM UIKit | `WebInspectorUIDOM` panel/tree/element controllers and their direct ProxyKit value spellings | generic DOM FRC/render coordinator tests and no ProxyKit target dependency |
| Network UIKit | `WebInspectorUINetwork`, compact navigation, body/media preview, `WebInspectorUISyntaxBody` | one route, one flat snapshot apply, grouped detail and initial AVPlayerViewController tests |
| Public shell/package/docs | `WebInspectorUI`, two-line `WebInspectorKit`, Package.swift, previews, README/DocC/MIGRATION | real WebInspectorKit target, single-import and explicit-advanced-import contracts, updated source-of-truth links |

The source/API cutover is nevertheless one version-coherence SCC. New
ProxyKit cannot land before DataKit because removing `ConnectionModelFeed`,
`ModelDomain`, and model-command authority breaks the current container. New
DataKit cannot land first because its feature owners require the new ordered
scope, reply-boundary, and capability contracts. Changing DataKit then breaks
the two-parameter FRC and ModelContext domain-command UIKit call sites. Moving
the shell or syntax preview independently leaves an empty or source-incomplete
target, and deferring tests leaves the shared scheme uncompilable.

Work inside the isolated cutover branch follows this build order before being
squashed into the single integration commit:

1. ProxyKit wire/connection primitives and deletion of the model feed;
2. swift-syntax dependency plus WebInspectorDataKitMacros expansion/tests;
3. DataKit typed mutation, store, flat query, and FRC contracts;
4. DOM/CSS/picker, Network, and Console/Runtime feature owners;
5. Container, context registry/lifecycle/ingress, and ModelActorBinding;
6. WebInspectorSwiftUI;
7. DOM and Network UIKit consumers, including syntax-preview source move;
8. WebInspectorKit shell/session/tab source move and Package.swift topology;
9. testing products, all shared-scheme tests, and ContractTests.

The cutover review explicitly searches for four high-risk half-migrations:
`ProtocolCommand.Result.modelFeedSequence` still crossing a command result,
`ConnectionCore.TerminalCause.modelFeedFailure` still making a feature error
physical, any closed `WebInspectorProxyEvent` decoder/switch, and any consumer
of `WebInspectorFetchedResultsController<Model, SectionName>`,
`makeContext(isolation:)`, ModelContext domain commands, or
`NetworkBody.load()`.
The same gate rejects a hand-written `: WebInspectorModelActor` conformance;
the supported source spelling is the macro.

## Migration sequence

No commit leaves a second production data path, compatibility facade, or a
nonbuilding package. Temporary work may exist only on isolated task
branches/worktrees and is not merged as history into the integration branch.

1. Commit the approved architecture gate and documentation-source-of-truth
   cleanup. This is docs-only and passes link/fence/diff checks.
2. Prepare ProxyKit owner extraction, DataKit features/store/context/query,
   SwiftUI overlay, package topology, UIKit consumers, testing support,
   ContractTests, and old-path deletion in isolated worktrees. Read-only
   contract reviews can run in parallel; no partial production route lands.
3. Apply those patches to the integration worktree and create one atomic
   breaking cutover commit. That commit simultaneously removes the ProxyKit
   model feed and old DataKit/FRC APIs, installs the new owners, moves all
   UI/consumer call sites, deletes WebInspectorUI/WebInspectorUISyntaxBody and
   obsolete tests, and passes package plus ContractTests. Worker commit history
   is not merged.
4. Land later DOM/Network correctness, idle-performance, documentation, and
   test refinements only as individually buildable commits on the new path.
5. Run all correctness, contract, runtime, Time Profiler, and self-review gates
   before handoff. Any failure is fixed in another buildable commit; the legacy
   path is never restored as fallback.

## Acceptance tests

### Public API and lifecycle

- WebInspectorDataKit import-only consumer compiles.
- WebInspectorSwiftUI import-only consumer compiles.
- UIKit quick start and inferred/default custom tab consumer compile with only
  `import WebInspectorKit`; advanced descriptor and raw-proxy stories compile
  with their explicit module imports.
- raw ProxyKit consumer compiles.
- one container supports mainContext plus two separately issued bindings
  installed by `@WebInspectorModelActor` actors.
- macro expansion contains one stored `nonisolated let` binding; repeated
  binding and unownedExecutor reads keep one object identity for the actor's
  lifetime, including actors with a custom designated initializer.
- the macro diagnoses non-actor attachment, a computed/conflicting binding,
  and conflicting executor members; repository/ContractTests source contains
  no direct hand-written `: WebInspectorModelActor` conformance.
- the same ID resolves to separate model objects for separate binding
  issuances; two actors sharing one issuance share its object identity map.
- closing one shared issuance through either model actor closes that context
  for both, while a separately issued context remains open.
- mainContext and separately issued contexts receive the same semantic changes.
- context/FRC explicit close is idempotent and awaited.
- makeModelActorBinding while closing/closed throws containerClosed; abandoning an
  unused issuance leaves no live registration or mailbox drain.
- concurrent makeModelActorBinding and container close linearize so the issuance
  is either joined by close or rejected, never escaped after the snapshot.
- mainContext identity is stable while retained; after container close it is
  inert and cannot register new work.
- explicitly closing mainContext while the container remains open evicts it;
  the next getter issues one new open context.
- two containers cannot reserve one WKWebView; detach releases the reservation.
- attach-detach and attach-close races cancel/join once and complete every
  waiter with the documented typed outcome.
- attach during detaching throws attachmentInProgress; detach from failed and
  native disconnect during detach both finish detached without throwing.
- detach during closing joins close and finishes closed; detach after closed is
  a no-op; concurrent close callers join one transition.
- current container/feature state and last-value-first state sequences agree.
- container, context, FRC, update iterator, and SwiftUI storage release at the
  retain/close matrix boundaries.
- container close rejects new scopes, joins feature runners and each scope's
  capability release, then detaches Proxy and releases the WKWebView reservation
  in that order.

### Initial, delta, and failure

- a pre-attach query does not report a successful empty initial.
- attach mid-load yields current DOM and Network snapshots.
- a pre-ready performFetch remains registered without a polling task; its first
  ready source emits `initial`, while a new attachment after an accepted result
  emits `reset`.
- initial is followed only by contiguous deltas or reset.
- multiple slow context/query consumers independently receive a reset and
  continue; a pending reset cannot be dropped.
- navigation advances the appropriate document/navigation/binding identity and
  makes prior-document IDs stale without replacing the attachment generation.
- previousNodeId zero inserts at the first child repeatedly; an unknown nonzero
  previous sibling under a fully loaded parent fails the attachment.
- a required method's JSON-RPC `-32601` response publishes static unsupported
  availability for only that feature; dependent tabs and queries fail without
  a retry action while siblings remain usable.
- every other enabled feature bootstrap/protocol/route/store failure fails and
  tears down the attachment; no transient local unavailable state or retry
  task is published.
- an ordered target/document reset during bootstrap repeats that moving-source
  cut; no other failure enters the stabilization loop.
- a malformed known domain event terminates its Proxy scope with method and
  sequence diagnostics and the DataKit runner fails the attachment; an unknown
  event preserves its full method and
  semantic null, fragment, array, or object parameter shape without promising
  byte-identical whitespace/key order/number spelling.
- scope overflow terminally stops delivery; the DataKit runner closes the scope
  and fails the attachment rather than activating a replacement scope.
- one composite Page/Network scope preserves cross-domain FIFO order, and its
  reply marker is queued before command continuation resume; the same feature
  owner then drains exactly through that boundary before committing.
- overflow/target loss before the requested boundary fails the entire cut, and
  a second outstanding boundary command is rejected.
- equivalent capability leases coalesce by physical agent, domain, and
  activation configuration; last release follows the descriptor's safe-disable
  policy and never clears Network interception/cache/header/emulation state
  owned by another command owner.
- a two-domain dummy feature dynamically enrolls/leaves a worker target and
  preserves FIFO without editing any central domain or target-kind switch.

### Query

- compound #Predicate and multiple SortDescriptor values work.
- equal sort keys use canonical rank and remain stable across incremental
  updates.
- offset/limit validation throws without trapping.
- descriptor replacement is linearizable with concurrent source deltas.
- failed replacement retains the last result and sets fetchError.
- a deterministic initial failure followed by a valid refetch, and a direct
  refetch on a never-accepted FRC, both publish `initial` on their first
  success; only a controller with an accepted result publishes `reset` for a
  later replacement.
- while a requested replacement is failed, old-descriptor deltas can update
  the retained result but cannot clear that error; deterministic failures wait
  for explicit refetch/new semantic ID.
- an unchanged SwiftUI query ID causes zero refetches; a changed ID in the
  same context causes exactly one atomic refetch on the same FRC.
- DynamicProperty.update owns binding changes; repeated wrappedValue,
  fetchError, and modelContext reads perform zero lifecycle work.
- a real SwiftUI host verifies that the container Environment value is visible
  to the first custom DynamicProperty.update, State preserves one observable
  Storage identity across View reconstruction, and update precedes body; this
  is not replaced by manually invoking update in a unit test.
- repeated View reconstruction may create and discard inert Storage values,
  but those values create zero FRCs, registrations, contexts, or tasks; the
  installed Storage alone binds one FRC and leaves one registration.
- a hosted view that reads only wrappedValue observes explicit mainContext
  close, obtains the one reissued context/FRC automatically, and does not need
  to read fetchError or manually request a body update; container close instead
  settles empty with no rebind.
- an equal query ID with a different environment context closes/rebinds once;
  missing-to-present context also binds once, and a context switch exposes no
  model from the old context while the new binding is pending.
- FRC Observation reports fetchError-only changes without a parallel Query
  result mirror or a permanent updates-sequence subscription.
- missing environment context is reported by bindingError without constructing
  an FRC, and a later successful bind clears only that error.
- `@MainActor` Query storage uses `isolated deinit`; teardown cancels its
  lifecycle task and invalidates the FRC registration without an actor escape
  or leaked registry entry.
- FRC emits one atomic initial, structural insert/delete/move changes, and one
  nonduplicated updatedItemIDs set.
- `initial` and every `reset` carry a full membership snapshot; reset causes
  include descriptor replacement, source rebase, generation/navigation reset,
  new-attachment replacement, and slow-subscriber recovery. A contiguous `changes`
  publication carries no snapshot and performs no full-membership copy.
- the update sequence's `Failure` is `Never`; deterministic fetch failure
  changes fetchError and an explicit successful refetch may publish again,
  while FRC or context/container close finishes every iterator normally.
- no section API or ResultsObserver symbol remains.
- 10,000-record tests retain zero full evaluations for single-record
  insert/update/delete and content-only updates.
- an executor probe confirms predicate, sort, membership, and difference work
  never runs on MainActor, including when the fetch originates there.

### DOM and picker

- DOM tree remains visible after supported child-count/live-tree events.
- an unexpected same-document relation gap fails the attachment; a confirmed
  document replacement atomically retires old identities and bootstraps the
  new document.
- DOM.getDocument reply-adjacent events obey the watermark cut, and
  documentUpdated during bootstrap discards/restarts only that attempt.
- picker enable, cancel, select, and re-enable work repeatedly.
- Inspector.inspect and DOM.inspect immediately return backend picker state to
  idle; remote-object resolution cannot reactivate it.
- rapid enable/disable intents and navigation use the latest generation.
- a second picker waiter is busy; cancel, target reset, command failure, and
  selection-resolution failure each complete once with the documented state.
- row selection/styles never use a context from another actor.
- an out-of-order DOM projection from an old generation/revision/expansion is
  dropped and never replaces newer rows or selection.

### Network

- requestWillBeSent, responseReceived-first, memory-cache, failure, WebSocket,
  and navigation cases are covered.
- resource-tree reply-adjacent events obey the watermark cut.
- an ordered target reset before the reply boundary discards and repeats only
  the moving-source bootstrap cut; malformed contradictions fail attachment.
- a request starting after Network.enable but during resource-tree capture is
  present exactly once in the reconciled initial transaction.
- a Network event gap fails the attachment without opening a replacement scope
  or inventing WebSocket continuity.
- a snapshot request keeps its persistent ID when a raw requestId is learned.
- redirects remain one request/entry and preserve ordered hops.
- requests with one exact scoped initiator node are one flat NetworkEntry; a
  redirect retains its first-hop membership.
- DOM-only rebootstrap issues a new shared binding scope without resetting
  Network or regrouping existing entries.
- Site Isolation keeps semantic/agent target scopes distinct and routes iframe
  requests to the correct grouping scope.
- standalone-to-group merge preserves the earliest entry ID; representative
  removal and multiple playable URLs follow the documented selection rules.
- list search/filter/sort applies incrementally to grouped entries.
- detail renders all member requests and redirects.
- AVPlayerViewController exists on initial media preview presentation.
- playback shows no WKWebView-request warning.
- response-body failure does not terminate Network.
- snapshot-only bodies use Page.getResourceContent; requestId-backed bodies use
  Network.getResponseBody.

### UI and performance

- compact detail pop cannot re-push itself.
- regular/compact layouts share one route and selection.
- one context transaction causes at most one list snapshot application.
- after quiescence, diagnostic counters show zero additional store commits,
  query publications, context applies, DOM render builds, and diffable snapshot
  applies over a fixed observation window.
- quiescence is acknowledged through feature boundary, store revision,
  context/FRC apply, and visible UI apply before the counter baseline is taken.
- a runtime Time Profiler smoke check confirms MainActor is not continuously
  occupied while an unchanged DOM or Network tab is visible.
- no Observation feedback-loop warning originates from WebInspectorKit state.

### Required commands

~~~sh
xcodebuild test \
  -workspace WebInspectorKit.xcworkspace \
  -scheme WebInspectorKit \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'

swift test --package-path ContractTests

Scripts/verify-model-context-confinement.sh
Scripts/verify-removed-architecture-symbols.sh

Scripts/run-idle-probe.sh \
  --destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  --tab dom \
  --duration 10

Scripts/run-idle-probe.sh \
  --destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  --tab network \
  --duration 10

git diff --check
~~~

The confinement script compiles positive `@WebInspectorModelActor` consumers,
verifies stable binding/executor identity, and compiles negative context/model
cross-actor fixtures. The removed-symbol script checks
exact retired declarations, generic arity, domain-command extensions, and
module imports. It also rejects direct hand-written ModelActor conformances in
repository consumers while allowing the macro declaration/implementation. It
does not reject unrelated presentation properties such as CSS style
`sections`.

The removed-symbol gate scans production and consumer evidence only:
`Sources`, `Tests`, `ContractTests`, and `README.md`. It deliberately excludes
this architecture document, `Docs/MIGRATION.md`, and the verifier scripts,
because those files must name retired symbols while explaining or detecting
them. The gate has four independent parts: exact retired symbol and
receiver-qualified call-site absence; presence of the new one-parameter FRC
declarations and `performFetch`/`refetch`/nonfailing update-sequence surface;
deleted path and forbidden import absence; and `swift package dump-package`
JSON validation of the target DAG. Broad words such as `section`, `load`,
`domain`, `responseBody`, `protocolViolation`, and `precondition` are not
searched bare. This keeps the deletion proof sensitive to the legacy owners
without rejecting unrelated UIKit or CSS terminology.

If that simulator is not installed locally, a developer may substitute an
available iOS Simulator for an exploratory run. CI and the documented required
gate keep the repository-standard destination.

## Approved design gate

Approval on 2026-07-15 accepts these coupled decisions:

- keep ModelContainer/ModelContext/PersistentModel and the incremental query
  engine;
- issue each custom Context through a WebInspectorModelActorBinding whose one
  retained DispatchSerialQueue is installed by the `@WebInspectorModelActor`
  macro as a stored let; do not trust a computed protocol getter or expose a
  public executor/context escape hatch;
- make Container the only physical/model-session owner;
- keep WebInspectorSession only as a UIKit presentation facade;
- move semantic feature ownership out of ProxyKit connection core;
- keep target/document bootstrap stabilization inside each feature owner, but
  fail the attachment on unexpected bootstrap/protocol/route/store errors;
- use one context operation queue and one typed mutation pipeline;
- ship one-parameter flat FRC and a separate WebInspectorSwiftUI overlay;
- expose query results plus fetchError, with no projected phase;
- require an explicit semantic ID for dynamically changing SwiftUI queries;
- keep built-in model schemas closed for this migration;
- model redirects and exact scoped initiator grouping as flat NetworkEntry
  semantics;
- migrate all production/test/UI consumers without compatibility wrappers;
- replace the three existing design documents with this document.

Implementation proceeds only as the one-pass cutover defined above.
