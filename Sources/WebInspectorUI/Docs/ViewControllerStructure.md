# ViewController Structure

`Sources/WebInspectorUI` で作っている ViewController の親子構造だけを示します。
View、処理、状態、モデル、タブ定義は省略します。

矢印は child ViewController を表します。

## Source Layout

- `Containers`: host / wrapper ViewController。`UINavigationController` / `UITabBarController` / split root など、UIKit container の責務を持つ型。
- `Tabs`: public tab API、layout 別 display item projection、content cache、content factory。
- `DOM`: DOM 固有の content ViewController、navigation item、built-in DOM tab controller。
- `Network`: Network 固有の container / built-in tab controller。`List` に一覧 UI、`Detail` に選択 entry の detail UI を置く。

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
