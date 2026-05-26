# Console Transport Research

This note records the WebKit Console and Runtime transport behavior that
`WebInspectorCore` should compare against when adding the native Console tab.

## Scope

- Focus: transport, protocol decoding, target routing, and the minimal semantic
  model needed before UI work.
- Non-goal for this pass: native console UI layout, filtering UI, command
  prompt design, object tree expansion UI, and full Web Inspector parity.
- Checked sources:
  - current `WebInspectorKit` checkout
  - user-provided WebKit latest checkout
  - user-provided WebKit iOS 18.5 snapshot

## Current WebInspectorKit State

- `ProtocolDomain` already includes `.console`, so raw protocol method names
  such as `Console.messageAdded` are classified correctly.
- `TransportSession` already routes target-scoped console events through
  `Target.dispatchMessageFromTarget` and exposes them on `events(for: .console)`
  / `orderedEvents()`.
- `TransportSessionTests.domainStreamsReceiveIndependentTargetEventsInOrder`
  already verifies a target-scoped `Console.messageAdded` event is delivered
  independently from DOM, CSS, and Network streams.
- `InspectorSession.handleProtocolEvent` currently ignores `.console`; no
  Console events are applied to Core yet.
- `InspectorSession` owns `dom`, `css`, and `network`, but has no
  `ConsoleSession`.
- `ProtocolTargetCapabilities` has `.dom`, `.runtime`, `.target`,
  `.inspector`, `.network`, and `.css`, but no `.console`.
- Page default capabilities currently omit Console. If `Target.targetCreated`
  does not advertise a `domains` array, Console would not be discoverable from
  current Core capability state unless the default is expanded.
- Existing bootstrap order is:
  1. `Inspector.enable`
  2. `Inspector.initialized`
  3. `DOM.enable` (transport-local no-op)
  4. `Runtime.enable`
  5. `DOM.getDocument`
  6. `Network.enable`
- WebKit initializes Console late because `Console.enable` can immediately
  replay buffered messages. In `WebInspectorKit`, `Console.enable` should be
  appended after the existing bootstrap commands so backlog events do not race
  ahead of initial DOM/Network setup.
- `ConsoleCallFramePayload` and `ConsoleStackTracePayload` already exist, but
  they currently live in `NetworkProtocol.swift` because Network initiators use
  stack traces. Console should either reuse them from a shared protocol file or
  move them out of Network-specific ownership before adding a first-class
  Console model.
- There is no generic JSON value type in Core/Transport today. Decoding
  `Runtime.RemoteObject.value` will need a small Sendable JSON value
  representation rather than `Any`.

## WebKit Protocol Surface

### Console Domain

`Source/JavaScriptCore/inspector/protocol/Console.json` defines the useful
first-cut command/event surface.

Commands:

- `Console.enable`: starts delivery and replays messages collected before
  enable.
- `Console.disable`: stops reporting further console messages.
- `Console.clearMessages`: clears backend-collected messages.
- `Console.setConsoleClearAPIEnabled(enable)`: controls whether
  `console.clear()` has an effect in Web Inspector.
- `Console.getLoggingChannels`: returns non-default logging channels.
- `Console.setLoggingChannelLevel(source, level)`: changes a logging channel
  level.

Events:

- `Console.messageAdded(message)`
- `Console.messageRepeatCountUpdated(count, timestamp?)`
- `Console.messagesCleared(reason)`
- `Console.heapSnapshot(timestamp, snapshotData, title?)`

For a practical debug console, the required first-cut events are
`messageAdded`, `messageRepeatCountUpdated`, and `messagesCleared`.
`heapSnapshot` can be ignored initially.

### ConsoleMessage Payload

`Console.ConsoleMessage` fields:

- `source`: channel source such as `javascript`, `network`, `console-api`,
  `storage`, `rendering`, `css`, `accessibility`, `security`, `media`,
  `webrtc`, `payment-request`, or `other`.
- `level`: `log`, `info`, `warning`, `error`, or `debug`.
- `text`: message text.
- `type?`: `log`, `dir`, `dirxml`, `table`, `trace`, `clear`,
  `startGroup`, `startGroupCollapsed`, `endGroup`, `assert`, `timing`,
  `profile`, `profileEnd`, or `image`.
- `url?`, `line?`, `column?`: source location metadata.
- `repeatCount?`: backend repeat count for repeated adjacent messages.
- `parameters?`: array of `Runtime.RemoteObject`.
- `stackTrace?`: `Console.StackTrace`.
- `networkRequestId?`: associated `Network.RequestId` for network messages.
- `timestamp?`: backend timestamp, currently used for expensive operations.

