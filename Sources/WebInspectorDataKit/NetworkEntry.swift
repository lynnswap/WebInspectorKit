import Foundation
import Observation
import WebInspectorProxyKit

/// One logical Network list item with its requests in canonical chronology.
@Observable
public final class NetworkEntry: WebInspectorPersistentModel {
    /// Stable identity assigned by the canonical Network owner.
    public struct ID: WebInspectorPersistentIdentifier {
        public typealias Model = NetworkEntry

        package let storage: CanonicalNetworkEntryIDStorage

        package init(canonical storage: CanonicalNetworkEntryIDStorage) {
            self.storage = storage
        }
    }

    /// Immutable fields evaluated by generic fetch descriptors.
    public struct QueryValue: Identifiable, Sendable {
        /// The entry identity.
        public let id: ID

        /// The earliest protocol timestamp among the entry's requests.
        public let startedAt: Double?

        /// The canonical insertion ordinal used when no timestamp is available.
        public let insertionOrdinal: UInt64

        /// Member request methods in the same order as the entry membership.
        public let methods: [String]

        /// Resource categories represented by the entry.
        public let resourceCategories: Set<NetworkRequest.ResourceCategory>

        /// Member search projections in the same order as the entry membership.
        public let searchTexts: [String]

        package init(
            id: ID,
            startedAt: Double?,
            insertionOrdinal: UInt64,
            methods: [String],
            resourceCategories: Set<NetworkRequest.ResourceCategory>,
            searchTexts: [String]
        ) {
            precondition(
                methods.count == searchTexts.count,
                "A NetworkEntry query must keep member methods and search text aligned."
            )
            self.id = id
            self.startedAt = startedAt
            self.insertionOrdinal = insertionOrdinal
            self.methods = methods
            self.resourceCategories = resourceCategories
            self.searchTexts = searchTexts
        }
    }

    /// Aggregate loading state for all requests in the entry.
    public enum Lifecycle: Equatable, Sendable {
        case loading
        case finished
        case failed
    }

    /// Highest status severity among the entry's requests.
    public enum StatusSeverity: Int, Comparable, Hashable, Sendable {
        case neutral
        case success
        case notice
        case warning
        case error

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The stable entry identity.
    public let id: ID

    /// The request that supplies the entry's primary display metadata.
    public private(set) var primaryRequestID: NetworkRequest.ID

    /// Member requests in canonical chronology.
    public private(set) var requestIDs: [NetworkRequest.ID]

    /// The primary request URL.
    public private(set) var url: String

    /// The primary request method.
    public private(set) var method: String

    /// The primary request resource type.
    public private(set) var resourceType: Network.ResourceType?

    /// The primary response MIME type.
    public private(set) var mimeType: String?

    /// The primary response status code.
    public private(set) var statusCode: Int?

    /// The highest status severity among all members.
    public private(set) var statusSeverity: StatusSeverity

    /// Total decoded bytes across all members.
    public private(set) var decodedDataLength: Int

    /// Total encoded bytes across all members.
    public private(set) var encodedDataLength: Int

    /// Aggregate loading state across all members.
    public private(set) var lifecycle: Lifecycle

    @ObservationIgnored weak var modelContext: WebInspectorModelContext?
    @ObservationIgnored package private(set) var isInvalidated: Bool

    package init(
        canonical record: CanonicalNetworkEntryRecord,
        modelContext: WebInspectorModelContext
    ) {
        id = ID(canonical: record.id)
        let requestIDs = record.requestIDs.map(NetworkRequest.ID.init(canonical:))
        precondition(
            requestIDs.count == record.summary.requestCount,
            "A NetworkEntry summary lost its ordered request membership."
        )
        primaryRequestID = NetworkRequest.ID(
            canonical: record.summary.primaryRequestID
        )
        self.requestIDs = requestIDs
        url = record.summary.url
        method = record.summary.method
        resourceType = record.summary.resourceType.map(
            Network.ResourceType.init(rawValue:)
        )
        mimeType = record.summary.mimeType
        statusCode = record.summary.statusCode
        statusSeverity = Self.statusSeverity(record.summary.statusSeverity)
        decodedDataLength = record.summary.decodedDataLength
        encodedDataLength = record.summary.encodedDataLength
        lifecycle = Self.lifecycle(record.summary.lifecycle)
        self.modelContext = modelContext
        isInvalidated = false
    }

    package func replaceCanonicalRecord(
        _ record: CanonicalNetworkEntryRecord,
        modelContext: WebInspectorModelContext
    ) {
        precondition(
            id == ID(canonical: record.id),
            "A NetworkEntry cannot adopt another canonical identity."
        )
        self.modelContext = modelContext
        isInvalidated = false
        applyCanonicalPatch(
            CanonicalNetworkEntryPatch(
                requestIDs: record.requestIDs,
                summary: record.summary
            )
        )
    }

    package func applyCanonicalPatch(_ patch: CanonicalNetworkEntryPatch) {
        precondition(!isInvalidated, "An invalid NetworkEntry cannot be patched.")
        let requestIDs = patch.requestIDs.map(NetworkRequest.ID.init(canonical:))
        precondition(
            requestIDs.count == patch.summary.requestCount,
            "A NetworkEntry patch lost its ordered request membership."
        )
        primaryRequestID = NetworkRequest.ID(
            canonical: patch.summary.primaryRequestID
        )
        self.requestIDs = requestIDs
        url = patch.summary.url
        method = patch.summary.method
        resourceType = patch.summary.resourceType.map(
            Network.ResourceType.init(rawValue:)
        )
        mimeType = patch.summary.mimeType
        statusCode = patch.summary.statusCode
        statusSeverity = Self.statusSeverity(patch.summary.statusSeverity)
        decodedDataLength = patch.summary.decodedDataLength
        encodedDataLength = patch.summary.encodedDataLength
        lifecycle = Self.lifecycle(patch.summary.lifecycle)
    }

    package func invalidateCanonicalRecord() {
        modelContext = nil
        isInvalidated = true
    }

    private static func lifecycle(
        _ lifecycle: CanonicalNetworkEntryLifecycleSummary
    ) -> Lifecycle {
        switch lifecycle {
        case .loading:
            .loading
        case .finished:
            .finished
        case .failed:
            .failed
        }
    }

    private static func statusSeverity(
        _ severity: CanonicalNetworkEntryStatusSeverity
    ) -> StatusSeverity {
        switch severity {
        case .neutral:
            .neutral
        case .success:
            .success
        case .notice:
            .notice
        case .warning:
            .warning
        case .error:
            .error
        }
    }
}
