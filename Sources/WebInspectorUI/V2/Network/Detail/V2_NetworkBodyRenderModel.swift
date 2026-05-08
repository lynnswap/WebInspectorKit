#if canImport(UIKit)
import Foundation
import SyntaxEditorUI
import UIKit
import WebInspectorEngine
import WebInspectorRuntime

struct V2_NetworkBodyRenderModel: Sendable {
    enum SyntaxStyle: Equatable, Sendable {
        case highlighted(SyntaxLanguage)
        case plainText
    }

    enum FetchDisplayState: Sendable {
        case normal
        case fetching
        case failed(String)
    }

    struct FormEntry: Sendable {
        let name: String
        let value: String
        let isFile: Bool
        let fileName: String?

        init(_ entry: NetworkBody.FormEntry) {
            name = entry.name
            value = entry.value
            isFile = entry.isFile
            fileName = entry.fileName
        }
    }

    struct Input: Sendable {
        let kind: NetworkBody.Kind?
        let full: String?
        let preview: String?
        let summary: String?
        let isBase64Encoded: Bool
        let formEntries: [FormEntry]
        let fetchDisplayState: FetchDisplayState
        let isURLEncodedForm: Bool
        let syntaxKind: NetworkEntry.BodySyntaxKind
        let unavailableText: String
        let fetchingText: String

        @MainActor
        init(
            entry: NetworkEntry?,
            body: NetworkBody?,
            role: NetworkBody.Role,
            unavailableText: String,
            fetchingText: String
        ) {
            kind = body?.kind
            full = body?.full
            preview = body?.preview
            summary = body?.summary
            isBase64Encoded = body?.isBase64Encoded ?? false
            formEntries = body?.formEntries.map(FormEntry.init) ?? []
            isURLEncodedForm = entry?.isURLEncodedFormBody(for: role) ?? false
            syntaxKind = entry?.bodySyntaxKind(for: role) ?? .plainText
            self.unavailableText = unavailableText
            self.fetchingText = fetchingText

            switch body?.fetchState {
            case .fetching:
                fetchDisplayState = .fetching
            case .failed(let error):
                fetchDisplayState = .failed(error.localizedDescriptionText)
            default:
                fetchDisplayState = .normal
            }
        }
    }

    let text: String
    let syntaxStyle: SyntaxStyle

    static func make(from input: Input) -> V2_NetworkBodyRenderModel {
        if case .fetching = input.fetchDisplayState {
            return V2_NetworkBodyRenderModel(
                text: input.fetchingText,
                syntaxStyle: .plainText
            )
        }

        let decoded = decodedText(from: input)
        let contentText = decoded ?? input.full ?? input.preview
        let formText = formattedFormText(from: input, contentText: contentText)
        let prettyJSON = formText == nil ? prettyPrintedJSON(from: contentText) : nil
        let displayText = formText
            ?? prettyJSON
            ?? contentText
            ?? input.summary
            ?? input.unavailableText

        let text: String
        if case .failed(let errorText) = input.fetchDisplayState {
            text = displayText + "\n\n" + errorText
        } else {
            text = displayText
        }

        return V2_NetworkBodyRenderModel(
            text: text,
            syntaxStyle: syntaxStyle(from: input, contentText: contentText, didPrettyPrintJSON: prettyJSON != nil)
        )
    }
}

extension V2_NetworkBodyRenderModel.SyntaxStyle {
    @MainActor
    var language: SyntaxLanguage {
        switch self {
        case .highlighted(let language):
            language
        case .plainText:
            .json
        }
    }

    @MainActor
    var colorTheme: SyntaxEditorColorTheme {
        switch self {
        case .highlighted:
            .xcode
        case .plainText:
            .webInspectorPlainText
        }
    }
}

@MainActor
extension SyntaxEditorColorTheme {
    static let webInspectorPlainText = SyntaxEditorColorTheme(
        baseForeground: .label,
        bracketBackground: .clear,
        comment: .label,
        string: .label,
        keyword: .label,
        number: .label,
        function: .label,
        type: .label,
        constant: .label,
        variable: .label,
        punctuation: .label
    )
}

private extension V2_NetworkBodyRenderModel {
    static func decodedText(from input: Input) -> String? {
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

    static func formattedFormText(from input: Input, contentText: String?) -> String? {
        guard input.kind == .form || input.isURLEncodedForm else {
            return nil
        }
        if input.formEntries.isEmpty == false {
            return input.formEntries.map(formEntryLine).joined(separator: "\n")
        }
        guard let contentText else {
            return nil
        }
        return formattedURLEncodedFormText(from: contentText)
    }

    static func formEntryLine(_ entry: FormEntry) -> String {
        let value: String
        if entry.isFile, let fileName = entry.fileName, fileName.isEmpty == false {
            value = "<file \(fileName)>"
        } else {
            value = entry.value
        }
        return "\(entry.name)=\(value)"
    }

    static func formattedURLEncodedFormText(from text: String) -> String? {
        guard text.isEmpty == false, text.contains("=") else {
            return nil
        }

        var lines: [String] = []
        for pair in text.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.isEmpty == false else {
                continue
            }
            guard let name = decodedFormComponent(String(parts[0])) else {
                return nil
            }
            let value: String
            if parts.count > 1 {
                guard let decodedValue = decodedFormComponent(String(parts[1])) else {
                    return nil
                }
                value = decodedValue
            } else {
                value = ""
            }
            lines.append("\(name)=\(value)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func decodedFormComponent(_ component: String) -> String? {
        component
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding
    }

    static func prettyPrintedJSON(from text: String?) -> String? {
        guard let text, let data = text.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        guard JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        guard
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
            let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }
        return pretty
    }

    static func syntaxStyle(
        from input: Input,
        contentText: String?,
        didPrettyPrintJSON: Bool
    ) -> V2_NetworkBodyRenderModel.SyntaxStyle {
        if input.kind == .form || input.isURLEncodedForm {
            return .plainText
        }
        if didPrettyPrintJSON {
            return .highlighted(.json)
        }
        if contentText.flatMap(prettyPrintedJSON(from:)) != nil {
            return .highlighted(.json)
        }
        return input.syntaxKind.syntaxStyle
    }
}

private extension NetworkEntry.BodySyntaxKind {
    var syntaxStyle: V2_NetworkBodyRenderModel.SyntaxStyle {
        switch self {
        case .plainText:
            .plainText
        case .json:
            .highlighted(.json)
        case .html:
            .highlighted(.html)
        case .xml:
            .highlighted(.xml)
        case .css:
            .highlighted(.css)
        case .javascript:
            .highlighted(.javascript)
        }
    }
}
#endif
