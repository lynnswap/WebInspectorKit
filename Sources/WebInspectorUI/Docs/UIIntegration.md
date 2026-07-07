# WebInspector UI Integration

This document describes the current WebInspector UIKit inspector UI. It focuses
on view-controller ownership and the boundary between UIKit presentation state
and the `WebInspectorDataKit` model stack.

The visible UI is native UIKit/TextKit2. DOM and Network views render DataKit
state; they do not keep copied DOM graphs, copied Network requests, or protocol
target registries.

## Current View Controller Tree

```mermaid
flowchart TD
    Root["WebInspectorViewController"]
    Compact["CompactTabBarController"]
    Regular["RegularTabContentViewController"]
    DOMTree["DOMTreeViewController"]
    DOMElement["DOMElementViewController"]
    NetworkList["NetworkListViewController"]
    NetworkDetail["NetworkDetailViewController"]

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

## WebInspector UI Wiring

```mermaid
flowchart TD
    PublicSession["WebInspectorSession<br/>UIKit facade"]
    Container["WebInspectorContainer"]
    Context["WebInspectorContext"]
    DOMTreeController["DOMTreeController"]
    DOMTree["DOMTreeViewController"]
    DOMTextView["DOMTreeTextView"]
    DOMElement["DOMElementViewController"]
    NetworkPanel["NetworkPanelModel"]
    NetworkList["NetworkListViewController"]
    NetworkDetail["NetworkDetailViewController"]

    PublicSession --> Container
    PublicSession --> Context
    Context --> DOMTreeController
    DOMTreeController --> DOMTextView
    Context --> DOMTree
    Context --> DOMElement
    Context --> NetworkPanel
    NetworkPanel --> NetworkList
    NetworkPanel --> NetworkDetail
```

`WebInspectorSession` remains the UIKit facade and custom-tab compatibility
owner. It wraps `WebInspectorContainer` / `WebInspectorContext`. The UI must not
own native bridge objects, protocol envelopes, `TransportSession`, or
`TransportBackend` directly.

## DOM Presentation

The DOM UI renders a projection generated from `DOMTreeController`, not a second
DOM graph.

```mermaid
flowchart TD
    Context["WebInspectorContext<br/>DOM model + selection"]
    Controller["DOMTreeController<br/>semantic tree transactions"]
    Expansion["DOMTreeTextView.ExpansionState<br/>UI-owned"]
    Rows["DOM rendered rows"]
    DOMTree["DOMTreeTextView / TextKit2"]
    Detail["DOMElementViewController"]
    Commands["DataKit commands<br/>load children / select / highlight / delete"]

    Context --> Controller
    Controller --> Rows
    Expansion --> Rows
    Rows --> DOMTree
    Context --> Detail
    DOMTree --> Commands
    Detail --> Commands
    Commands --> Context
```

Picker selection flow:

```mermaid
sequenceDiagram
    participant WebKit as WebKit inspector backend
    participant Proxy as WebInspectorProxyKit
    participant Data as WebInspectorDataKit
    participant UI as DOM UI

    UI->>Data: enable picker
    Data->>Proxy: DOM.setInspectModeEnabled
    WebKit-->>Proxy: Inspector.inspect or DOM.inspect
    Proxy->>Proxy: normalize Runtime node object with DOM.requestNode
    Proxy-->>Data: DOM.Event.inspect(nodeID)
    Data->>Data: materialize selected node if needed
    Data->>Data: restore selected-node highlight for touch picker
    Data-->>UI: selectedNode/status/tree transaction
    UI->>UI: open ancestors and scroll selected row into view
```

Hover/click highlight flow:

```mermaid
sequenceDiagram
    participant UI as DOMTreeTextView
    participant Data as WebInspectorDataKit
    participant Proxy as WebInspectorProxyKit
    participant WebKit as WebKit inspector backend

    UI->>Data: hover or select DOM node
    Data->>Proxy: DOM.highlightNode
    Proxy->>WebKit: DOM.highlightNode
    UI->>Data: hover ended
    Data->>Proxy: restore selected-node highlight or DOM.hideHighlight
```

Frame documents remain frame-owned and are projected under their owner iframe:

```mermaid
flowchart TD
    Page["DOM page"]
    MainFrame["main frame"]
    MainDocument["main document"]
    RootNode["#document DOMNode"]
    IFrameNode["iframe DOMNode<br/>frame owner"]
    ChildFrame["child frame"]
    ChildDocument["current frame document"]

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

Network UI observes request lifecycle state through `NetworkPanelModel` and
keeps only view-local state in UIKit controllers.

```mermaid
flowchart TD
    Context["WebInspectorContext<br/>request lifecycle source of truth"]
    Panel["NetworkPanelModel<br/>selection / filter / lazy body fetch"]
    RequestOrder["ordered request identifiers"]
    Requests["requests by target-scoped request ID"]
    Redirects["redirect history"]
    List["NetworkListViewController"]
    Detail["NetworkDetailViewController"]
    Commands["DataKit commands<br/>body / certificate / websocket detail"]

    Context --> Panel
    Context --> RequestOrder
    Context --> Requests
    Requests --> Redirects
    RequestOrder --> List
    Requests --> Detail
    Panel --> List
    Panel --> Detail
    List --> Commands
    Detail --> Commands
    Commands --> Context
```

The primary request identity remains target-scoped request identity. Redirects
are request history, not separate top-level requests. Cross-origin navigation is
a DataKit retarget transition, not a UI detach.

## UI-Owned State

The semantic source of truth lives in `WebInspectorContext` and DataKit models.
UIKit controllers may keep only local presentation state:

- selected tab and split layout state
- scroll position
- TextKit2 fragment/view cache
- active find text and transient find UI state
- list selection presentation
- DOM row expansion/collapse state
- keyboard command registration and first-responder routing

The UI should not keep copied DOM nodes, copied network requests, protocol
target registries, or raw transport state.

## Cleanup Checkpoints

1. Keep built-in WebInspector UI code reading from `WebInspectorSession.context`
   and DataKit models.
2. Keep DOM controllers reading from `WebInspectorContext` /
   `DOMTreeController` and submitting DataKit commands.
3. Keep Network controllers reading from `NetworkPanelModel` and submitting
   DataKit commands.
4. Keep picker selection, selected-node highlight restore, and navigation
   retarget recovery owned by DataKit.
5. Keep row expansion, scroll-to-selection, hover/click affordances, and
   keyboard command routing owned by UI.
