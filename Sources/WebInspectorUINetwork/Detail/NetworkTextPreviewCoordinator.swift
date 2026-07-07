#if canImport(UIKit)
import WebInspectorUIBase
import Foundation
import WebInspectorDataKit

package enum NetworkTextPreviewPreparationAction {
    case unavailable
    case active(text: String, syntaxKind: NetworkBody.SyntaxKind)
    case ready(text: String, syntaxKind: NetworkBody.SyntaxKind)
}

package enum NetworkTextPreviewResultAction {
    case ignore
    case show(text: String, syntaxKind: NetworkBody.SyntaxKind)
}

@MainActor
package final class NetworkTextPreviewCoordinator {
    private var generation = 0
    private var task: Task<Void, Never>?
    private var pendingInput: NetworkTextPreviewInput?
    private var displayedInput: NetworkTextPreviewInput?
    private var displayedOutput: NetworkTextPreviewOutput?

    package init() {}

    package func preparePreview(
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

    package func suspendPreparation() {
        cancelPending()
    }

    package func cancel() {
        cancelPending()
        displayedInput = nil
        displayedOutput = nil
    }

#if DEBUG
    package var hasActivePreparationForTesting: Bool {
        task != nil
    }

    package var activePreparationBodyIDForTesting: ObjectIdentifier? {
        pendingInput?.bodyID
    }

    package func waitUntilPreparationFinishedForTesting() async {
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
        guard let firstNonWhitespace = text.unicodeScalars.first(where: { scalar in
            scalar.value != 0x20
                && scalar.value != 0x0A
                && scalar.value != 0x0D
                && scalar.value != 0x09
        }) else {
            return false
        }
        return firstNonWhitespace.value == 0x7B || firstNonWhitespace.value == 0x5B
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

        private let scalars: String.UnicodeScalarView
        private var index: String.UnicodeScalarView.Index
        private var checkpointCounter = 0

        init(text: String) {
            self.scalars = text.unicodeScalars
            self.index = scalars.startIndex
        }

        mutating func prettyPrintedJSON() throws -> String? {
            try skipWhitespace()
            guard let first = currentScalar,
                  first.value == 0x7B || first.value == 0x5B else {
                return nil
            }
            let result = try parseValue(depth: 0)
            try skipWhitespace()
            guard index == scalars.endIndex else {
                return nil
            }
            return result
        }

        private mutating func parseValue(depth: Int) throws -> String? {
            guard depth <= Self.maximumNestingDepth else {
                return nil
            }
            try skipWhitespace()
            guard let scalar = currentScalar else {
                return nil
            }
            switch scalar.value {
            case 0x7B:
                return try parseObject(depth: depth)
            case 0x5B:
                return try parseArray(depth: depth)
            case 0x22:
                return try parseString()
            case 0x74:
                return try consumeLiteral("true") ? "true" : nil
            case 0x66:
                return try consumeLiteral("false") ? "false" : nil
            case 0x6E:
                return try consumeLiteral("null") ? "null" : nil
            case 0x2D:
                return try parseNumber()
            default:
                if isASCIIDigit(scalar) {
                    return try parseNumber()
                }
                return nil
            }
        }

        private mutating func parseObject(depth: Int) throws -> String? {
            try consumeExpected(0x7B)
            try skipWhitespace()
            if try consumeIfPresent(0x7D) {
                return "{}"
            }

            var members: [String] = []
            while true {
                try skipWhitespace()
                guard currentScalar?.value == 0x22 else {
                    return nil
                }
                guard let key = try parseString() else {
                    return nil
                }
                try skipWhitespace()
                guard try consumeIfPresent(0x3A) else {
                    return nil
                }
                guard let value = try parseValue(depth: depth + 1) else {
                    return nil
                }
                members.append("\(indent(depth + 1))\(key) : \(value)")
                try skipWhitespace()
                if try consumeIfPresent(0x7D) {
                    break
                }
                guard try consumeIfPresent(0x2C) else {
                    return nil
                }
            }
            return "{\n" + members.joined(separator: ",\n") + "\n" + indent(depth) + "}"
        }

        private mutating func parseArray(depth: Int) throws -> String? {
            try consumeExpected(0x5B)
            try skipWhitespace()
            if try consumeIfPresent(0x5D) {
                return "[]"
            }

            var values: [String] = []
            while true {
                guard let value = try parseValue(depth: depth + 1) else {
                    return nil
                }
                values.append("\(indent(depth + 1))\(value)")
                try skipWhitespace()
                if try consumeIfPresent(0x5D) {
                    break
                }
                guard try consumeIfPresent(0x2C) else {
                    return nil
                }
            }
            return "[\n" + values.joined(separator: ",\n") + "\n" + indent(depth) + "]"
        }

        private mutating func parseString() throws -> String? {
            let start = index
            try consumeExpected(0x22)
            while let scalar = currentScalar {
                try checkpoint()
                advance()
                if scalar.value == 0x22 {
                    return String(scalars[start..<index])
                }
                if scalar.value == 0x5C {
                    guard let escaped = currentScalar else {
                        return nil
                    }
                    advance()
                    if escaped.value == 0x75 {
                        for _ in 0..<4 {
                            guard let scalar = currentScalar,
                                  isASCIIHexDigit(scalar) else {
                                return nil
                            }
                            advance()
                        }
                    } else if isJSONEscapedCharacter(escaped) == false {
                        return nil
                    }
                } else if scalar.value < 0x20 {
                    return nil
                }
            }
            return nil
        }

        private mutating func parseNumber() throws -> String? {
            let start = index
            if try consumeIfPresent(0x2D) == false {
                try checkpoint()
            }
            guard let firstDigit = currentScalar,
                  isASCIIDigit(firstDigit) else {
                return nil
            }
            if firstDigit.value == 0x30 {
                advance()
            } else {
                while let scalar = currentScalar,
                      isASCIIDigit(scalar) {
                    try checkpoint()
                    advance()
                }
            }
            if try consumeIfPresent(0x2E) {
                guard let digit = currentScalar,
                      isASCIIDigit(digit) else {
                    return nil
                }
                while let scalar = currentScalar,
                      isASCIIDigit(scalar) {
                    try checkpoint()
                    advance()
                }
            }
            if let scalar = currentScalar,
               scalar.value == 0x65 || scalar.value == 0x45 {
                advance()
                if let sign = currentScalar,
                   sign.value == 0x2B || sign.value == 0x2D {
                    advance()
                }
                guard let digit = currentScalar,
                      isASCIIDigit(digit) else {
                    return nil
                }
                while let scalar = currentScalar,
                      isASCIIDigit(scalar) {
                    try checkpoint()
                    advance()
                }
            }
            return String(scalars[start..<index])
        }

        private mutating func consumeLiteral(_ literal: String) throws -> Bool {
            for expected in literal.unicodeScalars {
                try checkpoint()
                guard currentScalar?.value == expected.value else {
                    return false
                }
                advance()
            }
            return true
        }

        private mutating func skipWhitespace() throws {
            while let scalar = currentScalar,
                  scalar.value == 0x20
                    || scalar.value == 0x0A
                    || scalar.value == 0x0D
                    || scalar.value == 0x09 {
                try checkpoint()
                advance()
            }
        }

        private mutating func consumeExpected(_ expectedValue: UInt32) throws {
            guard currentScalar?.value == expectedValue else {
                return
            }
            try checkpoint()
            advance()
        }

        private mutating func consumeIfPresent(_ expectedValue: UInt32) throws -> Bool {
            guard currentScalar?.value == expectedValue else {
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
            index = scalars.index(after: index)
        }

        private var currentScalar: Unicode.Scalar? {
            index == scalars.endIndex ? nil : scalars[index]
        }

        private func indent(_ depth: Int) -> String {
            String(repeating: "  ", count: depth)
        }

        private func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
            return (0x30...0x39).contains(scalar.value)
        }

        private func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
            return (0x30...0x39).contains(scalar.value)
                || (0x41...0x46).contains(scalar.value)
                || (0x61...0x66).contains(scalar.value)
        }

        private func isJSONEscapedCharacter(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                return true
            default:
                return false
            }
        }
    }
}
#endif
