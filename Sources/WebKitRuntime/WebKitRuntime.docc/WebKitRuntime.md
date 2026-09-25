# ``WebKitRuntime``

Share native symbol discovery and page access between WebKit features.

## Overview

Add the `WebKitRuntime` product from the WebInspectorKit package to use the
runtime foundation independently of Inspector sessions and UI. Swift consumers
import `WebKitRuntime`; Objective-C++ consumers can include `WebKitRuntimeObjC.h`
from the same product.

Resolve only the symbols your operation requires. ABIBridge resolves declarations off MainActor and owns the loaded-image and shared-cache indexes. WebKitRuntime preserves ordered image/name alternatives and shares successful results across consumers. A failed requirement does not invalidate other resolved symbols. Missing requirements can be retried after an image loads.

```swift
import WebKitRuntime

let getter = RuntimeSymbol(
    .cxx("WebKit::WebPageProxy::legacyMainFrameProcessPtrForSwift() const"),
    in: .webKit,
    kind: .function
)
let symbols = try await WebKitRuntime.resolve([getter])
let address = symbols[0].address
```

This declaration is an example of a feature-specific requirement, not an entry
point guaranteed to exist on every OS. Catch `RuntimeLookupError` and disable
only the dependent operation when discovery is unavailable. `requestIndex`
identifies the failed batch requirement; error descriptions omit decoded names.

## Native ABI and ownership

Resolution checks symbol identity, containing storage, and image ownership.
It does not verify a C++ return convention, class layout, virtual interface, or
IPC message schema. Consumers own those contracts and must validate them before
calling an address. Use exact mangled alternatives when a demangled declaration
cannot distinguish ABI variants, such as deleting and nondeleting destructors.
`sectionRange` bounds memory reads; it does not describe a symbol's object size.
Each resolved result retains its ABIBridge symbol and containing image. Keep the result alive while using its numeric address. Byte reads use ABIBridge's bounded current-process reader and report incomplete reads with the `.unreadableMemory` lookup-error reason.

Page access runs on MainActor and retains both the WKWebView and native owner
for a synchronous operation:

```swift
import WebKit
import WebKitRuntime

@MainActor
func pageStorageSize(of webView: WKWebView) throws -> Int {
    try unsafe WebKitRuntime.withUnsafePage(of: webView) { _, byteCount in
        byteCount
    }
}
```

Do not retain the borrowed pointer or use it after the closure returns.
Objective-C++ consumers can acquire `WKRuntimePageStorage` on the main thread
and retain that snapshot for their synchronous native operation. Acquire a fresh
snapshot for subsequent operations; do not treat it as a connection or global
page identity.

The foundation uses private WebKit accessors and runtime metadata. Compatibility
is checked against available runtime evidence, not a list of OS build numbers.
Inspector connections and tile-specific IPC encoding remain consumer concerns.

## Topics

### Symbol lookup

- ``RuntimeImage``
- ``RuntimeSymbol``
- ``ResolvedRuntimeSymbol``
- ``RuntimeLookupError``
