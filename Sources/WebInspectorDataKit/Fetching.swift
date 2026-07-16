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
public struct WebInspectorFetchSection<Model: WebInspectorFetchableModel>: Identifiable {
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
    /// The descriptor currently used by the results.
    public private(set) var fetchDescriptor: WebInspectorFetchDescriptor<Model>

    /// The section descriptor currently used by the results.
    public private(set) var sectionBy: WebInspectorSectionDescriptor<Model>?

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

    init(
        fetchDescriptor: WebInspectorFetchDescriptor<Model>,
        sectionBy: WebInspectorSectionDescriptor<Model>? = nil,
        items: [Model] = [],
        modelContext: WebInspectorContext? = nil
    ) {
        self.fetchDescriptor = fetchDescriptor
        self.sectionBy = sectionBy
        self.items = items
        sections = Self.sections(for: items, sectionBy: sectionBy)
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

    func setItems(_ items: [Model], updatedItemIDs: Set<Model.ID> = []) {
        let oldSnapshot = currentSnapshot
        self.items = items
        sections = Self.sections(for: items, sectionBy: sectionBy)
        bumpTopologyRevisionIfNeeded(oldSnapshot: oldSnapshot)
        yieldTransaction(oldSnapshot: oldSnapshot, updatedItemIDs: updatedItemIDs)
    }

    func insertItem(_ item: Model) {
        precondition(items.contains { $0.id == item.id } == false, "WebInspectorFetchedResults cannot insert a duplicate item ID.")
        let oldSnapshot = currentSnapshot
        items.append(item)
        sections = Self.sections(for: items, sectionBy: sectionBy)
        bumpTopologyRevisionIfNeeded(oldSnapshot: oldSnapshot)
        yieldTransaction(oldSnapshot: oldSnapshot, updatedItemIDs: [])
    }

    func refreshAfterItemMutation(_ item: Model) {
        guard items.contains(where: { $0.id == item.id }) else {
            return
        }
        let oldSnapshot = currentSnapshot
        if sectionBy != nil {
            sections = Self.sections(for: items, sectionBy: sectionBy)
        }
        bumpTopologyRevisionIfNeeded(oldSnapshot: oldSnapshot)
        yieldTransaction(oldSnapshot: oldSnapshot, updatedItemIDs: [item.id])
    }

    func resetItems(_ items: [Model]) {
        let oldSnapshot = currentSnapshot
        self.items = items
        sections = Self.sections(for: items, sectionBy: sectionBy)
        bumpTopologyRevision()
        yieldResetTransaction(oldSnapshot: oldSnapshot)
    }

    func applyFetchDescriptor(_ descriptor: WebInspectorFetchDescriptor<Model>, items: [Model]) {
        fetchDescriptor = descriptor
        resetItems(items)
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

    func currentNetworkQueryPlan(context: WebInspectorContext) -> NetworkRequestQueryPlan {
        if let networkQueryPlan {
            return networkQueryPlan
        }
        let plan = NetworkRequestQueryPlan(descriptor: fetchDescriptor, context: context)
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

    func applyNetworkFetchDescriptor(
        _ descriptor: WebInspectorFetchDescriptor<NetworkRequest>,
        plan: NetworkRequestQueryPlan,
        requests: [NetworkRequest],
        lookup: (NetworkRequest.ID) -> NetworkRequest?
    ) {
        fetchDescriptor = descriptor
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
        if networkQueryPlan?.requiresQuery == false, sectionBy == nil {
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
            if sectionBy == nil, networkQueryPlan?.requiresQuery == false {
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
            sectionBy == nil,
            "An unfiltered Network change must not have a section descriptor."
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
#if DEBUG
        networkFullMembershipVisitCountForTesting &+= delta.snapshot.itemIDs.count
#endif
        let oldSnapshot = networkSnapshotForDelta
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
        if oldSnapshot != delta.snapshot {
            bumpTopologyRevision()
        }
        guard transactionRelay.hasContinuations,
              let transaction = delta.transaction,
              transaction.hasChanges else {
            return
        }
        transactionRelay.yield(transaction)
    }

    func insertUnfilteredNetworkRequest(_ request: NetworkRequest) {
        precondition(networkQueryState == nil, "An unfiltered Network insert cannot have query state.")
        precondition(
            networkQueryPlan?.requiresQuery == false,
            "An unfiltered Network insert must not require query evaluation."
        )
        precondition(
            sectionBy == nil,
            "An unfiltered Network insert must not have a section descriptor."
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
        if plan.requiresQuery == false, sectionBy == nil {
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
