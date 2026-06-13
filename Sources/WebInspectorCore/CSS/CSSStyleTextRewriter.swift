import Foundation

enum CSSStyleTextRewriter {
    static func canSafelyRewriteStyleText(for style: CSSStylePayload, propertyIndex: Int) -> Bool {
        guard style.cssProperties.indices.contains(propertyIndex) else {
            return false
        }
        if let cssText = style.cssText,
           !cssText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let property = style.cssProperties[propertyIndex]
            guard let propertyText = property.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !propertyText.isEmpty else {
                return false
            }
            return authoredDeclarationRange(
                for: propertyText,
                sourceRange: property.range,
                in: cssText,
                previousPropertyTexts: style.cssProperties[..<propertyIndex].map(\.text)
            ) != nil
        }
        return style.cssProperties.allSatisfy { property in
            property.text != nil
                && !property.implicit
                && property.status != .inactive
        }
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
        if let cssText = style.cssText,
           !cssText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rewriteAuthoredStyleText(
                cssText,
                replacing: property,
                in: style,
                propertyIndex: propertyIndex,
                with: toggledText
            )
        }

        var texts: [String] = []
        for index in style.cssProperties.indices {
            if index == propertyIndex {
                texts.append(toggledText)
                continue
            }
            let property = style.cssProperties[index]
            guard let text = property.text,
                  !property.implicit,
                  property.status != .inactive else {
                return nil
            }
            texts.append(text)
        }
        return texts.joined(separator: "\n")
    }

    static func canTogglePropertyText(_ property: CSSPropertyPayload) -> Bool {
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

    private static func rewriteAuthoredStyleText(
        _ cssText: String,
        replacing property: CSSProperty,
        in style: CSSStyle,
        propertyIndex: Int,
        with toggledText: String
    ) -> String? {
        guard let propertyText = property.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !propertyText.isEmpty else {
            return nil
        }
        let nsText = cssText as NSString
        if let range = authoredDeclarationRange(
            for: propertyText,
            sourceRange: property.range,
            in: cssText,
            previousPropertyTexts: style.cssProperties[..<propertyIndex].map(\.text)
        ) {
            return nsText.replacingCharacters(in: range, with: toggledText)
        }

        return nil
    }

    private static func authoredDeclarationRange(
        for propertyText: String,
        sourceRange: CSSSourceRange?,
        in cssText: String,
        previousPropertyTexts: [String?]
    ) -> NSRange? {
        let nsText = cssText as NSString
        if let range = sourceRange.flatMap({ nsRange(in: cssText, sourceRange: $0) }),
           NSMaxRange(range) <= nsText.length,
           nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines) == propertyText {
            return range
        }

        let ranges = declarationRanges(of: propertyText, in: cssText)
        if ranges.count == 1 {
            return ranges[0]
        }
        let occurrence = previousPropertyTexts.filter { previousText in
            previousText?.trimmingCharacters(in: .whitespacesAndNewlines) == propertyText
        }.count
        guard ranges.indices.contains(occurrence) else {
            return nil
        }
        return ranges[occurrence]
    }

    private static func nsRange(in text: String, sourceRange: CSSSourceRange) -> NSRange? {
        guard sourceRange.startLine >= 0,
              sourceRange.endLine >= sourceRange.startLine,
              sourceRange.startColumn >= 0,
              sourceRange.endColumn >= 0 else {
            return nil
        }

        let lineStartOffsets = lineStartUTF16Offsets(in: text)
        guard sourceRange.startLine < lineStartOffsets.count,
              sourceRange.endLine < lineStartOffsets.count else {
            return nil
        }
        let startOffset = lineStartOffsets[sourceRange.startLine] + sourceRange.startColumn
        let endOffset = lineStartOffsets[sourceRange.endLine] + sourceRange.endColumn
        guard endOffset >= startOffset,
              endOffset <= (text as NSString).length else {
            return nil
        }
        return NSRange(location: startOffset, length: endOffset - startOffset)
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

    private static func declarationRanges(of needle: String, in haystack: String) -> [NSRange] {
        let nsHaystack = haystack as NSString
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

    private static func toggledPropertyText(_ property: CSSPropertyPayload, enabled: Bool) -> String? {
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
