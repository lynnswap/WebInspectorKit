# MIGRATION (Current Release)

This release includes **breaking API changes** around typed panel modeling and the `WI*` naming cleanup.

## Breaking Changes

| Old | New |
| --- | --- |
| `WIInspectorController` | `WISessionController` |
| `WIInspectorViewController` | `WIContainerViewController` |
| `WIInspectorTab` | `WITab` |
| `WIInspectorPanelConfiguration` | `WIPanelConfiguration` |
| `WIInspectorPanelKind` | `WIPanelKind` |
| `WIInspectorConfiguration` | `WISessionConfiguration` |
| `WIInspectorBackendSupport` | `WIBackendSupport` |
| `WIDOMInspectorStore` | `WIDOMStore` |
| `WINetworkInspectorStore` | `WINetworkStore` |

## New Architecture

- `WebInspectorKit` is the only supported public entry point.
- Internal targets are split into `WebInspectorCore`, `WebInspectorUI`, `WebInspectorTransport`, `WebInspectorResources`, and a thin `WebInspectorKit` umbrella.
- `WISessionController` owns lifecycle, page binding, selected panel, and DOM/Network activation policy.
- `WIDOMStore` owns DOM inspector state.
- `WINetworkStore` owns network inspector state.
- `WITab` now carries a typed `WIPanelConfiguration` instead of relying on string-only built-in tab checks.
- Only `WebInspectorKit` re-exports internal modules; non-umbrella targets no longer chain `@_exported import`.

## Migration Steps

1. Replace direct imports of legacy internal products with `import WebInspectorKit`.
2. Rename controller/store/container types to the new `WISession*` / `WIContainer*` / `WITab` / `WIDOMStore` / `WINetworkStore` names.
3. Update custom tab construction to `WITab`.
4. Treat panel selection/state through `WIPanelConfiguration` / `WIPanelKind`.
5. Rebuild and run the current simulator + SwiftPM + TypeScript gates before shipping.
