# ScrollableTabBar Target Design

Status: Implemented

Baseline: `3e842f340b19d2001968c852cfa7daae7103bc6e`

## Objective

Extract the reusable tab-selection capability currently embedded in Network
Detail into a public, iOS UIKit library product and target named
`ScrollableTabBar`.

The target must:

- preserve the verified system floating tab presentation, pagination, Liquid
  Glass selection lens, and expanded iPhone pagination width when the private
  UIKit contract is available;
- preserve access to every item through a public UIKit fallback when that
  undocumented contract is unavailable;
- expose no WebInspector domain types and depend on no WebInspector targets;
- keep semantic selection in the consumer;
- be movable to a standalone repository without changing consumer source.

The target does not own Network content, Network mode titles, request
availability, or navigation-item composition.

## Findings

1. `NetworkDetailModeControlController.swift` currently mixes a generic UIKit
   runtime, Network `Mode` mapping, WebInspector localization, fallback UI, and
   test seams in one 684-line file. The system-floating capability itself is a
   coherent unit of roughly 370 lines.
2. The generic implementation requires only UIKit, Objective-C runtime, and
   OSLog. `WebInspectorUIBase` is used only by the Network-specific localized
   accessibility label.
3. `NetworkDetailViewController` already owns semantic selection through its
   `mode` property and `setMode(_:)`. The control is a UI projection and input
   surface, not a second semantic owner.
4. The hidden `UITabBarController`, its `UITab` instances, the transplanted tab
   model, and the standalone floating view are one lifecycle unit. They must be
   retained and torn down by the reusable control rather than returned as a
   bare `UIView`.
5. The current UI pages horizontally with system page buttons; it is not a
   freely scrolling `UIScrollView`. `ScrollableTabBar` therefore means that
   overflow items remain horizontally reachable, not that continuous scrolling
   is part of the public contract.
6. A same-package leaf target preserves the existing dependency direction. A
   separate library product establishes the future repository boundary now.
7. The repository already has an external `ContractTests` package. It can prove
   the public product without `@testable`, but its current macOS-only CI command
   does not compile or run UIKit contracts.

## Product and Target Graph

```text
ScrollableTabBar product
└── ScrollableTabBar target
    ├── UIKit
    ├── ObjectiveC
    └── OSLog

WebInspectorKit
└── WebInspectorUI
    └── WebInspectorUINetwork
        └── ScrollableTabBar
```

`WebInspectorKit` does not re-export `ScrollableTabBar`. An app that wants the
control directly selects the `ScrollableTabBar` product explicitly.

The root package remains iOS 18 / macOS 15. The new source is guarded by
`canImport(UIKit)`, matching the existing UI targets. A future standalone
package should declare only iOS 18+ rather than publishing an empty macOS
module.

## Public API

```swift
import UIKit

@MainActor
public final class ScrollableTabBar<ID: Hashable>: UIControl {
    public struct Item: Identifiable {
        public let id: ID
        public let title: String
        public let image: UIImage?
        public let accessibilityIdentifier: String?

        public init(
            id: ID,
            title: String,
            image: UIImage? = nil,
            accessibilityIdentifier: String? = nil
        )
    }

    /// Membership and order are fixed for this control's lifetime.
    public let items: [Item]

    /// Always identifies one of `items`.
    /// Programmatic changes do not send `.valueChanged`.
    public var selectedID: ID { get set }

    public init(
        items: [Item],
        selectedID: ID
    )
}
```

`UIControl.isEnabled`, target/action, `addAction(_:for:)`, tint, Auto Layout,
and the standard accessibility properties remain the standard UIKit API.

### Invariants and Events

- `items` is nonempty.
- Item IDs are unique.
- The initial and every subsequently assigned `selectedID` belongs to `items`.
- These array-wide invariants are validated once by the control owner at its
  initialization or selection boundary. They are programmer errors because no
  standard Swift collection type can express nonempty unique membership.
- A user selection updates `selectedID` first and then sends exactly one
  `.valueChanged` event when the selected ID actually changes.
- Assigning `selectedID` programmatically updates the native selection and
  makes it visible, but sends no event.
- Setting `isEnabled` to `false` prevents user selection and applies the
  disabled appearance to the active presentation.
- Membership/order mutation, per-item enablement, badges, styling knobs, and
  pagination-width policy are not v1 API. If dynamic membership becomes a real
  consumer requirement, it should be added as one atomic
  `apply(items:selectedID:)` operation.

The API is intentionally Swift-only in v1. A generic ID preserves the
consumer's domain identity and removes String/object mapping. No Objective-C
consumer currently exists, so an erased Objective-C wrapper is not added.

