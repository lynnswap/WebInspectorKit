import Foundation
import Observation

struct NetworkBodyFormEntryPayload: Decodable {
    let name: String
    let value: String
    let isFile: Bool?
    let fileName: String?
    let size: Int?
}

struct NetworkBodyPayload: Decodable {
    let kind: String
    let encoding: String?
    let size: Int?
    let truncated: Bool
    let preview: String?
    let content: String?
    let summary: String?
    let formEntries: [NetworkBodyFormEntryPayload]?
    let ref: String?
    let handle: AnyObject?

    private enum CodingKeys: String, CodingKey {
        case kind
        case encoding
        case size
        case truncated
        case preview
        case content
        case summary
        case formEntries
        case ref
        case handle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "other"
        encoding = try container.decodeIfPresent(String.self, forKey: .encoding)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        formEntries = try container.decodeIfPresent([NetworkBodyFormEntryPayload].self, forKey: .formEntries)
        ref = try container.decodeIfPresent(String.self, forKey: .ref)
        handle = nil
    }

    init(dictionary: NSDictionary) {
        kind = (dictionary["kind"] as? String) ?? "other"
        encoding = dictionary["encoding"] as? String
        if let size = dictionary["size"] as? Int {
            self.size = size
        } else if let size = dictionary["size"] as? NSNumber {
            self.size = size.intValue
        } else {
            self.size = nil
        }
        truncated = (dictionary["truncated"] as? Bool) ?? false
        preview = dictionary["preview"] as? String
        content = dictionary["content"] as? String
        summary = dictionary["summary"] as? String
        if let entries = dictionary["formEntries"] as? [NSDictionary] {
            formEntries = entries.compactMap { entry in
                guard let name = entry["name"] as? String,
                      let value = entry["value"] as? String else {
                    return nil
                }
                return NetworkBodyFormEntryPayload(
                    name: name,
                    value: value,
                    isFile: entry["isFile"] as? Bool,
                    fileName: entry["fileName"] as? String,
                    size: (entry["size"] as? NSNumber)?.intValue
                )
            }
        } else {
            formEntries = nil
        }
        ref = dictionary["ref"] as? String
        handle = dictionary["handle"] as AnyObject?
    }
}

@Observable
public final class NetworkBody {
    public enum Kind: String, Sendable {
        case text
        case form
        case binary
        case other
    }

    public enum FetchError: Equatable, Sendable {
        case unavailable
        case decodeFailed
        case unknown
    }

    public enum FetchState: Equatable {
        case inline
        case fetching
        case full
        case failed(FetchError)
    }

    public enum Role: CaseIterable {
        case request
        case response
    }

    public struct FormEntry: Sendable {
        public let name: String
        public let value: String
        public let isFile: Bool
        public let fileName: String?

        init(name: String, value: String, isFile: Bool, fileName: String?) {
            self.name = name
            self.value = value
            self.isFile = isFile
            self.fileName = fileName
        }

        init?(dictionary: NSDictionary) {
            let name = dictionary["name"] as? String ?? ""
            let value = dictionary["value"] as? String ?? ""
            if name.isEmpty && value.isEmpty {
                return nil
            }
            let isFile = dictionary["isFile"] as? Bool ?? false
            let fileName = dictionary["fileName"] as? String
            self.init(name: name, value: value, isFile: isFile, fileName: fileName)
        }

        init(payload: NetworkBodyFormEntryPayload) {
            self.init(
                name: payload.name,
                value: payload.value,
                isFile: payload.isFile ?? false,
                fileName: payload.fileName
            )
        }
    }

    public var kind: Kind
    public var preview: String?
    public var full: String?
    public var size: Int?
    public var isBase64Encoded: Bool
    public var isTruncated: Bool
    public var summary: String?
    public var reference: String?
    public var handle: AnyObject?
    public var formEntries: [FormEntry]
    public var fetchState: FetchState
    public var role: Role

