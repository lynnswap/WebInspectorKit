# Design Audit — MainActor Detachment + Two-Layer SDK (In-Progress Implementation)

Status: read-only audit (2026-07-03). Auditor: Claude Code (design-audit).

Audited snapshot: branch `docs/rearchitecture-sdk-surface`, working tree as of
2026-07-03 13:04 JST (uncommitted M3/M4 work in flight; the
`WebInspectorEventPump` API migration was mid-edit during the audit and the
findings below reflect the newer init-based pump shape).

Follow-up status (Codex, 2026-07-03):

- F1 resolved by `WebInspectorContainer`-owned
  `WebInspectorDomainEnablementRegistry`: first context enables the wire domain,
  subsequent contexts share the lease, and the final release disables it.
- F2/F3 resolved by binding `WebInspectorContext` to the actor passed at init and
  preconditioning public/model entrypoints on that owner actor.
- F4 resolved by debug-level DataKit lifecycle logs for context state transitions
  and shared domain enable/disable transitions.
- The finding text below remains as the audit record of the pre-fix snapshot.

Inputs:

- `/Users/kn/Downloads/WebInspectorKit-MainActor-Investigation.md` (WebKit
  boundary contract)
- [05-two-layer-sdk-design.md](05-two-layer-sdk-design.md) and
  [06-implementation-gate.md](06-implementation-gate.md) (architecture and
  locked decisions)
- WebKit primary source at `/Users/kn/Dev/WebKit/WebKit_latest`
- CodexKit (`/Users/kn/Dev/CodexKit`) as the style reference, including the
  structural weaknesses identified in the 2026-07-02 CodexKit PR #16 audit
  (identity splits, replay boundaries, observation lifecycle, multicast,
  isolation).

## Verdict

The direction is sound. The implementation deliberately avoids most of the
structural weaknesses that made CodexKit's review cycle non-convergent, and it
does not violate the WebKit main-thread boundary contract anywhere.

One CONFIRMED contract gap remains: **wire-level domain enablement has no
owner** when more than one `WebInspectorContext` shares a container. This must
be resolved (by refcounting or by shrinking the public surface) before the
DataKit context API ships publicly; otherwise it will become the same class of
recurring lifecycle findings that CodexKit's observation registry produced.

## Verified-Sound Structures

Each row was adversarially checked against the failure class it corresponds to
in the CodexKit audit; the protecting mechanism is real code, not intent.

| Failure class (CodexKit precedent) | WebInspectorDataKit/ProxyKit status | Evidence |
| --- | --- | --- |
| Observation mutations pinned to the wrong actor | Avoided by construction: event pumps consume detached and hop each event to the owning isolation via an `isolated` parameter | `Sources/WebInspectorDataKit/WebInspectorEventPump.swift` (Task.detached consume; `WebInspectorEventPumpTarget.apply(_:isolation:)`) |
| Replay boundary / generation cursor drift | Avoided structurally: the proxy is live-only; startup owns the ordering invariant `subscribe → subscription barrier → enable` | `WebInspectorContext.startup` — `subscribe(to:)` then `target.waitForModelEventSubscriptions()` before any `enable()` (`Sources/WebInspectorDataKit/WebInspectorContext.swift:391-397`); barrier in `Sources/WebInspectorProxyKit/WebInspectorTarget.swift:83` |
| Replay-vs-live identity dedup (content matching) | Avoided: replay-backed domains are reset before enable instead of merged with dedup | `resetReplayBackedModelsBeforeEnable()` (`Sources/WebInspectorDataKit/WebInspectorContext.swift:471-477`) |
| Single-consumer update streams behaving as load-balancers | Avoided: transport registers one continuation per subscriber (true multicast) | `TransportSession.events(for:)` (`Sources/WebInspectorTransport/TransportSession.swift:46-55`) |
| Multicast transactions dropped before mainContext exists | Not applicable: no cross-context transaction machinery exists | `Sources/WebInspectorDataKit/WebInspectorContainer.swift` |
| Identity inferred from content / fallback ids | Avoided: DOM identity pruning is proof-based (replacement payload IDs), unknown parents fail fast; network requests keep one model per requestId with redirect hops embedded | `applySetChildNodes` (`Sources/WebInspectorDataKit/WebInspectorContext.swift:757-779`); `Sources/WebInspectorDataKit/NetworkRequest.swift` (`redirects: [RedirectHop]`) |
| WebKit main-thread boundary violations | None found: no `@unchecked Sendable`/`assumeIsolated`/`@preconcurrency` on the WebKit path; `@MainActor` remains only on `WKWebView` attachment and `mainContext` | `rg @MainActor Sources/WebInspectorDataKit Sources/WebInspectorProxyKit` → attachment + mainContext only |
| Startup/teardown cancellation races | Handled: cancellation checkpoints after every await in `startup`, disable paths are idempotent (tracking target nil-first), `start()` chains the previous startup task | `Sources/WebInspectorDataKit/WebInspectorContext.swift:382-460, 479-501` |

Gate G6's claim of non-MainActor Story A coverage is verified:
`ContractDataKitActor` owns a `WebInspectorContext(container, isolation: self)`
(`ContractTests/Tests/WebInspectorConsumerContractTests/ContractTestSupport.swift:149,290`).

## Findings

### F1 — Wire domain enablement has no owner across contexts

- Verdict: **CONFIRMED** (P1 — contract decision required before public ship)
- Symptom (future, once a second context exists): a second
  `WebInspectorContext` (a) never receives console/runtime backlog, and (b)
  silently stops receiving live events when the first context stops.
