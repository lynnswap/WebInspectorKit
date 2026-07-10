import Foundation
import Observation

/// Value configuration for fetching DataKit model objects.
///
/// A descriptor describes predicate, sort, limit, and offset behavior for
/// models such as ``NetworkRequest`` and ``ConsoleMessage``.
///
/// Example:
///
/// ```swift
/// let descriptor = WebInspectorFetchDescriptor<NetworkRequest>(
///     predicate: #Predicate { request in
///         request.method == "POST"
///     },
///     sortBy: [
///         SortDescriptor(\.requestSentTimestamp, order: .reverse)
///     ],
///     fetchLimit: 100
/// )
///
/// let results = context.network.fetchedResults(for: descriptor)
/// ```
public struct WebInspectorFetchDescriptor<Model: WebInspectorFetchableModel>: Sendable {
    enum Kind: Hashable, Sendable {
        case networkRequests
        case consoleMessages
    }

    let kind: Kind
    /// Predicate used to filter fetched models.
    public var predicate: Predicate<Model>?

    /// Sort descriptors used to order fetched models.
    public var sortBy: [SortDescriptor<Model>]

    /// Maximum number of models to fetch.
    public var fetchLimit: Int? {
        didSet {
            Self.validate(fetchLimit: fetchLimit)
        }
    }
    /// Number of models to skip before returning results.
    public var fetchOffset: Int {
        didSet {
            Self.validate(fetchOffset: fetchOffset)
        }
    }

    /// Creates a fetch descriptor.
    public init(
        predicate: Predicate<Model>? = nil,
        sortBy: [SortDescriptor<Model>] = [],
        fetchLimit: Int? = nil,
        fetchOffset: Int = 0
    ) {
        Self.validate(fetchLimit: fetchLimit)
        Self.validate(fetchOffset: fetchOffset)
        self.kind = Self.requireKnownKind()
        self.predicate = predicate
        self.sortBy = sortBy
        self.fetchLimit = fetchLimit
        self.fetchOffset = fetchOffset
    }

    private static func requireKnownKind() -> Kind {
        if Model.self == NetworkRequest.self {
            return .networkRequests
        }
        if Model.self == ConsoleMessage.self {
            return .consoleMessages
        }
        preconditionFailure("WebInspectorFetchDescriptor does not support fetching \(Model.self).")
    }

    private static func validate(fetchLimit: Int?) {
        if let fetchLimit {
            precondition(fetchLimit >= 0, "WebInspectorFetchDescriptor fetchLimit must be non-negative.")
        }
    }

    private static func validate(fetchOffset: Int) {
        precondition(fetchOffset >= 0, "WebInspectorFetchDescriptor fetchOffset must be non-negative.")
    }

    var requiresRecordBackedQuery: Bool {
        predicate != nil || sortBy.isEmpty == false || fetchLimit != nil || fetchOffset > 0
    }
}

/// Mutable builder for a ``WebInspectorFetchDescriptor``.
public final class WebInspectorFetchRequest<Model: WebInspectorFetchableModel> {
    /// Predicate used to filter fetched models.
    public var predicate: Predicate<Model>?

    /// Sort descriptors used to order fetched models.
    public var sortDescriptors: [SortDescriptor<Model>]

    /// Maximum number of models to fetch.
    public var fetchLimit: Int? {
        didSet {
            Self.validate(fetchLimit: fetchLimit)
        }
    }
    /// Number of models to skip before returning results.
    public var fetchOffset: Int {
        didSet {
            Self.validate(fetchOffset: fetchOffset)
        }
    }

    /// Creates a mutable fetch request.
    public init(
        predicate: Predicate<Model>? = nil,
        sortDescriptors: [SortDescriptor<Model>] = [],
        fetchLimit: Int? = nil,
        fetchOffset: Int = 0
    ) {
        Self.validate(fetchLimit: fetchLimit)
        Self.validate(fetchOffset: fetchOffset)
        self.predicate = predicate
        self.sortDescriptors = sortDescriptors
        self.fetchLimit = fetchLimit
        self.fetchOffset = fetchOffset
    }

