import Foundation
import Observation
import WebInspectorProxyKit

final class WeakWebInspectorFetchedResults<Model: WebInspectorPersistentModel> {
    weak var value: WebInspectorFetchedResults<Model>?

    init(_ value: WebInspectorFetchedResults<Model>) {
        self.value = value
    }
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
    @ObservationIgnored private var networkQueryPlan: NetworkRequestQueryPlan?
    @ObservationIgnored private var networkQueryState: NetworkRequestQueryState?
    @ObservationIgnored private var networkResultSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>?
    @ObservationIgnored private var networkUnfilteredSnapshotLedger:
        WebInspectorFetchedResultsSingleSectionSnapshotLedger<NetworkRequest.ID>?
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
        networkQueryPlan = nil
        networkQueryState = nil
        networkResultSnapshot = nil
        networkUnfilteredSnapshotLedger = nil
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
        modelContext: WebInspectorContext? = nil
    ) {
        self.init(queryStorage: .network(query), items: items, modelContext: modelContext)
    }

    var networkQuery: NetworkRequestQuery {
        guard case let .network(query) = queryStorage else {
            preconditionFailure("NetworkRequest results must own a NetworkRequestQuery.")
        }
        return query
    }

    var networkSnapshotForDelta: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID> {
        if let networkUnfilteredSnapshotLedger {
            return networkUnfilteredSnapshotLedger.snapshot(at: items.count)
        }
        if let networkResultSnapshot {
            return networkResultSnapshot
        }
        let snapshot = WebInspectorFetchedResultsSnapshot(sections: sections)
        networkResultSnapshot = snapshot
        return snapshot
    }

    func currentNetworkQueryPlan() -> NetworkRequestQueryPlan {
        if let networkQueryPlan {
            return networkQueryPlan
        }
        let plan = NetworkRequestQueryPlan(query: networkQuery)
        networkQueryPlan = plan
        return plan
    }

    func setNetworkItems(
        _ requests: [NetworkRequest],
        plan: NetworkRequestQueryPlan,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) {
        networkQueryPlan = plan
        if plan.requiresQuery {
            let state = NetworkRequestQueryState(plan: plan, requests: requests)
            networkQueryState = state
            setItems(state.visibleRequests(lookup: lookup))
        } else {
            networkQueryState = nil
            setItems(requests)
        }
        configureNetworkSnapshotStorage(plan: plan)
    }

    func applyNetworkQuery(
        _ query: NetworkRequestQuery,
        plan: NetworkRequestQueryPlan,
        requests: [NetworkRequest],
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) {
        queryStorage = .network(query)
        networkQueryPlan = plan
        if plan.requiresQuery {
            let state = NetworkRequestQueryState(plan: plan, requests: requests)
            networkQueryState = state
            resetItems(state.visibleRequests(lookup: lookup))
        } else {
            networkQueryState = nil
            resetItems(requests)
        }
        configureNetworkSnapshotStorage(plan: plan)
    }

    func resetNetworkItems() {
        if let state = networkQueryState {
            networkQueryState = NetworkRequestQueryState(plan: state.plan, requests: [])
        }
        resetItems([])
        if networkQueryPlan?.requiresQuery == false, networkQuery.sectionBy == nil {
            networkUnfilteredSnapshotLedger = WebInspectorFetchedResultsSingleSectionSnapshotLedger(
                itemIDs: []
            )
            networkResultSnapshot = nil
        } else {
            networkUnfilteredSnapshotLedger = nil
            networkResultSnapshot = WebInspectorFetchedResultsSnapshot()
        }
    }

    func insertNetworkRequest(
        _ request: NetworkRequest,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) {
        guard var state = networkQueryState else {
            if networkQuery.sectionBy == nil, networkQueryPlan?.requiresQuery == false {
                insertUnfilteredNetworkRequest(request)
            } else {
                insertItem(request)
                networkResultSnapshot = WebInspectorFetchedResultsSnapshot(sections: sections)
            }
            return
        }
        state.upsert(request: request)
        networkQueryState = state
        setItems(state.visibleRequests(lookup: lookup))
        networkResultSnapshot = WebInspectorFetchedResultsSnapshot(sections: sections)
    }

    func refreshNetworkRequestAfterMutation(
        _ request: NetworkRequest,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) {
#if DEBUG
        networkFullMembershipVisitCountForTesting += items.count
#endif
        guard var state = networkQueryState else {
            refreshAfterItemMutation(request)
            networkResultSnapshot = WebInspectorFetchedResultsSnapshot(sections: sections)
            return
        }
        state.upsert(request: request)
        networkQueryState = state
        setItems(state.visibleRequests(lookup: lookup), updatedItemIDs: [request.id])
        networkResultSnapshot = WebInspectorFetchedResultsSnapshot(sections: sections)
    }

    func applyUnfilteredNetworkRequestChange(
        _ request: NetworkRequest,
        at itemIndex: Int,
        publishesContentUpdate: Bool,
        requestAtIndex: (Int) -> NetworkRequest
    ) {
        precondition(
            networkQueryState == nil,
            "An unfiltered Network change cannot have query state."
        )
        precondition(
            networkQuery.sectionBy == nil,
            "An unfiltered Network change must not have a section query."
        )
        precondition(itemIndex >= 0, "An unfiltered Network change must have a valid item index.")

        while items.count <= itemIndex {
            let nextIndex = items.count
            let nextRequest = requestAtIndex(nextIndex)
            insertUnfilteredNetworkRequest(nextRequest)
        }
        precondition(
            items.indices.contains(itemIndex) && items[itemIndex] === request,
            "An unfiltered Network change must reference its registered item position."
        )
        guard publishesContentUpdate else {
            return
        }
        guard let networkUnfilteredSnapshotLedger else {
            preconditionFailure("An unfiltered Network change must have append-only snapshot storage.")
        }
        let itemCount = items.count
        precondition(
            networkUnfilteredSnapshotLedger.itemID(
                at: itemIndex,
                expectedCount: itemCount
            ) == request.id,
            "An unfiltered Network change must preserve its existing snapshot position."
        )
        guard transactionRelay.hasContinuations else {
            return
        }
        transactionRelay.yield(WebInspectorFetchedResultsTransaction<NetworkRequest>(
            singleSectionLedger: networkUnfilteredSnapshotLedger,
            oldCount: itemCount,
            newCount: itemCount,
            itemChanges: [
                .update(
                    itemID: request.id,
                    indexPath: WebInspectorFetchedResultsIndexPath(section: 0, item: itemIndex)
                ),
            ]
        ))
    }

    func applyNetworkDelta(
        _ delta: NetworkResultSetDelta,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) {
        let oldSnapshot = networkSnapshotForDelta
        if oldSnapshot != delta.snapshot {
#if DEBUG
            networkFullMembershipVisitCountForTesting &+= delta.snapshot.itemIDs.count
#endif
            items = delta.snapshot.itemIDs.compactMap(lookup)
            sections = delta.snapshot.sections.map { section in
                WebInspectorFetchSection(
                    id: section.id,
                    title: section.title,
                    items: section.itemIDs.compactMap(lookup)
                )
            }
            networkUnfilteredSnapshotLedger = nil
            networkResultSnapshot = delta.snapshot
            bumpTopologyRevision()
        }
        guard transactionRelay.hasContinuations else {
            return
        }
        transactionRelay.yield(delta.transaction)
    }

    func insertUnfilteredNetworkRequest(_ request: NetworkRequest) {
        precondition(networkQueryState == nil, "An unfiltered Network insert cannot have query state.")
        precondition(
            networkQueryPlan?.requiresQuery == false,
            "An unfiltered Network insert must not require query evaluation."
        )
        precondition(
            networkQuery.sectionBy == nil,
            "An unfiltered Network insert must not have a section query."
        )
        guard let networkUnfilteredSnapshotLedger else {
            preconditionFailure("An unfiltered Network insert must have append-only snapshot storage.")
        }

        let oldCount = items.count
        let newCount = networkUnfilteredSnapshotLedger.append(
            request.id,
            expectedCount: oldCount
        )
        precondition(newCount == oldCount + 1, "An unfiltered Network insert must append one item.")

        items.append(request)
        if oldCount == 0 {
            precondition(sections.isEmpty, "An empty unfiltered result cannot have sections.")
            sections = [
                WebInspectorFetchSection(
                    id: .defaultSection,
                    title: nil,
                    items: [request]
                ),
            ]
        } else {
            precondition(
                sections.count == 1
                    && sections[0].id == .defaultSection
                    && sections[0].items.count == oldCount,
                "An unfiltered Network result must preserve its single section."
            )
            sections[0].items.append(request)
        }
        networkResultSnapshot = nil
        bumpTopologyRevision()

        guard transactionRelay.hasContinuations else {
            return
        }
        let sectionChanges: [WebInspectorFetchedResultsSectionChange] = oldCount == 0
            ? [.insert(sectionID: .defaultSection, index: 0)]
            : []
        transactionRelay.yield(WebInspectorFetchedResultsTransaction<NetworkRequest>(
            singleSectionLedger: networkUnfilteredSnapshotLedger,
            oldCount: oldCount,
            newCount: newCount,
            sectionChanges: sectionChanges,
            itemChanges: [
                .insert(
                    itemID: request.id,
                    indexPath: WebInspectorFetchedResultsIndexPath(
                        section: 0,
                        item: oldCount
                    )
                ),
            ]
        ))
    }

    private func configureNetworkSnapshotStorage(plan: NetworkRequestQueryPlan) {
        if plan.requiresQuery == false, networkQuery.sectionBy == nil {
            networkUnfilteredSnapshotLedger = WebInspectorFetchedResultsSingleSectionSnapshotLedger(
                itemIDs: items.map(\.id)
            )
            networkResultSnapshot = nil
        } else {
            networkUnfilteredSnapshotLedger = nil
            networkResultSnapshot = WebInspectorFetchedResultsSnapshot(sections: sections)
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
