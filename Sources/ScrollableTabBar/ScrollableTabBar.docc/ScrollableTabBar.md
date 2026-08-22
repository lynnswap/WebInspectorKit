# ``ScrollableTabBar``

An iOS UIKit tab selector that keeps overflow items horizontally reachable.

## Overview

Use `ScrollableTabBar` when a compact selection surface has more tabs than can
fit at once. Give each item a stable domain ID, then handle the standard
`UIControl.Event.valueChanged` event to update your application's selection.

The control is Swift-only, requires iOS 18 or later, and preserves the ID type
chosen by the consumer.

```swift
import ScrollableTabBar
import UIKit

@MainActor
final class ReportViewController: UIViewController {
    private enum Section: Hashable {
        case overview
        case activity
        case settings
    }
    private var selectedSection: Section = .overview

    private lazy var sectionControl: ScrollableTabBar<Section> = {
        let control = ScrollableTabBar(
            items: [
                .init(
                    id: .overview,
                    title: "Overview",
                    accessibilityIdentifier: "Report.Section.Overview"
                ),
                .init(
                    id: .activity,
                    title: "Activity",
                    accessibilityIdentifier: "Report.Section.Activity"
                ),
                .init(
                    id: .settings,
                    title: "Settings",
                    image: UIImage(systemName: "gear"),
                    accessibilityIdentifier: "Report.Section.Settings"
                ),
            ],
            selectedID: .overview
        )
        control.accessibilityLabel = "Report Section"
        control.addAction(
            UIAction { [weak self, weak control] _ in
                guard let selectedID = control?.selectedID else {
                    return
                }
                self?.selectSection(selectedID)
            },
            for: .valueChanged
        )
        return control
    }()

    private func selectSection(_ section: Section) {
        selectedSection = section
        sectionControl.selectedID = selectedSection
        // Render content for `section`.
    }
}
```

Install the control like any other UIKit view, including as a navigation item's
`titleView`, and constrain its size with Auto Layout. `ScrollableTabBar`
inherits target/action, `addAction(_:for:)`, `isEnabled`, tint, and standard
accessibility properties from `UIControl`.

## Own Selection in the Consumer

The consumer owns semantic selection and content routing. The control owns only
the current UIKit projection and user input:

- Create the control with a nonempty, ordered item collection whose IDs are
  unique.
- Choose an initial `selectedID` that belongs to those items.
- Assign `selectedID` when application state changes. Programmatic assignment
  updates the visible selection and does not send `.valueChanged`.
- On user input, the control updates `selectedID` first, then sends exactly one
  `.valueChanged` event if the ID changed. Reselecting the current item sends no
  event.
- Set `isEnabled` to `false` to prevent user selection and show the disabled
  presentation.

Item membership and order are immutable for the control's lifetime. Create a
new control when a different tab set is required. Empty items, duplicate IDs,
or a selection outside the item collection violate the initializer and
selection contract.

## Presentation and Compatibility

`ScrollableTabBar` prefers the system floating-tab presentation when the
expected UIKit runtime contract is available. On verified system versions this
can provide native pagination and a Liquid Glass selection lens. When that
undocumented contract is unavailable or changes, the control automatically
uses a public UIKit segmented or menu presentation with the same item,
selection, enablement, and event semantics.

The name describes the behavior that overflow items remain horizontally
reachable. Continuous `UIScrollView` scrolling, a particular number of items
per page, page-arrow placement, and an exact visual treatment are not public
contracts.

> Important: The preferred floating presentation relies on undocumented UIKit
> runtime behavior. Exact pagination and Liquid Glass appearance can change
> between OS releases, and use of this product does not guarantee App Store
> acceptance. The public fallback preserves selection behavior, not identical
> appearance.

## Topics

### Creating a Tab Bar

- ``ScrollableTabBar/init(items:selectedID:)``
- ``ScrollableTabBar/Item``
- ``ScrollableTabBar/items``

### Managing Selection

- ``ScrollableTabBar/selectedID``
