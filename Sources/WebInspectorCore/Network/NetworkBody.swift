import Foundation
import Observation

package enum NetworkBodyRole: CaseIterable, Hashable, Sendable {
    case request
    case response
}

package enum NetworkBodyKind: Hashable, Sendable {
    case text
    case form
    case binary
}

package enum NetworkBodySyntaxKind: Hashable, Sendable {
    case plainText
    case json
    case html
    case xml
    case css
    case javascript
}

package enum NetworkBodyFetchError: Equatable, Sendable {
    case unavailable
    case decodeFailed
    case unknown(String?)
}

package enum NetworkBodyFetchState: Equatable, Sendable {
    case available
    case fetching
    case loaded
    case failed(NetworkBodyFetchError)
}

package struct NetworkBodyPayload: Equatable, Sendable {
    package var body: String
    package var base64Encoded: Bool
    package var size: Int?
    package var isTruncated: Bool

    package init(
        body: String,
        base64Encoded: Bool,
        size: Int? = nil,
        isTruncated: Bool = false
    ) {
        self.body = body
        self.base64Encoded = base64Encoded
        self.size = size
        self.isTruncated = isTruncated
    }
}

@MainActor
@Observable
package final class NetworkBody {
    package let role: NetworkBodyRole
    package var kind: NetworkBodyKind {
        didSet {
            refreshTextRepresentation()
        }
    }
    package private(set) var full: String? {
        didSet {
            refreshTextRepresentation()
        }
    }
    package private(set) var size: Int?
    package private(set) var isBase64Encoded: Bool {
        didSet {
            refreshTextRepresentation()
        }
    }
    package private(set) var isTruncated: Bool
    package var fetchState: NetworkBodyFetchState
    package private(set) var sourceSyntaxKind: NetworkBodySyntaxKind {
        didSet {
            refreshTextRepresentation()
        }
    }
    package private(set) var textRepresentation: String?
    package private(set) var textRepresentationSyntaxKind: NetworkBodySyntaxKind

    package init(
        role: NetworkBodyRole,
        kind: NetworkBodyKind = .text,
        full: String? = nil,
        size: Int? = nil,
        isBase64Encoded: Bool = false,
        isTruncated: Bool = false,
        sourceSyntaxKind: NetworkBodySyntaxKind = .plainText,
        fetchState: NetworkBodyFetchState? = nil
    ) {
        self.role = role
        self.kind = kind
        self.full = full
        self.size = size ?? full?.utf8.count
        self.isBase64Encoded = isBase64Encoded
        self.isTruncated = isTruncated
        self.fetchState = fetchState ?? (full == nil ? .available : .loaded)
        self.sourceSyntaxKind = sourceSyntaxKind
        self.textRepresentation = nil
        self.textRepresentationSyntaxKind = .plainText
        refreshTextRepresentation()
    }

    package var needsFetch: Bool {
        switch fetchState {
        case .available, .failed:
            full == nil
        case .fetching, .loaded:
            false
        }
    }

    package func updateHints(kind: NetworkBodyKind, sourceSyntaxKind: NetworkBodySyntaxKind) {
        self.kind = kind
        self.sourceSyntaxKind = sourceSyntaxKind
    }

    package func markFetching() {
        fetchState = .fetching
    }

    package func markFailed(_ error: NetworkBodyFetchError) {
        fetchState = .failed(error)
    }

    package func apply(_ payload: NetworkBodyPayload) {
        full = payload.body
        isBase64Encoded = payload.base64Encoded
        isTruncated = payload.isTruncated
        size = payload.size ?? payload.body.utf8.count
        fetchState = .loaded
    }

    package static func makeRequestBody(for request: NetworkRequestPayload) -> NetworkBody? {
        guard let postData = request.postData else {
            return nil
        }
        let hints = bodyHints(
            mimeType: nil,
            headers: request.headers,
            url: request.url,
            role: .request
        )
        return NetworkBody(
            role: .request,
            kind: hints.kind,
            full: postData,
            size: postData.utf8.count,
            sourceSyntaxKind: hints.syntaxKind,
            fetchState: .loaded
        )
    }

    package static func makeResponseBody(for response: NetworkResponsePayload) -> NetworkBody {
        let hints = bodyHints(
            mimeType: response.mimeType,
            headers: response.headers,
            url: response.url,
            role: .response
        )
        return NetworkBody(
            role: .response,
            kind: hints.kind,
            sourceSyntaxKind: hints.syntaxKind,
            fetchState: .available
        )
    }

    package static func bodyHints(
        mimeType: String?,
        headers: [String: String],
        url: String,
        role: NetworkBodyRole
    ) -> (kind: NetworkBodyKind, syntaxKind: NetworkBodySyntaxKind) {
        let contentType = (mimeType ?? headerValue(named: "content-type", in: headers) ?? "")
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).lowercased() } ?? ""

        if role == .request && contentType == "application/x-www-form-urlencoded" {
            return (.form, .plainText)
        }
        if contentType.contains("json") {
            return (.text, .json)
        }
        if contentType == "text/html" || contentType == "application/xhtml+xml" {
            return (.text, .html)
        }
        if contentType == "text/xml" || contentType == "application/xml" || contentType.hasSuffix("+xml") {
            return (.text, .xml)
        }
        if contentType == "text/css" {
            return (.text, .css)
        }
        if contentType == "text/javascript" || contentType == "application/javascript" || contentType == "application/ecmascript" {
            return (.text, .javascript)
        }
        if contentType.hasPrefix("text/") || contentType.isEmpty {
            return (.text, syntaxKind(forPathExtensionIn: url))
        }
        return (.binary, .plainText)
    }

    private static func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func syntaxKind(forPathExtensionIn url: String) -> NetworkBodySyntaxKind {
        switch URL(string: url)?.pathExtension.lowercased() {
        case "json":
            .json
        case "html", "htm":
            .html
        case "xml", "svg":
            .xml
        case "css":
            .css
        case "js", "mjs", "cjs":
            .javascript
        default:
            .plainText
        }
    }

    private func refreshTextRepresentation() {
        let contentText = decodedContentText()
        let formText = kind == .form ? formattedURLEncodedFormText(from: contentText) : nil
        let prettyJSON = formText == nil ? prettyPrintedJSON(from: contentText) : nil
        let displayText = formText ?? prettyJSON ?? (kind == .binary ? nil : contentText)
        let syntaxKind: NetworkBodySyntaxKind
        if kind == .binary || kind == .form {
            syntaxKind = .plainText
        } else if prettyJSON != nil {
            syntaxKind = .json
        } else {
            syntaxKind = sourceSyntaxKind
        }

        if textRepresentation != displayText {
            textRepresentation = displayText
        }
        if textRepresentationSyntaxKind != syntaxKind {
            textRepresentationSyntaxKind = syntaxKind
        }
    }

    private func decodedContentText() -> String? {
        guard let full else {
            return nil
        }
        guard kind != .binary else {
            return isBase64Encoded ? nil : full
        }
        guard isBase64Encoded else {
            return full
        }
        guard let data = Data(base64Encoded: full) else {
            return nil
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func formattedURLEncodedFormText(from text: String?) -> String? {
        guard let text, text.isEmpty == false, text.contains("=") else {
            return nil
        }

        var lines: [String] = []
        for pair in text.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.isEmpty == false else {
                continue
            }
            guard let name = decodeFormComponent(String(parts[0])) else {
                return nil
            }
            let value: String
            if parts.count > 1 {
                guard let decodedValue = decodeFormComponent(String(parts[1])) else {
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

    private func decodeFormComponent(_ component: String) -> String? {
        component
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding
    }

    private func prettyPrintedJSON(from text: String?) -> String? {
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
}
