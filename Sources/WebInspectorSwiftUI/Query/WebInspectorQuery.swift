import Foundation
import SwiftUI
import WebInspectorDataKit

/// A SwiftUI dynamic property that fetches persistent inspector models.
///
/// The wrapped value is the last successful result. Fetch and binding errors
/// are available from the backing property; there is intentionally no
/// projected loading/ready phase.
@MainActor
@propertyWrapper
public struct WebInspectorQuery<Model>: @MainActor DynamicProperty
where Model: WebInspectorPersistentModel {
    @Environment(\.webInspectorModelContainer)
    private var container
    @State private var storage: WebInspectorQueryStorage<Model>

    private let descriptor: WebInspectorFetchDescriptor<Model>
    private let semanticIdentity: WebInspectorQuerySemanticIdentity

    public init(
        filter: Predicate<Model.QueryValue>? = nil,
        sort: [SortDescriptor<Model.QueryValue>] = []
    ) {
        self.init(
            WebInspectorFetchDescriptor(predicate: filter, sortBy: sort)
        )
    }

    public init<ID: Hashable>(
        filter: Predicate<Model.QueryValue>? = nil,
        sort: [SortDescriptor<Model.QueryValue>] = [],
        id: ID
    ) {
        self.init(
            WebInspectorFetchDescriptor(predicate: filter, sortBy: sort),
            id: id
        )
    }

    public init(_ descriptor: WebInspectorFetchDescriptor<Model>) {
        self.descriptor = descriptor
        self.semanticIdentity = .fixed
        _storage = State(wrappedValue: WebInspectorQueryStorage())
    }

    public init<ID: Hashable>(
        _ descriptor: WebInspectorFetchDescriptor<Model>,
        id: ID
    ) {
        self.descriptor = descriptor
        self.semanticIdentity = .dynamic(
            type: ObjectIdentifier(ID.self),
            value: AnyHashable(id)
        )
        _storage = State(wrappedValue: WebInspectorQueryStorage())
    }

    public var wrappedValue: [Model] {
        storage.fetchedObjects
    }

    public var fetchError: (any Error)? {
        storage.fetchError
    }

    public var modelContext: WebInspectorModelContext? {
        storage.modelContext
    }

    public mutating func update() {
        storage.submit(
            container: container,
            descriptor: descriptor,
            semanticIdentity: semanticIdentity
        )
    }
}

/// An error raised while binding a SwiftUI query to its model context.
public enum WebInspectorQueryError: Error, Equatable, Sendable {
    /// No model container is installed in the view environment.
    case missingModelContext
}

@MainActor
enum WebInspectorQuerySemanticIdentity: Equatable {
    case fixed
    case dynamic(type: ObjectIdentifier, value: AnyHashable)
}
