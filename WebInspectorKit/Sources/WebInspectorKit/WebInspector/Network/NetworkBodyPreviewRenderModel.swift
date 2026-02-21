import Foundation
import WebInspectorKitCore

struct NetworkBodyPreviewRenderModel: Sendable {
    enum Mode: Int, Sendable, CaseIterable {
        case text = 0
        case objectTree = 1
    }

    struct Input: Sendable {
        let kind: NetworkBody.Kind
        let full: String?
        let preview: String?
        let summary: String?
        let isBase64Encoded: Bool
        let unavailableText: String

        init(body: NetworkBody, unavailableText: String) {
            kind = body.kind
            full = body.full
            preview = body.preview
            summary = body.summary
            isBase64Encoded = body.isBase64Encoded
            self.unavailableText = unavailableText
        }
    }

    let text: String
    let objectTreeNodes: [NetworkJSONNode]
    let availableModes: [Mode]
    let preferredMode: Mode

    static func make(from input: Input) -> NetworkBodyPreviewRenderModel {
        let decoded = decodedText(from: input)
        let contentText = decoded ?? input.full ?? input.preview
        let displaySource = contentText ?? input.summary
        let objectTreeNodes = contentText.flatMap(NetworkJSONNode.nodes(from:)) ?? []
        let displayText = formattedText(from: contentText) ?? displaySource ?? input.unavailableText

        if objectTreeNodes.isEmpty {
            return NetworkBodyPreviewRenderModel(
                text: displayText,
                objectTreeNodes: [],
                availableModes: [.text],
                preferredMode: .text
            )
        }

        return NetworkBodyPreviewRenderModel(
            text: displayText,
            objectTreeNodes: objectTreeNodes,
            availableModes: [.text, .objectTree],
            preferredMode: .objectTree
        )
    }

    func displayText(
        for fetchState: NetworkBody.FetchState,
        fetchingText: String,
        unavailableText: String
    ) -> String {
        switch fetchState {
        case .fetching:
            return fetchingText
        case .failed(let error):
            let base = text.isEmpty ? unavailableText : text
            return base + "\n\n\(error.localizedDescriptionText)"
        default:
            return text
        }
    }

    private static func decodedText(from input: Input) -> String? {
        guard input.kind != .binary else {
            return nil
        }
        guard let candidate = input.full ?? input.preview else {
            return nil
        }
        guard input.isBase64Encoded else {
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

    private static func formattedText(from sourceText: String?) -> String? {
        guard let sourceText else {
            return nil
        }
        return prettyPrintedJSON(from: sourceText) ?? sourceText
    }

    private static func prettyPrintedJSON(from text: String) -> String? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        guard
            let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted]
            ),
            let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }
        return pretty
    }
}

@MainActor
final class NetworkBodyPreviewRenderGeneration {
    private var currentValue: UInt64 = 0

    func advance() -> UInt64 {
        currentValue &+= 1
        return currentValue
    }

    func shouldApply(_ generation: UInt64) -> Bool {
        generation == currentValue
    }
}
