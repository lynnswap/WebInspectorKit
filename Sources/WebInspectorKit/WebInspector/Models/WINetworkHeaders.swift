import Foundation

public struct WINetworkHeaderField: Hashable {
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

public struct WINetworkHeaders: Hashable, Sequence {
    public typealias Element = WINetworkHeaderField

    public private(set) var fields: [WINetworkHeaderField]

    public init(_ fields: [WINetworkHeaderField] = []) {
        self.fields = WINetworkHeaders.sort(fields)
    }

    public init(dictionary: [String: String]) {
        self.init(dictionary.map { WINetworkHeaderField(name: $0.key, value: $0.value) })
    }

    public var isEmpty: Bool {
        fields.isEmpty
    }

    public subscript(name: String) -> String? {
        let normalized = name.lowercased()
        return fields.first { $0.normalizedName == normalized }?.value
    }

    public mutating func append(_ field: WINetworkHeaderField) {
        fields.append(field)
        fields = Self.sort(fields)
    }

    public func makeIterator() -> IndexingIterator<[WINetworkHeaderField]> {
        fields.makeIterator()
    }

    private static func sort(_ fields: [WINetworkHeaderField]) -> [WINetworkHeaderField] {
        fields.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
