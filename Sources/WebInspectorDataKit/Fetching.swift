import Foundation
import Observation
import WebInspectorProxyKit

final class WeakWebInspectorFetchedResults<Model: WebInspectorPersistentModel> {
    weak var value: WebInspectorFetchedResults<Model>?

    init(_ value: WebInspectorFetchedResults<Model>) {
        self.value = value
    }
}

private struct NetworkUnfilteredFetchedResultsProjection {
    var generation: NetworkRequestStore.ProjectionGeneration
}

private struct NetworkIndexedFetchedResultsProjection {
    var plan: NetworkRequestQueryPlan
    var snapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>
}

private enum NetworkFetchedResultsProjection {
    case unfiltered(NetworkUnfilteredFetchedResultsProjection)
    case indexed(NetworkIndexedFetchedResultsProjection)
}

/// Stable identity for a fetched-results section.
public struct WebInspectorFetchSectionID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral
{
    /// The raw section identity.
    public var rawValue: String

    /// Creates a section identity from a raw value.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a section identity from a string literal.
    public init(stringLiteral value: String) {
        rawValue = value
    }

    /// The display representation of the section identity.
    public var description: String {
        rawValue
    }

    /// The section identity used when results are not sectioned.
    public static let defaultSection = WebInspectorFetchSectionID(rawValue: "__default")
}

/// One fetched-results section and its models.
public struct WebInspectorFetchSection<Model: WebInspectorPersistentModel>: Identifiable {
    /// The stable section identity.
    public var id: WebInspectorFetchSectionID

    /// The display title for the section.
    public var title: String?

    /// The models in the section.
    public var items: [Model]

