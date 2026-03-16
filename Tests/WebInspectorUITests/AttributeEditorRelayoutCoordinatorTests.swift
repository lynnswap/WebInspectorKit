import Testing
@testable import WebInspectorUI
@testable import WebInspectorRuntime

struct AttributeEditorRelayoutCoordinatorTests {
    @Test
    func beginRelayoutStartsWhenPendingAndVisible() {
        var coordinator = AttributeEditorRelayoutCoordinator()

        coordinator.requestRelayout()

        #expect(coordinator.beginRelayoutIfPossible(isViewVisible: true) == true)
        #expect(coordinator.isPerformingRelayout == true)
        #expect(coordinator.hasPendingRelayout == false)
    }

    @Test
    func beginRelayoutDefersWhileDequeuingCell() {
        var coordinator = AttributeEditorRelayoutCoordinator()
        coordinator.beginCellDequeue()
        coordinator.requestRelayout()

        #expect(coordinator.beginRelayoutIfPossible(isViewVisible: true) == false)
        #expect(coordinator.hasPendingRelayout == true)

        coordinator.endCellDequeue()

        #expect(coordinator.beginRelayoutIfPossible(isViewVisible: true) == true)
    }

    @Test
    func beginRelayoutDefersWhileHidden() {
        var coordinator = AttributeEditorRelayoutCoordinator()
        coordinator.requestRelayout()

        #expect(coordinator.beginRelayoutIfPossible(isViewVisible: false) == false)
        #expect(coordinator.hasPendingRelayout == true)

        #expect(coordinator.beginRelayoutIfPossible(isViewVisible: true) == true)
    }

    @Test
    func beginRelayoutBlocksUntilPreviousRelayoutFinishes() {
        var coordinator = AttributeEditorRelayoutCoordinator()
        coordinator.requestRelayout()
        #expect(coordinator.beginRelayoutIfPossible(isViewVisible: true) == true)

        coordinator.requestRelayout()
        #expect(coordinator.beginRelayoutIfPossible(isViewVisible: true) == false)
        #expect(coordinator.hasPendingRelayout == true)

        coordinator.finishRelayout()
        #expect(coordinator.beginRelayoutIfPossible(isViewVisible: true) == true)
    }
}
