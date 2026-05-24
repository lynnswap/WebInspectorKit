# WebInspector View Controller Structure

This document shows only the WebInspector view-controller containment tree. Views,
processing, state, models, and tab definitions are intentionally omitted.

Arrows represent child view controllers.

For WebInspector runtime/model wiring, see [`UIIntegration.md`](UIIntegration.md).

## Source Layout

- `Containers`: host/wrapper view controllers. These own UIKit container
  responsibilities such as `UINavigationController`, `UITabBarController`, and
  split roots.
- `Tabs`: public tab API, layout-specific display item projection, content
  cache, and content factory.
- `DOM`: DOM-specific content view controllers, navigation items, and built-in
  DOM tab controllers.
- `Network`: Network-specific containers and built-in tab controllers. `List`
  contains the request list UI; `Detail` contains the selected entry detail UI.

```mermaid
flowchart TD
    Root["WebInspectorViewController<br/>UIViewController"]

    CompactHost["CompactTabBarController<br/>UITabBarController"]
    RegularHost["RegularTabContentViewController<br/>UINavigationController"]

    DOMCompactNavigation["DOMCompactNavigationController<br/>UINavigationController"]
    ElementCompactNavigation["DOMCompactNavigationController<br/>UINavigationController"]
    RegularDOMRoot["RegularSplitRootViewController<br/>UIViewController"]
    DOMSplit["DOMSplitViewController<br/>UISplitViewController"]
    NetworkCompactNavigation["NetworkCompactNavigationController<br/>UINavigationController"]
    NetworkCompactList["NetworkListViewController<br/>UICollectionViewController"]
    NetworkCompactDetail["NetworkDetailViewController<br/>UIViewController"]
    RegularNetworkRoot["RegularSplitRootViewController<br/>UIViewController"]
    NetworkSplit["NetworkSplitViewController<br/>UISplitViewController"]

    CompactTree["DOMTreeViewController<br/>UIViewController"]
    CompactElement["DOMElementViewController<br/>UIViewController"]
    RegularTreeNavigation["RegularSplitColumnNavigationController<br/>UINavigationController"]
    RegularTree["DOMTreeViewController<br/>UIViewController"]
    RegularElementNavigation["RegularSplitColumnNavigationController<br/>UINavigationController"]
    RegularElement["DOMElementViewController<br/>UIViewController"]

    NetworkPrimaryNavigation["NetworkListColumnNavigationController<br/>UINavigationController"]
    NetworkSecondaryNavigation["RegularSplitColumnNavigationController<br/>UINavigationController"]
    NetworkList["NetworkListViewController<br/>UICollectionViewController"]
    NetworkDetail["NetworkDetailViewController<br/>UIViewController"]

    Root -->|compact| CompactHost
    Root -->|regular| RegularHost

    CompactHost --> DOMCompactNavigation
    CompactHost --> ElementCompactNavigation
    CompactHost --> NetworkCompactNavigation
    DOMCompactNavigation --> CompactTree
    ElementCompactNavigation --> CompactElement
    NetworkCompactNavigation --> NetworkCompactList
    NetworkCompactNavigation -. "push on selection" .-> NetworkCompactDetail

    RegularHost --> RegularDOMRoot
    RegularHost --> RegularNetworkRoot
    RegularDOMRoot --> DOMSplit
    RegularNetworkRoot --> NetworkSplit

    DOMSplit --> RegularTreeNavigation
    RegularTreeNavigation --> RegularTree
    DOMSplit --> RegularElementNavigation
    RegularElementNavigation --> RegularElement

    NetworkSplit --> NetworkPrimaryNavigation
    NetworkSplit --> NetworkSecondaryNavigation
    NetworkPrimaryNavigation --> NetworkList
    NetworkSecondaryNavigation --> NetworkDetail
```