    /// Immutable descriptor representing the request's current values.
    public var fetchDescriptor: WebInspectorFetchDescriptor<Model> {
        WebInspectorFetchDescriptor(
            predicate: predicate,
            sortBy: sortDescriptors,
            fetchLimit: fetchLimit,
            fetchOffset: fetchOffset
        )
    }

    private static func validate(fetchLimit: Int?) {
        if let fetchLimit {
            precondition(fetchLimit >= 0, "WebInspectorFetchRequest fetchLimit must be non-negative.")
        }
    }

    private static func validate(fetchOffset: Int) {
        precondition(fetchOffset >= 0, "WebInspectorFetchRequest fetchOffset must be non-negative.")
    }
}

final class WeakWebInspectorFetchedResults<Model: WebInspectorFetchableModel> {
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

enum WebInspectorSectionKey: Hashable, Sendable {
    case networkMethod
    case networkResourceType
    case networkResourceCategory
    case networkMIMEType
    case consoleSource
    case consoleLevel
    case consoleKind
    case consoleURL
}

/// Descriptor for sectioning fetched results by a supported model key path.
public struct WebInspectorSectionDescriptor<Model: WebInspectorFetchableModel>: Hashable, Sendable {
    let key: WebInspectorSectionKey

    /// Creates a section descriptor from a non-optional string key path.
    public init(_ keyPath: KeyPath<Model, String>) {
        key = Self.requireKnownSectionKey(for: keyPath)
    }

    /// Creates a section descriptor from an optional string key path.
    public init(_ keyPath: KeyPath<Model, String?>) {
        key = Self.requireKnownSectionKey(for: keyPath)
    }

    /// Creates a section descriptor from a raw-representable string value key path.
    public init<Value: RawRepresentable & Hashable & Sendable>(
        _ keyPath: KeyPath<Model, Value>
    ) where Value.RawValue == String {
        key = Self.requireKnownSectionKey(for: keyPath)
    }

    /// Creates a section descriptor from an optional raw-representable string value key path.
    public init<Value: RawRepresentable & Hashable & Sendable>(
        _ keyPath: KeyPath<Model, Value?>
    ) where Value.RawValue == String {
        key = Self.requireKnownSectionKey(for: keyPath)
    }

    private static func requireKnownSectionKey(for keyPath: AnyKeyPath) -> WebInspectorSectionKey {
        guard let key = WebInspectorKnownKeyPaths.sectionKey(for: Model.self, keyPath: keyPath) else {
            preconditionFailure(
                "WebInspectorSectionDescriptor does not support sectioning \(Model.self) by key path \(keyPath)."
            )
        }
        return key
    }
}

private enum WebInspectorKnownKeyPaths {
    static func sectionKey<Model: WebInspectorFetchableModel>(
        for _: Model.Type,
        keyPath: AnyKeyPath
    ) -> WebInspectorSectionKey? {
        if Model.self == NetworkRequest.self {
            return networkSectionKey(keyPath)
        }
        if Model.self == ConsoleMessage.self {
            return consoleSectionKey(keyPath)
        }
        return nil
    }

    private static func networkSectionKey(
        _ keyPath: AnyKeyPath
    ) -> WebInspectorSectionKey? {
        if keyPath == (\NetworkRequest.method as AnyKeyPath) {
            return .networkMethod
        }
        if keyPath == (\NetworkRequest.resourceType as AnyKeyPath) {
            return .networkResourceType
        }
        if keyPath == (\NetworkRequest.resourceCategory as AnyKeyPath) {
            return .networkResourceCategory
        }
        if keyPath == (\NetworkRequest.mimeType as AnyKeyPath) {
            return .networkMIMEType
        }
        return nil
    }

    private static func consoleSectionKey(
        _ keyPath: AnyKeyPath
    ) -> WebInspectorSectionKey? {
        if keyPath == (\ConsoleMessage.source as AnyKeyPath) {
            return .consoleSource
        }
        if keyPath == (\ConsoleMessage.level as AnyKeyPath) {
            return .consoleLevel
        }
        if keyPath == (\ConsoleMessage.kind as AnyKeyPath) {
            return .consoleKind
        }
        if keyPath == (\ConsoleMessage.url as AnyKeyPath) {
            return .consoleURL
        }
        return nil
    }
}

/// Observable collection of models produced by a fetch descriptor.
@Observable
public final class WebInspectorFetchedResults<Model: WebInspectorFetchableModel> {
    private struct State {
        var fetchDescriptor: WebInspectorFetchDescriptor<Model>
        var sectionBy: WebInspectorSectionDescriptor<Model>?
        var items: [Model]
        var sections: [WebInspectorFetchSection<Model>]
        var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID>
        var revision: UInt64
        var topologyRevision: UInt64
    }

