import Foundation

struct WINetworkBodyPreviewData {
    let text: String?
    let jsonNodes: [WINetworkJSONNode]?
}

extension WINetworkBody {
    var previewData: WINetworkBodyPreviewData {
        let decoded = decodedPreviewText
        let text = decoded ?? full ?? preview ?? summary
        let jsonNodes = decoded.flatMap(WINetworkJSONNode.nodes(from:))
        return WINetworkBodyPreviewData(text: text, jsonNodes: jsonNodes)
    }

    var canFetchBody: Bool {
        guard let reference, !reference.isEmpty else {
            return false
        }
        return true
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
