# CSS Model Research

This note records the WebKit CSS model and Element styles sidebar behavior that
`WebInspectorCore` is comparing against. It is split from `DOMModelResearch.md`
so DOM ownership/projection rules stay focused on DOM, while CSS keeps the
protocol, cascade, and UI rendering shape in one place.

## 2026-05-16 Element Styles Sidebar Research

This is the continuation log for the Web Inspector-style rules/computed styles
view shown in the Elements tab.

## DOM Boundary

CSS is node-scoped, but it is not DOM-owned state.

- DOM owns target/document/node identity, selection, and frame-document
  projection.
- CSS owns node style refresh, cascade ordering, computed properties,
  stylesheet invalidation, and style-specific protocol events.
- The DOM/CSS handoff is the currently selected live DOM node plus a CSS
  node-styles object.
- CSS commands use the selected node's command identity: owning target, active
  document generation, and raw protocol node id for that target.
- If the selected node is non-element, stale, or owned by a target that does
  not expose CSS, CSS reports an unavailable state instead of mutating DOM
  state or repairing selection.

The high-level dependency is:

```text
DOM selection -> selected DOMNode.ID
  -> CSSSession stylesForNode(selected node command identity)
    -> matched rules + inline styles + computed styles
    -> observable DOMNodeStyles-like object
      -> style rules list and computed list render directly
```

## Current WebInspectorKit State

- `Sources/WebInspectorUI/DOM/DOMElementViewController.swift` observes
  `DOMSession.treeRevision` and `DOMSession.selectionRevision`, but currently
  renders only `UIContentUnavailableConfiguration` placeholders for loading,
  no selection, and selected-node detail.
- `WebInspectorCore` currently models DOM identity, projection, and selection,
  but it has no CSS domain model, no CSS transport adapter, and no node-scoped
  style state equivalent to WebKit's `WI.DOMNodeStyles`.

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
  `["itml", "web-page"]`. In the checked source, CSS is a page-target domain,
  not a frame-target DOM domain.
- `InspectorCSSAgent` resolves CSS node ids through the persistent DOM agent:
  `elementForId` / `nodeForId` call `persistentDOMAgent().assertElement` /
  `assertNode`. CSS styling is therefore coupled to a DOM-enabled target and
  the node id namespace for that target. A future frame-target CSS path needs
  backend verification before assuming WebInspectorUI's target-scoped frontend
  string ids are valid CSS protocol node ids.
- The read path for the screenshot-level rules/computed view is:
  - `CSS.getMatchedStylesForNode(nodeId, includePseudo: true, includeInherited: true)`
    returns `matchedCSSRules`, `pseudoElements`, and `inherited`.
  - `CSS.getInlineStylesForNode(nodeId)` returns `inlineStyle` and
    `attributesStyle`.
  - `CSS.getComputedStyleForNode(nodeId)` returns a flat array of computed
    `{name, value}` properties.
  - `CSS.getFontDataForNode(nodeId)` is optional and powers the separate Font
    details panel, not the rules list itself.
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

## CSS Payloads for Styles and Computed Lists

Protocol optionality is part of the payload contract. Optional fields improve
source links, editing, grouping labels, and diagnostics, but their absence is
valid for user-agent, attribute, inline, source-less, or non-editable styles.

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
  the same backend rule. The rules panel renders from this list rather than
  directly dumping every payload array.
- `_markOverriddenProperties` and `_associateRelatedProperties` compute the
  effective property map. Protocol `status` / `parsedOk` / `implicit` cover
  useful row state, but proper overridden styling requires the same cascade
  pass or an intentionally smaller local equivalent.
- CSS invalidation is not driven only by CSS events. WebKit marks node styles
  dirty when DOM attributes or pseudo-class state change for the node or its
  descendants, when style sheets are changed/added/removed, and when the main
  resource changes.

## WebKit Property Toggle Behavior

For a rule such as:

```css
body {
    margin: 0;
    box-sizing: border-box;
}
```

WebKit represents `body` as the style declaration section and `margin` /
`box-sizing` as property rows inside that section. Each property row has state
for active/overridden/disabled/invalid and may expose an enable/disable toggle
when the owning declaration is editable.

WebKit does not have a dedicated `CSS.toggleProperty` command. Its toggle path
is text-based:

- `SpreadsheetStyleProperty` renders an `<input type="checkbox">` only when
  the property is editable. The checkbox's checked state is `property.enabled`.
- Clicking the checkbox calls `CSSProperty.commentOut(property.enabled)`.
- `commentOut(true)` changes the property text from `name: value;` to
  `/* name: value; */`; `commentOut(false)` strips that comment wrapper.
- Changing `CSSProperty.text` regenerates the owning style declaration text via
  `CSSStyleDeclaration.generateFormattedText(...)`.
- The generated declaration text is committed with
  `CSS.setStyleText(styleId, text)`.
- On success, WebKit refreshes `DOMNodeStyles`; if the changed rule no longer
  matches the selected node, it also parses the returned style payload to keep
  validity state current.

Protocol status maps to row state as follows:

| `CSS.CSSProperty.status` | WebKit property state | UI meaning |
| --- | --- | --- |
| `active` | `enabled = true`, `overridden = false` | checked, effective within this declaration |
| `inactive` | `enabled = true`, `overridden = true` | checked, present but overridden by another property in the same style |
| `disabled` | `enabled = false` | unchecked, rendered/commented as disabled |
| absent / `style` | `enabled = true`, anonymous/style-generated | checked unless non-editable; often source-less or computed-style data |

Toggle availability follows style editability, not just row display:

- Rule declarations are editable only when the rule has an editable `ruleId`
  and is not from a user-agent stylesheet.
- Inline declarations are editable when the node has an inline `styleId` and
  the node is not in a user-agent shadow tree, unless that backend supports
  editing user-agent shadow trees.
- Attribute styles, computed styles, source-less user-agent styles, and styles
  without `styleId` render rows but do not expose an enabled toggle.
- A disabled property remains part of the declaration text and WebKit keeps it
  as a row. It is not the same operation as deleting the property.

## Open Research Questions

- Whether Safari's inspected `WKWebView` exposes CSS only on the page target in
  the same way as current WebKit source. If frame-target DOM support becomes
  available, the CSS node-id namespace needs source-level or runtime
  verification before assuming frame-owned nodes can be styled through CSS
  commands.
- How WebKit surfaces selected non-element nodes, frame-target nodes without
  CSS support, and stale selection generations in the Styles sidebar.
- How much of WebKit's overridden-property calculation is required for the
  screenshot-level Styles list. Protocol row state covers some cases, while
  full cascade conflict styling depends on the `DOMNodeStyles` cascade pass.

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