    private var state: State
    @ObservationIgnored private let updateBroker =
        WebInspectorFetchedResultsUpdateBroker<Model.ID>()
    @ObservationIgnored weak var modelContext: WebInspectorContext?
    @ObservationIgnored private var networkQueryPlan: NetworkRequestQueryPlan?
    @ObservationIgnored private var networkQueryState: NetworkRequestQueryState?
    @ObservationIgnored private var networkIndexSequence: UInt64
    @ObservationIgnored private var consoleQueryPlan: ConsoleMessageQueryPlan?
    @ObservationIgnored private var consoleQueryState: ConsoleMessageQueryState?
    @ObservationIgnored private var consoleIndexSequence: UInt64

    /// The descriptor currently used by the results.
    public var fetchDescriptor: WebInspectorFetchDescriptor<Model> {
        state.fetchDescriptor
    }

    /// The section descriptor currently used by the results.
    public var sectionBy: WebInspectorSectionDescriptor<Model>? {
        state.sectionBy
    }

    /// The fetched models in display order.
    public var items: [Model] {
        state.items
    }

    /// The fetched models grouped into display sections.
    public var sections: [WebInspectorFetchSection<Model>] {
        state.sections
    }

    /// The complete current section and item identity snapshot.
    public var snapshot: WebInspectorFetchedResultsSnapshot<Model.ID> {
        state.snapshot
    }

    /// Monotonically increasing publication revision.
    public var revision: UInt64 {
        state.revision
    }

    package var topologyRevision: UInt64 {
        state.topologyRevision
    }

    init(
        fetchDescriptor: WebInspectorFetchDescriptor<Model>,
        sectionBy: WebInspectorSectionDescriptor<Model>? = nil,
        items: [Model] = [],
        modelContext: WebInspectorContext? = nil
    ) {
        let sections = Self.sections(for: items, sectionBy: sectionBy)
        state = State(
            fetchDescriptor: fetchDescriptor,
            sectionBy: sectionBy,
            items: items,
            sections: sections,
            snapshot: WebInspectorFetchedResultsSnapshot(sections: sections),
            revision: 0,
            topologyRevision: 0
        )
        self.modelContext = modelContext
        networkQueryPlan = nil
        networkQueryState = nil
        networkIndexSequence = 0
        consoleQueryPlan = nil
        consoleQueryState = nil
        consoleIndexSequence = 0
    }

    deinit {
        updateBroker.finish()
    }

    /// Returns an atomic bounded stream beginning with the current result state.
    ///
    /// The first consumed element is always `.initial`; it advances to the
    /// newest complete state if publications arrive before consumption. The
    /// stream then retains only its newest unconsumed transaction. Every
    /// transaction includes a full current snapshot, so consumers recover from
    /// a revision gap by replacing their local snapshot.
    public func updates() -> AsyncStream<WebInspectorFetchedResultsUpdate<Model.ID>> {
        updateBroker.makeStream(initial: .initial(
            revision: state.revision,
            snapshot: state.snapshot
        ))
    }

    func setItems(_ items: [Model], updatedItemIDs: Set<Model.ID> = []) {
        let sections = Self.sections(for: items, sectionBy: state.sectionBy)
        publish(items: items, sections: sections, updatedItemIDs: updatedItemIDs)
    }

    func insertItem(_ item: Model) {
        precondition(
            state.items.contains { $0.id == item.id } == false,
            "WebInspectorFetchedResults cannot insert a duplicate item ID."
        )
        let items = state.items + [item]
        let sections = Self.sections(for: items, sectionBy: state.sectionBy)
        publish(items: items, sections: sections)
    }

    func refreshAfterItemMutation(_ item: Model) {
        guard state.items.contains(where: { $0.id == item.id }) else {
            return
        }
        let sections = Self.sections(for: state.items, sectionBy: state.sectionBy)
        publish(items: state.items, sections: sections, updatedItemIDs: [item.id])
    }