    public init(
        kind: Kind = .text,
        preview: String?,
        full: String? = nil,
        size: Int? = nil,
        isBase64Encoded: Bool = false,
        isTruncated: Bool = false,
        summary: String? = nil,
        reference: String? = nil,
        handle: AnyObject? = nil,
        formEntries: [FormEntry] = [],
        fetchState: FetchState? = nil,
        role: Role = .response
    ) {
        let resolvedFull = full ?? (isTruncated ? nil : preview)
        let resolvedSize = size ?? (resolvedFull?.count ?? preview?.count)
        self.kind = kind
        self.preview = preview
        self.full = resolvedFull
        self.size = resolvedSize
        self.isBase64Encoded = isBase64Encoded
        self.isTruncated = isTruncated
        self.summary = summary
        self.reference = reference
        self.handle = handle
        self.formEntries = formEntries
        self.role = role
        let hasReference = reference?.isEmpty == false
        let hasHandle = handle != nil
        if let fetchState {
            self.fetchState = fetchState
        } else if resolvedFull == nil && (hasReference || hasHandle) {
            self.fetchState = .inline
        } else {
            self.fetchState = .full
        }
    }

    convenience init?(dictionary: NSDictionary) {
        let rawKind = (dictionary["kind"] as? String)?.lowercased() ?? ""
        let kind = Kind(rawValue: rawKind) ?? .other
        let preview = dictionary["preview"] as? String
            ?? dictionary["body"] as? String
            ?? dictionary["inlineBody"] as? String
        let storedBody = dictionary["content"] as? String
            ?? dictionary["storageBody"] as? String
            ?? dictionary["fullBody"] as? String
        let encoding = (dictionary["encoding"] as? String)?.lowercased() ?? ""
        let base64 = dictionary["base64Encoded"] as? Bool
            ?? dictionary["base64encoded"] as? Bool
            ?? (encoding == "base64")
        let truncated = dictionary["truncated"] as? Bool ?? false
        let rawSize = dictionary["size"]
        let size = rawSize as? Int ?? (rawSize as? NSNumber)?.intValue
        let summary = dictionary["summary"] as? String
        let reference = dictionary["ref"] as? String
        let handle = dictionary["handle"] as AnyObject?
        let formEntries = (dictionary["formEntries"] as? [NSDictionary] ?? [])
            .compactMap(FormEntry.init(dictionary:))

        self.init(
            kind: kind,
            preview: preview,
            full: storedBody,
            size: size,
            isBase64Encoded: base64,
            isTruncated: truncated,
            summary: summary,
            reference: reference,
            handle: handle,
            formEntries: formEntries
        )
    }

    static func decode(from value: Any?) -> NetworkBody? {
        if let payload = value as? NetworkBodyPayload {
            return NetworkBody.from(payload: payload, role: .response)
        }
        if let dictionary = value as? NSDictionary {
            return NetworkBody(dictionary: dictionary)
        }
        if let string = value as? String {
            return NetworkBody(
                kind: .text,
                preview: string,
                full: string,
                size: string.count,
                isBase64Encoded: false,
                isTruncated: false
            )
        }
        return nil
    }

    static func from(payload: NetworkBodyPayload, role: Role) -> NetworkBody {
        let kind = Kind(rawValue: payload.kind.lowercased()) ?? .other
        let encoding = (payload.encoding ?? "").lowercased()
        let isBase64 = encoding == "base64"
        let entries = payload.formEntries?.map(FormEntry.init(payload:)) ?? []
        return NetworkBody(
            kind: kind,
            preview: payload.preview,
            full: payload.content,
            size: payload.size,
            isBase64Encoded: isBase64,
            isTruncated: payload.truncated,
            summary: payload.summary,
            reference: payload.ref,
            handle: payload.handle,
            formEntries: entries,
            role: role
        )
    }

    public var displayText: String? {
        full ?? preview ?? summary
    }

    public var isFetching: Bool {
        if case .fetching = fetchState {
            return true
        }
        return false
    }

    public func markFetching() {
        fetchState = .fetching
    }

    public func markFailed(_ error: FetchError) {
        fetchState = .failed(error)
    }

    public func applyFullBody(
        _ fullBody: String,
        isBase64Encoded: Bool,
        isTruncated: Bool,
        size: Int?
    ) {
        full = fullBody
        preview = preview ?? fullBody
        self.isBase64Encoded = isBase64Encoded
        self.isTruncated = isTruncated
        self.size = size ?? fullBody.count
        fetchState = .full
    }
}