WebInspectorUI's `ConsoleObserver.messageAdded` drops `type == "clear"` as a
visible message and treats `type == "assert"` with empty text as
`"Assertion"`. Transport/Core can preserve the raw payload and let UI decide
whether to hide or label these, but `messagesCleared` remains the semantic
clear signal.

### Stack Trace

`Console.StackTrace` is recursive:

- `callFrames`: array of `Console.CallFrame`
- `topCallFrameIsBoundary?`
- `truncated?`
- `parentStackTrace?`

`Console.CallFrame` contains `functionName`, `url`, `scriptId`, `lineNumber`,
and `columnNumber`.

The existing Network initiator stack payload already mirrors this shape, except
it stores parent stack traces as an array in the local model. Console should
reuse the same semantic shape.

### Runtime Domain

Console display and evaluation depend on `Runtime`.

Useful first-cut commands:

- `Runtime.evaluate`
- `Runtime.getPreview`
- `Runtime.getProperties`
- `Runtime.releaseObject`
- `Runtime.releaseObjectGroup`
- Optional/later: `Runtime.parse`, `Runtime.awaitPromise`,
  `Runtime.callFunctionOn`, `Runtime.saveResult`, `Runtime.setSavedResultAlias`

`Runtime.evaluate` parameters relevant to a console prompt:

- `expression`
- `objectGroup`
- `includeCommandLineAPI`
- `doNotPauseOnExceptionsAndMuteConsole`
- `contextId`
- `returnByValue`
- `generatePreview`
- `saveResult`
- `emulateUserGesture`

`Runtime.evaluate` returns:

- `result: Runtime.RemoteObject`
- `wasThrown?`
- `savedResultIndex?`

WebInspectorUI uses these prompt defaults:

- `objectGroup: "console"`
- `includeCommandLineAPI: true`
- `doNotPauseOnExceptionsAndMuteConsole: false`
- `returnByValue: false`
- `generatePreview: true`
- `saveResult: true`
- `emulateUserGesture` from UI setting

### Runtime.RemoteObject

`Runtime.RemoteObject` fields:

- `type`: `object`, `function`, `undefined`, `string`, `number`, `boolean`,
  `symbol`, or `bigint`.
- `subtype?`: `array`, `null`, `node`, `regexp`, `date`, `error`, `map`,
  `set`, `weakmap`, `weakset`, `iterator`, `class`, `proxy`, or `weakref`.
- `className?`
- `value?`: arbitrary JSON value for primitives or by-value results.
- `description?`
- `objectId?`
- `size?`
- `classPrototype?`
- `preview?`

The first transport/model pass should decode enough to render a concise line:
`type`, `subtype`, `description`, primitive `value`, `objectId`, `size`, and a
shallow `preview`. Full object-tree expansion can be layered later with
`Runtime.getProperties`, `getDisplayableProperties`, and
`getCollectionEntries`.

## WebKit Backend Behavior

### Enable and Replay

`InspectorConsoleAgent::enable` sets `m_enabled` and then sends previously
collected messages with `messageAdded`. If older messages were expired, it
first sends a warning message saying some console messages are not shown.

`InspectorConsoleAgent` keeps up to 100 messages and expires in steps of 10.
This means `Console.enable` is both a command response and a potential event
burst source.

### Clear

`InspectorConsoleAgent::clearMessages`:

- clears the backend message buffer
- resets expired message count
- releases object group `"console"`
- dispatches `Console.messagesCleared(reason)` when enabled

Reasons in current protocol:

- `console-api`
- `frontend`
- `main-frame-navigation`

### Repeat Count

`InspectorConsoleAgent::addConsoleMessage` compares a new message to the
previous one. If they are equal, it increments the previous message count and
dispatches `Console.messageRepeatCountUpdated`. Group messages and
`console.clear()` are never considered equal.

Core should model repeat updates as "update the previous matching message for
this target/session" rather than as a separate message identity.

### Network Messages

`WebConsoleAgent::didReceiveResponse` and `didFailLoading` synthesize network
console messages with `source == network`, `level == error` or `info`, URL
metadata, and a `networkRequestId`.

`Console.networkRequestId` is a `Network.RequestId` payload. In
`WebInspectorKit`, it should be related to the console event target:

```text
Console event target + networkRequestId -> NetworkRequestIdentifierKey
```

This mirrors the existing Network invariant that raw `Network.RequestId` only
becomes unique with its protocol event target.

## Target Routing

