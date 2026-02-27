import Testing
@testable import WebInspectorEngine

@MainActor
struct NetworkSessionTests {
    @Test
    func startsInActiveMode() {
        let session = NetworkSession()

        #expect(session.mode == .active)
    }
}