- Protocol facts (primary source): `InspectorConsoleAgent::enable()` returns
  early when already enabled — buffered console messages replay **only on the
  first enable transition**; `disable()` clears per-connection state
  (`/Users/kn/Dev/WebKit/WebKit_latest/Source/JavaScriptCore/inspector/agents/InspectorConsoleAgent.cpp`).
  All contexts share one frontend connection through the native bridge.
- Broken invariant: "domain enablement is per-connection wire state" — but each
  `WebInspectorContext` assumes exclusive ownership: it enables in `startup`
  and sends real `console.disable()` / `runtime.disable()` /
  `network.disable()` in `disableEnabledDomains`
  (`Sources/WebInspectorDataKit/WebInspectorContext.swift:479-486`).
- Failure trace: ctx2 starts on actor B → `console.enable` is a wire no-op (no
  replay → missing backlog) → ctx1 calls `stop()` →
  `disableEnabledDomains` sends `console.disable` → agent `m_enabled = false`
  → ctx2 remains `.attached` while `messageAdded` events stop arriving. No
  error surfaces anywhere.
- Owner: absent. Should be the shared layer — `WebInspectorContainer` (or the
  proxy) owning a per-domain enable refcount: enable on the first context's
  startup, disable on the last context's stop.
- Primary fix options (pick one before shipping the public context API):
  1. **Refcounted enablement** in the container/proxy. Document that
     late-joining contexts do not receive console/runtime backlog (protocol
     constraint: replay happens only on the first enable).
  2. **Shrink the public surface**: keep `mainContext` as the only public
     context for the initial ship; demote `WebInspectorContext.init` /
     `start()` to `package`. This is a coherent contract too — record it in
     06's locked decisions.
- Rejected as symptomatic: a runtime precondition "only one context per
  container" on the public init — it contradicts the CodexKit-style
  multi-context goal while still leaving the enable ownership implicit.

### F2 — Context owner isolation is accepted at init and then discarded

- Verdict: **CONFIRMED** (P2)
- `init(_ container:, isolation: isolated (any Actor))` receives the owner but
  discards it (`_ = isolation`,
  `Sources/WebInspectorDataKit/WebInspectorContext.swift:57-58`). Every entry point
  (`start`, `stop`, command surfaces, `apply` chains) re-captures the caller's
  isolation via `#isolation` defaults.
- Broken invariant (locked decision in 06): "DataKit applies live model
  mutations on the owning serial actor". Today this is guaranteed only by
  caller discipline: constructing on actor A and calling `start()` from actor
  B compiles and runs, mutating the model graph on B while observers read on
  A. The nil-isolation precondition inside `subscribe` catches nonisolated
  callers but not wrong-actor callers.
- Primary fix: store the owner at init (`private nonisolated let owner: any
  Actor`), pass the stored owner to the pumps, and `precondition(isolation ===
  owner)` at `start()`/`stop()` entry. This upgrades the contract from
  CodexKit-style caller discipline to "owner fixed at init", and makes the
  `isolation:` init parameter mean what it appears to mean.
- F3 below is resolved by the same fix.

### F3 — `stop()`/`detach()` are `nonisolated(nonsending)` public mutators

- Verdict: PLAUSIBLE (same root as F2; folded into F2's fix)
- `stop()` mutates task handles and `state` on whatever isolation the caller
  runs on (`Sources/WebInspectorDataKit/WebInspectorContext.swift:358-380`). With
  F2's stored owner + precondition, misuse fails fast instead of racing.

### F4 — Missing permanent observability in DataKit

- Verdict: noted (P3)
- No logger exists in `WebInspectorDataKit`. State transitions
  (attaching/attached/detached/failed) and domain enable/disable are the
  meaningful boundaries; F1's failure mode is silent by nature and will be
  hard to diagnose in the field without them. Add a `Logger` with debug-level
  transition logs, mirroring CodexKit's context logging.

## Notes (not defects)

- `fail(.disconnected(...))` on an unknown DOM parent fails the whole context.
  This is correct fail-fast: the wire is a single ordered stream, so an
  unknown parent implies a broken invariant, not a legal race.
- `TransportSession` per-subscriber buffers are `.unbounded`. Consumers are
  lightweight apply loops today; record the buffering policy in 05/06 so a
  future slow consumer is a documented trade-off rather than a surprise.
- `WebInspectorContainer.close()` stops only `mainContext`. Custom contexts'
  pumps end naturally when the backend streams finish on close; their domain
  disables are moot on a closing connection. Fine as-is; worth one sentence in
  the container's doc comment.

## Priorities

- **P1**: Decide and implement F1 (enable refcount in the shared layer, or
  single-public-context contract). Restored invariant: wire domain state has
  exactly one owner.
- **P2**: F2/F3 — bind the owner at init, precondition on entry. Restored
  invariant: one actor owns a context and its model graph, enforced at the
  boundary rather than by convention.
- **P3**: F4 — permanent transition/enable logs.

## Test Checklist

- Two contexts on one container (fake backend): second context's `start()`
  must not lose live events for the first; first context's `stop()` must not
  stop the second's events. (Drives F1 regardless of which contract option is
  chosen — under option 2 the test asserts the API shape instead.)
- Console backlog contract: messages emitted before the first context's
  enable are replayed once; a context started later sees only live messages —
  pinned as an explicit expectation, not an accident.
- Wrong-actor misuse: constructing a context on actor A and calling `start()`
  from actor B hits the owner precondition (F2).
- Existing coverage worth keeping: `ContractDataKitActor` Story A run on a
  non-main actor; startup cancellation checkpoints (`stop()` racing
  `start()`).
