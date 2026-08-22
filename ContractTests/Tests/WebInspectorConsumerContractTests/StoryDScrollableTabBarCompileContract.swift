#if canImport(UIKit)
import ScrollableTabBar
import Testing
import UIKit

private enum ContractReportSection: Hashable {
    case overview
    case activity
    case settings
}

@MainActor
@Test
func scrollableTabBarUsesTypedConsumerIdentityAndUIControlEvents() {
    let items: [ScrollableTabBar<ContractReportSection>.Item] = [
        .init(
            id: .overview,
            title: "Overview",
            accessibilityIdentifier: "Contract.ReportSection.Overview"
        ),
        .init(
            id: .activity,
            title: "Activity",
            accessibilityIdentifier: "Contract.ReportSection.Activity"
        ),
        .init(
            id: .settings,
            title: "Settings",
            image: UIImage(systemName: "gear"),
            accessibilityIdentifier: "Contract.ReportSection.Settings"
        ),
    ]
    let control = ScrollableTabBar(
        items: items,
        selectedID: ContractReportSection.overview
    )
    let recorder = ContractSelectionRecorder()
    control.addTarget(
        recorder,
        action: #selector(ContractSelectionRecorder.valueChanged),
        for: .valueChanged
    )

    #expect(control.items.map(\.id) == [.overview, .activity, .settings])
    #expect(control.items.last?.accessibilityIdentifier == "Contract.ReportSection.Settings")
    #expect(control.selectedID == .overview)

    control.selectedID = .settings

    #expect(control.selectedID == .settings)
    #expect(recorder.eventCount == 0)
    #expect(control.isEnabled)

    control.isEnabled = false
    #expect(control.isEnabled == false)
}

@MainActor
private final class ContractSelectionRecorder: NSObject {
    private(set) var eventCount = 0

    @objc func valueChanged() {
        eventCount += 1
    }
}
#endif
