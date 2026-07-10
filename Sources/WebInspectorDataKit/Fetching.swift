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
    private struct State {
        var items: [Model]
        var sections: [WebInspectorFetchSection<Model>]
        var modelsByID: [Model.ID: Model]
        var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID>
        var revision: UInt64
        var queryGeneration: UInt64?
        var querySourceEpoch: UInt64?
        var querySequence: UInt64
    }

    private var state: State
    @ObservationIgnored private let updateBroker =
        WebInspectorFetchedResultsUpdateBroker<Model.ID>()
    @ObservationIgnored weak var modelContext: WebInspectorModelContext?
    @ObservationIgnored private var queryRegistrationID: WebInspectorQueryRegistrationID?
    @ObservationIgnored private var queryRegistrationLifetime: WebInspectorQueryRegistrationLifetime?

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
    public var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID> {
        modelContext?.preconditionOwnerIsolation()
        return state.snapshot
    }

    /// Monotonically increasing publication revision.
    public var revision: UInt64 {
        modelContext?.preconditionOwnerIsolation()
        return state.revision
    }

    init(modelContext: WebInspectorModelContext) {
        state = State(
            items: [],
            sections: [],
            modelsByID: [:],
            snapshot: WebInspectorFetchedResultsSnapshot(),
            revision: 0,
            queryGeneration: nil,
            querySourceEpoch: nil,
            querySequence: 0
        )
        self.modelContext = modelContext
        queryRegistrationID = nil
        queryRegistrationLifetime = nil
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

    private func installInitialConcreteState(
        generation: UInt64,
        projection: WebInspectorIndexedQueryProjection<Model.ID>,
        lookup: (Model.ID) -> Model?
    ) {
        precondition(
            state.queryGeneration == nil,
            "A concrete fetched-results initial state can only be installed once."
        )
        let resolved = resolve(projection.snapshot, reusing: [:], lookup: lookup)
        state = State(
            items: resolved.items,
            sections: resolved.sections,
            modelsByID: resolved.modelsByID,
            snapshot: projection.snapshot,
            revision: 0,
            queryGeneration: generation,
            querySourceEpoch: projection.sourceEpoch,
            querySequence: projection.sequence
        )
    }

    @discardableResult
    private func applyConcreteProjection(
        generation: UInt64,
        projection: WebInspectorIndexedQueryProjection<Model.ID>,
        isReplacement: Bool,
        lookup: (Model.ID) -> Model?
    ) -> Bool {
        guard let currentGeneration = state.queryGeneration,
              let currentSourceEpoch = state.querySourceEpoch else {
            preconditionFailure("A concrete fetched-results projection requires an installed initial state.")
        }
        guard projection.sourceEpoch >= currentSourceEpoch,
              generation >= currentGeneration else {
            return false
        }
        if generation == currentGeneration {
            if projection.sourceEpoch == currentSourceEpoch,
               projection.sequence <= state.querySequence {
                return false
            }
        } else {
            precondition(
                isReplacement,
                "A newer concrete query generation must publish as one replacement."
            )
        }

        let resetsSource = projection.sourceEpoch != currentSourceEpoch
        let shouldReset = isReplacement || resetsSource
        let resolved = resolve(
            projection.snapshot,
            reusing: resetsSource ? [:] : state.modelsByID,
            lookup: lookup
        )
        let visibleReconfigureIDs = projection.reconfigureItemIDs.intersection(
            projection.snapshot.itemIDs
        )
        if shouldReset == false,
           state.snapshot == projection.snapshot,
           visibleReconfigureIDs.isEmpty {
            state.querySourceEpoch = projection.sourceEpoch
            state.querySequence = projection.sequence
            return true
        }
        publish(
            items: resolved.items,
            sections: resolved.sections,
            modelsByID: resolved.modelsByID,
            snapshot: projection.snapshot,
            queryGeneration: generation,
            querySourceEpoch: projection.sourceEpoch,
            querySequence: projection.sequence,
            isReset: shouldReset,
            updatedItemIDs: visibleReconfigureIDs
        )
        return true
    }

    private func resolve(
        _ snapshot: WebInspectorFetchedResultsSnapshot<Model.ID>,
        reusing existingModelsByID: [Model.ID: Model],
        lookup: (Model.ID) -> Model?
    ) -> (
        items: [Model],
        sections: [WebInspectorFetchSection<Model>],
        modelsByID: [Model.ID: Model]
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
        return (items, sections, modelsByID)
    }

    /// Returns an atomic bounded stream beginning with the current result state.
    ///
    /// The first consumed element is always `.initial`; it advances to the
    /// newest complete state if publications arrive before consumption. The
    /// stream then retains only its newest unconsumed transaction. Every
    /// transaction includes a full current snapshot, so consumers recover from
    /// a revision gap by replacing their local snapshot.
    public func updates() -> AsyncStream<WebInspectorFetchedResultsUpdate<Model.ID>> {
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
        snapshot: WebInspectorFetchedResultsSnapshot<Model.ID>,
        queryGeneration: UInt64,
        querySourceEpoch: UInt64,
        querySequence: UInt64,
        isReset: Bool,
        updatedItemIDs: Set<Model.ID>
    ) {
        let oldState = state
        let reconfigureItemIDs = updatedItemIDs.intersection(snapshot.itemIDs)
        guard isReset
            || oldState.snapshot != snapshot
            || reconfigureItemIDs.isEmpty == false else {
            return
        }

        let transaction: WebInspectorFetchedResultsTransaction<Model.ID>
        if isReset {
            transaction = WebInspectorFetchedResultsTransaction(
                oldSnapshot: oldState.snapshot,
                newSnapshot: snapshot,
                isReset: true,
                itemChanges: []
            )
        } else {
            transaction = WebInspectorFetchedResultsTransaction(
                oldSnapshot: oldState.snapshot,
                newSnapshot: snapshot,
                updatedItemIDs: reconfigureItemIDs
            )
        }

        precondition(
            oldState.revision < UInt64.max,
            "WebInspectorFetchedResults publication revision overflowed."
        )
        let revision = oldState.revision + 1
        state = State(
            items: items,
            sections: sections,
            modelsByID: modelsByID,
            snapshot: snapshot,
            revision: revision,
            queryGeneration: queryGeneration,
            querySourceEpoch: querySourceEpoch,
            querySequence: querySequence
        )
        updateBroker.yield(.transaction(
            revision: revision,
            transaction: transaction,
            reconfigureItemIDs: reconfigureItemIDs
        ))
    }
}