## Consumer Story

Network passes its existing `Mode` directly as the stable ID:

```swift
import ScrollableTabBar

private lazy var modeControl: ScrollableTabBar<Mode> = {
    let control = ScrollableTabBar(
        items: Mode.allCases.enumerated().map { index, mode in
            .init(
                id: mode,
                title: mode.title,
                accessibilityIdentifier:
                    "WebInspector.Network.DetailMode.\(index)"
            )
        },
        selectedID: mode
    )
    control.accessibilityIdentifier =
        "WebInspector.Network.DetailModeTabBar"
    control.accessibilityLabel = String(
        localized: "network.detail.mode.label",
        defaultValue: "Detail Mode",
        bundle: WebInspectorUILocalization.bundle
    )
    control.addAction(
        UIAction { [weak self, weak control] _ in
            guard let selectedMode = control?.selectedID else {
                return
            }
            self?.setMode(selectedMode)
        },
        for: .valueChanged
    )
    return control
}()
```

Rendering remains controlled by Network:

```swift
private func renderModeControl(selectedRequest request: NetworkRequest? = nil) {
    modeControl.selectedID = mode
    modeControl.isEnabled = (request ?? observedRequest) != nil
}
```

`navigationItem.titleView = modeControl` is unchanged in meaning.

## Ownership and Lifecycle

| Concern | Owner |
| --- | --- |
| Mode membership, order, localized title, semantic selection | Network consumer |
| Request-dependent enabled policy and content routing | `NetworkDetailViewController` |
| Current UI selection projection and `.valueChanged` delivery | `ScrollableTabBar` |
| `UITab` identity and mapping | system-floating content inside the target |
| Strong hidden `UITabBarController` lifetime | system-floating content inside the target |
| Private tab model attachment/detachment | system-floating content inside the target |
| Runtime capability selection | `ScrollableTabBar` content factory |
| Expanded-pagination Objective-C subclass | process-lifetime runtime owner |
| Segmented/menu fallback and trait adaptation | adaptive content inside the target |

The control installs one content implementation at initialization and keeps it
for its lifetime. It does not switch presentation implementations after
creation. On teardown, the floating content detaches `_tabModel` before its
hidden `UITabBarController` is released. The registered Objective-C subclass is
process-lifetime state and must have a globally unique, repository-independent
name.

## Runtime and Failure Boundary

Public APIs considered before the private path:

- `UITabBarController` provides the desired floating tab surface only as part
  of its container presentation; it does not expose that surface as a
  standalone title-view control on iPhone.
- `UITabBar` does not expose the iPad `tabSidebar` floating presentation.
- `UISegmentedControl` cannot provide the system pagination arrows or Liquid
  Glass lens, but is a valid semantic fallback.

`UITab` is not exposed publicly by this library because it requires an
irrelevant view-controller provider and carries root-container semantics.

The target contains all private class names, KVC keys, selector checks, method
type encodings, the verified 0.65 width correction, and OSLog diagnostics.
Consumers cannot select or inspect the implementation strategy through public
API.

The undocumented runtime is treated as a capability:

- when its core contract is verified, use the system floating presentation;
- on verified iOS 26 Glass metrics, apply the instance-isolated expanded-width
  pagination override;
- if only the width override is unverified, keep UIKit's standard pagination;
- if the core floating contract is unavailable or changed, use the public
  adaptive segmented/menu content with identical selection semantics.

This fallback is expected behavior for an undocumented OS boundary, not a
second source of semantic state. Documentation must state that App Store
acceptance and exact visuals are not guaranteed.

## Source Layout

```text
Sources/ScrollableTabBar/
  ScrollableTabBar.swift
  SystemFloatingTabContent.swift
  ExpandedPaginationRuntime.swift
  AdaptiveTabContent.swift
  ScrollableTabBar.docc/
    ScrollableTabBar.md

Tests/ScrollableTabBarTests/
  ScrollableTabBarTests.swift
  SystemFloatingTabContentTests.swift
  AdaptiveTabContentTests.swift
```

- `ScrollableTabBar.swift` owns the public control, item contract, selection,
  event forwarding, layout, and content lifetime.
- `SystemFloatingTabContent.swift` owns `UITab` projection, the strong hidden
  controller, private model attachment, and delegate translation.
- `ExpandedPaginationRuntime.swift` owns the one process-global runtime class
  and its verified method override.
- `AdaptiveTabContent.swift` owns compact/regular/accessibility fallback
  selection with no WebInspector localization dependency.

