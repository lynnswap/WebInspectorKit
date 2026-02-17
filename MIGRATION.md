# Migration Guide: SwiftUI API -> Native UIKit/AppKit API

This release introduces a breaking redesign of `WebInspectorKit`.

## Removed APIs

- `WebInspector.Panel`
- `WebInspector.Tab`
- `WebInspector.TabBuilder`
- `WebInspector.DOMTreeView`
- `WebInspector.ElementDetailsView`
- `WebInspector.NetworkView`
- SwiftUI toolbar modifiers (`domInspectorToolbar`, `networkInspectorToolbar`)
- SwiftUI-specific `NetworkInspector` bindings (`navigationPath`, `isShowingDetail`, `tableSelection`, filter `Binding` helpers)

## New APIs

- `WebInspector.TabDescriptor`
- `WebInspector.TabContext`
- `WebInspector.ContainerViewController`
- `WebInspector.SheetPresenter` (iOS)
- `WebInspector.WindowPresenter` (macOS)
- `WebInspector.TabDescriptor.dom()` / `.element()` / `.network()`

## API Mapping

- `WebInspector.Panel(controller, webView: webView)`
  -> `WebInspector.ContainerViewController(controller, webView: webView, tabs: [.dom(), .element(), .network()])`

- SwiftUI sheet presentation
  -> iOS: `WebInspector.SheetPresenter.shared.present(...)`

- SwiftUI window/sheet composition on macOS
  -> `WebInspector.WindowPresenter.shared.present(...)`

- `WebInspector.Tab { controller in AnyView(...) }`
  -> `WebInspector.TabDescriptor(id:title:systemImage:makeViewController:)`

## NetworkInspector updates

- Keep using:
  - `selectedEntryID`
  - `searchText`
  - `activeResourceFilters`
  - `effectiveResourceFilters`
  - `sortDescriptors`
  - `displayEntries`
- Removed:
  - any `Binding` helper properties for SwiftUI

## Notes

- DOM tree rendering still uses the internal DOM frontend assets in `WKWebView`.
- `WebInspectorKitCore` API surface remains unchanged.
