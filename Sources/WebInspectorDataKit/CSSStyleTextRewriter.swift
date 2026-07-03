import Foundation
import WebInspectorProxyKit

enum CSSStyleTextRewriter {
    struct RewriteContext {
        private var styleTextIndex: StyleTextIndex?
        private let properties: [RewriteProperty]
        private let previousPropertyTextOccurrences: [Int]
        private let canSerializeStyleText: Bool

        init(style: CSS.Style) {
            let properties = style.properties.map(RewriteProperty.init)
            styleTextIndex = StyleTextIndex(
                cssText: style.cssText,
                styleRange: style.range,
                properties: properties
            )
            self.properties = properties
            previousPropertyTextOccurrences = Self.previousPropertyTextOccurrences(for: properties)
            canSerializeStyleText = properties.allSatisfy(\.canSerializeStyleText)
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

    static func canSafelyRewriteStyleText(style: CSS.Style, propertyIndex: Int) -> Bool {
        var context = RewriteContext(style: style)
        return context.canSafelyRewriteStyleText(propertyIndex: propertyIndex)
    }

    static func rewrittenStyleText(style: CSS.Style, propertyIndex: Int, enabled: Bool) -> String? {
        guard style.properties.indices.contains(propertyIndex) else {
            return nil
        }
        let property = style.properties[propertyIndex]
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

    static func canTogglePropertyText(_ property: CSS.Property) -> Bool {
        guard property.status != .inactive else {
            return false
        }
        return toggledPropertyText(property, enabled: property.status == .disabled) != nil
    }

    private struct StyleTextIndex {
        private enum SourceRangeResolutionMode {
            case localFirst
            case stylesheetRelativeFirst
        }

        private let nsText: NSString
        private let lineStartOffsets: [Int]
        private let styleRange: CSS.Style.SourceRange?
        private let sourceRangeResolutionMode: SourceRangeResolutionMode
        private var declarationRangesByText: [String: [NSRange]] = [:]

        init?(cssText: String, styleRange: CSS.Style.SourceRange?, properties: [RewriteProperty]) {
            guard !cssText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let nsText = cssText as NSString
            let lineStartOffsets = CSSStyleTextRewriter.lineStartUTF16Offsets(in: cssText)
            self.nsText = nsText
            self.lineStartOffsets = lineStartOffsets
            self.styleRange = styleRange
            self.sourceRangeResolutionMode = Self.sourceRangeResolutionMode(
                properties: properties,
                styleRange: styleRange,
                nsText: nsText,
                lineStartOffsets: lineStartOffsets
            )
        }

        mutating func authoredDeclarationRange(
            for propertyText: String,
            sourceRange: CSS.Style.SourceRange?,
            previousOccurrence: Int
        ) -> NSRange? {
            if let sourceRange {
                let relativeSourceRange = styleRelativeSourceRange(sourceRange)
                switch sourceRangeResolutionMode {
                case .localFirst:
                    if let range = authoredDeclarationRange(for: propertyText, sourceRange: sourceRange) {
                        return range
                    }
                    if let relativeSourceRange,
                       let range = authoredDeclarationRange(for: propertyText, sourceRange: relativeSourceRange) {
                        return range
                    }
                case .stylesheetRelativeFirst:
                    if let relativeSourceRange,
                       let range = authoredDeclarationRange(for: propertyText, sourceRange: relativeSourceRange) {
                        return range
                    }
                    if relativeSourceRange == nil,
                       let range = authoredDeclarationRange(for: propertyText, sourceRange: sourceRange) {
                        return range
                    }
                }
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

        private func authoredDeclarationRange(
            for propertyText: String,
            sourceRange: CSS.Style.SourceRange
        ) -> NSRange? {
            Self.authoredDeclarationRange(
                for: propertyText,
                sourceRange: sourceRange,
                nsText: nsText,
                lineStartOffsets: lineStartOffsets
            )
        }

        private static func authoredDeclarationRange(
            for propertyText: String,
            sourceRange: CSS.Style.SourceRange,
            nsText: NSString,
            lineStartOffsets: [Int]
        ) -> NSRange? {
            guard let range = nsRange(
                sourceRange: sourceRange,
                lineStartOffsets: lineStartOffsets,
                textLength: nsText.length
            ),
                  nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines) == propertyText else {
                return nil
            }
            return range
        }

        private static func nsRange(
            sourceRange: CSS.Style.SourceRange,
            lineStartOffsets: [Int],
            textLength: Int
        ) -> NSRange? {
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
                  endOffset <= textLength else {
                return nil
            }
            return NSRange(location: startOffset, length: endOffset - startOffset)
        }

        private func styleRelativeSourceRange(_ sourceRange: CSS.Style.SourceRange) -> CSS.Style.SourceRange? {
            guard let styleRange else {
                return nil
            }
            return Self.styleRelativeSourceRange(sourceRange, styleRange: styleRange)
        }

        private static func styleRelativeSourceRange(
            _ sourceRange: CSS.Style.SourceRange,
            styleRange: CSS.Style.SourceRange
        ) -> CSS.Style.SourceRange? {
            guard
                  styleRange.startLine >= 0,
                  styleRange.endLine >= styleRange.startLine,
                  styleRange.startColumn >= 0,
                  styleRange.endColumn >= 0,
                  sourceRange.startLine >= 0,
                  sourceRange.endLine >= sourceRange.startLine,
                  sourceRange.startColumn >= 0,
                  sourceRange.endColumn >= 0,
                  isStylesheetSourceRange(sourceRange, containedIn: styleRange) else {
                return nil
            }

            let startLine = sourceRange.startLine - styleRange.startLine
            let endLine = sourceRange.endLine - styleRange.startLine
            var startColumn = sourceRange.startColumn
            var endColumn = sourceRange.endColumn
            if startLine == 0 {
                startColumn -= styleRange.startColumn
            }
            if endLine == 0 {
                endColumn -= styleRange.startColumn
            }

            guard startLine >= 0,
                  endLine >= startLine,
                  startColumn >= 0,
                  endColumn >= 0 else {
                return nil
            }

            return CSS.Style.SourceRange(
                startLine: startLine,
                startColumn: startColumn,
                endLine: endLine,
                endColumn: endColumn
            )
        }

        private static func isStylesheetSourceRange(
            _ sourceRange: CSS.Style.SourceRange,
            containedIn styleRange: CSS.Style.SourceRange
        ) -> Bool {
            let startsAfterStyleStart = sourceRange.startLine > styleRange.startLine
                || (sourceRange.startLine == styleRange.startLine
                    && sourceRange.startColumn >= styleRange.startColumn)
            let endsBeforeStyleEnd = sourceRange.endLine < styleRange.endLine
                || (sourceRange.endLine == styleRange.endLine
                    && sourceRange.endColumn <= styleRange.endColumn)
            return startsAfterStyleStart && endsBeforeStyleEnd
        }

        private static func sourceRangeResolutionMode(
            properties: [RewriteProperty],
            styleRange: CSS.Style.SourceRange?,
            nsText: NSString,
            lineStartOffsets: [Int]
        ) -> SourceRangeResolutionMode {
            guard let styleRange else {
                return .localFirst
            }

            var localMatches = 0
            var stylesheetRelativeMatches = 0
            for property in properties {
                guard let propertyText = property.trimmedText,
                      !propertyText.isEmpty,
                      let sourceRange = property.sourceRange else {
                    continue
                }

                if authoredDeclarationRange(
                    for: propertyText,
                    sourceRange: sourceRange,
                    nsText: nsText,
                    lineStartOffsets: lineStartOffsets
                ) != nil {
                    localMatches += 1
                }

                guard let relativeRange = styleRelativeSourceRange(sourceRange, styleRange: styleRange) else {
                    continue
                }
                if authoredDeclarationRange(
                    for: propertyText,
                    sourceRange: relativeRange,
                    nsText: nsText,
                    lineStartOffsets: lineStartOffsets
                ) != nil {
                    stylesheetRelativeMatches += 1
                }
            }

            return stylesheetRelativeMatches > localMatches ? .stylesheetRelativeFirst : .localFirst
        }

        private mutating func declarationRanges(for propertyText: String) -> [NSRange] {
            if let ranges = declarationRangesByText[propertyText] {
                return ranges
            }
            let ranges = CSSStyleTextRewriter.declarationRanges(of: propertyText, in: nsText)
            declarationRangesByText[propertyText] = ranges
            return ranges
        }
    }

    private struct RewriteProperty {
        var text: String?
        var trimmedText: String?
        var sourceRange: CSS.Style.SourceRange?
        var implicit: Bool
        var status: CSS.Status

        init(_ property: CSS.Property) {
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

    private static func lineStartUTF16Offsets(in text: String) -> [Int] {
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

    private static func toggledPropertyText(_ property: CSS.Property, enabled: Bool) -> String? {
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
