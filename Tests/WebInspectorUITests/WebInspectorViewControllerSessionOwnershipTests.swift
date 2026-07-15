#if canImport(UIKit)
import Testing
@testable import WebInspectorKit

@MainActor
@Test
func injectedSessionRemainsCallerOwnedAfterPresentationRetirement() async {
    let session = WebInspectorSession()
    let viewController = WebInspectorViewController(session: session)
    let baseline = viewController
        .rootPresentationRetirementTaskCompletionCountForTesting

    viewController.finishRootPresentationLifecycleForTesting()

    #expect(
        await viewController
            .waitForRootPresentationRetirementTaskCompletionForTesting(
                after: baseline
            )
    )
    #expect(session.modelContainer.state == .detached)
}

@MainActor
@Test
func defaultControllerClosesItsOwnedSessionAfterPresentationRetirement() async {
    let viewController = WebInspectorViewController()
    let session = viewController.session
    let baseline = viewController
        .rootPresentationRetirementTaskCompletionCountForTesting

    viewController.finishRootPresentationLifecycleForTesting()

    #expect(
        await viewController
            .waitForRootPresentationRetirementTaskCompletionForTesting(
                after: baseline
            )
    )
    #expect(session.modelContainer.state == .closed)
}
#endif
