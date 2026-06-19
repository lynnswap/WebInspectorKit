#if canImport(UIKit)
import Foundation
import WebInspectorCore

enum NetworkTextPreviewPreparationAction {
    case unavailable
    case active(text: String, syntaxKind: NetworkBody.SyntaxKind)
    case ready(text: String, syntaxKind: NetworkBody.SyntaxKind)
}

enum NetworkTextPreviewResultAction {
    case ignore
    case show(text: String, syntaxKind: NetworkBody.SyntaxKind)
}

@MainActor
final class NetworkTextPreviewCoordinator {
    private var generation = 0
    private var task: Task<Void, Never>?
    private var pendingInput: NetworkTextPreviewInput?
    private var displayedInput: NetworkTextPreviewInput?
    private var displayedOutput: NetworkTextPreviewOutput?

    func preparePreview(
        for body: NetworkBody,
        completion: @escaping @MainActor (NetworkTextPreviewResultAction) -> Void
    ) -> NetworkTextPreviewPreparationAction {
        guard let input = NetworkTextPreviewInput(body: body) else {
            cancel()
            return .unavailable
        }

        if displayedInput == input, let displayedOutput {
            return .ready(text: displayedOutput.text, syntaxKind: displayedOutput.syntaxKind)
        }
        if pendingInput == input {
            return .active(text: input.text, syntaxKind: input.syntaxKind)
        }
        guard input.requiresPreparation else {
            cancelPending()
            let output = input.rawOutput
            displayedInput = input
            displayedOutput = output
            return .ready(text: output.text, syntaxKind: output.syntaxKind)
        }

        startPreparation(for: input, completion: completion)
        return .active(text: input.text, syntaxKind: input.syntaxKind)
    }

    func suspendPreparation() {
        cancelPending()
    }

    func cancel() {
        cancelPending()
        displayedInput = nil
        displayedOutput = nil
    }

#if DEBUG
    var hasActivePreparationForTesting: Bool {
        task != nil
    }

    var activePreparationBodyIDForTesting: ObjectIdentifier? {
        pendingInput?.bodyID
    }

    func waitUntilPreparationFinishedForTesting() async {
        while let task {
            await task.value
        }
    }
#endif

    private func startPreparation(
        for input: NetworkTextPreviewInput,
        completion: @escaping @MainActor (NetworkTextPreviewResultAction) -> Void
    ) {
        cancelPending()
        displayedInput = nil
        displayedOutput = nil
        pendingInput = input
        generation += 1
        let generation = generation

        let worker = Task.detached(priority: .utility) {
            try NetworkTextPreviewOutput.prepared(from: input)
        }
        task = Task { @MainActor [worker, completion] in
            let output: NetworkTextPreviewOutput?
            do {
                output = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
            } catch is CancellationError {
                return
            } catch {
                output = nil
            }
            guard Task.isCancelled == false else {
                return
            }
            completion(consume(output: output, input: input, generation: generation))
        }
    }

    private func consume(
        output preparedOutput: NetworkTextPreviewOutput?,
        input: NetworkTextPreviewInput,
        generation: Int
    ) -> NetworkTextPreviewResultAction {
        guard generation == self.generation,
              pendingInput == input else {
            return .ignore
        }
        task = nil
        pendingInput = nil

        let output = preparedOutput ?? input.rawOutput
        displayedInput = input
        displayedOutput = output
        return .show(text: output.text, syntaxKind: output.syntaxKind)
    }

    private func cancelPending() {
        generation += 1
        task?.cancel()
        task = nil
        pendingInput = nil
    }
}

private struct NetworkTextPreviewInput: Equatable, Sendable {
    var bodyID: ObjectIdentifier
    var text: String
    var syntaxKind: NetworkBody.SyntaxKind

    @MainActor
    init?(body: NetworkBody) {
        guard let text = body.textRepresentation else {
            return nil
        }
        self.bodyID = ObjectIdentifier(body)
        self.text = text
        self.syntaxKind = body.textRepresentationSyntaxKind
    }

    var rawOutput: NetworkTextPreviewOutput {
        NetworkTextPreviewOutput(text: text, syntaxKind: syntaxKind)
    }

    var requiresPreparation: Bool {
        syntaxKind == .json || Self.looksLikeJSON(text)
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        guard let firstNonWhitespace = text.first(where: { $0.isWhitespace == false }) else {
            return false
        }
        return firstNonWhitespace == "{" || firstNonWhitespace == "["
    }
}

private struct NetworkTextPreviewOutput: Sendable {
    var text: String
    var syntaxKind: NetworkBody.SyntaxKind

    static func prepared(from input: NetworkTextPreviewInput) throws -> NetworkTextPreviewOutput? {
        guard let prettyJSON = try CancellableJSONPrettyPrinter.prettyPrintedJSON(from: input.text) else {
            return nil
        }
        return NetworkTextPreviewOutput(text: prettyJSON, syntaxKind: .json)
    }
}

private enum CancellableJSONPrettyPrinter {
    static func prettyPrintedJSON(from text: String) throws -> String? {
        var parser = Parser(text: text)
        return try parser.prettyPrintedJSON()
    }

    private struct Parser {
        private static let maximumNestingDepth = 128

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
            guard depth <= Self.maximumNestingDepth else {
                return nil
            }
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
#endif
