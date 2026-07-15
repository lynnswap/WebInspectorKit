import Foundation
import Observation
import SwiftUI
import Testing
@testable import WebInspectorDataKit
@testable import WebInspectorSwiftUI

#if canImport(UIKit)
    import UIKit
#endif

@Observable
private final class QueryTestModel: WebInspectorPersistentModel {
    struct ID: WebInspectorPersistentIdentifier {
        typealias Model = QueryTestModel

        let rawValue: Int
    }

    struct QueryValue: Identifiable, Sendable {
        let id: ID
        let score: Int
    }

    let id: ID
    private(set) var score: Int

    init(id: ID, score: Int) {
        self.id = id
        self.score = score
    }

    func replace(score: Int) {
        self.score = score
    }
}

private struct QueryTestRecord: Sendable {
    let score: Int
}

private let queryTestSchema = WebInspectorModelSchema<
    QueryTestModel,
    QueryTestRecord
>(
    featureID: .network,
    makeModel: { _, id, record in
        QueryTestModel(id: id, score: record.score)
    },
    updateModel: { _, model, record in
        model.replace(score: record.score)
    },
    invalidateModel: { _, _ in }
)

@MainActor
@Suite
struct WebInspectorQueryTests {
    @Test
    func unboundStorageStartsEmpty() {
        let storage = WebInspectorQueryStorage<QueryTestModel>()

        #expect(storage.fetchedObjects.isEmpty)
        #expect(storage.fetchError == nil)
        #expect(storage.modelContext == nil)
    }

    @Test
    func missingEnvironmentReportsErrorAndLaterBindingRecovers() async throws {
        let storage = WebInspectorQueryStorage<QueryTestModel>()
        let descriptor = WebInspectorFetchDescriptor<QueryTestModel>()

        storage.submit(
            container: nil,
            descriptor: descriptor,
            semanticIdentity: .fixed
        )

        #expect(
            storage.fetchError as? WebInspectorQueryError
                == .missingModelContext
        )
        #expect(storage.fetchedObjects.isEmpty)

        let container = try await makeContainer([(id: 1, score: 10)])
        storage.submit(
            container: container,
            descriptor: descriptor,
            semanticIdentity: .fixed
        )

        let didBind = await waitUntil {
            storage.fetchError == nil
                && storage.fetchedObjects.map(\.id.rawValue) == [1]
        }
        #expect(didBind)
        #expect(storage.modelContext === container.mainContext)

