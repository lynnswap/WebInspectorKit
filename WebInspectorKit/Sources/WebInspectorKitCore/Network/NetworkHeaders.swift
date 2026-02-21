import Foundation

public struct NetworkHeaderField: Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    var normalizedName: String {
        name.lowercased()
    }
}

public struct NetworkHeaders: Hashable, Sequence, Sendable {
    public typealias Element = NetworkHeaderField

    public private(set) var fields: [NetworkHeaderField]

    public init(_ fields: [NetworkHeaderField] = []) {
        self.fields = NetworkHeaders.sort(fields)
    }

    public init(dictionary: [String: String]) {
        self.init(dictionary.map { NetworkHeaderField(name: $0.key, value: $0.value) })
    }

    public var isEmpty: Bool {
        fields.isEmpty
    }

    public subscript(name: String) -> String? {
        let normalized = name.lowercased()
        return fields.first { $0.normalizedName == normalized }?.value
    }

    public mutating func append(_ field: NetworkHeaderField) {
        fields.append(field)
        fields = Self.sort(fields)
    }

    public func makeIterator() -> IndexingIterator<[NetworkHeaderField]> {
        fields.makeIterator()
    }

    private static func sort(_ fields: [NetworkHeaderField]) -> [NetworkHeaderField] {
        fields.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
