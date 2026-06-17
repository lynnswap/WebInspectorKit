import Foundation
#if DEBUG
import Synchronization
#endif

extension CSSStyle {
    enum TextRewriter {
    struct RewriteContext {
        private var styleTextIndex: StyleTextIndex?
        private let properties: [RewriteProperty]
        private let previousPropertyTextOccurrences: [Int]
        private let canSerializeStyleText: Bool

        init(style: CSSStyle.Payload) {
            self.init(
                properties: style.cssProperties.map(RewriteProperty.init),
                cssText: style.cssText
            )
        }

        init(style: CSSStyle) {
            self.init(
                properties: style.cssProperties.map(RewriteProperty.init),
                cssText: style.cssText
            )
        }

        private init(properties: [RewriteProperty], cssText: String?) {
            self.styleTextIndex = cssText.flatMap(StyleTextIndex.init(cssText:))
            self.properties = properties
            self.previousPropertyTextOccurrences = Self.previousPropertyTextOccurrences(for: properties)
            self.canSerializeStyleText = properties.allSatisfy(\.canSerializeStyleText)
        }

        mutating func canSafelyRewriteStyleText(propertyIndex: Int) -> Bool {
            guard properties.indices.contains(propertyIndex) else {
                return false
            }
            guard styleTextIndex != nil else {
                return canSerializeStyleText
            }
            return authoredDeclarationRange(propertyIndex: propertyIndex) != nil
        }

        var hasAuthoredStyleText: Bool {
            styleTextIndex != nil
        }

        mutating func rewriteAuthoredStyleText(propertyIndex: Int, with replacementText: String) -> String? {
            guard let range = authoredDeclarationRange(propertyIndex: propertyIndex),
                  let styleTextIndex else {
                return nil
            }
            return styleTextIndex.replacingCharacters(in: range, with: replacementText)
        }

        func serializedStyleText(replacingPropertyAt propertyIndex: Int, with replacementText: String) -> String? {
            guard properties.indices.contains(propertyIndex) else {
                return nil
            }
            var texts: [String] = []
            for index in properties.indices {
                if index == propertyIndex {
                    texts.append(replacementText)
                    continue
                }
                let property = properties[index]
                guard property.canSerializeStyleText,
                      let text = property.text else {
                    return nil
                }
                texts.append(text)
            }
            return texts.joined(separator: "\n")
        }

        private mutating func authoredDeclarationRange(propertyIndex: Int) -> NSRange? {
            guard properties.indices.contains(propertyIndex),
                  let propertyText = properties[propertyIndex].trimmedText,
                  !propertyText.isEmpty,
                  styleTextIndex != nil else {
                return nil
            }
            return styleTextIndex!.authoredDeclarationRange(
                for: propertyText,
                sourceRange: properties[propertyIndex].sourceRange,
                previousOccurrence: previousPropertyTextOccurrences[propertyIndex]
            )
        }

        private static func previousPropertyTextOccurrences(for properties: [RewriteProperty]) -> [Int] {
            var seenOccurrencesByText: [String: Int] = [:]
            return properties.map { property in
                guard let propertyText = property.trimmedText,
                      !propertyText.isEmpty else {
                    return 0
                }
                let occurrence = seenOccurrencesByText[propertyText, default: 0]
                seenOccurrencesByText[propertyText] = occurrence + 1
                return occurrence
            }
        }
    }

    static func canSafelyRewriteStyleText(for style: CSSStyle.Payload, propertyIndex: Int) -> Bool {
        var context = RewriteContext(style: style)
        return context.canSafelyRewriteStyleText(propertyIndex: propertyIndex)
    }

    static func rewrittenStyleText(style: CSSStyle, propertyIndex: Int, enabled: Bool) -> String? {
        guard style.cssProperties.indices.contains(propertyIndex) else {
            return nil
        }
        let property = style.cssProperties[propertyIndex]
        guard property.isEditable,
              let toggledText = toggledPropertyText(property, enabled: enabled) else {
            return nil
        }
        var context = RewriteContext(style: style)
        if context.hasAuthoredStyleText {
            return context.rewriteAuthoredStyleText(propertyIndex: propertyIndex, with: toggledText)
        }

        return context.serializedStyleText(replacingPropertyAt: propertyIndex, with: toggledText)
    }

