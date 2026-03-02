# MIGRATION (Next Release)

This release includes **breaking API changes** around tab modeling and ownership.

## Breaking Changes

| Old | New |
| --- | --- |
| `WITabDescriptor` | `WITab` |
| `WITab` (value type-like usage) | `WITab: NSObject` |
| `WIModel.setTabsFromUI(_:)` | `WIModel.setTabs(_:)` |
| Host-side tab cache (`RenderEntry` / `TabEntry` / `stableKey`) | `WITab` internal content VC cache |
| `WISessionLifecycle` in `WebInspectorEngine` | `WISessionLifecycle` in `WebInspectorRuntime` |

## New Architecture

- SSOT remains `WIModel` (`tabs` / `selectedTab`).
- `WITab` owns:
  - tab definition (`identifier`, `title`, `image`, `role`)
  - optional `viewControllerProvider`
  - optional `userInfo`
  - internal cached content view controller
- UIKit/AppKit hosts project `WIModel` directly using Observation.
- Compact Element synthetic tab handling stays in UIKit host layer only.

## Migration Steps

1. Replace `WITabDescriptor` with `WITab`.
2. Replace `setTabsFromUI(_:)` calls with `setTabs(_:)`.
3. Remove app-side dependencies on host `stableKey` behavior.
4. Keep custom tabs through `WITab(..., viewControllerProvider:)` and use `userInfo` for per-tab metadata when needed.
5. Rebuild and run tests to confirm there are no references to removed types/APIs.