    func resetItems(_ items: [Model]) {
        let sections = Self.sections(for: items, sectionBy: state.sectionBy)
        publish(items: items, sections: sections, isReset: true)
    }

    func applyFetchDescriptor(_ descriptor: WebInspectorFetchDescriptor<Model>, items: [Model]) {
        let sections = Self.sections(for: items, sectionBy: state.sectionBy)
        publish(
            items: items,
            sections: sections,
            fetchDescriptor: descriptor,
            isReset: true
        )
    }

    private func applyIndexedDelta(
        sequence: UInt64,
        snapshot: WebInspectorFetchedResultsSnapshot<Model.ID>,
        transaction: WebInspectorFetchedResultsTransaction<Model.ID>,
        reconfigureItemIDs: Set<Model.ID>,
        currentIndexSequence: UInt64,
        lookup: (Model.ID) -> Model?
    ) -> UInt64 {
        guard sequence > currentIndexSequence else {
            return currentIndexSequence
        }
        if snapshot == state.snapshot {
            publish(
                items: state.items,
                sections: state.sections,
                snapshot: snapshot,
                transaction: transaction,
                updatedItemIDs: reconfigureItemIDs
            )
            return sequence
        }
        let items = snapshot.itemIDs.map { id in
            guard let model = lookup(id) else {
                preconditionFailure("An indexed fetched-results snapshot referenced an unregistered \(Model.self).")
            }
            return model
        }
        let sections = snapshot.sections.map { section in
            WebInspectorFetchSection(
                id: section.id,
                title: section.title,
                items: section.itemIDs.map { id in
                    guard let model = lookup(id) else {
                        preconditionFailure("An indexed fetched-results section referenced an unregistered \(Model.self).")
                    }
                    return model
                }
            )
        }
        publish(
            items: items,
            sections: sections,
            snapshot: snapshot,
            transaction: transaction,
            updatedItemIDs: reconfigureItemIDs
        )
        return sequence
    }

    /// Replaces the fetch descriptor and updates the result contents.
    public func updateFetchDescriptor(
        _ descriptor: WebInspectorFetchDescriptor<Model>,
        isolation: isolated (any Actor) = #isolation
    ) {
        guard let modelContext else {
            preconditionFailure("WebInspectorFetchedResults is not registered in a WebInspectorContext.")
        }
        modelContext.updateFetchDescriptor(descriptor, for: self, isolation: isolation)
    }

    private func publish(
        items: [Model],
        sections: [WebInspectorFetchSection<Model>],
        snapshot: WebInspectorFetchedResultsSnapshot<Model.ID>? = nil,
        fetchDescriptor: WebInspectorFetchDescriptor<Model>? = nil,
        isReset: Bool = false,
        transaction suppliedTransaction: WebInspectorFetchedResultsTransaction<Model.ID>? = nil,
        updatedItemIDs: Set<Model.ID> = []
    ) {
        let oldState = state
        let newSnapshot = snapshot ?? WebInspectorFetchedResultsSnapshot(sections: sections)
        let reconfigureItemIDs = updatedItemIDs.intersection(newSnapshot.itemIDs)
        guard isReset
            || oldState.snapshot != newSnapshot
            || reconfigureItemIDs.isEmpty == false else {
            return
        }

        let transaction: WebInspectorFetchedResultsTransaction<Model.ID>
        if let suppliedTransaction {
            precondition(
                suppliedTransaction.oldSnapshot == oldState.snapshot
                    && suppliedTransaction.newSnapshot == newSnapshot,
                "A fetched-results transaction must describe the state publication it accompanies."
            )
            transaction = suppliedTransaction
        } else if isReset {
            transaction = WebInspectorFetchedResultsTransaction(
                oldSnapshot: oldState.snapshot,
                newSnapshot: newSnapshot,
                isReset: true,
                itemChanges: []
            )
        } else {
            transaction = WebInspectorFetchedResultsTransaction(
                oldSnapshot: oldState.snapshot,
                newSnapshot: newSnapshot,
                updatedItemIDs: reconfigureItemIDs
            )
        }

        let revision = oldState.revision &+ 1
        let topologyRevision = if isReset || oldState.snapshot != newSnapshot {
            oldState.topologyRevision &+ 1
        } else {
            oldState.topologyRevision
        }
        state = State(
            fetchDescriptor: fetchDescriptor ?? oldState.fetchDescriptor,
            sectionBy: oldState.sectionBy,
            items: items,
            sections: sections,
            snapshot: newSnapshot,
            revision: revision,
            topologyRevision: topologyRevision
        )
        updateBroker.yield(.transaction(
            revision: revision,
            transaction: transaction,
            reconfigureItemIDs: reconfigureItemIDs
        ))
    }