    static func canTogglePropertyText(_ property: CSSProperty.Payload) -> Bool {
        guard property.status != .inactive else {
            return false
        }
        return toggledPropertyText(property, enabled: property.status == .disabled) != nil
    }

    static func canTogglePropertyText(_ property: CSSProperty) -> Bool {
        guard property.status != .inactive else {
            return false
        }
        return toggledPropertyText(property, enabled: !property.isEnabled) != nil
    }

    private struct StyleTextIndex {
        private let nsText: NSString
        private let lineStartOffsets: [Int]
        private var declarationRangesByText: [String: [NSRange]] = [:]

        init?(cssText: String) {
            guard !cssText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            self.nsText = cssText as NSString
            self.lineStartOffsets = CSSStyle.TextRewriter.lineStartUTF16Offsets(in: cssText)
        }

        mutating func authoredDeclarationRange(
            for propertyText: String,
            sourceRange: CSSStyle.SourceRange?,
            previousOccurrence: Int
        ) -> NSRange? {
            if let range = sourceRange.flatMap(nsRange(sourceRange:)),
               NSMaxRange(range) <= nsText.length,
               nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines) == propertyText {
                return range
            }

            let ranges = declarationRanges(for: propertyText)
            if ranges.count == 1 {
                return ranges[0]
            }
            guard ranges.indices.contains(previousOccurrence) else {
                return nil
            }
            return ranges[previousOccurrence]
        }

        func replacingCharacters(in range: NSRange, with replacementText: String) -> String {
            nsText.replacingCharacters(in: range, with: replacementText)
        }

        private func nsRange(sourceRange: CSSStyle.SourceRange) -> NSRange? {
            guard sourceRange.startLine >= 0,
                  sourceRange.endLine >= sourceRange.startLine,
                  sourceRange.startColumn >= 0,
                  sourceRange.endColumn >= 0 else {
                return nil
            }

            guard sourceRange.startLine < lineStartOffsets.count,
                  sourceRange.endLine < lineStartOffsets.count else {
                return nil
            }
            let startOffset = lineStartOffsets[sourceRange.startLine] + sourceRange.startColumn
            let endOffset = lineStartOffsets[sourceRange.endLine] + sourceRange.endColumn
            guard endOffset >= startOffset,
                  endOffset <= nsText.length else {
                return nil
            }
            return NSRange(location: startOffset, length: endOffset - startOffset)
        }

        private mutating func declarationRanges(for propertyText: String) -> [NSRange] {
            if let ranges = declarationRangesByText[propertyText] {
                return ranges
            }
            let ranges = CSSStyle.TextRewriter.declarationRanges(of: propertyText, in: nsText)
            declarationRangesByText[propertyText] = ranges
            return ranges
        }
    }

    private struct RewriteProperty {
        var text: String?
        var trimmedText: String?
        var sourceRange: CSSStyle.SourceRange?
        var implicit: Bool
        var status: CSSProperty.Status

        init(_ property: CSSProperty.Payload) {
            text = property.text
            trimmedText = property.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            sourceRange = property.range
            implicit = property.implicit
            status = property.status
        }

        init(_ property: CSSProperty) {
            text = property.text
            trimmedText = property.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            sourceRange = property.range
            implicit = property.implicit
            status = property.status
        }

        var canSerializeStyleText: Bool {
            text != nil
                && !implicit
                && status != .inactive
        }
    }

#if DEBUG
    struct RewriteInstrumentationSnapshot: Equatable, Sendable {
        var lineStartUTF16OffsetScans: Int
        var declarationRangeScans: Int
    }

    private struct RewriteInstrumentationState: Sendable {
        var lineStartUTF16OffsetScans = 0
        var declarationRangeScans = 0
    }

    private final class RewriteInstrumentationRecorder: @unchecked Sendable {
        private let state = Mutex(RewriteInstrumentationState())