- Console is target-scoped transport, just like DOM/CSS/Runtime. Commands go
  through `Target.sendMessageToTarget` for the chosen protocol target, and
  events arrive through `Target.dispatchMessageFromTarget`.
- WebKit latest `Console.json` and `Runtime.json` include `frame` in
  `targetTypes`. The iOS 18.5 snapshot does not include `frame`.
- WebKit latest has concrete `PageConsoleAgent`, `FrameConsoleAgent`, and
  `WorkerConsoleAgent` classes. The frame agent is new relative to older
  snapshots and should be capability-checked rather than assumed.
- `TargetInfo` in protocol JSON still does not expose `frameId`,
  `parentFrameId`, or `domains`; current `WebInspectorKit` tolerates these
  observed fields when present. Console must follow the same rule as DOM/CSS:
  use advertised capabilities when available, and conservative defaults when
  they are absent.
- Current `ProtocolTargetCapabilities.frameDefault` is empty. For frame Console
  support, do not default-enable frame Console unless `domains` advertises it or
  a verified target metadata path proves it for the running backend.
- Page targets should default to Console support for legacy metadata-free
  payloads. The WebKit generated frontend has long registered Console for page
  targets, and the Console domain description says messages collected before
  enable are replayed on enable.
- Service worker targets have Console and Runtime in the protocol surface. A
  first WebInspectorKit implementation can preserve service-worker messages in
  the model even if the first UI only highlights page/frame output.

## Site Isolation and Frame Console

WebKit's "Web Inspector and Site Isolation" explainer was last updated on
2026-03-18 and explicitly calls out Console as the first domain fully migrated
to per-frame agents. The transport implication is stronger than the older
"Console has frame-target-related code paths" note:

- In Site Isolation mode, each frame can have its own inspector target and
  `FrameInspectorController`.
- `FrameInspectorController` constructs its `BackendDispatcher` with the parent
  page dispatcher as fallback. Domains not implemented at frame level can still
  fall through to the page-level agent.
- `FrameInspectorController` creates `FrameConsoleAgent` when Site Isolation is
  enabled, and can create it later when Site Isolation is first enabled for the
  main frame.
- `FrameConsoleAgent` subclasses `WebConsoleAgent`, so network/error logging,
  console API messages, logging channels, repeat updates, and clears follow the
  same `Console` protocol event shape, but originate from the frame target.
- Events emitted by frame-level agents go through
  `UIProcessForwardingFrontendChannel`, which forwards the raw protocol message
  with the frame `targetId`; UIProcess then delivers it through the target
  agent to the frontend.
- Provisional cross-origin frame navigation can create a provisional frame
  target before commit. If it commits, `Target.didCommitProvisionalTarget`
  swaps old/new target ids; if it fails, the provisional target is destroyed.

For `WebInspectorKit`, this means Console should not be treated as a page-only
domain on current WebKit. A message's protocol event target is part of the
message identity and must be retained. Enabling Console on frame targets should
happen only after the frame target is committed and known to support Console.

There is one compatibility wrinkle in the checked source: latest
`Console.json` and `Runtime.json` list `frame` in `targetTypes`, while the
checked iOS 26.4 legacy generated `InspectorBackendCommands.js` does not list
`frame` for `Console` or `Runtime`. The implementation should therefore avoid
hard-coding "all frame targets support Console" from target kind alone. Prefer
advertised target metadata when present, a successful `Console.enable` command
when probing is acceptable, and conservative defaults otherwise.

## Derived Model Invariants

- Console message identity is local to `ConsoleSession`; WebKit does not send a
  stable message id.
- Console messages must retain the protocol event target that delivered them.
- Remote objects must retain their owning Runtime agent target.
  `Runtime.releaseObject`, `getPreview`, `getProperties`, and
  `releaseObjectGroup` must be sent back to that same agent target. This can
  differ from the semantic frame target used to group DOM/Console UI state.
- `networkRequestId` is not globally unique. Resolve it with the console event
  target.
- `messageRepeatCountUpdated` updates the previous repeatable message for the
  same target stream; it is not a new backend message.
- `messagesCleared(reason: main-frame-navigation)` is a semantic session
  boundary. UI may choose whether to visually clear on navigation, but Core
  should record the clear reason.
- `Console.enable` can synchronously cause a backlog of `messageAdded` events
  after its command response path begins. Bootstrap should enable Console after
  other required initial domain setup.
- `Runtime.evaluate` should resolve the selected execution context and send the
  command to that context's `runtimeAgentTargetID`. Without UI context
  selection, the current page target/main-world context is the simplest first
  behavior. Later same-agent subframe contexts must not overwrite the target's
  default context; they are addressable through explicit/selected contexts or
  frame-target ownership when Site Isolation metadata is available.