        await container.close()
    }

    @Test
    func failedDynamicRefetchRetainsLastSuccessfulObjects() async throws {
        let container = try await makeContainer([
            (id: 1, score: 10),
            (id: 2, score: 20),
        ])
        let storage = WebInspectorQueryStorage<QueryTestModel>()
        let descriptor = WebInspectorFetchDescriptor<QueryTestModel>(
            sortBy: [SortDescriptor(\.score)]
        )

        storage.submit(
            container: container,
            descriptor: descriptor,
            semanticIdentity: dynamicIdentity(0)
        )
        let didFetch = await waitUntil {
            storage.fetchedObjects.map(\.score) == [10, 20]
        }
        #expect(didFetch)

        let controller = try #require(storage.fetchedResultsController)
        let acceptedRevision = try #require(controller.revision)
        var invalidDescriptor = descriptor
        invalidDescriptor.fetchLimit = -1

        storage.submit(
            container: container,
            descriptor: invalidDescriptor,
            semanticIdentity: dynamicIdentity(1)
        )
        let didFail = await waitUntil {
            storage.fetchError as? WebInspectorFetchError == .invalidLimit(-1)
        }
        #expect(didFail)
        #expect(storage.fetchedResultsController === controller)
        #expect(storage.fetchedObjects.map(\.score) == [10, 20])
        #expect(controller.revision == acceptedRevision)

        var limitedDescriptor = descriptor
        limitedDescriptor.fetchLimit = 1
        storage.submit(
            container: container,
            descriptor: limitedDescriptor,
            semanticIdentity: dynamicIdentity(2)
        )
        let didRecover = await waitUntil {
            storage.fetchError == nil
                && storage.fetchedObjects.map(\.score) == [10]
        }
        #expect(didRecover)
        #expect(controller.revision?.rawValue == acceptedRevision.rawValue + 1)

        await container.close()
    }

    @Test
    func repeatedStableSubmissionsDoNotRefetchOrPublish() async throws {
        let container = try await makeContainer([(id: 1, score: 10)])
        let storage = WebInspectorQueryStorage<QueryTestModel>()
        let descriptor = WebInspectorFetchDescriptor<QueryTestModel>()

        storage.submit(
            container: container,
            descriptor: descriptor,
            semanticIdentity: .fixed
        )
        let didFetch = await waitUntil {
            storage.fetchedObjects.map(\.id.rawValue) == [1]
        }
        #expect(didFetch)

        let controller = try #require(storage.fetchedResultsController)
        let acceptedRevision = try #require(controller.revision)
        for _ in 0..<100 {
            storage.submit(
                container: container,
                descriptor: descriptor,
                semanticIdentity: .fixed
            )
        }
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(storage.fetchedResultsController === controller)
        #expect(controller.revision == acceptedRevision)
        #expect(storage.fetchedObjects.map(\.id.rawValue) == [1])

        await container.close()
    }

    #if canImport(UIKit)
        @Test
        func hostedQueryRebindsWhenEnvironmentContainerChanges() async throws {
            let firstContainer = try await makeContainer([(id: 1, score: 10)])
            let secondContainer = try await makeContainer([(id: 2, score: 20)])
            let recorder = QueryHostRecorder()
            let host = UIHostingController(
                rootView: QueryHostProbe(recorder: recorder)
                    .webInspectorModelContainer(firstContainer)
            )

            host.loadViewIfNeeded()
            host.view.layoutIfNeeded()

            let firstContextID = ObjectIdentifier(firstContainer.mainContext)
            let didBindFirst = await waitUntil {
                recorder.observation
                    == QueryHostObservation(
                        itemIDs: [1],
                        contextID: firstContextID,
                        errorDescription: nil
                    )
            }
            #expect(didBindFirst)

            host.rootView = QueryHostProbe(recorder: recorder)
                .webInspectorModelContainer(secondContainer)
            host.view.layoutIfNeeded()

            let secondContextID = ObjectIdentifier(secondContainer.mainContext)
            let didRebind = await waitUntil {
                recorder.observation
                    == QueryHostObservation(
                        itemIDs: [2],
                        contextID: secondContextID,
                        errorDescription: nil
                    )
            }
            #expect(didRebind)
            #expect(firstContextID != secondContextID)

            await firstContainer.close()
            await secondContainer.close()
        }
    #endif
}

@MainActor
private func makeContainer(
    _ values: [(id: Int, score: Int)]
) async throws -> WebInspectorModelContainer {
    let registry = try WebInspectorModelSchemaRegistry([
        queryTestSchema.erased
    ])
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.network]),
        schemaRegistry: registry
    )
    var transaction = WebInspectorModelTransaction()
    for (rank, value) in values.enumerated() {
        transaction.append(
            queryTestSchema.upsert(
                record: QueryTestRecord(score: value.score),
                queryValue: .init(
                    id: .init(rawValue: value.id),
                    score: value.score
                ),
                canonicalRank: .init(rawValue: UInt64(rank))
            )
        )
    }
    transaction.setFeatureState(
        .ready(
            generation: .init(rawValue: 1),
            revision: .init(rawValue: 0)
        ),
        for: .network
    )
    _ = try await container.modelStoreSink.commit(transaction)
    return container
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
private func dynamicIdentity(_ value: Int)
    -> WebInspectorQuerySemanticIdentity
{
    .dynamic(
        type: ObjectIdentifier(Int.self),
        value: AnyHashable(value)
    )
}

#if canImport(UIKit)
    private struct QueryHostObservation: Equatable {
        let itemIDs: [Int]
        let contextID: ObjectIdentifier?
        let errorDescription: String?
    }

    @MainActor
    @Observable
    private final class QueryHostRecorder {
        private(set) var observation: QueryHostObservation?

        func record(_ observation: QueryHostObservation) {
            self.observation = observation
        }
    }

    private struct QueryHostProbe: View {
        @WebInspectorQuery<QueryTestModel>(sort: [SortDescriptor(\.score)])
        private var models

        let recorder: QueryHostRecorder

        var body: some View {
            let observation = QueryHostObservation(
                itemIDs: models.map(\.id.rawValue),
                contextID: _models.modelContext.map(ObjectIdentifier.init),
                errorDescription: _models.fetchError.map(String.init(describing:))
            )
            Color.clear
                .onAppear {
                    recorder.record(observation)
                }
                .onChange(of: observation, initial: true) { _, newValue in
                    recorder.record(newValue)
                }
        }
    }
#endif
