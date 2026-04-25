# V2 ViewController Structure

`Sources/WebInspectorUI/V2` で作っている ViewController の親子構造だけを示します。
View、処理、状態、モデル、タブ定義は省略します。

矢印は child ViewController を表します。

```mermaid
flowchart TD
    Root["V2_WIViewController<br/>UIViewController"]

    CompactHost["V2_WICompactTabBarController<br/>UITabBarController"]
    RegularHost["V2_WIRegularTabContentViewController<br/>UINavigationController"]

    DOMCompactNavigation["V2_WICompactTabNavigationController<br/>UINavigationController<br/>private"]
    DOMCompact["V2_DOMCompactViewController<br/>UIViewController"]
    RegularDOMRoot["V2_WIRegularSplitRootViewController<br/>UIViewController<br/>private"]
    DOMSplit["V2_DOMSplitViewController<br/>UISplitViewController"]
    NetworkCompactNavigation["V2_WICompactTabNavigationController<br/>UINavigationController<br/>private"]
    NetworkCompact["V2_NetworkCompactViewController<br/>UIViewController"]
    RegularNetworkRoot["V2_WIRegularSplitRootViewController<br/>UIViewController<br/>private"]
    NetworkSplit["V2_NetworkSplitViewController<br/>UISplitViewController"]

    CompactTree["V2_DOMTreeViewController<br/>UIViewController"]
    CompactElement["V2_DOMElementViewController<br/>UIViewController"]
    RegularTreeNavigation["V2_WIRegularSplitColumnNavigationController<br/>UINavigationController"]
    RegularTree["V2_DOMTreeViewController<br/>UIViewController"]
    RegularElementNavigation["V2_WIRegularSplitColumnNavigationController<br/>UINavigationController"]
    RegularElement["V2_DOMElementViewController<br/>UIViewController"]

    NetworkPrimaryNavigation["V2_WIRegularSplitColumnNavigationController<br/>UINavigationController"]
    NetworkSecondaryNavigation["V2_WIRegularSplitColumnNavigationController<br/>UINavigationController"]
    NetworkPrimary["UIViewController<br/>primary content"]
    NetworkSecondary["UIViewController<br/>secondary content"]

    Root -->|compact| CompactHost
    Root -->|regular| RegularHost

    CompactHost --> DOMCompactNavigation
    CompactHost --> NetworkCompactNavigation
    DOMCompactNavigation --> DOMCompact
    NetworkCompactNavigation --> NetworkCompact

    RegularHost --> RegularDOMRoot
    RegularHost --> RegularNetworkRoot
    RegularDOMRoot --> DOMSplit
    RegularNetworkRoot --> NetworkSplit

    DOMCompact --> CompactTree
    DOMCompact --> CompactElement

    DOMSplit --> RegularTreeNavigation
    RegularTreeNavigation --> RegularTree
    DOMSplit --> RegularElementNavigation
    RegularElementNavigation --> RegularElement

    NetworkSplit --> NetworkPrimaryNavigation
    NetworkSplit --> NetworkSecondaryNavigation
    NetworkPrimaryNavigation --> NetworkPrimary
    NetworkSecondaryNavigation --> NetworkSecondary
```

## 要点

- root は `V2_WIViewController`。
- root の child は compact なら `V2_WICompactTabBarController`、regular なら `V2_WIRegularTabContentViewController`。
- `V2_WIRegularTabContentViewController` は `UINavigationController`。DOM / Network の切り替え segment もここが持つ。
- compact host の下に来る標準 VC は hidden ではない `UINavigationController` で包んだ `V2_DOMCompactViewController` / `V2_NetworkCompactViewController`。custom tab にはこの wrapping を強制しない。
- regular host の下に来る標準 VC は `V2_DOMSplitViewController` / `V2_NetworkSplitViewController`。
- ただし `UISplitViewController` は `UINavigationController` に直接入れられないため、regular host では private な `V2_WIRegularSplitRootViewController` で包む。
- `UISplitViewController` の column は UIKit が自動で `UINavigationController` に包むため、regular split では column 側を明示的な hidden `UINavigationController` にしている。
- DOM compact / DOM split の下はそれぞれ Tree / Element。
- `V2_DOMTreeViewController` は `UIViewController`。compact では tab 側の `UINavigationController`、regular では split column 側の hidden `UINavigationController` が必要な navigation container を担う。
- `V2_NetworkSplitViewController` は hidden `UINavigationController` の root に空の `UIViewController` を持つ。
