# MIGRATION (Current Release)

This release includes **breaking API changes** around product exposure, typed panel modeling, and controller/store naming.

## Breaking Changes

| Old | New |
| --- | --- |
| public products `WebInspectorEngine` / `WebInspectorRuntime` / `WebInspectorUI` / `WebInspectorBridge` / `WebInspectorScripts` | single public product `WebInspectorKit` |
| `WIModel` | `WIInspectorController` |
| `WITab` | `WIInspectorTab` |
| `WITabViewController` | `WIInspectorViewController` |
| `WIDOMModel` | `WIDOMInspectorStore` |
| `WINetworkModel` | `WINetworkInspectorStore` |

## New Architecture

- `WebInspectorKit` is the only supported public entry point.
- Internal targets are split into `WebInspectorCore`, `WebInspectorDOM`, `WebInspectorNetwork`, `WebInspectorShell`, `WebInspectorUI`, `WebInspectorSPI`, `WebInspectorTransport`, and `WebInspectorScripts`.
- `WIInspectorController` owns lifecycle, page binding, selected panel, and DOM/Network activation policy.
- `WIDOMInspectorStore` owns DOM inspector state.
- `WINetworkInspectorStore` owns network inspector state.
- `WIInspectorTab` now carries a typed `WIInspectorPanelConfiguration` instead of relying on string-only built-in tab checks.
- Only `WebInspectorKit` re-exports internal modules; non-umbrella targets no longer chain `@_exported import`.

## Migration Steps

1. Replace direct imports of legacy internal products with `import WebInspectorKit`.
2. Rename controller/store/container types to the new `WIInspector*` names.
3. Update custom tab construction to `WIInspectorTab`.
4. Treat panel selection/state through `WIInspectorPanelConfiguration` / `WIInspectorPanelKind`.
5. Rebuild and run the current simulator + SwiftPM + TypeScript gates before shipping.
