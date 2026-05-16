# CSS Model Research

This note records the WebKit CSS model and Element styles sidebar behavior that
`WebInspectorCore` should intentionally match. It is split from
`DOMModelResearch.md` so DOM ownership/projection rules stay focused on DOM,
while CSS keeps the protocol, cascade, and UI rendering shape in one place.

## 2026-05-16 Element Styles Sidebar Research

This is the continuation log for replacing the native Element detail
placeholder with the Web Inspector-style rules/computed styles view shown in
the Elements tab.

## DOM Boundary

CSS is node-scoped, but it is not DOM-owned state.

- DOM owns target/document/node identity, selection, and frame-document
  projection.
- CSS owns node style refresh, cascade ordering, computed properties,
  stylesheet invalidation, and style-specific protocol events.
- The Element detail view should connect the currently selected live DOM node
  to a CSS node-styles object. It should not copy the selected DOM node into a
  long-lived UIKit-only view model.
- CSS commands must use the selected node's command identity: owning target,
  active document generation, and raw protocol node id for that target.
- If the selected node is non-element, stale, or owned by a target that does
  not expose CSS, the CSS model should report an unavailable state instead of
  mutating DOM state or repairing selection.

The high-level dependency is:

```text
DOM selection -> selected DOMNode.ID
  -> CSSSession stylesForNode(selected node command identity)
    -> matched rules + inline styles + computed styles
    -> observable DOMNodeStyles-like object
      -> native UIKit rules list and computed list render directly
```

## Current WebInspectorKit State

- `Sources/WebInspectorUI/DOM/DOMElementViewController.swift` observes
  `DOMSession.treeRevision` and `DOMSession.selectionRevision`, but currently
  renders only `UIContentUnavailableConfiguration` placeholders for loading,
  no selection, and selected-node detail.
- `WebInspectorCore` currently models DOM identity, projection, and selection,
  but it has no CSS domain model, no CSS transport adapter, and no node-scoped
  style state equivalent to WebKit's `WI.DOMNodeStyles`.
- The existing architecture preference still applies: the selected element
  detail should observe live source-of-truth objects. A future style list may
  use transient diffable snapshots or cells, but CSS rule/style/property state
  should not be duplicated into a long-lived UIKit-only view model.

## WebKit UI Ownership Map

| WebKit file | Role |
| --- | --- |
| `Source/WebInspectorUI/UserInterface/Views/ElementsTabContentView.js` | Registers the Elements details sidebars. The first two are `RulesStyleDetailsSidebarPanel` and `ComputedStyleDetailsSidebarPanel`, matching the screenshot's Styles and Computed surfaces. |
| `Source/WebInspectorUI/UserInterface/Views/RulesStyleDetailsSidebarPanel.js` | Thin wrapper that exposes the "Styles" sidebar using `SpreadsheetRulesStyleDetailsPanel`. |
| `Source/WebInspectorUI/UserInterface/Views/ComputedStyleDetailsSidebarPanel.js` | Thin wrapper that exposes the "Computed" sidebar and can jump from a computed property to the matching rules panel section. |
| `Source/WebInspectorUI/UserInterface/Views/GeneralStyleDetailsSidebarPanel.js` | Shared style-sidebar shell. It only supports element DOM nodes, installs the style panel, filter bar, new-rule control, class toggles, and forced pseudo-class checkboxes. |
| `Source/WebInspectorUI/UserInterface/Views/StyleDetailsPanel.js` | Base panel that owns the current `WI.DOMNodeStyles`, refreshes it when the selected DOM node changes, and preserves scroll position across refreshes. |
| `Source/WebInspectorUI/UserInterface/Views/SpreadsheetRulesStyleDetailsPanel.js` | Builds the rules list from `nodeStyles.uniqueOrderedStyles`, inserting pseudo-element and inherited headers, then creating one `SpreadsheetCSSStyleDeclarationSection` per style declaration. |
| `Source/WebInspectorUI/UserInterface/Views/ComputedStyleDetailsPanel.js` | Builds the computed surface from `nodeStyles.computedStyle`, plus box model, variable grouping, and property trace links into the rules panel. |
| `Source/WebInspectorUI/UserInterface/Models/DOMNodeStyles.js` | Node-scoped CSS source of truth for matched rules, pseudo rules, inherited rules, inline style, attribute style, computed style, ordered cascade styles, effective properties, and CSS variables. |
| `Source/WebInspectorUI/UserInterface/Models/CSSStyleDeclaration.js` | Style declaration model with style id, owner rule/sheet, editable state, enabled/visible properties, variables, source ranges, and text editing. |
| `Source/WebInspectorUI/UserInterface/Models/CSSRule.js` | Rule model with rule id, origin, selector text, selector list, matched selector indices, style declaration, groupings, and source location. |
| `Source/WebInspectorUI/UserInterface/Models/CSSProperty.js` | Property model with name/value/priority/text/range, enabled/overridden/implicit/anonymous/valid state, custom property detection, and editing helpers. |
| `Source/WebInspectorUI/UserInterface/Controllers/CSSManager.js` | Global CSS controller. Enables the CSS agent on CSS-capable targets, caches stylesheets, provides `stylesForNode(node)`, invalidates node styles on DOM attribute/pseudo-class changes, and handles CSS events. |

