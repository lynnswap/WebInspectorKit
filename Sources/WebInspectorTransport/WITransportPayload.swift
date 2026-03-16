import Foundation

package protocol WITransportObjectEncodable {
    func wiTransportObject() -> Any?
}

package protocol WITransportObjectDecodable {
    init(wiTransportObject: Any) throws
}

package struct WITransportPayload: @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var _object: Any?
        private var _data: Data?

        init(object: Any? = nil, data: Data? = nil) {
            self._object = object
            self._data = data
        }

        var object: Any? {
            lock.lock()
            defer { lock.unlock() }
            return _object
        }

        var data: Data? {
            lock.lock()
            defer { lock.unlock() }
            return _data
        }

        func updateObject(_ object: Any?) {
            lock.lock()
            _object = object
            lock.unlock()
        }

        func updateData(_ data: Data) {
            lock.lock()
            _data = data
            lock.unlock()
        }
    }

    private let storage: Storage

    private init(storage: Storage) {
        self.storage = storage
    }

    package static func object(_ object: Any?) -> Self {
        Self(storage: Storage(object: transportResolvedValue(object)))
    }

    package static func data(_ data: Data) -> Self {
        Self(storage: Storage(data: data))
    }

    package var object: Any? {
        if let object = storage.object {
            return object
        }

        guard let data = storage.data,
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }

        let resolved = transportResolvedValue(parsed)
        storage.updateObject(resolved)
        return resolved
    }

    package var dictionaryObject: [String: Any]? {
        transportDictionary(from: object)
    }

    package func jsonObject() throws -> Any {
        if let object {
            return object
        }

        guard let data = storage.data else {
            return [:]
        }

        do {
            let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let resolved = transportResolvedValue(parsed)
            storage.updateObject(resolved)
            return resolved ?? NSNull()
        } catch {
            throw WITransportError.invalidCommandEncoding(error.localizedDescription)
        }
    }

    package func jsonData(defaultObject: Any = [:]) -> Data {
        if let data = storage.data {
            return data
        }

        let source = transportResolvedValue(object) ?? defaultObject
        let resolvedSource = source is NSNull ? defaultObject : source
        if JSONSerialization.isValidJSONObject(resolvedSource),
           let encoded = try? JSONSerialization.data(withJSONObject: resolvedSource, options: []) {
            storage.updateData(encoded)
            return encoded
        }

        let fallback = Data("{}".utf8)
        storage.updateData(fallback)
        return fallback
    }

    package func decode<T: Decodable>(
        _ type: T.Type,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        if let object,
           let fastType = T.self as? any WITransportObjectDecodable.Type {
            let decoded = try fastType.init(wiTransportObject: object)
            if let typed = decoded as? T {
                return typed
            }
            throw WITransportError.invalidResponse("Fast-path decode produced an unexpected response type.")
        }

        return try decoder.decode(T.self, from: jsonData())
    }
}

package func transportResolvedValue(_ value: Any?) -> Any? {
    return value
}

package func transportDictionary(from value: Any?) -> [String: Any]? {
    let resolved = transportResolvedValue(value)

    if let dictionary = resolved as? [String: Any] {
        return dictionary
    }

    if let dictionary = resolved as? NSDictionary {
        var mapped: [String: Any] = [:]
        mapped.reserveCapacity(dictionary.count)
        for (rawKey, rawValue) in dictionary {
            guard let key = rawKey as? String else {
                return nil
            }
            mapped[key] = rawValue
        }
        return mapped
    }

    return nil
}

package func transportArray(from value: Any?) -> [Any]? {
    let resolved = transportResolvedValue(value)

    if let array = resolved as? [Any] {
        return array
    }

    if let array = resolved as? NSArray {
        return array.map { $0 }
    }

    return nil
}

package func transportString(from value: Any?) -> String? {
    let resolved = transportResolvedValue(value)

    if resolved is NSNull {
        return nil
    }

    if let string = resolved as? String {
        return string
    }

    if let string = resolved as? NSString {
        return String(string)
    }

    if let number = resolved as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        return number.stringValue
    }

    return nil
}

package func transportBool(from value: Any?) -> Bool? {
    let resolved = transportResolvedValue(value)

    if let boolean = resolved as? Bool {
        return boolean
    }

    if let number = resolved as? NSNumber {
        return number.boolValue
    }

    return nil
}

package func transportDouble(from value: Any?) -> Double? {
    let resolved = transportResolvedValue(value)

    if let double = resolved as? Double {
        return double
    }

    if let number = resolved as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }
        return number.doubleValue
    }

    if let string = resolved as? String {
        return Double(string)
    }

    return nil
}

package func transportInt(from value: Any?) -> Int? {
    guard let double = transportDouble(from: value), double.isFinite else {
        return nil
    }

    let truncated = double.rounded(.towardZero)
    guard truncated == double,
          truncated >= Double(Int.min),
          truncated <= Double(Int.max) else {
        return nil
    }

    return Int(truncated)
}

package func transportStringDictionary(from value: Any?) -> [String: String]? {
    if let dictionary = transportDictionary(from: value) {
        var mapped: [String: String] = [:]
        mapped.reserveCapacity(dictionary.count)
        for (key, value) in dictionary {
            mapped[key] = transportString(from: value) ?? String(describing: value)
        }
        return mapped
    }

    return nil
}

package func transportIsEmptyJSONObject(_ value: Any?) -> Bool {
    guard let resolved = transportResolvedValue(value) else {
        return true
    }

    if resolved is NSNull {
        return true
    }

    if let dictionary = transportDictionary(from: resolved) {
        return dictionary.isEmpty
    }

    return false
}

extension WIEmptyTransportResponse: WITransportObjectDecodable {
    public init(wiTransportObject: Any) throws {
        _ = wiTransportObject
        self.init()
    }
}
