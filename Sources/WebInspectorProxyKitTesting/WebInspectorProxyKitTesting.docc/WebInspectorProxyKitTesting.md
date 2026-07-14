# ``WebInspectorProxyKitTesting``

Drive ProxyKit's production connection path from a concrete raw WebKit peer.

## Overview

`WebInspectorProxyKitTesting` replaces the native WebKit transport, not the
connection core. ``WebInspectorProxyTestRuntime`` connects
``WebInspectorTestPeer`` below the real connection core, so target discovery,
routing, command and event JSON codecs, reply correlation, reply boundaries,
and capability leases all run exactly as they do for a native attachment.

Start a runtime, perform work through the real proxy, then receive and complete
the resulting raw command:

```swift
import WebInspectorProxyKitTesting

let runtime = try await WebInspectorProxyTestRuntime.start()

let reload = Task {
    try await runtime.page.page.reload()
}

let command = try await runtime.peer.commands.next()
precondition(command.destination == .target("page-main"))
precondition(command.method == "Page.reload")

try await runtime.peer.reply(to: command)
try await reload.value
await runtime.close()
```

Every ``WebInspectorTestPeer/Command`` carries an opaque correlation. Reply or
fail that exact value once. Targeted replies automatically produce WebKit's
outer `Target.sendMessageToTarget` acknowledgement and inner target result.
Reusing, mixing, or retaining correlations across peer connections fails
explicitly.

Use ``WebInspectorTestJSONObject`` for validated raw objects. It rejects
non-object top-level JSON and stores canonical sorted-key bytes:

```swift
let parameters = try WebInspectorTestJSONObject(
    json: #"{"requestId":"request-1","timestamp":3}"#
)

try await runtime.peer.emitTargetEvent(
    targetID: "page-main",
    method: "Network.loadingFinished",
    parameters: parameters
)
```

Target creation, provisional commits, destruction, clean remote EOF, and fatal
transport failure also enter through the peer's raw transport boundary. Call
``WebInspectorProxyTestRuntime/close()`` and await it as the normal ownership
endpoint for every test runtime.

The testing product intentionally has no semantic backend, subscriber-state
injection, event sequence markers, generations, or synthetic model snapshots.
Build fixtures at the wire boundary so tests exercise the same contracts that
production data crosses.

## Topics

### Runtime Ownership

- ``WebInspectorProxyTestRuntime``

### Raw Peer

- ``WebInspectorTestPeer``
- ``WebInspectorTestPeer/Command``
- ``WebInspectorTestPeer/Target``
- ``WebInspectorTestPeerError``

### JSON and Value Fixtures

- ``WebInspectorTestJSONObject``
- ``WebInspectorProxyTestFixtures``