## WebKit Protocol and Backend Facts

- `Source/JavaScriptCore/inspector/protocol/CSS.json` declares the CSS domain
  for `targetTypes: ["itml", "page"]`. The generated iOS 26.4 frontend
  metadata also registers `CSS` for `["itml", "page"]` and activates it for
  `["itml", "web-page"]`. For WebInspectorKit, CSS should be treated as a
  page-target domain, not as a frame-target DOM domain.
- `InspectorCSSAgent` resolves CSS node ids through the persistent DOM agent:
  `elementForId` / `nodeForId` call `persistentDOMAgent().assertElement` /
  `assertNode`. CSS styling is therefore coupled to a DOM-enabled target and
  the node id namespace for that target. A future frame-target CSS path must be
  verified against backend support instead of assuming WebInspectorUI's
  target-scoped frontend string ids are valid CSS protocol node ids.
- The read path for the screenshot-level rules/computed view is:
  - `CSS.getMatchedStylesForNode(nodeId, includePseudo: true, includeInherited: true)`
    returns `matchedCSSRules`, `pseudoElements`, and `inherited`.
  - `CSS.getInlineStylesForNode(nodeId)` returns `inlineStyle` and
    `attributesStyle`.
  - `CSS.getComputedStyleForNode(nodeId)` returns a flat array of computed
    `{name, value}` properties.
  - `CSS.getFontDataForNode(nodeId)` is optional and powers the separate Font
    details panel, not the first rules-list milestone.
- `InspectorCSSAgent::getMatchedStylesForNode` resolves a DOM node id to a
  connected `Element`, handles pseudo-element nodes by switching to their host,
  builds matched rules from the element style resolver, optionally includes
  pseudo-element matches, and walks ancestor elements for inherited entries.
- `InspectorCSSAgent::getInlineStylesForNode` returns CSSOM inline style for
  `StyledElement` plus an attributes style payload for attributes such as
  `width` / `height`.
- `InspectorCSSAgent::getComputedStyleForNode` builds a
  `CSSComputedStyleDeclaration` and serializes every computed property through
  `InspectorStyle::buildArrayForComputedStyle`.
- `InspectorStyle::styleWithProperties` serializes authored style declarations
  into `CSS.CSSStyle.cssProperties`, setting `text`, `priority`, `parsedOk`,
  `status`, `implicit`, and source `range` where available. These fields are
  enough to render disabled/overridden/invalid/implicit property states.

## CSS Payloads for a Read-Only Rules List

The decoder must preserve protocol optionality. Optional fields improve source
links, editing, grouping labels, and diagnostics, but their absence is valid
for user-agent, attribute, inline, source-less, or non-editable styles.