    private static func sections(
        for items: [Model],
        sectionBy: WebInspectorSectionDescriptor<Model>?
    ) -> [WebInspectorFetchSection<Model>] {
        guard items.isEmpty == false else {
            return []
        }
        guard let sectionBy else {
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
            let section = sectionIdentity(for: item, sectionBy: sectionBy)
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
        sectionBy: WebInspectorSectionDescriptor<Model>
    ) -> (id: WebInspectorFetchSectionID, title: String?) {
        let value: String?
        switch sectionBy.key {
        case .networkMethod:
            value = (item as? NetworkRequest)?.method
        case .networkResourceType:
            value = (item as? NetworkRequest)?.resourceType?.rawValue
        case .networkResourceCategory:
            value = (item as? NetworkRequest)?.resourceCategory.rawValue
        case .networkMIMEType:
            value = (item as? NetworkRequest)?.mimeType
        case .consoleSource:
            value = (item as? ConsoleMessage)?.source.rawValue
        case .consoleLevel:
            value = (item as? ConsoleMessage)?.level.rawValue
        case .consoleKind:
            value = (item as? ConsoleMessage)?.kind?.rawValue
        case .consoleURL:
            value = (item as? ConsoleMessage)?.url
        }

        let title = value ?? ""
        return (WebInspectorFetchSectionID(rawValue: title), title)
    }
}

extension WebInspectorFetchedResults where Model == NetworkRequest {
    var networkSnapshotForDelta: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID> {
        state.snapshot
    }

    var networkIndexSequenceForDelta: UInt64 {
        networkIndexSequence
    }

    func currentNetworkQueryPlan(context: WebInspectorContext) -> NetworkRequestQueryPlan {
        if let networkQueryPlan {
            return networkQueryPlan
        }
        let plan = NetworkRequestQueryPlan(descriptor: state.fetchDescriptor, context: context)
        networkQueryPlan = plan
        return plan
    }

    func setNetworkItems(
        _ requests: [NetworkRequest],
        plan: NetworkRequestQueryPlan,
        indexSequence: UInt64,
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
        networkIndexSequence = indexSequence
    }

    func applyNetworkFetchDescriptor(
        _ descriptor: WebInspectorFetchDescriptor<NetworkRequest>,
        plan: NetworkRequestQueryPlan,
        requests: [NetworkRequest],
        indexSequence: UInt64,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) {
        networkQueryPlan = plan
        let visibleRequests: [NetworkRequest]
        if plan.requiresQuery {
            let state = NetworkRequestQueryState(plan: plan, requests: requests)
            networkQueryState = state
            visibleRequests = state.visibleRequests(lookup: lookup)
        } else {
            networkQueryState = nil
            visibleRequests = requests
        }
        let sections = Self.sections(for: visibleRequests, sectionBy: state.sectionBy)
        publish(
            items: visibleRequests,
            sections: sections,
            fetchDescriptor: descriptor,
            isReset: true
        )
        networkIndexSequence = indexSequence
    }

    func resetNetworkItems(indexSequence: UInt64) {
        if let state = networkQueryState {
            networkQueryState = NetworkRequestQueryState(plan: state.plan, requests: [])
        }
        resetItems([])
        networkIndexSequence = indexSequence
    }

    func insertNetworkRequest(
        _ request: NetworkRequest,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) {
        guard var state = networkQueryState else {
            insertItem(request)
            return
        }
        state.upsert(request: request)
        networkQueryState = state
        setItems(state.visibleRequests(lookup: lookup))
    }