No public protocol is introduced because there is no consumer-provided second
implementation.

## Migration and Deletion

1. Add the public `ScrollableTabBar` product/target and its dedicated test
   target. Add `ScrollableTabBar` as a one-way dependency of
   `WebInspectorUINetwork`.
2. Move the private runtime, floating lifecycle, expanded pagination, adaptive
   fallback, and generic test seams into the new target. Rename the Objective-C
   runtime subclass so it contains no WebInspector/Network identity.
3. Replace `NetworkDetailModeControlController` with
   `ScrollableTabBar<NetworkDetailViewController.Mode>` directly in
   `NetworkDetailViewController`.
4. Delete `NetworkDetailModeControlController.swift`; do not retain a deprecated
   wrapper or duplicate fallback.
5. Remove Network test seams that expose private UIKit hierarchy, page buttons,
   Liquid Lens, or expanded width. Those assertions move to target tests.
6. Keep Network tests for mode ordering/localization, request-dependent enabled
   state, title-view installation, and the four content transitions.
7. Add the product to the root README and add consumer-first DocC, including
   the private-API/App-Store warning and the semantic fallback behavior.
8. Extend the existing external `ContractTests` package with an iOS consumer
   that imports `ScrollableTabBar` without `@testable`.

## Verification

### Target Contract

- item order and identity;
- programmatic selection without `.valueChanged`;
- user selection updates first and emits exactly once;
- reselect emits nothing;
- disabled interaction changes neither selection nor events;
- stable native identity across selection changes;
- accessibility labels, identifiers, reading order, Dynamic Type, and RTL;
- floating and adaptive implementations have the same public semantics;
- model detachment and owner release on teardown.

### Private Runtime

- class, selector, KVC, and method-encoding guards;
- hidden `UITabBarController` retains the real tab model;
- no sidebar button;
- 314-point iPhone pagination has reachable items, page arrows, expanded
  container width, and a Liquid Glass lens on verified iOS 26;
- iPad regular width shows all four current Network items;
- swipe/page-button navigation and an actual item activation reach the normal
  delegate/event path.

### Integration and Distribution

- Network mode/content transitions and disabled state in `WebInspectorUITests`;
- the repository's default iOS Simulator `xcodebuild test` command;
- external `ContractTests` iOS Simulator build/test without `@testable`;
- minimum supported iOS, iOS 18.4 enabled propagation, verified iOS 26.5, and
  latest available OS drift detection;
- `git diff --check` and DocC generation/snippet compilation.

The existing macOS-only `swift test --package-path ContractTests` remains useful
for non-UIKit products, but it is not evidence for this product. The UIKit
consumer contract needs an iOS Simulator `xcodebuild` invocation.

## Future Repository Extraction Gate

The standalone extraction moves only:

- `Sources/ScrollableTabBar`;
- `Tests/ScrollableTabBarTests`;
- the ScrollableTabBar DocC/README material;
- the external iOS consumer contract and runtime support matrix.

WebInspectorKit then changes only the package dependency declaration. The
Network consumer source and its `ScrollableTabBar<Mode>` usage must remain
unchanged. Requiring source edits at that point means this boundary was not
complete.

## Alternatives Not Selected

- `FloatingTabBar`: accurately describes the preferred visual implementation,
  but would make the adaptive fallback violate the type name. It also makes an
  undocumented visual treatment sound like a public guarantee.
- `PaginatedTabBar`: describes compact-width implementation detail, but not the
  iPad case where every item fits without pagination.
- `ScrollableTabBarKit`: `Kit` is broader than a single control family.
- Public `UITab` items: leaks content-controller semantics and forces every
  selector item to provide a dummy view controller.
- Non-generic String/object item identity: adds avoidable mapping and loses the
  consumer's domain type.
- Public delegate or closure property: duplicates `UIControl` target/action and
  `.valueChanged`.
- Failable floating-only initializer: makes every consumer reimplement the same
  normal fallback boundary and leaves extraction incomplete.
- Dynamic item mutation in v1: adds membership/selection synchronization without
  a current consumer requirement.

## Design Gate

Implementation starts after agreement on these decisions:

1. Product, target, and public type name: `ScrollableTabBar`.
2. Swift-only generic `ID: Hashable` API with immutable items.
3. iOS 18+ semantic contract; iOS 26 Liquid Glass is a verified private-runtime
   implementation, not a guaranteed public appearance.
4. Adaptive public fallback is target-owned.
5. Separate public library product now; no `WebInspectorKit` re-export.
6. Future repository extraction must require no Network consumer-source change.
