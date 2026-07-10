import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

private actor StoreIsolationProbe {
    func exercise() async throws -> (networkCount: Int, consoleTexts: [String]) {
        let context = WebInspectorModelContext.preview()
        let networkStore = NetworkRequestStore()
        let networkID = Network.Request.ID("custom-actor-request")
        await networkStore.apply(
            .requestWillBeSent(
                id: networkID,
                request: Network.Request(
                    id: networkID,
                    url: "https://example.com/custom-actor",
                    method: "GET"
                ),
                resourceType: .fetch,
                redirectResponse: nil,
                timestamp: 1
            ),
            modelContext: context
        )

        let consoleStore = ConsoleMessageStore()
        let results = try await consoleStore.results(
            matching: ConsoleQuery(),
            modelContext: context
        )
        _ = await consoleStore.apply(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: "custom actor"
            )),
            targetID: nil,
            modelContext: context,
            registerRuntimeObject: { _ in
                fatalError("The fixture has no Runtime parameters.")
            }
        )
        return (
            networkStore.collectionState.requestCount,
            results.items.map(\.text)
        )
    }
}

@Test
func networkAndConsoleStoresInheritTheCallingActor() async throws {
    let values = try await StoreIsolationProbe().exercise()

    #expect(values.networkCount == 1)
    #expect(values.consoleTexts == ["custom actor"])
}

@MainActor
@Test
func consoleMessageStoreClearsOnlyTheAddressedTarget() async throws {
    let context = WebInspectorModelContext.preview()
    let store = ConsoleMessageStore()
    let firstTarget = WebInspectorTarget.ID("first")
    let secondTarget = WebInspectorTarget.ID("second")
    let results = try await store.results(
        matching: ConsoleQuery(),
        modelContext: context
    )

    for (target, text) in [(firstTarget, "first"), (secondTarget, "second")] {
        _ = await store.apply(
            .messageAdded(Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                text: text
            )),
            targetID: target,
            modelContext: context,
            registerRuntimeObject: { _ in
                fatalError("The fixture has no Runtime parameters.")
            }
        )
    }
    #expect(results.items.map(\.text) == ["first", "second"])

    let effects = await store.apply(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        targetID: firstTarget,
        modelContext: context,
        registerRuntimeObject: { _ in
            fatalError("Clear events have no Runtime parameters.")
        }
    )

    #expect(effects.clearedAllMessages == false)
    #expect(results.items.map(\.text) == ["second"])
}
