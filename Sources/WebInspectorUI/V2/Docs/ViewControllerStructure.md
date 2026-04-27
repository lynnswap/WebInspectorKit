# V2 ViewController Structure

`Sources/WebInspectorUI/V2` で作っている ViewController の親子構造だけを示します。
View、処理、状態、モデル、タブ定義は省略します。

矢印は child ViewController を表します。

## Source Layout

- `Containers`: V2 の host / wrapper ViewController。`UINavigationController` / `UITabBarController` / split root など、UIKit container の責務を持つ型。
- `Tabs`: public tab API、layout 別 display item projection、content cache、content factory。
- `DOM`: DOM 固有の content ViewController、navigation item、built-in DOM tab controller。
- `Network`: Network 固有の container / built-in tab controller。`List` に一覧 UI、`Detail` に選択 entry の detail UI を置く。

```mermaid
flowchart TD
    Root["V2_WIViewController<br/>UIViewController"]

    CompactHost["V2_WICompactTabBarController<br/>UITabBarController"]
    RegularHost["V2_WIRegularTabContentViewController<br/>UINavigationController"]

    DOMCompactNavigation["V2_DOMCompactTabNavigationController<br/>UINavigationController<br/>private"]
    ElementCompactNavigation["V2_DOMCompactTabNavigationController<br/>UINavigationController<br/>private"]
    RegularDOMRoot["V2_WIRegularSplitRootViewController<br/>UIViewController<br/>private"]
    DOMSplit["V2_DOMSplitViewController<br/>UISplitViewController"]
    NetworkCompactNavigation["V2_NetworkCompactNavigationController<br/>UINavigationController<br/>private"]
    NetworkCompactList["V2_NetworkListViewController<br/>UICollectionViewController"]
    NetworkCompactDetail["V2_NetworkEntryDetailViewController<br/>UICollectionViewController"]
    RegularNetworkRoot["V2_WIRegularSplitRootViewController<br/>UIViewController<br/>private"]
    NetworkSplit["V2_NetworkSplitViewController<br/>UISplitViewController"]

    CompactTree["V2_DOMTreeViewController<br/>UIViewController"]
    CompactElement["V2_DOMElementViewController<br/>UIViewController"]
    RegularTreeNavigation["V2_WIRegularSplitColumnNavigationController<br/>UINavigationController"]
    RegularTree["V2_DOMTreeViewController<br/>UIViewController"]
    RegularElementNavigation["V2_WIRegularSplitColumnNavigationController<br/>UINavigationController"]
    RegularElement["V2_DOMElementViewController<br/>UIViewController"]

    NetworkPrimaryNavigation["V2_NetworkListColumnNavigationController<br/>UINavigationController<br/>private"]
    NetworkSecondaryNavigation["V2_WIRegularSplitColumnNavigationController<br/>UINavigationController"]
    NetworkList["V2_NetworkListViewController<br/>UICollectionViewController"]
    NetworkDetail["V2_NetworkEntryDetailViewController<br/>UICollectionViewController"]

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