extension WebInspectorFetchedResults where Model == NetworkRequest {
    func installInitialNetworkQuery(
        _ query: NetworkQuery,
        generation: UInt64,
        projection: NetworkRequestIndex.QueryProjection,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) {
        installInitialConcreteState(
            generation: generation,
            projection: projection,
            lookup: lookup
        )
    }

    @discardableResult
    func applyNetworkQueryProjection(
        _ projection: NetworkRequestIndex.QueryProjection,
        query: NetworkQuery,
        generation: UInt64,
        isReplacement: Bool,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) -> Bool {
        applyConcreteProjection(
            generation: generation,
            projection: projection,
            isReplacement: isReplacement,
            lookup: lookup
        )
    }

    /// Replaces this result's Network query atomically.
    public nonisolated(nonsending) func update(_ query: NetworkQuery) async throws {
        guard queryRegistrationID != nil, state.queryGeneration != nil else {
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
    func installInitialConsoleQuery(
        _ query: ConsoleQuery,
        generation: UInt64,
        projection: ConsoleMessageIndex.QueryProjection,
        lookup: (ConsoleMessage.ID) -> ConsoleMessage?
    ) {
        installInitialConcreteState(
            generation: generation,
            projection: projection,
            lookup: lookup
        )
    }

    @discardableResult
    func applyConsoleQueryProjection(
        _ projection: ConsoleMessageIndex.QueryProjection,
        query: ConsoleQuery,
        generation: UInt64,
        isReplacement: Bool,
        lookup: (ConsoleMessage.ID) -> ConsoleMessage?
    ) -> Bool {
        applyConcreteProjection(
            generation: generation,
            projection: projection,
            isReplacement: isReplacement,
            lookup: lookup
        )
    }

    /// Replaces this result's Console query atomically.
    public nonisolated(nonsending) func update(_ query: ConsoleQuery) async throws {
        guard queryRegistrationID != nil, state.queryGeneration != nil else {
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
