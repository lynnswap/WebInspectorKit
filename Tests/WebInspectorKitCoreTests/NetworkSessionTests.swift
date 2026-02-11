import Testing
@testable import WebInspectorKitCore

@MainActor
struct NetworkSessionTests {
    @Test
    func startsInActiveMode() {
        let session = NetworkSession()

        #expect(session.mode == .active)
    }
}
