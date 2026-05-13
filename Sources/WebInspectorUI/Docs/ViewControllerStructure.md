# ViewController Structure

This document shows only the view-controller containment tree in
`Sources/WebInspectorUI`. Views, processing, state, models, and tab definitions
are intentionally omitted.

Arrows represent child view controllers.

For V2 runtime/model UI wiring, see
[`V2UIIntegration.md`](V2UIIntegration.md).

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
    Root["WIViewController<br/>UIViewController"]

    CompactHost["WICompactTabBarController<br/>UITabBarController"]
    RegularHost["WIRegularTabContentViewController<br/>UINavigationController"]

    DOMCompactNavigation["DOMCompactTabNavigationController<br/>UINavigationController<br/>private"]
    ElementCompactNavigation["DOMCompactTabNavigationController<br/>UINavigationController<br/>private"]
    RegularDOMRoot["WIRegularSplitRootViewController<br/>UIViewController<br/>private"]
    DOMSplit["DOMSplitViewController<br/>UISplitViewController"]
    NetworkCompactNavigation["NetworkCompactNavigationController<br/>UINavigationController<br/>private"]
    NetworkCompactList["NetworkListViewController<br/>UICollectionViewController"]
    NetworkCompactDetail["NetworkEntryDetailViewController<br/>UICollectionViewController"]
    RegularNetworkRoot["WIRegularSplitRootViewController<br/>UIViewController<br/>private"]
    NetworkSplit["NetworkSplitViewController<br/>UISplitViewController"]

    CompactTree["DOMTreeViewController<br/>UIViewController"]
    CompactElement["DOMElementViewController<br/>UIViewController"]
    RegularTreeNavigation["WIRegularSplitColumnNavigationController<br/>UINavigationController"]
    RegularTree["DOMTreeViewController<br/>UIViewController"]
    RegularElementNavigation["WIRegularSplitColumnNavigationController<br/>UINavigationController"]
    RegularElement["DOMElementViewController<br/>UIViewController"]

    NetworkPrimaryNavigation["NetworkListColumnNavigationController<br/>UINavigationController<br/>private"]
    NetworkSecondaryNavigation["WIRegularSplitColumnNavigationController<br/>UINavigationController"]
    NetworkList["NetworkListViewController<br/>UICollectionViewController"]
    NetworkDetail["NetworkEntryDetailViewController<br/>UICollectionViewController"]

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
