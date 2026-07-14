import Testing
@testable import WebInspectorDataKit
@testable import WebInspectorSwiftUI

@MainActor
@Suite
struct WebInspectorQueryTests {
    @Test
    func unboundStorageStartsEmpty() {
        let storage = WebInspectorQueryStorage<DOMNode>()

        #expect(storage.fetchedObjects.isEmpty)
        #expect(storage.fetchError == nil)
        #expect(storage.modelContext == nil)
    }
}
