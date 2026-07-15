import Testing
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKit
@testable import WebInspectorUINetwork

@MainActor
private final class NetworkPanelFixture {
    let runtime: WebInspectorDataKitTestRuntime

    var context: WebInspectorModelContext { runtime.container.mainContext }

    init(
        requests: [WebInspectorDataKitTestRuntime.NetworkRequest] = []
    ) async throws {
        runtime = try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(enabledFeatures: [.network]),
                networkReplay: requests
            )
        )
    }

    func request(url: String) async throws -> NetworkRequest {
        let models = try await context.fetch(
            WebInspectorFetchDescriptor<NetworkRequest>()
        )
        return try #require(models.first(where: { $0.url == url }))
    }

    func entry(containing requestID: NetworkRequest.ID) async throws
        -> NetworkEntry
    {
        let entries = try await context.fetch(
            WebInspectorFetchDescriptor<NetworkEntry>()
        )
        return try #require(entries.first(where: {
            $0.requestIDs.contains(requestID)
        }))
    }

    func close() async {
        await runtime.close()
    }
}

@Suite
struct NetworkPanelModelTests {
    @MainActor
    @Test
    func filtersAndSortsCanonicalEntriesThroughGenericDescriptor() async throws {
        let fixture = try await NetworkPanelFixture(requests: [
            .init(
                id: "document",
                url: "https://example.test/index.html",
                resourceType: .document
            ),
            .init(
                id: "script",
                url: "https://cdn.example.test/app.js",
                resourceType: .script
            ),
            .init(
                id: "image",
                url: "https://cdn.example.test/photo.png",
                mimeType: "image/png",
                resourceType: .image
            ),
        ])
        let document = try await fixture.request(
            url: "https://example.test/index.html"
        )
        let script = try await fixture.request(
            url: "https://cdn.example.test/app.js"
        )
        let image = try await fixture.request(
            url: "https://cdn.example.test/photo.png"
        )
        let documentEntry = try await fixture.entry(containing: document.id)
        let scriptEntry = try await fixture.entry(containing: script.id)
        let imageEntry = try await fixture.entry(containing: image.id)
        let model = try await NetworkPanelModel.make(context: fixture.context)

        #expect(
            model.entries.snapshot?.itemIDs == [
                imageEntry.id,
                scriptEntry.id,
                documentEntry.id,
            ]
        )

        let initialRevision = try #require(model.entries.revision)
        model.setSearchText("cdn")
        model.setResourceFilter(.script, enabled: true)
        await model.waitForQueryUpdates()

        #expect(model.entries.snapshot?.itemIDs == [scriptEntry.id])
        #expect(model.entries.revision?.rawValue == initialRevision.rawValue + 1)
        #expect(model.queryError == nil)
        await model.retire()
        await fixture.close()
    }

    @MainActor
    @Test
    func groupedSelectionResolvesEveryRequestThroughTheSameContext() async throws {
        let fixture = try await NetworkPanelFixture(requests: [
            .init(
                id: "playlist",
                url: "https://media.example.test/master.m3u8",
                mimeType: "application/vnd.apple.mpegurl",
                resourceType: .media,
                initiatorNodeID: "101"
            ),
            .init(
                id: "segment",
                url: "https://media.example.test/segment.m4s",
                mimeType: "video/mp4",
                resourceType: .media,
                initiatorNodeID: "101"
            ),
        ])
        let playlist = try await fixture.request(
            url: "https://media.example.test/master.m3u8"
        )
        let segment = try await fixture.request(
            url: "https://media.example.test/segment.m4s"
        )
        let entry = try await fixture.entry(containing: playlist.id)
        #expect(entry.requestIDs.contains(segment.id))
        let model = try await NetworkPanelModel.make(context: fixture.context)

        model.selectEntry(entry.id)

        #expect(model.selectedEntryID == entry.id)
        #expect(model.selectedRequests.map(\.id) == [playlist.id, segment.id])
        #expect(model.selectedRequests.allSatisfy { request in
            fixture.context.model(for: request.id) === request
        })
        await model.retire()
        await fixture.close()
    }

    @MainActor
    @Test
    func filteringOutSelectionReturnsToListAndClearDeletesCanonicalEntries() async throws {
        let fixture = try await NetworkPanelFixture(requests: [
            .init(
                id: "script",
                url: "https://cdn.example.test/app.js",
                resourceType: .script
            )
        ])
        let request = try await fixture.request(
            url: "https://cdn.example.test/app.js"
        )
        let entry = try await fixture.entry(containing: request.id)
        let model = try await NetworkPanelModel.make(context: fixture.context)
        let allEntries = WebInspectorFetchedResultsController<NetworkEntry>(
            modelContext: fixture.context
        )
        try await allEntries.performFetch()
        var allEntryUpdates = allEntries.updates.makeAsyncIterator()
        _ = await allEntryUpdates.next()
        model.selectEntry(entry.id)
        model.setSearchText("does-not-match")
        await model.waitForQueryUpdates()

        #expect(model.entries.snapshot?.itemIDs.isEmpty == true)
        #expect(model.selectedEntryID == nil)
        #expect(model.selectedRequests.isEmpty)

        model.clearRequests()
        _ = await allEntryUpdates.next()

        #expect(allEntries.snapshot?.itemIDs.isEmpty == true)
        #expect(model.selectedEntryID == nil)
        #expect(model.selectedRequests.isEmpty)
        await allEntries.close()
        await model.retire()
        await fixture.close()
    }

    @MainActor
    @Test
    func retireClosesTheEntryFetchedResultsController() async throws {
        let fixture = try await NetworkPanelFixture()
        let model = try await NetworkPanelModel.make(context: fixture.context)

        await model.retire()

        #expect(model.isRetiredForTesting)
        #expect(model.entries.fetchError as? WebInspectorFetchError == .contextClosed)
        await fixture.close()
    }

    @MainActor
    @Test
    func deinitBackstopClosesTheEntryFetchedResultsController() async throws {
        let fixture = try await NetworkPanelFixture()
        var model: NetworkPanelModel? = try await NetworkPanelModel.make(
            context: fixture.context
        )
        let entries = try #require(model?.entries)

        model = nil

        #expect(model == nil)
        #expect(entries.fetchError as? WebInspectorFetchError == .contextClosed)
        await fixture.close()
    }
}