| Protocol payload | Required by protocol | Optional but useful | Why it matters |
| --- | --- | --- | --- |
| `CSS.CSSRule` | `selectorList`, `sourceLine`, `origin`, `style` | `ruleId`, `sourceURL`, `groupings`, `isImplicitlyNested` | Drives section headers, source links, origin icons, matched selector highlighting, and grouping labels. `@media` appears through `Grouping.type`, not a `CSSRule.media` field. |
| `CSS.CSSStyle` | `cssProperties`, `shorthandEntries` | `styleId`, `cssText`, `range`, `width`, `height` | Owns the declaration block and authored properties. `width` / `height` are useful for future box-model display, but not mandatory for the first rules list. |
| `CSS.CSSProperty` | `name`, `value` | `text`, `priority`, `status`, `parsedOk`, `implicit`, `range` | Drives property rows, disabled/commented rows, invalid warning state, and implicit/deprecated states. Missing `priority`, `parsedOk`, `implicit`, or `status` has protocol-defined defaults. |
| `CSS.CSSComputedStyleProperty` | `name`, `value` | none | Drives the Computed tab/list and can later be traced back to effective authored properties. |
| `CSS.InheritedStyleEntry` | `matchedCSSRules` | `inlineStyle` | Separates inherited sections by ancestor node and avoids showing non-inherited properties as normal active declarations. |
| `CSS.PseudoIdMatches` | `pseudoId`, `matches` | none | Allows `::before`, `::after`, and other pseudo-element sections before inherited rules. |

## WebKit Cascade and Refresh Behavior

- `CSSManager.stylesForNode(node)` caches a `WI.DOMNodeStyles` object per DOM
  node id. The style object is the node-scoped source of truth, and panels
  observe its `Refreshed` / `NeedsRefresh` events.
- `DOMNodeStyles.refresh()` performs the three main CSS calls in parallel with
  the selected node id, parses the payloads, then updates ordered cascade
  state in one refresh boundary.
- `DOMNodeStyles` reverses `matchedRules` before storing them so displayed
  sections follow cascade order. It then orders styles as inline style,
  matched author/inspector rules, attributes style, user/user-agent rules, and
  inherited styles. Pseudo-element styles are rendered as their own group
  before inherited rules in the rules panel.
- `DOMNodeStyles.uniqueOrderedStyles` deduplicates rule styles that refer to
  the same backend rule. The rules panel should render from this list rather
  than directly dumping every payload array.
- `_markOverriddenProperties` and `_associateRelatedProperties` compute the
  effective property map. The first native milestone can render protocol
  `status` / `parsedOk` / `implicit` directly, but proper overridden styling
  requires the same cascade pass or an intentionally smaller local equivalent.
- CSS invalidation is not driven only by CSS events. WebKit marks node styles
  dirty when DOM attributes or pseudo-class state change for the node or its
  descendants, when style sheets are changed/added/removed, and when the main
  resource changes. WebInspectorKit should keep refresh ownership in the CSS
  session/model layer, not in individual cells.

## Local Implementation Entry Points

- `Sources/WebInspectorTransport/TransportTypes.swift` already has
  `ProtocolDomain.css`, and `TransportSession.compatibilityResult` already
  accepts `CSS.enable` as a no-op compatibility success.
- `Sources/WebInspectorCore/Protocol/ProtocolTypes.swift` does not yet include
  a CSS bit in `ProtocolTargetCapabilities`; `pageDefault` also lacks CSS and
  `init(domainNames:)` ignores `"css"`. The first model change should add a
  `.css` capability and make page targets CSS-capable when protocol metadata
  advertises CSS or when the default WebKit page-target path is used.
- `Sources/WebInspectorRuntime/InspectorSession.swift` bootstraps
  `Inspector.enable`, `Inspector.initialized`, `DOM.enable`, `Runtime.enable`,
  `DOM.getDocument`, and `Network.enable`, but it does not send `CSS.enable`
  and `handleProtocolEvent` currently ignores `.css`. A CSS session should
  subscribe to CSS events after self-checking which events are needed for the
  read-only milestone.