    func refreshNetworkRequestAfterMutation(
        _ request: NetworkRequest,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) {
        guard var state = networkQueryState else {
            refreshAfterItemMutation(request)
            return
        }
        state.upsert(request: request)
        networkQueryState = state
        setItems(state.visibleRequests(lookup: lookup), updatedItemIDs: [request.id])
    }

    func applyNetworkDelta(
        _ delta: NetworkResultSetDelta,
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) {
        networkIndexSequence = applyIndexedDelta(
            sequence: delta.sequence,
            snapshot: delta.snapshot,
            transaction: delta.transaction,
            reconfigureItemIDs: delta.reconfigureItemIDs,
            currentIndexSequence: networkIndexSequence,
            lookup: lookup
        )
    }
}

extension WebInspectorFetchedResults where Model == ConsoleMessage {
    var consoleSnapshotForDelta: WebInspectorFetchedResultsSnapshot<ConsoleMessage.ID> {
        state.snapshot
    }

    var consoleIndexSequenceForDelta: UInt64 {
        consoleIndexSequence
    }

    func currentConsoleQueryPlan(context: WebInspectorContext) -> ConsoleMessageQueryPlan {
        if let consoleQueryPlan {
            return consoleQueryPlan
        }
        let plan = ConsoleMessageQueryPlan(descriptor: state.fetchDescriptor, context: context)
        consoleQueryPlan = plan
        return plan
    }

    func setConsoleItems(
        _ messages: [ConsoleMessage],
        plan: ConsoleMessageQueryPlan,
        indexSequence: UInt64,
        lookup: (ConsoleMessage.ID) -> ConsoleMessage?
    ) {
        consoleQueryPlan = plan
        if plan.requiresQuery {
            let queryState = ConsoleMessageQueryState(plan: plan, messages: messages)
            consoleQueryState = queryState
            setItems(queryState.visibleMessages(lookup: lookup))
        } else {
            consoleQueryState = nil
            setItems(messages)
        }
        consoleIndexSequence = indexSequence
    }

    func applyConsoleFetchDescriptor(
        _ descriptor: WebInspectorFetchDescriptor<ConsoleMessage>,
        plan: ConsoleMessageQueryPlan,
        messages: [ConsoleMessage],
        indexSequence: UInt64,
        lookup: (ConsoleMessage.ID) -> ConsoleMessage?
    ) {
        consoleQueryPlan = plan
        let visibleMessages: [ConsoleMessage]
        if plan.requiresQuery {
            let queryState = ConsoleMessageQueryState(plan: plan, messages: messages)
            consoleQueryState = queryState
            visibleMessages = queryState.visibleMessages(lookup: lookup)
        } else {
            consoleQueryState = nil
            visibleMessages = messages
        }
        let sections = Self.sections(for: visibleMessages, sectionBy: state.sectionBy)
        publish(
            items: visibleMessages,
            sections: sections,
            fetchDescriptor: descriptor,
            isReset: true
        )
        consoleIndexSequence = indexSequence
    }

    func insertConsoleMessage(
        _ message: ConsoleMessage,
        lookup: (ConsoleMessage.ID) -> ConsoleMessage?
    ) {
        guard var queryState = consoleQueryState else {
            insertItem(message)
            return
        }
        queryState.upsert(message: message)
        consoleQueryState = queryState
        setItems(queryState.visibleMessages(lookup: lookup))
    }

    func refreshConsoleMessageAfterMutation(
        _ message: ConsoleMessage,
        lookup: (ConsoleMessage.ID) -> ConsoleMessage?
    ) {
        guard var queryState = consoleQueryState else {
            refreshAfterItemMutation(message)
            return
        }
        queryState.upsert(message: message)
        consoleQueryState = queryState
        setItems(queryState.visibleMessages(lookup: lookup), updatedItemIDs: [message.id])
    }

    func applyConsoleDelta(
        _ delta: ConsoleResultSetDelta,
        lookup: (ConsoleMessage.ID) -> ConsoleMessage?
    ) {
        consoleIndexSequence = applyIndexedDelta(
            sequence: delta.sequence,
            snapshot: delta.snapshot,
            transaction: delta.transaction,
            reconfigureItemIDs: delta.reconfigureItemIDs,
            currentIndexSequence: consoleIndexSequence,
            lookup: lookup
        )
    }
}