        func recordLineStartUTF16OffsetScan() {
            state.withLock { state in
                state.lineStartUTF16OffsetScans += 1
            }
        }

        func recordDeclarationRangeScan() {
            state.withLock { state in
                state.declarationRangeScans += 1
            }
        }

        func snapshot() -> RewriteInstrumentationSnapshot {
            state.withLock { state in
                RewriteInstrumentationSnapshot(
                    lineStartUTF16OffsetScans: state.lineStartUTF16OffsetScans,
                    declarationRangeScans: state.declarationRangeScans
                )
            }
        }
    }

    @TaskLocal private static var rewriteInstrumentationRecorder: RewriteInstrumentationRecorder?

    static func withInstrumentationCounters<Result>(
        _ operation: () throws -> Result
    ) rethrows -> (result: Result, snapshot: RewriteInstrumentationSnapshot) {
        let recorder = RewriteInstrumentationRecorder()
        let result = try $rewriteInstrumentationRecorder.withValue(recorder) {
            try operation()
        }
        return (result, recorder.snapshot())
    }

    private static func recordLineStartUTF16OffsetScan() {
        rewriteInstrumentationRecorder?.recordLineStartUTF16OffsetScan()
    }

    private static func recordDeclarationRangeScan() {
        rewriteInstrumentationRecorder?.recordDeclarationRangeScan()
    }
#else
    private static func recordLineStartUTF16OffsetScan() {}

    private static func recordDeclarationRangeScan() {}
#endif

    private static func lineStartUTF16Offsets(in text: String) -> [Int] {
        recordLineStartUTF16OffsetScan()
        var offsets = [0]
        var offset = 0
        for scalar in text.unicodeScalars {
            offset += scalar.utf16.count
            if scalar == "\n" {
                offsets.append(offset)
            }
        }
        return offsets
    }

    private static func declarationRanges(of needle: String, in haystack: NSString) -> [NSRange] {
        recordDeclarationRangeScan()
        let nsHaystack = haystack
        var searchRange = NSRange(location: 0, length: nsHaystack.length)
        var ranges: [NSRange] = []
        while searchRange.length > 0 {
            let range = nsHaystack.range(of: needle, options: [], range: searchRange)
            guard range.location != NSNotFound else {
                break
            }
            if isDeclarationRange(range, propertyText: needle, in: nsHaystack) {
                ranges.append(range)
            }
            let nextLocation = range.location + max(range.length, 1)
            searchRange = NSRange(location: nextLocation, length: nsHaystack.length - nextLocation)
        }
        return ranges
    }

    private static func isDeclarationRange(_ range: NSRange, propertyText: String, in text: NSString) -> Bool {
        isNormalCSSPosition(range.location, in: text)
            && hasDeclarationBoundary(before: range.location, in: text)
            && hasDeclarationEndBoundary(after: NSMaxRange(range), propertyText: propertyText, in: text)
    }

    private static func isNormalCSSPosition(_ location: Int, in text: NSString) -> Bool {
        var index = 0
        var quotedString: unichar?
        var isEscaped = false
        var isComment = false
        while index < location {
            let character = text.character(at: index)
            let nextCharacter = index + 1 < text.length ? text.character(at: index + 1) : 0

            if isComment {
                if character == asterisk && nextCharacter == slash {
                    isComment = false
                    index += 2
                    continue
                }
                index += 1
                continue
            }

            if let quote = quotedString {
                if isEscaped {
                    isEscaped = false
                } else if character == backslash {
                    isEscaped = true
                } else if character == quote {
                    quotedString = nil
                }
                index += 1
                continue
            }

            if character == slash && nextCharacter == asterisk {
                isComment = true
                index += 2
                continue
            }
            if character == doubleQuote || character == singleQuote {
                quotedString = character
            }
            index += 1
        }
        return !isComment && quotedString == nil
    }

    private static func hasDeclarationBoundary(before location: Int, in text: NSString) -> Bool {
        var index = location - 1
        while index >= 0 {
            let character = text.character(at: index)
            if character == slash,
               index > 0,
               text.character(at: index - 1) == asterisk {
                guard let commentStart = cssCommentStart(endingAt: index, in: text) else {
                    return false
                }
                index = commentStart - 1
                continue
            }
            if !isCSSWhitespace(character) {
                return character == semicolon || character == leftBrace
            }
            index -= 1
        }
        return true
    }

