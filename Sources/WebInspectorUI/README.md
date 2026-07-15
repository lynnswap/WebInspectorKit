# WebInspectorUI

WebInspectorUI contains the internal UIKit implementation used by the public
`WebInspectorKit` product.

Use this target when maintaining the built-in inspector UI. App code should
import `WebInspectorKit`; custom inspector UIs should use `WebInspectorDataKit`
or `WebInspectorProxyKit` directly.

This README is target orientation only. Generate DocC documentation from the
package for symbol-level details.

## Main Areas

- `WebInspectorSession`: UIKit facade and custom-tab compatibility owner. It
  wraps `WebInspectorContainer` / `WebInspectorContext` and is the UI-facing
  inspection lifecycle surface.
- `WebInspectorViewController`: Public built-in inspector root controller.
- `PresentationContentStore`: Root-controller-owned cache for tab controllers
  and the Network panel model. It is never shared through a session.
- `Containers`: Host and wrapper view controllers for compact tab and regular
  split presentation.
- `Tabs`: Public tab API, layout-specific display item projection, content
  cache, and content factory.
- `DOM`: Built-in DOM tab controllers and DOM-specific navigation items.
- `Network`: Built-in Network tab containers, request list, and detail UI.

The visible UI is native UIKit/TextKit2. Compact width uses tab navigation;
regular width uses split presentation.

## Data Flow

`WebInspectorSession` owns the UI-facing session lifecycle and exposes the
current `WebInspectorContext`. DOM and Network controllers observe DataKit
models and submit DataKit commands. Each `WebInspectorViewController` owns its
presentation content so two roots borrowing one session cannot reparent or
retire each other's view controllers.

The UI must not own native bridge objects, protocol envelopes,
`TransportSession`, or `TransportBackend` directly. Protocol implementation is
ProxyKit-owned. Semantic inspector state is DataKit-owned. Presentation state is
UI-owned.

## UI-Owned State

UIKit controllers may keep only local presentation state:

- selected tab and split layout state
- scroll position
- TextKit2 fragment/view cache
- active find text and transient find UI state
- list selection presentation
- DOM row expansion/collapse state
- keyboard command registration and first-responder routing

Do not add UI mirrors for copied DOM nodes, copied network requests, protocol
target registries, or transport lifecycle.

## Testing

UI tests should verify UIKit behavior at the UI/DataKit boundary:

- root controller attach/detach lifecycle through `WebInspectorSession`
- compact and regular controller containment
- DOM row expansion, selection reveal, hover/click highlight affordances, and
  keyboard commands
- Network request list topology, selection, detail presentation, and lazy body
  loading
- custom tab construction and lifecycle
