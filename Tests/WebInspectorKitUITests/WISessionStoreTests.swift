import Testing
import WebInspectorKitCore
@testable import WebInspectorKit

@MainActor
struct WISessionStoreTests {
    @Test
    func rebuildsStateFromEventStreamDeterministically() async {
        let store = WISessionStore()
        let (stream, continuation) = AsyncStream<WISessionEvent>.makeStream()
        store.bind(to: stream)

        continuation.yield(
            .stateChanged(
                WISessionViewState(
                    lifecycle: .active,
                    selectedPaneID: "wi_dom",
                    dom: WIDOMViewState(hasAttachedPage: true, selectedNodeID: 101, isAutoSnapshotEnabled: true),
                    network: WINetworkViewState(hasAttachedPage: true, mode: .buffering, isRecording: true, entryCount: 7)
                )
            )
        )
        continuation.yield(.recoverableError("payload decode failed"))

        for _ in 0..<40 {
            if store.viewState.selectedPaneID == "wi_dom",
               store.viewState.lastRecoverableError == "payload decode failed" {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(store.viewState.lifecycle == .active)
        #expect(store.viewState.selectedPaneID == "wi_dom")
        #expect(store.viewState.dom.selectedNodeID == 101)
        #expect(store.viewState.network.entryCount == 7)
        #expect(store.viewState.lastRecoverableError == "payload decode failed")

        continuation.finish()
    }
}
