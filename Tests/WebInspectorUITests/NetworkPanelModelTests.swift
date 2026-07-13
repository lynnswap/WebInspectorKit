import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
@testable import WebInspectorUINetwork

@MainActor
final class CanonicalNetworkPanelFixture {
    let context: WebInspectorModelContext
    private var store: CanonicalNetworkStore
    private var revision: UInt64 = 0
    private let scope: WebInspectorCanonicalNetworkEventScope

    init() async throws {
        let storeID = WebInspectorContainerStoreID()
        var store = CanonicalNetworkStore(storeID: storeID)
        let attachment = WebInspectorContainerAttachmentGeneration(rawValue: 1)
        let generation = WebInspectorPage.Generation(rawValue: 1)
        _ = try store.reset(
            attachmentGeneration: attachment,
            pageGeneration: generation
        )
        self.store = store
        context = WebInspectorModelContext(
            configuration: .init(domains: [.network]),
            modelSchemaRegistry: WebInspectorModelSchemaRegistry(
                WebInspectorNetworkModelSchemas.registrations
            ),
            isolation: MainActor.shared
        )
        scope = WebInspectorCanonicalNetworkEventScope(
            modelScope: ModelEventScope(
                generation: generation,
                target: ModelTarget(
                    id: WebInspectorTarget.ID("page"),
                    kind: .page,
                    frameID: FrameID("main-frame"),
                    parentFrameID: nil
                ),
                agentTarget: ModelTarget(
                    id: WebInspectorTarget.ID("page"),
                    kind: .page,
                    frameID: FrameID("main-frame"),
                    parentFrameID: nil
                ),
                navigationEpoch: ModelNavigationEpoch(rawValue: 1),
                domBindingEpoch: ModelDOMBindingEpoch(rawValue: 1),
                runtimeBindingEpoch: nil,
                consoleBindingEpoch: nil
            )
        )
        try await applyInitial()
    }

    func insert(
        id rawID: String,
        url: String,
        method: String = "GET",
        resourceType: Network.ResourceType = .fetch,
        initiatorNodeID: String? = nil,
        timestamp: Double
    ) async throws -> NetworkRequest.ID {
        let event = Network.Event.requestWillBeSent(
            id: Network.Request.ID(rawID),
            request: Network.Request(
                id: Network.Request.ID(rawID),
                url: url,
                method: method
            ),
            initiator: Network.Initiator(
                kind: "other",
                nodeID: initiatorNodeID.map(DOM.Node.ID.init)
            ),
            resourceType: resourceType,
            redirectResponse: nil,
            timestamp: timestamp
        )
        try await apply(event)
        guard let id = store.requests.first(where: {
            $0.id.rawRequestID == Network.Request.ID(rawID)
        })?.id else {
            preconditionFailure("Canonical Network insertion lost its request.")
        }
        return NetworkRequest.ID(canonical: id)
    }

    func receiveResponse(
        id rawID: String,
        status: Int = 200,
        mimeType: String,
        resourceType: Network.ResourceType,
        timestamp: Double
    ) async throws {
        try await apply(
            .responseReceived(
                id: Network.Request.ID(rawID),
                response: Network.Response(
                    url: "https://example.test/\(rawID)",
                    status: status,
                    mimeType: mimeType
                ),
                resourceType: resourceType,
                timestamp: timestamp
            )
        )
    }

    func entryID(containing requestID: NetworkRequest.ID) -> NetworkEntry.ID {
        guard let storage = requestID.canonicalStorage,
              let entry = store.entries.first(where: {
                  $0.requestIDs.contains(storage)
              }) else {
            preconditionFailure("Canonical Network request lost its entry.")
        }
        return NetworkEntry.ID(canonical: entry.id)
    }

    func clear() async throws {
        try await apply(store.clear())
    }

    func apply(_ event: Network.Event) async throws {
        guard let transaction = try store.reduce(event, scope: scope) else {
            return
        }
        try await apply(transaction)
    }

    func request(rawID: Network.Request.ID) -> NetworkRequest? {
        guard let record = store.requests.first(where: {
            $0.id.rawRequestID == rawID
        }) else {
            return nil
        }
        return context.model(for: NetworkRequest.ID(canonical: record.id))
    }

    private func apply(_ transaction: CanonicalNetworkTransaction) async throws {
        precondition(revision < .max)
        revision += 1
        var canonical = WebInspectorCanonicalModelTransaction()
        canonical.network = transaction
        let transaction = context.modelSchemaContextCore.changes(
            at: revision,
            transaction: canonical
        )
        let commit = try await transaction.stage(
            on: context.fetchedResultsQueryCore
        )
        precondition(context.publish(commit))
    }

    private func applyInitial() async throws {
        let snapshot = WebInspectorCanonicalModelSnapshot(
            binding: nil,
            network: store.snapshot,
            DOM: nil,
            CSS: nil,
            consoleRuntime: nil
        )
        let transaction = context.modelSchemaContextCore.initial(
            at: revision,
            snapshot: snapshot
        )
        let commit = try await transaction.stage(
            on: context.fetchedResultsQueryCore
        )
        precondition(context.publish(commit))
    }
}