- `Sources/WebInspectorUI/DOM/DOMElementViewController.swift` is the native
  placeholder to replace. It already observes `DOMSession.treeRevision` and
  `DOMSession.selectionRevision`; the CSS view should attach to the selected
  live DOM node/style object rather than copy selected-node state into a new
  long-lived UIKit view model.

## First Native Milestone

The first native milestone should be read-only:

- add page-target CSS capability and bootstrap `CSS.enable`;
- decode CSS protocol payloads needed by the three read calls;
- create a node-scoped observable style object keyed by selected node command
  identity and DOM document generation;
- refresh that object when selection changes, the active document generation
  changes, relevant DOM attributes/pseudo-state changes, or CSS stylesheet
  events arrive;
- render a Styles list with sections for inline style, matched author rules,
  attribute style, user/user-agent styles, pseudo-elements, and inherited
  sections in WebKit cascade order;
- render a Computed list from `getComputedStyleForNode`, initially as a
  searchable/sorted property list without full box-model or trace UI;
- render disabled/inactive/invalid/implicit property states from protocol
  fields, but defer editing, new rule insertion, class toggles, forced
  pseudo-classes, box model, variables grouping, font details, and jump-to-rule
  trace interactions.

## Open Implementation Questions

- Whether Safari's inspected `WKWebView` exposes CSS only on the page target in
  the same way as current WebKit source. If frame-target DOM support becomes
  available, the CSS node-id namespace must be tested before enabling styles
  for frame-owned nodes.
- Whether WebInspectorKit should show "styles unavailable" for selected
  non-element nodes, frame-target nodes without CSS support, and stale
  selection generations, or keep the existing generic placeholder until a
  recoverable selection is available.
- How much of WebKit's overridden-property calculation is required for the
  first visible milestone. A simple read-only list can be useful without full
  cascade conflict styling, but the screenshot-level quality needs overridden
  and invalid property classes.

## Source References

- `Source/WebInspectorUI/UserInterface/Views/ElementsTabContentView.js`
- `Source/WebInspectorUI/UserInterface/Views/RulesStyleDetailsSidebarPanel.js`
- `Source/WebInspectorUI/UserInterface/Views/ComputedStyleDetailsSidebarPanel.js`
- `Source/WebInspectorUI/UserInterface/Views/GeneralStyleDetailsSidebarPanel.js`
- `Source/WebInspectorUI/UserInterface/Views/StyleDetailsPanel.js`
- `Source/WebInspectorUI/UserInterface/Views/SpreadsheetRulesStyleDetailsPanel.js`
- `Source/WebInspectorUI/UserInterface/Views/ComputedStyleDetailsPanel.js`
- `Source/WebInspectorUI/UserInterface/Views/SpreadsheetCSSStyleDeclarationSection.js`
- `Source/WebInspectorUI/UserInterface/Views/SpreadsheetCSSStyleDeclarationEditor.js`
- `Source/WebInspectorUI/UserInterface/Views/SpreadsheetStyleProperty.js`
- `Source/WebInspectorUI/UserInterface/Models/DOMNodeStyles.js`
- `Source/WebInspectorUI/UserInterface/Models/CSSStyleDeclaration.js`
- `Source/WebInspectorUI/UserInterface/Models/CSSRule.js`
- `Source/WebInspectorUI/UserInterface/Models/CSSProperty.js`
- `Source/WebInspectorUI/UserInterface/Models/CSSStyleSheet.js`
- `Source/WebInspectorUI/UserInterface/Controllers/CSSManager.js`
- `Source/WebInspectorUI/UserInterface/Protocol/CSSObserver.js`
- `Source/JavaScriptCore/inspector/protocol/CSS.json`
- `Source/WebCore/inspector/agents/InspectorCSSAgent.cpp`
- `Source/WebCore/inspector/InspectorStyleSheet.cpp`