- Remote object lifetime belongs to `RuntimeSession`. It keeps the remote object
  payload plus object group/context metadata as the single release owner; any
  snapshot-level object group target index is derived from those records.
  `Console.messageAdded` registers parameter objects in Runtime under object
  group `"console"`, and `Console.messagesCleared` /
  `Runtime.executionContextsCleared` release the matching Runtime agent's cached
  handles.
- `Target.didCommitProvisionalTarget` may move semantic context ownership to
  the committed target, but it must not re-key existing remote object handles to
  the new Runtime agent target. Handles created by the old agent are stale and
  should be dropped.
- Runtime execution contexts need two target identities. `targetID` is the
  semantic owner used by DOM selection and future UI grouping.
  `runtimeAgentTargetID` is the protocol agent that delivered the context and
  is the scope for `Runtime.executionContextsCleared`. They differ when the
  page Runtime agent reports a subframe context that should be owned by a frame
  target. Normal-context replacement is scoped by both semantic target and
  Runtime agent so a later frame agent does not discard still-valid contexts
  from the page agent. Execution context IDs are only unique inside one Runtime
  agent, so Core, DOM compatibility storage, and Transport registries use
  `RuntimeExecutionContextKey(runtimeAgentTargetID, contextID)` for context
  identity.
- Site Isolation frame Console means `ConsoleSession` must merge page, frame,
  worker, and service-worker message streams without dropping the target
  identity. A flat display can still be built later, but the Core model should
  preserve per-target origin.

## Minimal WebInspectorKit Implementation Shape

### Core

Add first-class Runtime and Console domains beside DOM/CSS/Network:

- `Sources/WebInspectorCore/Runtime/RuntimeProtocol.swift`
  - JSON values
  - execution context payloads
  - remote object, preview, property, collection, and evaluation payloads
  - command intents
- `Sources/WebInspectorCore/Runtime/RuntimeModel.swift`
  - `@MainActor @Observable RuntimeSession`
  - execution contexts keyed by `RuntimeExecutionContextKey`
  - `RuntimeExecutionContext.targetID` for semantic ownership
  - `RuntimeExecutionContext.runtimeAgentTargetID` for agent-scoped clears
  - Runtime-agent-scoped remote object records, object group index, and
    unsupported command state
- `Sources/WebInspectorCore/Console/ConsoleProtocol.swift`
  - identifiers
  - message/source/level/type/clear reason enums or raw wrappers
  - `ConsoleMessagePayload`
  - command intents
- `Sources/WebInspectorCore/Console/ConsoleModel.swift`
  - `@MainActor @Observable ConsoleSession`
  - append message
  - update previous repeat count
  - clear with reason
  - evaluate result append or return
  - optional warning/error counts

Use raw-value wrappers for protocol enums whose value sets drift across WebKit
versions. For example, `ChannelSource` changed between iOS 18.5 and WebKit
latest (`appcache` removed, `accessibility` added).

### Transport

Add `ConsoleTransportAdapter`:

- build `Console.enable`, `Console.disable`, `Console.clearMessages`,
  `Console.setConsoleClearAPIEnabled`, `Console.getLoggingChannels`, and
  `Console.setLoggingChannelLevel` commands.
- decode `Console.messageAdded`
- decode `Console.messageRepeatCountUpdated`
- decode `Console.messagesCleared`
- preserve target id from `ProtocolEventEnvelope.targetID`

Add `RuntimeTransportAdapter`:

- build `Runtime.enable`, `Runtime.evaluate`, `Runtime.getPreview`,
  `Runtime.getProperties`, `Runtime.getDisplayableProperties`,
  `Runtime.getCollectionEntries`, `Runtime.saveResult`,
  `Runtime.setSavedResultAlias`, `Runtime.releaseObject`, and
  `Runtime.releaseObjectGroup` commands.
- decode Runtime command results.
- decode `Runtime.executionContextCreated`,
  `Runtime.executionContextDestroyed`, and `Runtime.executionContextsCleared`.
- preserve `ProtocolEventEnvelope.sourceTargetID` as the Runtime agent source
  when recording contexts and applying clear events.

### Runtime Session

Add `console` to `InspectorSession` construction and event handling:

- `package let runtime: RuntimeSession`
- `package let console: ConsoleSession`
- bootstrap `Console.enable` for the main page target after existing DOM,
  Runtime, and Network setup when the target has Console capability.
- when target lifecycle events create/commit a target with Runtime and/or
  Console capability, enable each supported agent independently after the target
  is no longer provisional.