    private static func hasDeclarationBoundary(after location: Int, in text: NSString) -> Bool {
        var index = location
        while index < text.length {
            let character = text.character(at: index)
            let nextCharacter = index + 1 < text.length ? text.character(at: index + 1) : 0
            if character == slash,
               nextCharacter == asterisk {
                guard let commentEnd = cssCommentEnd(startingAt: index, in: text) else {
                    return false
                }
                index = commentEnd + 1
                continue
            }
            if !isCSSWhitespace(character) {
                return character == semicolon || character == rightBrace
            }
            index += 1
        }
        return true
    }

    private static func hasDeclarationEndBoundary(after location: Int, propertyText: String, in text: NSString) -> Bool {
        let trimmedPropertyText = propertyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPropertyText.hasSuffix(";")
            || trimmedPropertyText.hasSuffix("*/") {
            return true
        }
        return hasDeclarationBoundary(after: location, in: text)
    }

    private static func cssCommentStart(endingAt commentEndSlashIndex: Int, in text: NSString) -> Int? {
        var index = 0
        var quotedString: unichar?
        var isEscaped = false
        var commentStart: Int?
        while index <= commentEndSlashIndex {
            let character = text.character(at: index)
            let nextCharacter = index + 1 < text.length ? text.character(at: index + 1) : 0

            if let start = commentStart {
                if character == asterisk,
                   nextCharacter == slash {
                    if index + 1 == commentEndSlashIndex {
                        return start
                    }
                    commentStart = nil
                    index += 2
                    continue
                }
                index += 1
                continue
            }

            if let quote = quotedString {
                if isEscaped {
                    isEscaped = false
                } else if character == backslash {
                    isEscaped = true
                } else if character == quote {
                    quotedString = nil
                }
                index += 1
                continue
            }

            if character == slash,
               nextCharacter == asterisk {
                commentStart = index
                index += 2
                continue
            }
            if character == doubleQuote || character == singleQuote {
                quotedString = character
            }
            index += 1
        }
        return nil
    }

    private static func cssCommentEnd(startingAt commentStartSlashIndex: Int, in text: NSString) -> Int? {
        var index = commentStartSlashIndex + 2
        while index < text.length {
            if text.character(at: index - 1) == asterisk,
               text.character(at: index) == slash {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func isCSSWhitespace(_ character: unichar) -> Bool {
        character == space
            || character == tab
            || character == newline
            || character == carriageReturn
            || character == formFeed
    }

    private static func toggledPropertyText(_ property: CSSProperty, enabled: Bool) -> String? {
        guard let text = property.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              property.isEnabled != enabled else {
            return nil
        }

        if enabled {
            guard text.hasPrefix("/*"),
                  text.hasSuffix("*/") else {
                return nil
            }
            let inner = String(text.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }

        guard !text.contains("/*"),
              !text.contains("*/") else {
            return nil
        }
        return "/* \(text) */"
    }

    private static func toggledPropertyText(_ property: CSSProperty.Payload, enabled: Bool) -> String? {
        guard let text = property.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              (property.status != .disabled) != enabled else {
            return nil
        }

        if enabled {
            guard text.hasPrefix("/*"),
                  text.hasSuffix("*/") else {
                return nil
            }
            let inner = String(text.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }

        guard !text.contains("/*"),
              !text.contains("*/") else {
            return nil
        }
        return "/* \(text) */"
    }

    private static let tab = unichar(9)
    private static let newline = unichar(10)
    private static let formFeed = unichar(12)
    private static let carriageReturn = unichar(13)
    private static let space = unichar(32)
    private static let doubleQuote = unichar(34)
    private static let singleQuote = unichar(39)
    private static let asterisk = unichar(42)
    private static let semicolon = unichar(59)
    private static let leftBrace = unichar(123)
    private static let backslash = unichar(92)
    private static let rightBrace = unichar(125)
    private static let slash = unichar(47)
    }
}
