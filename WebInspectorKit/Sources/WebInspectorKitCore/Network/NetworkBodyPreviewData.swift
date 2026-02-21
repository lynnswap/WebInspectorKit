import Foundation

public struct NetworkBodyPreviewData: Sendable {
    public let text: String?
    public let jsonNodes: [NetworkJSONNode]?

    public init(text: String?, jsonNodes: [NetworkJSONNode]?) {
        self.text = text
        self.jsonNodes = jsonNodes
    }
}

extension NetworkBody {
    public var previewData: NetworkBodyPreviewData {
        let decoded = decodedPreviewText
        let text = decoded ?? full ?? preview ?? summary
        let jsonNodes = decoded.flatMap(NetworkJSONNode.nodes(from:))
        return NetworkBodyPreviewData(text: text, jsonNodes: jsonNodes)
    }

    public var canFetchBody: Bool {
        if let reference, !reference.isEmpty {
            return true
        }
        return handle != nil
    }

    private var decodedPreviewText: String? {
        guard kind != .binary else {
            return nil
        }
        guard let candidate = full ?? preview else {
            return nil
        }
        guard isBase64Encoded else {
            return candidate
        }
        guard let data = Data(base64Encoded: candidate) else {
            return nil
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }
}