- handle `.console` in `handleProtocolEvent` by applying decoded events to
  `ConsoleSession`.
- when handling `Console.messageAdded`, register parameter `RemoteObject`
  handles with `RuntimeSession` using object group `"console"`.
- when handling `Console.messagesCleared`, also release Runtime object group
  `"console"` for the console event target to match backend lifetime.
- handle `.runtime` by applying decoded events to `RuntimeSession` and the DOM
  compatibility execution-context store. Runtime agent source target controls
  `executionContextsCleared`, while semantic target ownership remains available
  for DOM selection and future Console UI grouping.

Do not create a UI-only view model for Console transport state. The native UI
can observe `ConsoleSession` directly later, matching the existing
Observation-backed Core boundary.

### Capability Changes

`ProtocolTargetCapabilities` should add:

```swift
package static let console = Self(rawValue: 1 << 6)
```

and decode `"console"` from target domain metadata. Page and service-worker
defaults should include Console. Frame defaults should stay conservative unless
target metadata advertises Console.

Check the `UInt8` capacity before adding further domains; bit 6 still fits.

## Testing Notes

Useful tests before UI work:

- `ProtocolTargetCapabilities` decodes `domains: ["Console", "Runtime"]`.
- Metadata-free page target has Console capability.
- Metadata-free frame target does not assume Console capability.
- `ConsoleTransportAdapter` builds `Console.enable` as a target command.
- `ConsoleTransportAdapter` builds `Runtime.evaluate` with WebInspectorUI-like
  console defaults.
- `Console.messageAdded` appends a target-scoped message with parameters,
  stack trace, source location, timestamp, and network request key, and
  registers parameter remote objects in `RuntimeSession`.
- `Console.messageRepeatCountUpdated` updates the previous message instead of
  appending.
- `Console.messagesCleared` clears or starts a new model session with the raw
  clear reason preserved.
- `InspectorSession.connect` sends `Console.enable` after the existing bootstrap
  sequence when the main target supports Console.
- A frame target with advertised `domains: ["Console", "Runtime"]` is enabled
  after target creation/commit.
- A provisional frame target that emits or buffers Console messages before
  commit is associated with the committed target only through the transport's
  target-commit rewrite/buffering path, not through URL or frame id guesses.
- `Runtime.evaluate` result decodes `RemoteObject`, `wasThrown`, and
  `savedResultIndex`, preserving the Runtime agent target on the returned
  object record.

## Source References

- `https://docs.webkit.org/Deep%20Dive/Web%20Inspector/SiteIsolationExplainer.html`
- `Source/JavaScriptCore/inspector/protocol/Console.json`
- `Source/JavaScriptCore/inspector/protocol/Runtime.json`
- `Source/JavaScriptCore/inspector/agents/InspectorConsoleAgent.cpp`
- `Source/JavaScriptCore/inspector/agents/InspectorRuntimeAgent.cpp`
- `Source/JavaScriptCore/inspector/ConsoleMessage.cpp`
- `Source/WebCore/inspector/agents/WebConsoleAgent.cpp`
- `Source/WebCore/inspector/agents/page/PageConsoleAgent.cpp`
- `Source/WebCore/inspector/agents/frame/FrameConsoleAgent.cpp`
- `Source/WebCore/inspector/agents/worker/WorkerConsoleAgent.cpp`
- `Source/WebCore/inspector/agents/page/PageRuntimeAgent.cpp`
- `Source/WebCore/inspector/agents/frame/FrameRuntimeAgent.cpp`
- `Source/WebCore/inspector/FrameInspectorController.cpp`
- `Source/WebKit/WebProcess/Inspector/UIProcessForwardingFrontendChannel.cpp`
- `Source/WebKit/UIProcess/Inspector/WebPageInspectorController.cpp`
- `Source/WebInspectorUI/UserInterface/Protocol/Target.js`
- `Source/WebInspectorUI/UserInterface/Protocol/ConsoleObserver.js`
- `Source/WebInspectorUI/UserInterface/Protocol/RuntimeObserver.js`
- `Source/WebInspectorUI/UserInterface/Controllers/ConsoleManager.js`
- `Source/WebInspectorUI/UserInterface/Controllers/RuntimeManager.js`
- `Source/WebInspectorUI/UserInterface/Controllers/JavaScriptLogViewController.js`
- `Source/WebInspectorUI/UserInterface/Models/ConsoleMessage.js`
- `Source/WebInspectorUI/UserInterface/Models/ConsoleCommandResultMessage.js`
- `Source/WebInspectorUI/UserInterface/Protocol/RemoteObject.js`
