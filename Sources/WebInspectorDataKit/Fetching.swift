import Foundation
import Observation

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
public struct WebInspectorFetchSection<Model: Identifiable>: Identifiable
where Model.ID: Hashable & Sendable {
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

/// Observable results for one closed Network or Console query.
@Observable
public final class WebInspectorFetchedResults<Model: WebInspectorPersistentModel> {
    private enum ConcreteQuery {
        case network(NetworkQuery)
        case console(ConsoleQuery)
    }

    private struct State {
        var items: [Model]
        var sections: [WebInspectorFetchSection<Model>]
        var modelsByID: [Model.ID: Model]
        var sectionsByID: [WebInspectorFetchSectionID: WebInspectorFetchSection<Model>]
        var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID, WebInspectorFetchSectionID>
        var revision: UInt64
        var query: ConcreteQuery?
    }

    private var state: State
    @ObservationIgnored private let updateBroker =
        WebInspectorLegacyFetchedResultsUpdateBroker<Model.ID>()
    @ObservationIgnored weak var modelContext: WebInspectorModelContext?
    @ObservationIgnored private var queryRegistrationID: WebInspectorQueryRegistrationID?
    @ObservationIgnored private var queryRegistrationLifetime: WebInspectorQueryRegistrationLifetime?
    @ObservationIgnored private var queryGeneration: UInt64?
    @ObservationIgnored private var indexedQueryState: WebInspectorIndexedQueryState<Model.ID>?

    /// The fetched models in display order.
    public var items: [Model] {
        modelContext?.preconditionOwnerIsolation()
        return state.items
    }

    /// The fetched models grouped into display sections.
    public var sections: [WebInspectorFetchSection<Model>] {
        modelContext?.preconditionOwnerIsolation()
        return state.sections
    }

    /// The complete current section and item identity snapshot.
    public var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID, WebInspectorFetchSectionID> {
        modelContext?.preconditionOwnerIsolation()
        return state.snapshot
    }

    /// Monotonically increasing publication revision.
    public var revision: UInt64 {
        modelContext?.preconditionOwnerIsolation()
        return state.revision
    }

    /// Returns a model by identity from the current published result.
    public subscript(id id: Model.ID) -> Model? {
        modelContext?.preconditionOwnerIsolation()
        return state.modelsByID[id]
    }

    /// Returns a section by identity from the current published result.
    public subscript(section id: WebInspectorFetchSectionID) -> WebInspectorFetchSection<Model>? {
        modelContext?.preconditionOwnerIsolation()
        return state.sectionsByID[id]
    }

    init(modelContext: WebInspectorModelContext) {
        state = State(
            items: [],
            sections: [],
            modelsByID: [:],
            sectionsByID: [:],
            snapshot: WebInspectorFetchedResultsSnapshot(),
            revision: 0,
            query: nil
        )
        self.modelContext = modelContext
        queryRegistrationID = nil
        queryRegistrationLifetime = nil
        queryGeneration = nil
        indexedQueryState = nil
    }

    deinit {
        updateBroker.finish()
    }

    func installQueryRegistration(
        id: WebInspectorQueryRegistrationID,
        lifetime: WebInspectorQueryRegistrationLifetime
    ) {
        precondition(
            queryRegistrationID == nil && queryRegistrationLifetime == nil,
            "WebInspectorFetchedResults already owns a query registration."
        )
        queryRegistrationID = id
        queryRegistrationLifetime = lifetime
    }

    var concreteQueryRegistrationID: WebInspectorQueryRegistrationID? {
        queryRegistrationID
    }

    func nextConcreteQueryGeneration() -> UInt64 {
        guard let queryRegistrationLifetime else {
            preconditionFailure("WebInspectorFetchedResults has no concrete query registration lifetime.")
        }
        return queryRegistrationLifetime.nextGeneration()
    }

    func isCurrentConcreteQueryGeneration(_ generation: UInt64) -> Bool {
        queryRegistrationLifetime?.isCurrent(generation: generation) == true
    }

    @discardableResult
    private func installInitialConcreteState(
        query: ConcreteQuery,
        generation: UInt64,
        publication: WebInspectorIndexedQueryPublication<Model.ID>,
        lookup: (Model.ID) -> Model?
    ) -> WebInspectorIndexedQueryState<Model.ID> {
        precondition(
            queryGeneration == nil && indexedQueryState == nil,
            "A concrete fetched-results initial state can only be installed once."
        )
        guard case .reset = publication.change else {
            preconditionFailure("A concrete fetched-results initial state must be a reset publication.")
        }
        let queryState = publication.state
        let resolved = resolve(queryState.snapshot, reusing: [:], lookup: lookup)
        state = State(
            items: resolved.items,
            sections: resolved.sections,
            modelsByID: resolved.modelsByID,
            sectionsByID: resolved.sectionsByID,
            snapshot: queryState.snapshot,
            revision: 0,
            query: query
        )
        queryGeneration = generation
        indexedQueryState = queryState
        return queryState
    }

    @discardableResult
    private func applyConcretePublication(
        query: ConcreteQuery,
        generation: UInt64,
        publication: WebInspectorIndexedQueryPublication<Model.ID>,
        isReplacement: Bool,
        lookup: (Model.ID) -> Model?
    ) -> WebInspectorIndexedQueryState<Model.ID>? {
        guard let currentGeneration = queryGeneration,
              let currentQueryState = indexedQueryState else {
            preconditionFailure("A concrete fetched-results publication requires an installed initial state.")
        }
        let incomingState = publication.state
        guard incomingState.cursor.sourceEpoch >= currentQueryState.cursor.sourceEpoch,
              generation >= currentGeneration else {
            return nil
        }
        if generation == currentGeneration {
            if incomingState.cursor.sourceEpoch == currentQueryState.cursor.sourceEpoch,
               incomingState.cursor.sequence <= currentQueryState.cursor.sequence {
                return currentQueryState
            }
        } else {
            precondition(
                isReplacement,
                "A newer concrete query generation must publish as one replacement."
            )
        }

        let resetsSource = incomingState.cursor.sourceEpoch != currentQueryState.cursor.sourceEpoch
        if isReplacement || resetsSource {
            guard case .reset = publication.change else {
                preconditionFailure("A query replacement or source epoch change must publish as a reset.")
            }
        }

        let transaction: WebInspectorFetchedResultsTransaction<Model.ID>
        let rebuildsResolvedTopology: Bool
        switch publication.change {
        case .reset:
            // Initial/replacement/source recovery carries a complete state and
            // deliberately does not construct a collection diff on this owner.
            transaction = WebInspectorFetchedResultsTransaction(
                oldSnapshot: currentQueryState.snapshot,
                newSnapshot: incomingState.snapshot,
                isReset: true,
                itemChanges: []
            )
            rebuildsResolvedTopology = true
        case let .transaction(base, actorTransaction):
            if base != currentQueryState.cursor {
                // A bounded delivery gap is recoverable from the complete
                // delivered state without rebuilding the actor's missing diff.
                transaction = WebInspectorFetchedResultsTransaction(
                    oldSnapshot: currentQueryState.snapshot,
                    newSnapshot: incomingState.snapshot,
                    isReset: true,
                    itemChanges: []
                )
                rebuildsResolvedTopology = true
            } else if actorTransaction.hasChanges == false,
                      publication.reconfigureItemIDs.isEmpty {
                queryGeneration = generation
                indexedQueryState = incomingState
                return incomingState
            } else {
                transaction = actorTransaction
                rebuildsResolvedTopology = transactionChangesResolvedTopology(actorTransaction)
            }
        }

        if rebuildsResolvedTopology {
            let resolved = resolve(
                incomingState.snapshot,
                reusing: resetsSource ? [:] : state.modelsByID,
                lookup: lookup
            )
            publish(
                items: resolved.items,
                sections: resolved.sections,
                modelsByID: resolved.modelsByID,
                sectionsByID: resolved.sectionsByID,
                query: query,
                queryGeneration: generation,
                queryState: incomingState,
                transaction: transaction,
                reconfigureItemIDs: publication.reconfigureItemIDs
            )
        } else {
            publish(
                items: state.items,
                sections: state.sections,
                modelsByID: state.modelsByID,
                sectionsByID: state.sectionsByID,
                query: query,
                queryGeneration: generation,
                queryState: incomingState,
                transaction: transaction,
                reconfigureItemIDs: publication.reconfigureItemIDs
            )
        }
        return incomingState
    }

    private func transactionChangesResolvedTopology(
        _ transaction: WebInspectorFetchedResultsTransaction<Model.ID>
    ) -> Bool {
        guard transaction.sectionChanges.isEmpty else {
            return true
        }
        return transaction.itemChanges.contains { change in
            switch change {
            case .update:
                return false
            case .insert, .delete, .move:
                return true
            }
        }
    }

    private func resolve(
        _ snapshot: WebInspectorFetchedResultsSnapshot<Model.ID, WebInspectorFetchSectionID>,
        reusing existingModelsByID: [Model.ID: Model],
        lookup: (Model.ID) -> Model?
    ) -> (
        items: [Model],
        sections: [WebInspectorFetchSection<Model>],
        modelsByID: [Model.ID: Model],
        sectionsByID: [WebInspectorFetchSectionID: WebInspectorFetchSection<Model>]
    ) {
        var modelsByID: [Model.ID: Model] = [:]
        modelsByID.reserveCapacity(snapshot.itemIDs.count)
        for id in snapshot.itemIDs {
            if let existing = existingModelsByID[id] {
                modelsByID[id] = existing
                continue
            }
            guard let model = lookup(id) else {
                preconditionFailure("A concrete fetched-results snapshot referenced an unregistered \(Model.self).")
            }
            modelsByID[id] = model
        }
        let items = snapshot.itemIDs.map { id in
            guard let model = modelsByID[id] else {
                preconditionFailure("A concrete fetched-results identity map lost a visible \(Model.self).")
            }
            return model
        }
        let sections = snapshot.sections.map { section in
            WebInspectorFetchSection(
                id: section.id,
                title: section.title,
                items: section.itemIDs.map { id in
                    guard let model = modelsByID[id] else {
                        preconditionFailure("A concrete fetched-results section lost a visible \(Model.self).")
                    }
                    return model
                }
            )
        }
        var sectionsByID: [WebInspectorFetchSectionID: WebInspectorFetchSection<Model>] = [:]
        sectionsByID.reserveCapacity(sections.count)
        for section in sections {
            precondition(
                sectionsByID.updateValue(section, forKey: section.id) == nil,
                "A fetched-results snapshot cannot contain duplicate section IDs."
            )
        }
        return (items, sections, modelsByID, sectionsByID)
    }

    /// Returns an atomic bounded stream beginning with the current result state.
    ///
    /// The first consumed element is always `.initial`; it advances to the
    /// newest complete state if publications arrive before consumption. The
    /// stream then retains only its newest unconsumed transaction. Every
    /// transaction includes a full current snapshot, so consumers recover from
    /// a revision gap by replacing their local snapshot.
    public func updates() -> AsyncStream<WebInspectorLegacyFetchedResultsUpdate<Model.ID>> {
        modelContext?.preconditionOwnerIsolation()
        return updateBroker.makeStream(initial: .initial(
            revision: state.revision,
            snapshot: state.snapshot
        ))
    }

    private func publish(
        items: [Model],
        sections: [WebInspectorFetchSection<Model>],
        modelsByID: [Model.ID: Model],
        sectionsByID: [WebInspectorFetchSectionID: WebInspectorFetchSection<Model>],
        query: ConcreteQuery,
        queryGeneration: UInt64,
        queryState: WebInspectorIndexedQueryState<Model.ID>,
        transaction: WebInspectorFetchedResultsTransaction<Model.ID>,
        reconfigureItemIDs: Set<Model.ID>
    ) {
        let oldState = state
        precondition(
            oldState.revision < UInt64.max,
            "WebInspectorFetchedResults publication revision overflowed."
        )
        let revision = oldState.revision + 1
        state = State(
            items: items,
            sections: sections,
            modelsByID: modelsByID,
            sectionsByID: sectionsByID,
            snapshot: queryState.snapshot,
            revision: revision,
            query: query
        )
        self.queryGeneration = queryGeneration
        indexedQueryState = queryState
        updateBroker.yield(.transaction(
            revision: revision,
            transaction: transaction,
            reconfigureItemIDs: reconfigureItemIDs
        ))
    }
}

extension WebInspectorFetchedResults where Model == NetworkRequest {
    @discardableResult
    func installInitialNetworkQuery(
        _ query: NetworkQuery,
        generation: UInt64,
        publication: NetworkRequestIndex.QueryPublication,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) -> NetworkRequestIndex.QueryState {
        installInitialConcreteState(
            query: .network(query),
            generation: generation,
            publication: publication,
            lookup: lookup
        )
    }

    @discardableResult
    func applyNetworkQueryPublication(
        _ publication: NetworkRequestIndex.QueryPublication,
        query: NetworkQuery,
        generation: UInt64,
        isReplacement: Bool,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) -> NetworkRequestIndex.QueryState? {
        applyConcretePublication(
            query: .network(query),
            generation: generation,
            publication: publication,
            isReplacement: isReplacement,
            lookup: lookup
        )
    }

    /// The Network query that produced the current published result.
    ///
    /// An in-flight replacement does not change this value. It changes
    /// atomically with the replacement's items, sections, snapshot, and
    /// revision when that replacement publishes.
    public var query: NetworkQuery {
        modelContext?.preconditionOwnerIsolation()
        guard case let .network(query) = state.query else {
            preconditionFailure(
                "Network fetched results require an installed Network query."
            )
        }
        return query
    }

    /// Replaces this result's Network query atomically.
    public nonisolated(nonsending) func update(_ query: NetworkQuery) async throws {
        guard queryRegistrationID != nil, queryGeneration != nil else {
            preconditionFailure(
                "A Network query can only update results created by networkRequests(matching:)."
            )
        }
        guard let modelContext else {
            preconditionFailure("WebInspectorFetchedResults is not registered in a WebInspectorModelContext.")
        }
        try await modelContext.updateNetworkQuery(query, for: self)
    }
}

extension WebInspectorFetchedResults where Model == ConsoleMessage {
    @discardableResult
    func installInitialConsoleQuery(
        _ query: ConsoleQuery,
        generation: UInt64,
        publication: ConsoleMessageIndex.QueryPublication,
        lookup: (ConsoleMessage.ID) -> ConsoleMessage?
    ) -> ConsoleMessageIndex.QueryState {
        installInitialConcreteState(
            query: .console(query),
            generation: generation,
            publication: publication,
            lookup: lookup
        )
    }

    @discardableResult
    func applyConsoleQueryPublication(
        _ publication: ConsoleMessageIndex.QueryPublication,
        query: ConsoleQuery,
        generation: UInt64,
        isReplacement: Bool,
        lookup: (ConsoleMessage.ID) -> ConsoleMessage?
    ) -> ConsoleMessageIndex.QueryState? {
        applyConcretePublication(
            query: .console(query),
            generation: generation,
            publication: publication,
            isReplacement: isReplacement,
            lookup: lookup
        )
    }

    /// The Console query that produced the current published result.
    ///
    /// An in-flight replacement does not change this value. It changes
    /// atomically with the replacement's items, sections, snapshot, and
    /// revision when that replacement publishes.
    public var query: ConsoleQuery {
        modelContext?.preconditionOwnerIsolation()
        guard case let .console(query) = state.query else {
            preconditionFailure(
                "Console fetched results require an installed Console query."
            )
        }
        return query
    }

    /// Replaces this result's Console query atomically.
    public nonisolated(nonsending) func update(_ query: ConsoleQuery) async throws {
        guard queryRegistrationID != nil, queryGeneration != nil else {
            preconditionFailure(
                "A Console query can only update results created by consoleMessages(matching:)."
            )
        }
        guard let modelContext else {
            preconditionFailure("WebInspectorFetchedResults is not registered in a WebInspectorModelContext.")
        }
        try await modelContext.updateConsoleQuery(query, for: self)
    }
}
