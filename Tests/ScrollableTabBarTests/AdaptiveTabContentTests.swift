#if canImport(UIKit)
import Testing
import UIKit
@testable import ScrollableTabBar

@MainActor
@Suite(.serialized)
struct AdaptiveTabContentTests {
    @Test
    func rendersEquivalentSegmentedAndMenuSelection() {
        let content = makeContent()
        content.render(
            selectedIndex: 2,
            isEnabled: true,
            accessibilityLabel: "Detail Mode"
        )

        #expect(content.segmentedControl.selectedSegmentIndex == 2)
        #expect(content.segmentedControl.accessibilityLabel == "Detail Mode")
        #expect(content.segmentedControl.accessibilityValue == "Cookies")
        #expect(content.menuButton.configuration?.title == "Cookies")
        #expect(content.menuButton.accessibilityLabel == "Detail Mode")
        #expect(content.menuButton.accessibilityValue == "Cookies")
        let menuActions = content.menuButton.menu?.children.compactMap { $0 as? UIAction }
        #expect(menuActions?.map(\.title) == ["Headers", "Preview", "Cookies", "Security"])
        #expect(menuActions?.map(\.state) == [.off, .off, .on, .off])
    }

    @Test
    func segmentedSelectionUsesTheNormalValueChangedPath() {
        let content = makeContent()
        var selectedIndices: [Int] = []
        content.selectionHandler = { index in
            selectedIndices.append(index)
        }
        content.render(
            selectedIndex: 0,
            isEnabled: true,
            accessibilityLabel: nil
        )

        content.segmentedControl.selectedSegmentIndex = 3
        content.valueChanged(content.segmentedControl)

        #expect(selectedIndices == [3])
    }

    @Test
    func disabledStateAppliesToBothPresentations() {
        let content = makeContent()
        content.render(
            selectedIndex: 1,
            isEnabled: false,
            accessibilityLabel: "Detail Mode"
        )

        #expect(content.segmentedControl.isEnabled == false)
        #expect(content.menuButton.isEnabled == false)
        #expect((0..<content.segmentedControl.numberOfSegments).allSatisfy {
            content.segmentedControl.isEnabledForSegment(at: $0) == false
        })
    }

    @Test
    func adaptsRegularContentAndAccessibilitySizes() {
        let regular = UITraitCollection(horizontalSizeClass: .regular)
        let compact = UITraitCollection(horizontalSizeClass: .compact)
        let accessibilityRegular = UITraitCollection { mutableTraits in
            mutableTraits.horizontalSizeClass = .regular
            mutableTraits.preferredContentSizeCategory = .accessibilityLarge
        }

        #expect(AdaptiveTabView.presentation(for: regular) == .segmented)
        #expect(AdaptiveTabView.presentation(for: compact) == .menu)
        #expect(AdaptiveTabView.presentation(for: accessibilityRegular) == .menu)
    }

    private func makeContent() -> AdaptiveTabContent {
        AdaptiveTabContent(
            items: [
                .init(title: "Headers", image: nil, accessibilityIdentifier: nil),
                .init(title: "Preview", image: nil, accessibilityIdentifier: nil),
                .init(title: "Cookies", image: nil, accessibilityIdentifier: nil),
                .init(title: "Security", image: nil, accessibilityIdentifier: nil),
            ]
        )
    }
}
#endif
