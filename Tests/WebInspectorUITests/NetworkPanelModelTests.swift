import Testing
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKit
@testable import WebInspectorUINetwork

@MainActor
private final class NetworkPanelFixture {
    let runtime: WebInspectorDataKitTestRuntime

    var context: WebInspectorModelContext { runtime.model }

    init(
        requests: [WebInspectorDataKitTestRuntime.NetworkRequest] = []
    ) async throws {
        runtime = try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(domains: [.network]),
                networkReplay: requests
            ),
            isolation: MainActor.shared
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
            model.entries.snapshot.itemIDs == [
                imageEntry.id,
                scriptEntry.id,
                documentEntry.id,
            ]
        )

        model.setSearchText("cdn")
        model.setResourceFilter(.script, enabled: true)
        await model.waitForQueryUpdates()

        #expect(model.entries.snapshot.itemIDs == [scriptEntry.id])
        #expect(model.appliedQueryRevision == model.queryRevision)
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
    func filteredEntriesDoNotDisableClearOrInvalidateSelection() async throws {
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
        model.selectEntry(entry.id)
        model.setSearchText("does-not-match")
        await model.waitForQueryUpdates()

        #expect(model.entries.snapshot.itemIDs.isEmpty)
        #expect(model.hasClearableRequests)
        #expect(model.selectedEntryID == entry.id)
        #expect(model.selectedRequests.map(\.id) == [request.id])

        try await fixture.context.clearNetworkRequests()

        #expect(model.hasClearableRequests == false)
        #expect(model.selectedEntryID == nil)
        #expect(model.selectedRequests.isEmpty)
        await model.retire()
        await fixture.close()
    }

    @MainActor
    @Test
    func retireClosesBothFetchedResultsControllers() async throws {
        let fixture = try await NetworkPanelFixture()
        let model = try await NetworkPanelModel.make(context: fixture.context)
        #expect(fixture.context.fetchedResultsControllerOwnerCountForTesting == 2)

        await model.retire()

        #expect(fixture.context.fetchedResultsControllerOwnerCountForTesting == 0)
        await fixture.close()
    }

    @MainActor
    @Test
    func deinitBackstopRemovesBothFetchedResultsOwners() async throws {
        let fixture = try await NetworkPanelFixture()
        var model: NetworkPanelModel? = try await NetworkPanelModel.make(
            context: fixture.context
        )
        #expect(fixture.context.fetchedResultsControllerOwnerCountForTesting == 2)

        model = nil

        #expect(model == nil)
        #expect(fixture.context.fetchedResultsControllerOwnerCountForTesting == 0)
        await fixture.close()
    }
}
