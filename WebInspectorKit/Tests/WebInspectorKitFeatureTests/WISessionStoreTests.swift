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
                    selectedTabID: "wi_dom",
                    dom: WIDOMViewState(hasAttachedPage: true, selectedNodeID: 101, isAutoSnapshotEnabled: true),
                    network: WINetworkViewState(hasAttachedPage: true, mode: .buffering, isRecording: true, entryCount: 7)
                )
            )
        )
        continuation.yield(.recoverableError("payload decode failed"))

        for _ in 0..<40 {
            if store.viewState.selectedTabID == "wi_dom",
               store.viewState.lastRecoverableError == "payload decode failed" {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(store.viewState.lifecycle == .active)
        #expect(store.viewState.selectedTabID == "wi_dom")
        #expect(store.viewState.dom.selectedNodeID == 101)
        #expect(store.viewState.network.entryCount == 7)
        #expect(store.viewState.lastRecoverableError == "payload decode failed")

        continuation.finish()
    }

    @Test
    func keepsLatestStateWhenLifecycleTransitionsInterleaveWithErrors() async {
        let store = WISessionStore()
        let (stream, continuation) = AsyncStream<WISessionEvent>.makeStream()
        store.bind(to: stream)

        continuation.yield(
            .stateChanged(
                WISessionViewState(
                    lifecycle: .active,
                    selectedTabID: "wi_dom",
                    dom: WIDOMViewState(hasAttachedPage: true, selectedNodeID: 5, isAutoSnapshotEnabled: true),
                    network: WINetworkViewState(hasAttachedPage: true, mode: .buffering, isRecording: true, entryCount: 2),
                    lastRecoverableError: nil
                )
            )
        )
        continuation.yield(.recoverableError("first error"))
        continuation.yield(
            .stateChanged(
                WISessionViewState(
                    lifecycle: .suspended,
                    selectedTabID: "wi_network",
                    dom: WIDOMViewState(hasAttachedPage: false, selectedNodeID: nil, isAutoSnapshotEnabled: false),
                    network: WINetworkViewState(hasAttachedPage: false, mode: .stopped, isRecording: false, entryCount: 2),
                    lastRecoverableError: "first error"
                )
            )
        )
        continuation.yield(.recoverableError("second error"))
        continuation.yield(
            .stateChanged(
                WISessionViewState(
                    lifecycle: .active,
                    selectedTabID: "wi_network",
                    dom: WIDOMViewState(hasAttachedPage: true, selectedNodeID: 99, isAutoSnapshotEnabled: false),
                    network: WINetworkViewState(hasAttachedPage: true, mode: .active, isRecording: true, entryCount: 12),
                    lastRecoverableError: "second error"
                )
            )
        )

        for _ in 0..<40 {
            let viewState = store.viewState
            if viewState.lifecycle == .active,
               viewState.selectedTabID == "wi_network",
               viewState.network.mode == .active,
               viewState.lastRecoverableError == "second error" {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(store.viewState.lifecycle == .active)
        #expect(store.viewState.selectedTabID == "wi_network")
        #expect(store.viewState.dom.hasAttachedPage == true)
        #expect(store.viewState.dom.selectedNodeID == 99)
        #expect(store.viewState.network.hasAttachedPage == true)
        #expect(store.viewState.network.mode == .active)
        #expect(store.viewState.network.entryCount == 12)
        #expect(store.viewState.lastRecoverableError == "second error")

        continuation.finish()
    }
}
