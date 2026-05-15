# V2 UI Integration

This document describes the current V2 UIKit inspector UI. It focuses on view
controller ownership and the boundary between UIKit presentation state and the
V2 runtime/model stack.

The visible UI is native UIKit/TextKit2. DOM and Network views render semantic
V2 model state; they do not keep copied DOM graphs, copied Network requests, or
protocol target registries.

## Current View Controller Tree

```mermaid
flowchart TD
    Root["WebInspectorViewController"]
    Compact["V2_CompactTabBarController"]
    Regular["V2_RegularTabContentViewController"]
    DOMTree["V2_DOMTreeViewController"]
    DOMElement["V2_DOMElementViewController"]
    NetworkList["V2_NetworkListViewController"]
    NetworkDetail["V2_NetworkDetailViewController"]

    Root --> Compact
    Root --> Regular
    Compact --> DOMTree
    Compact --> DOMElement
    Compact --> NetworkList
    Compact -. "push on selection" .-> NetworkDetail
    Regular --> DOMTree
    Regular --> DOMElement
    Regular --> NetworkList
    Regular --> NetworkDetail
```

For the full UIKit containment map, see
[`ViewControllerStructure.md`](ViewControllerStructure.md).

## V2 UI Wiring

```mermaid
flowchart TD
    PublicSession["WebInspectorSession"]
    Runtime["V2_InspectorSession"]
    DOMSession["DOMSession"]
    NetworkSession["NetworkSession"]
    DOMTree["V2_DOMTreeViewController"]
    DOMElement["V2_DOMElementViewController"]
    NetworkPanel["V2_NetworkPanelModel"]
    NetworkList["V2_NetworkListViewController"]
    NetworkDetail["V2_NetworkDetailViewController"]
    DOMCommands["DOMCommandIntent"]
    NetworkCommands["NetworkCommandIntent"]

    PublicSession --> Runtime
    Runtime --> DOMSession
    Runtime --> NetworkSession
    DOMSession --> DOMTree
    DOMSession --> DOMElement
    NetworkSession --> NetworkPanel
    NetworkPanel --> NetworkList
    NetworkPanel --> NetworkDetail
    DOMTree --> DOMCommands
    DOMElement --> DOMCommands
    NetworkList --> NetworkCommands
    NetworkDetail --> NetworkCommands
    DOMCommands --> Runtime
    NetworkCommands --> Runtime
```

The UI receives `WebInspectorSession` and must not own transport or native bridge
objects directly.

## DOM Presentation

The DOM UI renders a projection generated from the semantic DOM model, not a
second DOM graph.

```mermaid
flowchart TD
    DOMSession["DOMSession<br/>page / frame / document / node / selection"]
    DOMProjection["DOM tree projection<br/>visible rows"]
    DOMTree["V2_DOMTreeViewController<br/>V2_DOMTreeTextView / TextKit2"]
    DetailSnapshot["DOM element detail snapshot"]
    ElementView["V2_DOMElementViewController"]
    Commands["DOM command intents<br/>request children / inspect / highlight"]

    DOMSession --> DOMProjection
    DOMProjection --> DOMTree
    DOMSession --> DetailSnapshot
    DetailSnapshot --> ElementView
    DOMTree --> Commands
    ElementView --> Commands
```

Frame documents remain frame-owned and are projected under their owner iframe:

```mermaid
flowchart TD
    Page["DOMPage"]
    MainFrame["DOMFrame<br/>main frame"]
    MainDocument["DOMDocument<br/>main document"]
    RootNode["#document DOMNode"]
    IFrameNode["iframe DOMNode<br/>frame owner"]
    ChildFrame["DOMFrame<br/>child frame"]
    ChildDocument["DOMDocument<br/>current frame document"]

    Page --> MainFrame
    MainFrame --> MainDocument
    MainDocument --> RootNode
    RootNode --> IFrameNode
    Page --> ChildFrame
    ChildFrame --> ChildDocument
    IFrameNode -. "projection only" .-> ChildDocument
```

The child frame document is not stored as a regular child of the iframe node.
This invariant prevents iframe refresh from corrupting the parent document.

## Network Presentation

Network UI observes request lifecycle state through `V2_NetworkPanelModel` and
keeps only view-local state in UIKit controllers.

```mermaid
flowchart TD
    NetworkSession["NetworkSession<br/>request lifecycle source of truth"]
    Panel["V2_NetworkPanelModel<br/>selection / filter / lazy body fetch"]
    RequestOrder["ordered request identifiers"]
    Requests["requests by target-scoped request ID"]
    Redirects["redirect history"]
    List["V2_NetworkListViewController"]
    Detail["V2_NetworkDetailViewController"]
    Commands["Network command intents<br/>body / certificate / websocket detail"]

    NetworkSession --> Panel
    NetworkSession --> RequestOrder
    NetworkSession --> Requests
    Requests --> Redirects
    RequestOrder --> List
    Requests --> Detail
    Panel --> List
    Panel --> Detail
    List --> Commands
    Detail --> Commands
```

The primary request identity remains target-scoped request identity. Redirects
are request history, not separate top-level requests.

## UI-Owned State

The semantic source of truth lives in `WebInspectorSession`, `DOMSession`, and
`NetworkSession`. UIKit controllers may keep only local presentation state:

- selected tab and split layout state
- scroll position
- TextKit2 fragment/view cache
- active find text and transient find UI state
- list selection presentation
- expanded/collapsed visual state when it is not semantic DOM state

The UI should not keep copied DOM nodes, copied network requests, or protocol
target registries.

## Cleanup Checkpoints

1. Keep V2 UI code reading from `WebInspectorSession`.
2. Keep DOM controllers reading from `DOMSession` projections and submitting
   `DOMCommandIntent`.
3. Keep Network controllers reading from `NetworkSession` through
   `V2_NetworkPanelModel` and submitting `NetworkCommandIntent`.
4. Move this documentation with the final UI target when the V2 target is
   renamed.
