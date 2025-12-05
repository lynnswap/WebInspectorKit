import Testing
@testable import WebInspectorKit

@MainActor
struct WIDOMAgentModelTests {
    @Test
    func didClearPageWebViewClearsSelection() {
        let agent = WIDOMAgentModel(configuration: .init(snapshotDepth: 3, subtreeDepth: 2))
        agent.selection.nodeId = 42
        agent.selection.preview = "<div>"
        agent.selection.attributes = [WIDOMAttribute(nodeId: 42, name: "class", value: "title")]
        agent.selection.path = ["html", "body", "div"]
        agent.selection.selectorPath = "#title"

        agent.didClearPageWebView()

        #expect(agent.selection.nodeId == nil)
        #expect(agent.selection.preview.isEmpty)
        #expect(agent.selection.attributes.isEmpty)
        #expect(agent.selection.path.isEmpty)
        #expect(agent.selection.selectorPath.isEmpty)
    }

    @Test
    func beginSelectionModeWithoutWebViewThrows() async {
        let agent = WIDOMAgentModel(configuration: .init())
        await #expect(throws: WIError.scriptUnavailable) {
            _ = try await agent.beginSelectionMode()
        }
    }

    @Test
    func captureSnapshotWithoutWebViewThrows() async {
        let agent = WIDOMAgentModel(configuration: .init(snapshotDepth: 2))
        await #expect(throws: WIError.scriptUnavailable) {
            _ = try await agent.captureSnapshot()
        }
    }

    @Test
    func selectionCopyTextWithoutWebViewThrows() async {
        let agent = WIDOMAgentModel(configuration: .init())
        await #expect(throws: WIError.scriptUnavailable) {
            _ = try await agent.selectionCopyText(for: 1, kind: .html)
        }
    }
}
