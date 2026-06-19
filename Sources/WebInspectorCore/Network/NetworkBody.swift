import Foundation
import Observation
import WebInspectorTransport

extension NetworkBody {
    package enum Role: CaseIterable, Hashable, Sendable {        case request
        case response
    }
}

extension NetworkBody {
    package enum Kind: Hashable, Sendable {        case text
        case form
        case binary
    }
}

extension NetworkBody {
    package enum SyntaxKind: Hashable, Sendable {        case plainText
        case json
        case html
        case xml
        case css
        case javascript
    }
}

extension NetworkBody {
    package enum FetchError: Equatable, Sendable {        case unavailable
        case decodeFailed
        case unknown(String?)
    }
}

extension NetworkBody {
    package enum Phase: Equatable, Sendable {        case available
        case fetching
        case loaded
        case failed(NetworkBody.FetchError)
    }
}

extension NetworkBody {
    package struct Payload: Equatable, Sendable {        package var body: String
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
}

extension NetworkBody {
    package struct TextPreparation: Sendable {        private let task: Task<Void, Never>

        fileprivate init(task: Task<Void, Never>) {
            self.task = task
        }

        package func wait() async {
            await task.value
        }
    }
}

extension NetworkBody {
    @MainActor
    fileprivate final class TextRepresentationPreparationJob {
        let id: Int
        let generation: Int
        private let worker: Task<NetworkBody.PreparedTextRepresentation.Result?, Error>
        private let completion: Task<Void, Never>

        init(
            id: Int,
            generation: Int,
            worker: Task<NetworkBody.PreparedTextRepresentation.Result?, Error>,
            completion: Task<Void, Never>
        ) {
            self.id = id
            self.generation = generation
            self.worker = worker
            self.completion = completion
        }

        var preparation: NetworkBody.TextPreparation {
            NetworkBody.TextPreparation(task: completion)
        }

        func cancel() {
            worker.cancel()
            completion.cancel()
        }
    }
}

extension NetworkBody {
    @MainActor
    fileprivate final class TextRepresentationPreparationState {        private(set) var generation = 0
        private var preparedGeneration: Int?
        private var job: NetworkBody.TextRepresentationPreparationJob?
        private var nextJobID = 0
        private var isBatchingInvalidation = false
        private var needsInvalidation = false

        var needsPreparation: Bool {
            preparedGeneration != generation
        }

        var currentPreparation: NetworkBody.TextPreparation? {
            job?.preparation
        }

        func withInvalidationBatch(_ updates: () -> Void, invalidate: () -> Void) {
            isBatchingInvalidation = true
            updates()
            isBatchingInvalidation = false

            if needsInvalidation {
                needsInvalidation = false
                invalidate()
            }
        }

        @discardableResult
        func invalidate() -> Bool {
            guard isBatchingInvalidation == false else {
                needsInvalidation = true
                return false
            }
            generation += 1
            preparedGeneration = nil
            cancelPreparation()
            return true
        }

        func markCurrentGenerationPrepared() {
            preparedGeneration = generation
        }

        func makeJobID() -> Int {
            nextJobID += 1
            return nextJobID
        }

        func startPreparation(_ job: NetworkBody.TextRepresentationPreparationJob) {
            self.job = job
        }

        func isCurrent(generation: Int, jobID: Int) -> Bool {
            generation == self.generation && job?.id == jobID
        }

        func finishPreparation(generation: Int, jobID: Int) {
            guard isCurrent(generation: generation, jobID: jobID) else {
                return
            }
            preparedGeneration = generation
            job = nil
        }

        func cancelPreparation() {
            job?.cancel()
            job = nil
        }
    }
}

@MainActor
@Observable
package final class NetworkBody {
    package let role: NetworkBody.Role
    package var kind: NetworkBody.Kind {
        didSet {
            invalidatePreparedTextRepresentation()
        }
    }
    package private(set) var full: String? {
        didSet {
            invalidatePreparedTextRepresentation()
        }
    }
    package private(set) var size: Int?
    package private(set) var isBase64Encoded: Bool {
        didSet {
            invalidatePreparedTextRepresentation()
        }
    }
    package private(set) var isTruncated: Bool
    package var phase: NetworkBody.Phase
    package private(set) var sourceSyntaxKind: NetworkBody.SyntaxKind {
        didSet {
            invalidatePreparedTextRepresentation()
        }
    }
    package private(set) var textRepresentation: String?
    package private(set) var textRepresentationSyntaxKind: NetworkBody.SyntaxKind
    @ObservationIgnored private let textRepresentationPreparation = NetworkBody.TextRepresentationPreparationState()

    package init(
        role: NetworkBody.Role,
        kind: NetworkBody.Kind = .text,
        full: String? = nil,
        size: Int? = nil,
        isBase64Encoded: Bool = false,
        isTruncated: Bool = false,
        sourceSyntaxKind: NetworkBody.SyntaxKind = .plainText,
        phase: NetworkBody.Phase? = nil
    ) {
        self.role = role
        self.kind = kind
        self.full = full
        self.size = size ?? full?.utf8.count
        self.isBase64Encoded = isBase64Encoded
        self.isTruncated = isTruncated
        self.phase = phase ?? (full == nil ? .available : .loaded)
        self.sourceSyntaxKind = sourceSyntaxKind
        self.textRepresentation = nil
        self.textRepresentationSyntaxKind = .plainText
        refreshTextRepresentation()
    }

    isolated deinit {
        textRepresentationPreparation.cancelPreparation()
    }

    package var needsFetch: Bool {
        switch phase {
        case .available:
            full == nil
        case .fetching, .loaded, .failed:
            false
        }
    }

    package func updateHints(kind: NetworkBody.Kind, sourceSyntaxKind: NetworkBody.SyntaxKind) {
        withTextRepresentationInvalidationBatch {
            self.kind = kind
            self.sourceSyntaxKind = sourceSyntaxKind
        }
    }

    package func markFetching() {
        phase = .fetching
    }

    package func markFailed(_ error: NetworkBody.FetchError) {
        phase = .failed(error)
    }

    package func apply(_ payload: NetworkBody.Payload) {
        withTextRepresentationInvalidationBatch {
            full = payload.body
            isBase64Encoded = payload.base64Encoded
            isTruncated = payload.isTruncated
        }
        size = payload.size ?? payload.body.utf8.count
        phase = .loaded
    }

    @discardableResult
    package func prepareTextRepresentation() -> NetworkBody.TextPreparation? {
        guard case .loaded = phase else {
            return nil
        }
        guard textRepresentationPreparation.needsPreparation else {
            return nil
        }
        if let currentPreparation = textRepresentationPreparation.currentPreparation {
            return currentPreparation
        }
        guard let input = preparedTextRepresentationInput() else {
            textRepresentationPreparation.markCurrentGenerationPrepared()
            return nil
        }

        let generation = textRepresentationPreparation.generation
        let jobID = textRepresentationPreparation.makeJobID()
        let worker = Task.detached(priority: .utility) {
            try NetworkBody.PreparedTextRepresentation.make(from: input)
        }
        let completion = Task { @MainActor [weak self, worker] in
            let result: NetworkBody.PreparedTextRepresentation.Result?
            do {
                result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard Task.isCancelled == false else {
                return
            }
            self?.applyPreparedTextRepresentation(result, generation: generation, jobID: jobID)
        }
        let job = NetworkBody.TextRepresentationPreparationJob(
            id: jobID,
            generation: generation,
            worker: worker,
            completion: completion
        )
        textRepresentationPreparation.startPreparation(job)
        return job.preparation
    }

    package func cancelTextRepresentationPreparation() {
        textRepresentationPreparation.cancelPreparation()
    }

    package static func makeRequestBody(for request: NetworkRequest.Payload) -> NetworkBody? {
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
            phase: .loaded
        )
    }

    package static func makeResponseBody(for response: NetworkRequest.Response.Payload) -> NetworkBody {
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
            phase: .available
        )
    }

