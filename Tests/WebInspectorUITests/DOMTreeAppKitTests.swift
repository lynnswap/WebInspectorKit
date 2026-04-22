#if canImport(AppKit)
import AppKit
import Testing
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct DOMTreeAppKitTests {
    @Test
    func treeViewShowsAndClearsDocumentErrorMessage() async throws {
        let inspector = WIDOMInspector()
        let controller = WIDOMTreeViewController(inspector: inspector)
        let window = NSWindow(contentViewController: controller)
        defer {
            window.orderOut(nil)
            window.close()
        }

        controller.loadViewIfNeeded()
        window.makeKeyAndOrderFront(nil)

        inspector.document.setErrorMessage("Failed to resolve selected element.")

        #expect(await waitUntilAppKitCondition {
            controller.errorLabelStringValueForTesting == "Failed to resolve selected element."
                && controller.isErrorLabelHiddenForTesting == false
        })

        inspector.document.setErrorMessage(nil)

        #expect(await waitUntilAppKitCondition {
            controller.errorLabelStringValueForTesting.isEmpty
                && controller.isErrorLabelHiddenForTesting
        })
    }
}

@MainActor
private func waitUntilAppKitCondition(
    timeout: TimeInterval = 1.0,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    return condition()
}
#endif