@Suite
struct NetworkPanelModelTests {
    @MainActor
    @Test
    func filtersAndSortsCanonicalEntriesThroughGenericDescriptor() async throws {
        let fixture = try await CanonicalNetworkPanelFixture()
        let documentID = try await fixture.insert(
            id: "document",
            url: "https://example.test/index.html",
            resourceType: .document,
            timestamp: 1
        )
        let scriptID = try await fixture.insert(
            id: "script",
            url: "https://cdn.example.test/app.js",
            resourceType: .script,
            timestamp: 2
        )
        let imageID = try await fixture.insert(
            id: "image",
            url: "https://cdn.example.test/photo.png",
            resourceType: .image,
            timestamp: 3
        )
        let model = try await NetworkPanelModel.make(context: fixture.context)
        #expect(
            model.entries.snapshot.itemIDs == [
                fixture.entryID(containing: imageID),
                fixture.entryID(containing: scriptID),
                fixture.entryID(containing: documentID),
            ]
        )

        model.setSearchText("cdn")
        model.setResourceFilter(.script, enabled: true)
        await model.waitForQueryUpdates()

        #expect(model.entries.snapshot.itemIDs == [fixture.entryID(containing: scriptID)])
        #expect(model.appliedQueryRevision == model.queryRevision)
        await model.retire()
    }

    @MainActor
    @Test
    func groupedSelectionResolvesEveryRequestThroughTheSameContext() async throws {
        let fixture = try await CanonicalNetworkPanelFixture()
        let playlistID = try await fixture.insert(
            id: "playlist",
            url: "https://media.example.test/master.m3u8",
            resourceType: .media,
            initiatorNodeID: "video",
            timestamp: 1
        )
        let segmentID = try await fixture.insert(
            id: "segment",
            url: "https://media.example.test/segment.m4s",
            resourceType: .media,
            initiatorNodeID: "video",
            timestamp: 2
        )
        let model = try await NetworkPanelModel.make(context: fixture.context)
        let entryID = fixture.entryID(containing: playlistID)
        #expect(entryID == fixture.entryID(containing: segmentID))

        model.selectEntry(entryID)

        #expect(model.selectedEntryID == entryID)
        #expect(model.selectedRequests.map(\.id) == [playlistID, segmentID])
        #expect(model.selectedRequests.allSatisfy { request in
            fixture.context.model(for: request.id) === request
        })
        await model.retire()
    }

    @MainActor
    @Test
    func filteredEntriesDoNotDisableClearOrInvalidateSelection() async throws {
        let fixture = try await CanonicalNetworkPanelFixture()
        let requestID = try await fixture.insert(
            id: "script",
            url: "https://cdn.example.test/app.js",
            resourceType: .script,
            timestamp: 1
        )
        let model = try await NetworkPanelModel.make(context: fixture.context)
        let entryID = fixture.entryID(containing: requestID)
        model.selectEntry(entryID)
        model.setSearchText("does-not-match")
        await model.waitForQueryUpdates()

        #expect(model.entries.snapshot.itemIDs.isEmpty)
        #expect(model.hasClearableRequests)
        #expect(model.selectedEntryID == entryID)
        #expect(model.selectedRequests.map(\.id) == [requestID])

        try await fixture.clear()

        #expect(model.hasClearableRequests == false)
        #expect(model.selectedEntryID == nil)
        #expect(model.selectedRequests.isEmpty)
        await model.retire()
    }

    @MainActor
    @Test
    func entryContentChangesReevaluateFilterWithoutReplacingModelIdentity() async throws {
        let fixture = try await CanonicalNetworkPanelFixture()
        let requestID = try await fixture.insert(
            id: "response",
            url: "https://example.test/response",
            resourceType: .fetch,
            timestamp: 1
        )
        let model = try await NetworkPanelModel.make(context: fixture.context)
        let entryID = fixture.entryID(containing: requestID)
        let entry = try #require(fixture.context.model(for: entryID))
        model.setSearchText("404")
        await model.waitForQueryUpdates()
        #expect(model.entries.snapshot.itemIDs.isEmpty)

        try await fixture.receiveResponse(
            id: "response",
            status: 404,
            mimeType: "application/json",
            resourceType: .fetch,
            timestamp: 2
        )

        #expect(model.entries.snapshot.itemIDs == [entryID])
        #expect(fixture.context.model(for: entryID) === entry)
        #expect(entry.statusCode == 404)
        await model.retire()
    }

    @MainActor
    @Test
    func retireClosesBothFilteredAndClearAvailabilityControllers() async throws {
        let fixture = try await CanonicalNetworkPanelFixture()
        let model = try await NetworkPanelModel.make(context: fixture.context)
        #expect(fixture.context.fetchedResultsControllerOwnerCountForTesting == 2)

        await model.retire()

        #expect(model.isRetiredForTesting)
        #expect(fixture.context.fetchedResultsControllerOwnerCountForTesting == 0)
    }

    @MainActor
    @Test
    func deinitBackstopSynchronouslyRemovesBothFetchedResultsOwnerEntries() async throws {
        let fixture = try await CanonicalNetworkPanelFixture()
        var model: NetworkPanelModel? = try await NetworkPanelModel.make(
            context: fixture.context
        )
        #expect(fixture.context.fetchedResultsControllerOwnerCountForTesting == 2)

        model = nil

        #expect(model == nil)
        #expect(fixture.context.fetchedResultsControllerOwnerCountForTesting == 0)
    }
}
