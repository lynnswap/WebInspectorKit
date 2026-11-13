import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
private func makeStoreRequest(
    id: String,
    context: WebInspectorContext,
    timestamp: Double = 1
) -> NetworkRequest {
    NetworkRequest(
        request: Network.Request(
            id: Network.Request.ID(id),
            url: "https://example.test/\(id)",
            method: "GET"
        ),
        initiator: nil,
        resourceType: .fetch,
        timestamp: timestamp,
        modelContext: context
    )
}

@MainActor
private func insertStoreRequest(
    _ id: String,
    store: NetworkRequestStore,
    context: WebInspectorContext
) throws -> NetworkRequestStore.Registration {
    let resolution = try #require(
        store.resolve(
            id: NetworkRequest.ID(Network.Request.ID(id)),
            admission: .requestWillBeSent(hasRedirectResponse: false),
            create: { makeStoreRequest(id: id, context: context) }
        ))
    guard case let .inserted(registration) = resolution else {
        Issue.record("Expected a new Network request registration.")
        throw NetworkRequestStoreTestFailure()
    }
    return registration
}

private struct NetworkRequestStoreTestFailure: Error {}

@MainActor
@Test
func storePublishesInsertionsUpdatesAndResetsInOrder() async throws {
    let context = WebInspectorContext.preview()
    let store = NetworkRequestStore()
    var changes = store.changes.makeAsyncIterator()

    let first = try insertStoreRequest("first", store: store, context: context)
    store.commitUpdate(first)
    let restored = [
        makeStoreRequest(id: "restored-a", context: context),
        makeStoreRequest(id: "restored-b", context: context),
    ]
    store.insertResourceTreeRequests(restored)
    #expect(store.requests.map(\.id) == [first.request.id] + restored.map(\.id))

    store.reset(for: .userClear)
    store.commitUpdate(first)
    #expect(store.requests.isEmpty)

    #expect(await changes.next() == .inserted([first.request.id]))
    #expect(await changes.next() == .updated([first.request.id]))
    #expect(await changes.next() == .inserted(restored.map(\.id)))
    #expect(await changes.next() == .removedAll)

    let second = try insertStoreRequest("second", store: store, context: context)
    #expect(await changes.next() == .inserted([second.request.id]))
}

@MainActor
@Test
func userClearAndAttachmentResetApplyDistinctSameIDAdmissionPolicies() throws {
    let context = WebInspectorContext.preview()
    let store = NetworkRequestStore()
    let first = try insertStoreRequest("reset-policy", store: store, context: context)
    let modelID = first.request.id

    store.reset(for: .userClear)
    #expect(store.isCurrent(first) == false)
    #expect(store.isTombstoned(modelID))
    #expect(
        store.resolve(
            id: modelID,
            admission: .ordinary,
            create: { makeStoreRequest(id: "reset-policy", context: context, timestamp: 2) }
        ) == nil)
    #expect(
        store.resolve(
            id: modelID,
            admission: .requestWillBeSent(hasRedirectResponse: true),
            create: { makeStoreRequest(id: "reset-policy", context: context, timestamp: 3) }
        ) == nil)
    let reopened = try #require(
        store.resolve(
            id: modelID,
            admission: .requestWillBeSent(hasRedirectResponse: false),
            create: { makeStoreRequest(id: "reset-policy", context: context, timestamp: 4) }
        ))
    #expect(reopened.registration.request !== first.request)
    #expect(reopened.registration.orderIndex == 0)

    store.reset(for: .userClear)
    let webSocketReopened = try #require(
        store.resolve(
            id: modelID,
            admission: .webSocketCreated,
            create: { makeStoreRequest(id: "reset-policy", context: context, timestamp: 5) }
        ))
    #expect(webSocketReopened.registration.orderIndex == 0)

    store.reset(for: .userClear)
    store.reset(for: .newAttachment)
    let attachmentResponse = try #require(
        store.resolve(
            id: modelID,
            admission: .ordinary,
            create: { makeStoreRequest(id: "reset-policy", context: context, timestamp: 6) }
        ))
    #expect(attachmentResponse.registration.orderIndex == 0)
    #expect(store.isTombstoned(modelID) == false)
}