    package static func bodyHints(
        mimeType: String?,
        headers: [String: String],
        url: String,
        role: NetworkBody.Role
    ) -> (kind: NetworkBody.Kind, syntaxKind: NetworkBody.SyntaxKind) {
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

    private static func syntaxKind(forPathExtensionIn url: String) -> NetworkBody.SyntaxKind {
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

    private func withTextRepresentationInvalidationBatch(_ updates: () -> Void) {
        textRepresentationPreparation.withInvalidationBatch(updates) {
            invalidatePreparedTextRepresentation()
        }
    }

    private func invalidatePreparedTextRepresentation() {
        guard textRepresentationPreparation.invalidate() else {
            return
        }
        refreshTextRepresentation()
    }

    private func refreshTextRepresentation() {
        let contentText = decodedContentText()
        let formText = kind == .form ? formattedURLEncodedFormText(from: contentText) : nil
        let displayText = formText ?? (kind == .binary ? nil : contentText)
        let syntaxKind: NetworkBody.SyntaxKind
        if kind == .binary || kind == .form {
            syntaxKind = .plainText
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

    private func preparedTextRepresentationInput() -> NetworkBody.PreparedTextRepresentation.Input? {
        guard kind != .binary, kind != .form else {
            return nil
        }
        guard let contentText = decodedContentText() else {
            return nil
        }
        let isJSONCandidate = sourceSyntaxKind == .json || Self.looksLikeJSON(contentText)
        guard isJSONCandidate else {
            return nil
        }
        return NetworkBody.PreparedTextRepresentation.Input(text: contentText)
    }

    private func applyPreparedTextRepresentation(
        _ result: NetworkBody.PreparedTextRepresentation.Result?,
        generation: Int,
        jobID: Int
    ) {
        guard textRepresentationPreparation.isCurrent(generation: generation, jobID: jobID) else {
            return
        }
        if let result {
            if textRepresentation != result.text {
                textRepresentation = result.text
            }
            if textRepresentationSyntaxKind != result.syntaxKind {
                textRepresentationSyntaxKind = result.syntaxKind
            }
        }
        textRepresentationPreparation.finishPreparation(generation: generation, jobID: jobID)
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

    private static func looksLikeJSON(_ text: String?) -> Bool {
        guard let firstNonWhitespace = text?.first(where: { $0.isWhitespace == false }) else {
            return false
        }
        return firstNonWhitespace == "{" || firstNonWhitespace == "["
    }
}

extension NetworkBody {
    fileprivate enum PreparedTextRepresentation {
        struct Input: Sendable {
            let text: String
        }

        struct Result: Sendable {
            let text: String
            let syntaxKind: NetworkBody.SyntaxKind
        }

        static func make(from input: Input) throws -> Result? {
            guard let prettyJSON = try CancellableJSONPrettyPrinter.prettyPrintedJSON(from: input.text) else {
                return nil
            }
            return Result(text: prettyJSON, syntaxKind: .json)
        }
    }
}

private enum CancellableJSONPrettyPrinter {
    static func prettyPrintedJSON(from text: String) throws -> String? {
        var parser = Parser(text: text)
        return try parser.prettyPrintedJSON()
    }

    private struct Parser {
        private let text: String
        private var index: String.Index
        private var checkpointCounter = 0

        init(text: String) {
            self.text = text
            self.index = text.startIndex
        }

        mutating func prettyPrintedJSON() throws -> String? {
            try skipWhitespace()
            guard let first = currentCharacter,
                  first == "{" || first == "[" else {
                return nil
            }
            let result = try parseValue(depth: 0)
            try skipWhitespace()
            guard index == text.endIndex else {
                return nil
            }
            return result
        }

        private mutating func parseValue(depth: Int) throws -> String? {
            try skipWhitespace()
            guard let character = currentCharacter else {
                return nil
            }
            switch character {
            case "{":
                return try parseObject(depth: depth)
            case "[":
                return try parseArray(depth: depth)
            case "\"":
                return try parseString()
            case "t":
                return try consumeLiteral("true") ? "true" : nil
            case "f":
                return try consumeLiteral("false") ? "false" : nil
            case "n":
                return try consumeLiteral("null") ? "null" : nil
            case "-":
                return try parseNumber()
            default:
                if isASCIIDigit(character) {
                    return try parseNumber()
                }
                return nil
            }
        }

        private mutating func parseObject(depth: Int) throws -> String? {
            try consumeExpected("{")
            try skipWhitespace()
            if try consumeIfPresent("}") {
                return "{}"
            }

            var members: [String] = []
            while true {
                try skipWhitespace()
                guard currentCharacter == "\"" else {
                    return nil
                }
                guard let key = try parseString() else {
                    return nil
                }
                try skipWhitespace()
                guard try consumeIfPresent(":") else {
                    return nil
                }
                guard let value = try parseValue(depth: depth + 1) else {
                    return nil
                }
                members.append("\(indent(depth + 1))\(key) : \(value)")
                try skipWhitespace()
                if try consumeIfPresent("}") {
                    break
                }
                guard try consumeIfPresent(",") else {
                    return nil
                }
            }
            return "{\n" + members.joined(separator: ",\n") + "\n" + indent(depth) + "}"
        }

        private mutating func parseArray(depth: Int) throws -> String? {
            try consumeExpected("[")
            try skipWhitespace()
            if try consumeIfPresent("]") {
                return "[]"
            }

            var values: [String] = []
            while true {
                guard let value = try parseValue(depth: depth + 1) else {
                    return nil
                }
                values.append("\(indent(depth + 1))\(value)")
                try skipWhitespace()
                if try consumeIfPresent("]") {
                    break
                }
                guard try consumeIfPresent(",") else {
                    return nil
                }
            }
            return "[\n" + values.joined(separator: ",\n") + "\n" + indent(depth) + "]"
        }

        private mutating func parseString() throws -> String? {
            let start = index
            try consumeExpected("\"")
            while let character = currentCharacter {
                try checkpoint()
                advance()
                if character == "\"" {
                    return String(text[start..<index])
                }
                if character == "\\" {
                    guard let escaped = currentCharacter else {
                        return nil
                    }
                    advance()
                    if escaped == "u" {
                        for _ in 0..<4 {
                            guard let scalar = currentCharacter,
                                  isASCIIHexDigit(scalar) else {
                                return nil
                            }
                            advance()
                        }
                    } else if "\"\\/bfnrt".contains(escaped) == false {
                        return nil
                    }
                } else if character.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                    return nil
                }
            }
            return nil
        }

        private mutating func parseNumber() throws -> String? {
            let start = index
            if try consumeIfPresent("-") == false {
                try checkpoint()
            }
            guard let firstDigit = currentCharacter,
                  isASCIIDigit(firstDigit) else {
                return nil
            }
            if firstDigit == "0" {
                advance()
            } else {
                while let character = currentCharacter,
                      isASCIIDigit(character) {
                    try checkpoint()
                    advance()
                }
            }
            if try consumeIfPresent(".") {
                guard let digit = currentCharacter,
                      isASCIIDigit(digit) else {
                    return nil
                }
                while let character = currentCharacter,
                      isASCIIDigit(character) {
                    try checkpoint()
                    advance()
                }
            }
            if let character = currentCharacter,
               character == "e" || character == "E" {
                advance()
                if let sign = currentCharacter,
                   sign == "+" || sign == "-" {
                    advance()
                }
                guard let digit = currentCharacter,
                      isASCIIDigit(digit) else {
                    return nil
                }
                while let character = currentCharacter,
                      isASCIIDigit(character) {
                    try checkpoint()
                    advance()
                }
            }
            return String(text[start..<index])
        }

        private mutating func consumeLiteral(_ literal: String) throws -> Bool {
            for expected in literal {
                try checkpoint()
                guard currentCharacter == expected else {
                    return false
                }
                advance()
            }
            return true
        }

        private mutating func skipWhitespace() throws {
            while let character = currentCharacter,
                  character == " " || character == "\n" || character == "\r" || character == "\t" {
                try checkpoint()
                advance()
            }
        }

        private mutating func consumeExpected(_ expected: Character) throws {
            guard currentCharacter == expected else {
                return
            }
            try checkpoint()
            advance()
        }

        private mutating func consumeIfPresent(_ expected: Character) throws -> Bool {
            guard currentCharacter == expected else {
                return false
            }
            try checkpoint()
            advance()
            return true
        }

        private mutating func checkpoint() throws {
            checkpointCounter += 1
            if checkpointCounter >= 128 {
                checkpointCounter = 0
                try Task.checkCancellation()
            }
        }

        private mutating func advance() {
            index = text.index(after: index)
        }

        private var currentCharacter: Character? {
            index == text.endIndex ? nil : text[index]
        }

        private func indent(_ depth: Int) -> String {
            String(repeating: "  ", count: depth)
        }

        private func isASCIIDigit(_ character: Character) -> Bool {
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first else {
                return false
            }
            return (0x30...0x39).contains(scalar.value)
        }

        private func isASCIIHexDigit(_ character: Character) -> Bool {
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first else {
                return false
            }
            return (0x30...0x39).contains(scalar.value)
                || (0x41...0x46).contains(scalar.value)
                || (0x61...0x66).contains(scalar.value)
        }
    }
}
