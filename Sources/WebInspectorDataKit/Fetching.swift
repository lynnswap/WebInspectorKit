import Foundation
import Observation

public struct WebInspectorFetchDescriptor<Model: WebInspectorFetchableModel>: Sendable {
    enum Kind: Hashable, Sendable {
        case networkRequests
        case consoleMessages
    }

    let kind: Kind
    public var predicate: Predicate<Model>?
    public var sortBy: [SortDescriptor<Model>]
    public var fetchLimit: Int? {
        didSet {
            Self.validate(fetchLimit: fetchLimit)
        }
    }
    public var fetchOffset: Int {
        didSet {
            Self.validate(fetchOffset: fetchOffset)
        }
    }

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

public final class WebInspectorFetchRequest<Model: WebInspectorFetchableModel> {
    public var predicate: Predicate<Model>?
    public var sortDescriptors: [SortDescriptor<Model>]
    public var fetchLimit: Int? {
        didSet {
            Self.validate(fetchLimit: fetchLimit)
        }
    }
    public var fetchOffset: Int {
        didSet {
            Self.validate(fetchOffset: fetchOffset)
        }
    }

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

public struct WebInspectorFetchSectionID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible, ExpressibleByStringLiteral
{
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public var description: String {
        rawValue
    }

    public static let defaultSection = WebInspectorFetchSectionID(rawValue: "__default")
}

public struct WebInspectorFetchSection<Model: WebInspectorFetchableModel>: Identifiable {
    public var id: WebInspectorFetchSectionID
    public var title: String?
    public var items: [Model]

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

public struct WebInspectorSectionDescriptor<Model: WebInspectorFetchableModel>: Hashable, Sendable {
    let key: WebInspectorSectionKey

    public init(_ keyPath: KeyPath<Model, String>) {
        key = Self.requireKnownSectionKey(for: keyPath)
    }

    public init(_ keyPath: KeyPath<Model, String?>) {
        key = Self.requireKnownSectionKey(for: keyPath)
    }

    public init<Value: RawRepresentable & Hashable & Sendable>(
        _ keyPath: KeyPath<Model, Value>
    ) where Value.RawValue == String {
        key = Self.requireKnownSectionKey(for: keyPath)
    }

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

@Observable
public final class WebInspectorFetchedResults<Model: WebInspectorFetchableModel> {
    public private(set) var fetchDescriptor: WebInspectorFetchDescriptor<Model>
    public private(set) var sectionBy: WebInspectorSectionDescriptor<Model>?
    public private(set) var items: [Model]
    public private(set) var sections: [WebInspectorFetchSection<Model>]
    package private(set) var topologyRevision: Int

    @ObservationIgnored private let transactionRelay = WebInspectorAsyncStreamRelay<
        WebInspectorFetchedResultsTransaction<Model>
    >()
    @ObservationIgnored weak var modelContext: WebInspectorContext?

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

    func refreshTopologyAfterItemMutation(_ item: Model) {
        guard sectionBy != nil,
              items.contains(where: { $0.id == item.id }) else {
            return
        }
        let oldSnapshot = currentSnapshot
        sections = Self.sections(for: items, sectionBy: sectionBy)
        bumpTopologyRevisionIfNeeded(oldSnapshot: oldSnapshot)
        yieldTransaction(oldSnapshot: oldSnapshot, updatedItemIDs: [])
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
