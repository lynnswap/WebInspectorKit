# MIGRATION (Next Release)

This release includes a **breaking terminology rename** from `Pane` to `Tab`.
There is no backward-compatible alias layer in this release.

## Breaking Rename Map

| Old | New |
| --- | --- |
| `WIPaneDescriptor` | `WITabDescriptor` |
| `WIPaneContext` | `WITabContext` |
| `WIDOMPaneViewModel` | `WIDOMTabViewModel` |
| `WINetworkPaneViewModel` | `WINetworkTabViewModel` |
| `WIPaneActivation` | `WITabActivation` |
| `WIPaneRuntimeDescriptor` | `WITabRuntimeDescriptor` |
| `WISessionCommand.configurePanes` | `WISessionCommand.configureTabs` |
| `WISessionCommand.selectPane` | `WISessionCommand.selectTab` |
| `WISessionViewState.selectedPaneID` | `WISessionViewState.selectedTabID` |
| `WISessionStore.selectedPaneID` | `WISessionStore.selectedTabID` |

## Migration Steps

1. Replace all type and API references listed above in your app code.
2. Update any custom tab construction from `WIPaneDescriptor(...)` to `WITabDescriptor(...)`.
3. Rename local identifiers such as `customPane` to `customTab` for consistency.
4. Rebuild and run tests to confirm there are no remaining `Pane` references in your integration code.
