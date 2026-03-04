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
- Observation compatibility layer has been renamed to `ObservationBridge` and package resolution now targets `ObservationBridge` `0.4.0`.
- `WITab` owns:
  - tab definition (`identifier`, `title`, `image`, `role`)
  - optional `viewControllerProvider`
  - optional `userInfo`
  - internal cached content view controller
- UIKit/AppKit hosts project `WIModel` directly using Observation.
- Observation handles are retained explicitly via `.store(in:)` with lifecycle-scoped `Set<ObservationHandle>` stores in UI hosts/cells.
- `ObservationsCompat` remains only as a temporary shim in upstream package and is no longer imported in this repository.
- Compact Element synthetic tab handling stays in UIKit host layer only.

## Migration Steps

1. Replace `WITabDescriptor` with `WITab`.
2. Replace `setTabsFromUI(_:)` calls with `setTabs(_:)`.
3. Remove app-side dependencies on host `stableKey` behavior.
4. Keep custom tabs through `WITab(..., viewControllerProvider:)` and use `userInfo` for per-tab metadata when needed.
5. Migrate imports from `ObservationsCompat` to `ObservationBridge`.
6. For all `observe/observeTask` usage, keep returned handles in lifecycle-owned sets using `.store(in:)`.
7. Rebuild and run tests to confirm there are no references to removed types/APIs.