    /// Creates a fetched-results section.
    public init(id: WebInspectorFetchSectionID, title: String?, items: [Model]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

/// Observable collection of models produced by a query.
///
/// The collection can outlive its registration in a
/// ``WebInspectorContext``. See <doc:ModelRegistrationLifetimes>.
@Observable
public final class WebInspectorFetchedResults<Model: WebInspectorPersistentModel> {
    private var queryStorage: WebInspectorQueryStorage

    /// The fetched models in display order.
    public private(set) var items: [Model]

    /// The fetched models grouped into display sections.
    public private(set) var sections: [WebInspectorFetchSection<Model>]
    package private(set) var topologyRevision: Int

    @ObservationIgnored private let transactionRelay = WebInspectorAsyncStreamRelay<
        WebInspectorFetchedResultsTransaction<Model>
    >()
    @ObservationIgnored weak var modelContext: WebInspectorContext?
    @ObservationIgnored private var networkProjection: NetworkFetchedResultsProjection?
#if DEBUG
    @ObservationIgnored package private(set) var networkFullMembershipVisitCountForTesting = 0
#endif

    private init(
        queryStorage: WebInspectorQueryStorage,
        items: [Model] = [],
        modelContext: WebInspectorContext? = nil
    ) {
        self.queryStorage = queryStorage
        self.items = items
        sections = Self.sections(for: items, queryStorage: queryStorage)
        self.modelContext = modelContext
        topologyRevision = 0
        networkProjection = nil
    }

    deinit {
        transactionRelay.finish()
    }

    func makeTransactionStream() -> AsyncStream<WebInspectorFetchedResultsTransaction<Model>> {
        transactionRelay.makeStream()
    }

    func invalidateRegistration() {
        modelContext = nil
        transactionRelay.finish()
    }

    func setItems(_ items: [Model], updatedItemIDs: Set<Model.ID> = []) {
        let oldSnapshot = currentSnapshot
        self.items = items
        sections = Self.sections(for: items, queryStorage: queryStorage)
        bumpTopologyRevisionIfNeeded(oldSnapshot: oldSnapshot)
        yieldTransaction(oldSnapshot: oldSnapshot, updatedItemIDs: updatedItemIDs)
    }

    func insertItem(_ item: Model) {
        precondition(items.contains { $0.id == item.id } == false, "WebInspectorFetchedResults cannot insert a duplicate item ID.")
        let oldSnapshot = currentSnapshot
        items.append(item)
        sections = Self.sections(for: items, queryStorage: queryStorage)
        bumpTopologyRevisionIfNeeded(oldSnapshot: oldSnapshot)
        yieldTransaction(oldSnapshot: oldSnapshot, updatedItemIDs: [])
    }

    func refreshAfterItemMutation(_ item: Model) {
        guard items.contains(where: { $0.id == item.id }) else {
            return
        }
        let oldSnapshot = currentSnapshot
        if queryStorage.isSectioned {
            sections = Self.sections(for: items, queryStorage: queryStorage)
        }
        bumpTopologyRevisionIfNeeded(oldSnapshot: oldSnapshot)
        yieldTransaction(oldSnapshot: oldSnapshot, updatedItemIDs: [item.id])
    }

    func resetItems(_ items: [Model]) {
        let oldSnapshot = currentSnapshot
        self.items = items
        sections = Self.sections(for: items, queryStorage: queryStorage)
        bumpTopologyRevision()
        yieldResetTransaction(oldSnapshot: oldSnapshot)
    }

    private var currentSnapshot: WebInspectorFetchedResultsSnapshot<Model.ID> {
        WebInspectorFetchedResultsSnapshot(sections: sections)
    }

    private func bumpTopologyRevisionIfNeeded(oldSnapshot: WebInspectorFetchedResultsSnapshot<Model.ID>) {
        guard oldSnapshot != currentSnapshot else {
            return
        }
        bumpTopologyRevision()
    }

    private func bumpTopologyRevision() {
        topologyRevision &+= 1
    }

    private func yieldTransaction(
        oldSnapshot: WebInspectorFetchedResultsSnapshot<Model.ID>,
        updatedItemIDs: Set<Model.ID>
    ) {
        guard transactionRelay.hasContinuations else {
            return
        }
        let transaction = WebInspectorFetchedResultsTransaction<Model>(
            oldSnapshot: oldSnapshot,
            newSnapshot: currentSnapshot,
            updatedItemIDs: updatedItemIDs
        )
        guard transaction.hasChanges else {
            return
        }
        transactionRelay.yield(transaction)
    }

    private func yieldResetTransaction(
        oldSnapshot: WebInspectorFetchedResultsSnapshot<Model.ID>
    ) {
        guard transactionRelay.hasContinuations else {
            return
        }
        let transaction = WebInspectorFetchedResultsTransaction<Model>(
            oldSnapshot: oldSnapshot,
            newSnapshot: currentSnapshot,
            isReset: true,
            itemChanges: []
        )
        transactionRelay.yield(transaction)
    }

    private static func sections(
        for items: [Model],
        queryStorage: WebInspectorQueryStorage
    ) -> [WebInspectorFetchSection<Model>] {
        guard items.isEmpty == false else {
            return []
        }
        guard queryStorage.isSectioned else {
            return [
                WebInspectorFetchSection(
                    id: .defaultSection,
                    title: nil,
                    items: items
                )
            ]
        }

        var sections: [(id: WebInspectorFetchSectionID, title: String?, items: [Model])] = []
        for item in items {
            let section = sectionIdentity(for: item, queryStorage: queryStorage)
            if let index = sections.firstIndex(where: { $0.id == section.id }) {
                sections[index].items.append(item)
            } else {
                sections.append((id: section.id, title: section.title, items: [item]))
            }
        }
        return sections.map {
            WebInspectorFetchSection(id: $0.id, title: $0.title, items: $0.items)
        }
    }

    private static func sectionIdentity(
        for item: Model,
        queryStorage: WebInspectorQueryStorage
    ) -> (id: WebInspectorFetchSectionID, title: String?) {
        let value: String?
        switch queryStorage {
        case let .network(query):
            guard let request = item as? NetworkRequest,
                  let section = query.sectionBy else {
                preconditionFailure("Network query storage must section NetworkRequest models.")
            }
            switch section.storage {
            case .method: value = request.method
            case .resourceType: value = request.resourceType?.rawValue
            case .resourceCategory: value = request.resourceCategory.rawValue
            case .mimeType: value = request.mimeType
            }
        case let .console(query):
            guard let message = item as? ConsoleMessage,
                  let section = query.sectionBy else {
                preconditionFailure("Console query storage must section ConsoleMessage models.")
            }
            switch section.storage {
            case .source: value = message.source.rawValue
            case .level: value = message.level.rawValue
            case .kind: value = message.kind?.rawValue
            case .url: value = message.url
            }
        }

        let title = value ?? ""
        return (WebInspectorFetchSectionID(rawValue: title), title)
    }
}

public extension WebInspectorFetchedResults where Model == NetworkRequest {
    /// The last query installed for these Network request results.
    ///
    /// The value remains readable after registration in the originating
    /// context ends.
    var query: NetworkRequestQuery {
        networkQuery
    }

    /// Replaces the query and updates the result contents atomically.
    ///
    /// - Throws: `WebInspectorProxyError.disconnected` when these results are
    ///   no longer registered in their originating context.
    func updateQuery(
        _ query: NetworkRequestQuery,
        isolation: isolated (any Actor) = #isolation
    ) throws {
        guard let modelContext else {
            throw WebInspectorProxyError.disconnected(
                "WebInspectorFetchedResults is not registered in this WebInspectorContext."
            )
        }
        try modelContext.updateNetworkQuery(query, for: self, isolation: isolation)
    }
}

public extension WebInspectorFetchedResults where Model == ConsoleMessage {
    /// The last query installed for these Console message results.
    ///
    /// The value remains readable after registration in the originating
    /// context ends.
    var query: ConsoleMessageQuery {
        consoleQuery
    }

    /// Replaces the query and updates the result contents atomically.
    ///
    /// - Throws: `WebInspectorProxyError.disconnected` when these results are
    ///   no longer registered in their originating context.
    func updateQuery(
        _ query: ConsoleMessageQuery,
        isolation: isolated (any Actor) = #isolation
    ) throws {
        guard let modelContext else {
            throw WebInspectorProxyError.disconnected(
                "WebInspectorFetchedResults is not registered in this WebInspectorContext."
            )
        }
        try modelContext.updateConsoleQuery(query, for: self, isolation: isolation)
    }
}

extension WebInspectorFetchedResults where Model == NetworkRequest {
    convenience init(
        query: NetworkRequestQuery,
        items: [NetworkRequest] = [],
        generation: NetworkRequestStore.ProjectionGeneration,
        modelContext: WebInspectorContext? = nil
    ) {
        self.init(queryStorage: .network(query), items: items, modelContext: modelContext)
        let plan = NetworkRequestQueryPlan(query: query)
        if Self.usesUnfilteredProjection(query: query, plan: plan) {
            networkProjection = .unfiltered(NetworkUnfilteredFetchedResultsProjection(
                generation: generation
            ))
        } else {
            networkProjection = .indexed(NetworkIndexedFetchedResultsProjection(
                plan: plan,
                snapshot: WebInspectorFetchedResultsSnapshot(sections: sections)
            ))
        }
    }

    var networkQuery: NetworkRequestQuery {
        guard case let .network(query) = queryStorage else {
            preconditionFailure("NetworkRequest results must own a NetworkRequestQuery.")
        }
        return query
    }

    var networkSnapshotForDelta: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID> {
        switch requiredNetworkProjection {
        case let .unfiltered(projection):
            return projection.generation.ledger.snapshot(at: items.count)
        case let .indexed(projection):
            return projection.snapshot
        }
    }

    func currentNetworkQueryPlan() -> NetworkRequestQueryPlan {
        switch requiredNetworkProjection {
        case .unfiltered:
            return NetworkRequestQueryPlan(query: networkQuery)
        case let .indexed(projection):
            return projection.plan
        }
    }

    var usesUnfilteredNetworkProjection: Bool {
        guard case .unfiltered = requiredNetworkProjection else {
            return false
        }
        return true
    }

    func setNetworkItems(
        _ requests: [NetworkRequest],
        plan: NetworkRequestQueryPlan,
        generation: NetworkRequestStore.ProjectionGeneration
    ) {
        if Self.usesUnfilteredProjection(query: networkQuery, plan: plan) {
            networkProjection = .unfiltered(NetworkUnfilteredFetchedResultsProjection(
                generation: generation
            ))
            setItems(requests)
        } else {
            let projected = Self.projectedRequests(requests, plan: plan)
            setItems(projected)
            networkProjection = .indexed(NetworkIndexedFetchedResultsProjection(
                plan: plan,
                snapshot: WebInspectorFetchedResultsSnapshot(sections: sections)
            ))
        }
    }

    func applyNetworkQuery(
        _ query: NetworkRequestQuery,
        plan: NetworkRequestQueryPlan,
        requests: [NetworkRequest],
        generation: NetworkRequestStore.ProjectionGeneration
    ) {
        queryStorage = .network(query)
        if Self.usesUnfilteredProjection(query: query, plan: plan) {
            networkProjection = .unfiltered(NetworkUnfilteredFetchedResultsProjection(
                generation: generation
            ))
            resetItems(requests)
        } else {
            let projected = Self.projectedRequests(requests, plan: plan)
            resetItems(projected)
            networkProjection = .indexed(NetworkIndexedFetchedResultsProjection(
                plan: plan,
                snapshot: WebInspectorFetchedResultsSnapshot(sections: sections)
            ))
        }
    }

    func resetNetworkItems(to generation: NetworkRequestStore.ProjectionGeneration) {
        let plan = currentNetworkQueryPlan()
        resetItems([])
        if Self.usesUnfilteredProjection(query: networkQuery, plan: plan) {
            networkProjection = .unfiltered(NetworkUnfilteredFetchedResultsProjection(
                generation: generation
            ))
        } else {
            networkProjection = .indexed(NetworkIndexedFetchedResultsProjection(
                plan: plan,
                snapshot: WebInspectorFetchedResultsSnapshot()
            ))
        }
    }

    func applySynchronousIndexedNetworkChange(
        _ change: NetworkRequestStore.Change,
        allRequests: [NetworkRequest]
    ) {
        guard case var .indexed(projection) = requiredNetworkProjection else {
            preconditionFailure("A synchronous indexed change requires indexed projection state.")
        }
        let projected = Self.projectedRequests(allRequests, plan: projection.plan)
        let updatedItemIDs: Set<NetworkRequest.ID> = change.publishesContentUpdate
            ? [change.registration.request.id]
            : []
        setItems(projected, updatedItemIDs: updatedItemIDs)
        projection.snapshot = WebInspectorFetchedResultsSnapshot(sections: sections)
        networkProjection = .indexed(projection)
    }

    func resetSynchronousIndexedNetworkItems(_ allRequests: [NetworkRequest]) {
        guard case var .indexed(projection) = requiredNetworkProjection else {
            preconditionFailure("A synchronous indexed reset requires indexed projection state.")
        }
        let projected = Self.projectedRequests(allRequests, plan: projection.plan)
        resetItems(projected)
        projection.snapshot = WebInspectorFetchedResultsSnapshot(sections: sections)
        networkProjection = .indexed(projection)
    }

    func applyUnfilteredNetworkChange(_ change: NetworkRequestStore.Change) {
        guard case let .unfiltered(projection) = requiredNetworkProjection else {
            preconditionFailure("An unfiltered Network change requires unfiltered projection state.")
        }
        let registration = change.registration
        precondition(
            change.projectionGeneration.id == projection.generation.id,
            "An unfiltered Network change must belong to the current store generation."
        )
        if change.isInsertion {
            applyUnfilteredNetworkInsert(registration, projection: projection)
        } else {
            applyUnfilteredNetworkUpdate(registration, projection: projection)
        }
    }

    func applyNetworkDelta(
        _ delta: NetworkResultSetDelta,
        lookup: (NetworkRequest.ID) -> NetworkRequest
    ) {
        guard case var .indexed(projection) = requiredNetworkProjection else {
            preconditionFailure("A Network result delta requires indexed projection state.")
        }
        let oldSnapshot = projection.snapshot
        if oldSnapshot != delta.snapshot {
#if DEBUG
            networkFullMembershipVisitCountForTesting &+= delta.snapshot.itemIDs.count
#endif
            items = delta.snapshot.itemIDs.map(lookup)
            sections = delta.snapshot.sections.map { section in
                WebInspectorFetchSection(
                    id: section.id,
                    title: section.title,
                    items: section.itemIDs.map(lookup)
                )
            }
            bumpTopologyRevision()
        }
        projection.snapshot = delta.snapshot
        networkProjection = .indexed(projection)
        guard transactionRelay.hasContinuations else {
            return
        }
        transactionRelay.yield(delta.transaction)
    }

    private func applyUnfilteredNetworkInsert(
        _ registration: NetworkRequestStore.Registration,
        projection: NetworkUnfilteredFetchedResultsProjection
    ) {
        let oldCount = items.count
        let newCount = oldCount + 1
        precondition(
            registration.orderIndex == oldCount,
            "An unfiltered Network insertion must advance the registered order by one."
        )
        precondition(
            projection.generation.ledger.itemID(
                at: registration.orderIndex,
                expectedCount: newCount
            ) == registration.request.id,
            "An unfiltered Network insertion must match the store ledger."
        )
        items.append(registration.request)
        if oldCount == 0 {
            sections = [
                WebInspectorFetchSection(
                    id: .defaultSection,
                    title: nil,
                    items: [registration.request]
                ),
            ]
        } else {
            sections[0].items.append(registration.request)
        }
        bumpTopologyRevision()
        guard transactionRelay.hasContinuations else {
            return
        }
        let sectionChanges: [WebInspectorFetchedResultsSectionChange] = oldCount == 0
            ? [.insert(sectionID: .defaultSection, index: 0)]
            : []
        transactionRelay.yield(WebInspectorFetchedResultsTransaction<NetworkRequest>(
            singleSectionLedger: projection.generation.ledger,
            oldCount: oldCount,
            newCount: newCount,
            sectionChanges: sectionChanges,
            itemChanges: [
                .insert(
                    itemID: registration.request.id,
                    indexPath: WebInspectorFetchedResultsIndexPath(
                        section: 0,
                        item: oldCount
                    )
                ),
            ]
        ))
    }

    private func applyUnfilteredNetworkUpdate(
        _ registration: NetworkRequestStore.Registration,
        projection: NetworkUnfilteredFetchedResultsProjection
    ) {
        precondition(
            items.indices.contains(registration.orderIndex)
                && items[registration.orderIndex] === registration.request,
            "An unfiltered Network update must preserve its registered position."
        )
        let itemCount = items.count
        precondition(
            projection.generation.ledger.itemID(
                at: registration.orderIndex,
                expectedCount: itemCount
            ) == registration.request.id,
            "An unfiltered Network update must match the store ledger."
        )
        guard transactionRelay.hasContinuations else {
            return
        }
        transactionRelay.yield(WebInspectorFetchedResultsTransaction<NetworkRequest>(
            singleSectionLedger: projection.generation.ledger,
            oldCount: itemCount,
            newCount: itemCount,
            itemChanges: [
                .update(
                    itemID: registration.request.id,
                    indexPath: WebInspectorFetchedResultsIndexPath(
                        section: 0,
                        item: registration.orderIndex
                    )
                ),
            ]
        ))
    }

    private var requiredNetworkProjection: NetworkFetchedResultsProjection {
        guard let networkProjection else {
            preconditionFailure("NetworkRequest results must own Network projection state.")
        }
        return networkProjection
    }

    private static func usesUnfilteredProjection(
        query: NetworkRequestQuery,
        plan: NetworkRequestQueryPlan
    ) -> Bool {
        plan.requiresQuery == false && query.sectionBy == nil
    }

    private static func projectedRequests(
        _ requests: [NetworkRequest],
        plan: NetworkRequestQueryPlan
    ) -> [NetworkRequest] {
        let requestsByID = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
        let state = NetworkRequestQueryState(plan: plan, requests: requests)
        return state.visibleRequests { id in
            guard let request = requestsByID[id] else {
                preconditionFailure("A projected Network request must remain registered.")
            }
            return request
        }
    }
}

extension WebInspectorFetchedResults where Model == ConsoleMessage {
    convenience init(
        query: ConsoleMessageQuery,
        items: [ConsoleMessage] = [],
        modelContext: WebInspectorContext? = nil
    ) {
        self.init(queryStorage: .console(query), items: items, modelContext: modelContext)
    }

    var consoleQuery: ConsoleMessageQuery {
        guard case let .console(query) = queryStorage else {
            preconditionFailure("ConsoleMessage results must own a ConsoleMessageQuery.")
        }
        return query
    }

    func applyConsoleQuery(_ query: ConsoleMessageQuery, items: [ConsoleMessage]) {
        queryStorage = .console(query)
        resetItems(items)
    }
}
