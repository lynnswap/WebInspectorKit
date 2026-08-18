import Foundation

package enum NetworkCookieParseStatus: Hashable, Sendable {
    case complete
    case partial
    case unparsed
    case ambiguousCombined
}

package struct NetworkCookieParseDiagnostic: Hashable, Sendable {
    package enum Kind: Hashable, Sendable {
        case multipleHeaderFields
        case invalidCookieFragment
        case prohibitedControlCharacter
        case ambiguousCombinedHeader
        case invalidAttribute
        case invalidExpires
        case invalidMaxAge
    }

    package let kind: Kind
    package let rawFragment: String

    package init(kind: Kind, rawFragment: String) {
        self.kind = kind
        self.rawFragment = rawFragment
    }
}

package struct NetworkRequestCookie: Hashable, Sendable {
    package let ordinal: Int
    package let name: String
    package let value: String
    package let raw: String

    package init(ordinal: Int, name: String, value: String, raw: String) {
        self.ordinal = ordinal
        self.name = name
        self.value = value
        self.raw = raw
    }
}

package struct NetworkResponseCookieAttribute: Hashable, Sendable {
    package let ordinal: Int
    package let name: String
    package let value: String?
    package let raw: String

    package init(ordinal: Int, name: String, value: String?, raw: String) {
        self.ordinal = ordinal
        self.name = name
        self.value = value
        self.raw = raw
    }
}

package enum NetworkCookieSameSite: Hashable, Sendable {
    case absent
    case none
    case lax
    case strict
    case other(String)
}

package struct NetworkResponseCookie: Hashable, Sendable {
    package let ordinal: Int
    package let name: String
    package let value: String
    package let raw: String
    package let attributes: [NetworkResponseCookieAttribute]
    private let projection: NetworkResponseCookieProjection

    package var domain: String? { projection.domain }
    package var path: String? { projection.path }
    package var rawExpires: String? { projection.rawExpires }
    package var expires: Date? { projection.expires }
    package var rawMaxAge: String? { projection.rawMaxAge }
    package var maxAgeSeconds: Int64? { projection.maxAgeSeconds }
    package var isSecure: Bool { projection.isSecure }
    package var isHTTPOnly: Bool { projection.isHTTPOnly }
    package var isPartitioned: Bool { projection.isPartitioned }
    package var sameSite: NetworkCookieSameSite { projection.sameSite }
    package var unknownAttributes: [NetworkResponseCookieAttribute] {
        projection.unknownAttributes
    }

    fileprivate var projectionDiagnostics: [NetworkCookieParseDiagnostic] {
        projection.diagnostics
    }

    fileprivate init(
        ordinal: Int,
        name: String,
        value: String,
        raw: String,
        attributes: [NetworkResponseCookieAttribute]
    ) {
        self.ordinal = ordinal
        self.name = name
        self.value = value
        self.raw = raw
        self.attributes = attributes
        projection = NetworkResponseCookieProjection(attributes: attributes)
    }
}

private struct NetworkResponseCookieProjection: Hashable, Sendable {
    let domain: String?
    let path: String?
    let rawExpires: String?
    let expires: Date?
    let rawMaxAge: String?
    let maxAgeSeconds: Int64?
    let isSecure: Bool
    let isHTTPOnly: Bool
    let isPartitioned: Bool
    let sameSite: NetworkCookieSameSite
    let unknownAttributes: [NetworkResponseCookieAttribute]
    let diagnostics: [NetworkCookieParseDiagnostic]

    init(attributes: [NetworkResponseCookieAttribute]) {
        var domain: String?
        var path: String?
        var rawExpires: String?
        var expires: Date?
        var rawMaxAge: String?
        var maxAgeSeconds: Int64?
        var isSecure = false
        var isHTTPOnly = false
        var isPartitioned = false
        var sameSite = NetworkCookieSameSite.absent
        var unknownAttributes: [NetworkResponseCookieAttribute] = []
        var diagnostics: [NetworkCookieParseDiagnostic] = []

        for attribute in attributes {
            guard NetworkCookieParser.isHTTPToken(attribute.name) else {
                diagnostics.append(NetworkCookieParseDiagnostic(
                    kind: .invalidAttribute,
                    rawFragment: attribute.raw
                ))
                continue
            }

            switch NetworkCookieParser.lowercaseASCII(attribute.name) {
            case "domain":
                guard let value = attribute.value, value.isEmpty == false else {
                    diagnostics.append(NetworkCookieParseDiagnostic(
                        kind: .invalidAttribute,
                        rawFragment: attribute.raw
                    ))
                    continue
                }
                domain = value

            case "path":
                guard let value = attribute.value, value.isEmpty == false else {
                    diagnostics.append(NetworkCookieParseDiagnostic(
                        kind: .invalidAttribute,
                        rawFragment: attribute.raw
                    ))
                    continue
                }
                path = value

            case "expires":
                guard
                    let value = attribute.value,
                    value.isEmpty == false,
                    let parsedDate = NetworkCookieParser.parseCookieDate(value)
                else {
                    diagnostics.append(NetworkCookieParseDiagnostic(
                        kind: .invalidExpires,
                        rawFragment: attribute.raw
                    ))
                    continue
                }
                rawExpires = value
                expires = parsedDate

            case "max-age":
                guard
                    let value = attribute.value,
                    let parsedSeconds = NetworkCookieParser.parseMaxAge(value)
                else {
                    diagnostics.append(NetworkCookieParseDiagnostic(
                        kind: .invalidMaxAge,
                        rawFragment: attribute.raw
                    ))
                    continue
                }
                rawMaxAge = value
                maxAgeSeconds = parsedSeconds

            case "secure":
                isSecure = true
                if attribute.value != nil {
                    diagnostics.append(NetworkCookieParseDiagnostic(
                        kind: .invalidAttribute,
                        rawFragment: attribute.raw
                    ))
                }

            case "httponly":
                isHTTPOnly = true
                if attribute.value != nil {
                    diagnostics.append(NetworkCookieParseDiagnostic(
                        kind: .invalidAttribute,
                        rawFragment: attribute.raw
                    ))
                }

            case "partitioned":
                isPartitioned = true
                if attribute.value != nil {
                    diagnostics.append(NetworkCookieParseDiagnostic(
                        kind: .invalidAttribute,
                        rawFragment: attribute.raw
                    ))
                }

            case "samesite":
                guard let value = attribute.value, value.isEmpty == false else {
                    diagnostics.append(NetworkCookieParseDiagnostic(
                        kind: .invalidAttribute,
                        rawFragment: attribute.raw
                    ))
                    continue
                }
                switch NetworkCookieParser.lowercaseASCII(value) {
                case "none":
                    sameSite = .none
                case "lax":
                    sameSite = .lax
                case "strict":
                    sameSite = .strict
                default:
                    sameSite = .other(value)
                }
            default:
                unknownAttributes.append(attribute)
            }
        }

        self.domain = domain
        self.path = path
        self.rawExpires = rawExpires
        self.expires = expires
        self.rawMaxAge = rawMaxAge
        self.maxAgeSeconds = maxAgeSeconds
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.isPartitioned = isPartitioned
        self.sameSite = sameSite
        self.unknownAttributes = unknownAttributes
        self.diagnostics = diagnostics
    }
}

package struct NetworkRequestCookieParseReport: Hashable, Sendable {
    package let cookies: [NetworkRequestCookie]
    package let rawHeaderValues: [String]
    package let diagnostics: [NetworkCookieParseDiagnostic]
    package let status: NetworkCookieParseStatus

    package init(
        cookies: [NetworkRequestCookie],
        rawHeaderValues: [String],
        diagnostics: [NetworkCookieParseDiagnostic],
        status: NetworkCookieParseStatus
    ) {
        self.cookies = cookies
        self.rawHeaderValues = rawHeaderValues
        self.diagnostics = diagnostics
        self.status = status
    }
}

package struct NetworkResponseCookieParseReport: Hashable, Sendable {
    package let cookies: [NetworkResponseCookie]
    package let rawHeaderValues: [String]
    package let diagnostics: [NetworkCookieParseDiagnostic]
    package let status: NetworkCookieParseStatus

    package init(
        cookies: [NetworkResponseCookie],
        rawHeaderValues: [String],
        diagnostics: [NetworkCookieParseDiagnostic],
        status: NetworkCookieParseStatus
    ) {
        self.cookies = cookies
        self.rawHeaderValues = rawHeaderValues
        self.diagnostics = diagnostics
        self.status = status
    }
}

package enum NetworkCookieParser {
    package static func parseRequestHeaders(
        _ headers: [String: String]
    ) -> NetworkRequestCookieParseReport? {
        guard let fields = matchingHeaderFields(named: "Cookie", in: headers) else {
            return nil
        }
        let rawHeaderValues = fields.map(\.value)
        guard fields.count == 1 else {
            let diagnostics = rawHeaderValues.map {
                NetworkCookieParseDiagnostic(kind: .multipleHeaderFields, rawFragment: $0)
            }
            return NetworkRequestCookieParseReport(
                cookies: [],
                rawHeaderValues: rawHeaderValues,
                diagnostics: diagnostics,
                status: .unparsed
            )
        }

        let rawHeaderValue = rawHeaderValues[0]
        guard trimOptionalWhitespace(rawHeaderValue).isEmpty == false else {
            return NetworkRequestCookieParseReport(
                cookies: [],
                rawHeaderValues: rawHeaderValues,
                diagnostics: [],
                status: .complete
            )
        }

        var cookies: [NetworkRequestCookie] = []
        var diagnostics: [NetworkCookieParseDiagnostic] = []
        let fragments = rawHeaderValue.split(separator: ";", omittingEmptySubsequences: false)
        cookies.reserveCapacity(fragments.count)

        for (ordinal, fragment) in fragments.enumerated() {
            let rawFragment = String(fragment)
            let trimmedFragment = trimOptionalWhitespace(rawFragment)
            guard containsNonOWSControlCharacter(rawFragment) == false else {
                diagnostics.append(NetworkCookieParseDiagnostic(
                    kind: .prohibitedControlCharacter,
                    rawFragment: rawFragment
                ))
                continue
            }
            guard let equalsIndex = trimmedFragment.firstIndex(of: "=") else {
                diagnostics.append(NetworkCookieParseDiagnostic(
                    kind: .invalidCookieFragment,
                    rawFragment: rawFragment
                ))
                continue
            }

            let name = trimOptionalWhitespace(String(trimmedFragment[..<equalsIndex]))
            let valueStart = trimmedFragment.index(after: equalsIndex)
            let value = trimOptionalWhitespace(String(trimmedFragment[valueStart...]))
            guard containsControlCharacter(name) == false,
                  containsControlCharacter(value) == false else {
                diagnostics.append(NetworkCookieParseDiagnostic(
                    kind: .prohibitedControlCharacter,
                    rawFragment: rawFragment
                ))
                continue
            }
            guard isHTTPToken(name) else {
                diagnostics.append(NetworkCookieParseDiagnostic(
                    kind: .invalidCookieFragment,
                    rawFragment: rawFragment
                ))
                continue
            }
            cookies.append(NetworkRequestCookie(
                ordinal: ordinal,
                name: name,
                value: value,
                raw: rawFragment
            ))
        }

        return NetworkRequestCookieParseReport(
            cookies: cookies,
            rawHeaderValues: rawHeaderValues,
            diagnostics: diagnostics,
            status: parseStatus(parsedCount: cookies.count, diagnostics: diagnostics)
        )
    }

    package static func parseResponseHeaders(
        _ headers: [String: String]
    ) -> NetworkResponseCookieParseReport? {
        guard let fields = matchingHeaderFields(named: "Set-Cookie", in: headers) else {
            return nil
        }
        let rawHeaderValues = fields.map(\.value)
        guard fields.count == 1 else {
            let diagnostics = rawHeaderValues.map {
                NetworkCookieParseDiagnostic(kind: .multipleHeaderFields, rawFragment: $0)
            }
            return NetworkResponseCookieParseReport(
                cookies: [],
                rawHeaderValues: rawHeaderValues,
                diagnostics: diagnostics,
                status: .unparsed
            )
        }

        let rawHeaderValue = rawHeaderValues[0]
        guard trimOptionalWhitespace(rawHeaderValue).isEmpty == false else {
            return NetworkResponseCookieParseReport(
                cookies: [],
                rawHeaderValues: rawHeaderValues,
                diagnostics: [],
                status: .complete
            )
        }
        guard containsNonOWSControlCharacter(rawHeaderValue) == false else {
            return NetworkResponseCookieParseReport(
                cookies: [],
                rawHeaderValues: rawHeaderValues,
                diagnostics: [NetworkCookieParseDiagnostic(
                    kind: .prohibitedControlCharacter,
                    rawFragment: rawHeaderValue
                )],
                status: .unparsed
            )
        }
        // Do not split: WebKit's HTTPHeaderMap irreversibly discards Set-Cookie field boundaries,
        // so commas in Expires or values cannot be safely distinguished from field separators.
        guard containsCombinedCookieCandidate(rawHeaderValue) == false else {
            return NetworkResponseCookieParseReport(
                cookies: [],
                rawHeaderValues: rawHeaderValues,
                diagnostics: [NetworkCookieParseDiagnostic(
                    kind: .ambiguousCombinedHeader,
                    rawFragment: rawHeaderValue
                )],
                status: .ambiguousCombined
            )
        }

        let fragments = rawHeaderValue.split(separator: ";", omittingEmptySubsequences: false)
        let rawCookiePair = String(fragments[0])
        let trimmedCookiePair = trimOptionalWhitespace(rawCookiePair)
        guard let equalsIndex = trimmedCookiePair.firstIndex(of: "=") else {
            return unparsedResponseReport(
                rawHeaderValues: rawHeaderValues,
                diagnostic: NetworkCookieParseDiagnostic(
                    kind: .invalidCookieFragment,
                    rawFragment: rawCookiePair
                )
            )
        }
        let name = trimOptionalWhitespace(String(trimmedCookiePair[..<equalsIndex]))
        let valueStart = trimmedCookiePair.index(after: equalsIndex)
        let value = trimOptionalWhitespace(String(trimmedCookiePair[valueStart...]))
        guard containsControlCharacter(name) == false,
              containsControlCharacter(value) == false else {
            return unparsedResponseReport(
                rawHeaderValues: rawHeaderValues,
                diagnostic: NetworkCookieParseDiagnostic(
                    kind: .prohibitedControlCharacter,
                    rawFragment: rawHeaderValue
                )
            )
        }
        guard isHTTPToken(name) else {
            return unparsedResponseReport(
                rawHeaderValues: rawHeaderValues,
                diagnostic: NetworkCookieParseDiagnostic(
                    kind: .invalidCookieFragment,
                    rawFragment: rawCookiePair
                )
            )
        }

        var attributes: [NetworkResponseCookieAttribute] = []
        attributes.reserveCapacity(max(fragments.count - 1, 0))
        for (ordinal, fragment) in fragments.dropFirst().enumerated() {
            let rawAttribute = String(fragment)
            let trimmedAttribute = trimOptionalWhitespace(rawAttribute)
            let attributeName: String
            let attributeValue: String?
            if let equalsIndex = trimmedAttribute.firstIndex(of: "=") {
                attributeName = trimOptionalWhitespace(String(trimmedAttribute[..<equalsIndex]))
                let valueStart = trimmedAttribute.index(after: equalsIndex)
                attributeValue = trimOptionalWhitespace(String(trimmedAttribute[valueStart...]))
            } else {
                attributeName = trimmedAttribute
                attributeValue = nil
            }
            guard containsControlCharacter(attributeName) == false,
                  attributeValue.map(containsControlCharacter) != true else {
                return unparsedResponseReport(
                    rawHeaderValues: rawHeaderValues,
                    diagnostic: NetworkCookieParseDiagnostic(
                        kind: .prohibitedControlCharacter,
                        rawFragment: rawHeaderValue
                    )
                )
            }

            let attribute = NetworkResponseCookieAttribute(
                ordinal: ordinal,
                name: attributeName,
                value: attributeValue,
                raw: rawAttribute
            )
            attributes.append(attribute)
        }

        let cookie = NetworkResponseCookie(
            ordinal: 0,
            name: name,
            value: value,
            raw: rawHeaderValue,
            attributes: attributes
        )
        let diagnostics = cookie.projectionDiagnostics
        return NetworkResponseCookieParseReport(
            cookies: [cookie],
            rawHeaderValues: rawHeaderValues,
            diagnostics: diagnostics,
            status: parseStatus(parsedCount: 1, diagnostics: diagnostics)
        )
    }
}

fileprivate extension NetworkCookieParser {
    struct HeaderField {
        let name: String
        let value: String
    }

    static func matchingHeaderFields(
        named targetName: String,
        in headers: [String: String]
    ) -> [HeaderField]? {
        let fields = headers.compactMap { name, value -> HeaderField? in
            guard asciiCaseInsensitiveEqual(name, targetName) else {
                return nil
            }
            return HeaderField(name: name, value: value)
        }.sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.value < rhs.value
        }
        return fields.isEmpty ? nil : fields
    }

    static func asciiCaseInsensitiveEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = lhs.utf8
        let rhsBytes = rhs.utf8
        guard lhsBytes.count == rhsBytes.count else {
            return false
        }
        return zip(lhsBytes, rhsBytes).allSatisfy { lhsByte, rhsByte in
            lowercaseASCII(lhsByte) == lowercaseASCII(rhsByte)
        }
    }

    static func lowercaseASCII(_ value: String) -> String {
        String(decoding: value.utf8.map(lowercaseASCII), as: UTF8.self)
    }

    static func lowercaseASCII(_ byte: UInt8) -> UInt8 {
        guard (65...90).contains(byte) else {
            return byte
        }
        return byte + 32
    }

    static func trimOptionalWhitespace(_ value: String) -> String {
        let bytes = value.utf8
        var lowerBound = bytes.startIndex
        var upperBound = bytes.endIndex
        while lowerBound < upperBound, isOptionalWhitespace(bytes[lowerBound]) {
            lowerBound = bytes.index(after: lowerBound)
        }
        while lowerBound < upperBound {
            let preceding = bytes.index(before: upperBound)
            guard isOptionalWhitespace(bytes[preceding]) else {
                break
            }
            upperBound = preceding
        }
        return String(decoding: bytes[lowerBound..<upperBound], as: UTF8.self)
    }

    static func isOptionalWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }

    static func parseStatus(
        parsedCount: Int,
        diagnostics: [NetworkCookieParseDiagnostic]
    ) -> NetworkCookieParseStatus {
        guard diagnostics.isEmpty == false else {
            return .complete
        }
        return parsedCount > 0 ? .partial : .unparsed
    }

    static func unparsedResponseReport(
        rawHeaderValues: [String],
        diagnostic: NetworkCookieParseDiagnostic
    ) -> NetworkResponseCookieParseReport {
        NetworkResponseCookieParseReport(
            cookies: [],
            rawHeaderValues: rawHeaderValues,
            diagnostics: [diagnostic],
            status: .unparsed
        )
    }

    static func containsNonOWSControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            let codePoint = scalar.value
            return (codePoint <= 0x1F && codePoint != 0x09) || codePoint == 0x7F
        }
    }

    static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value <= 0x1F || scalar.value == 0x7F
        }
    }

    static func containsCombinedCookieCandidate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        for commaIndex in bytes.indices where bytes[commaIndex] == 0x2C {
            var index = commaIndex + 1
            while index < bytes.count, isOptionalWhitespace(bytes[index]) {
                index += 1
            }
            let tokenStart = index
            while index < bytes.count, isHTTPTokenCharacter(bytes[index]) {
                index += 1
            }
            guard index > tokenStart else {
                continue
            }
            while index < bytes.count, isOptionalWhitespace(bytes[index]) {
                index += 1
            }
            if index < bytes.count, bytes[index] == 0x3D {
                return true
            }
        }
        return false
    }

    static func isHTTPTokenCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122:
            return true
        case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E,
             0x5E, 0x5F, 0x60, 0x7C, 0x7E:
            return true
        default:
            return false
        }
    }

    static func isHTTPToken(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.isEmpty == false && bytes.allSatisfy(isHTTPTokenCharacter)
    }

    static func parseMaxAge(_ value: String) -> Int64? {
        let bytes = Array(value.utf8)
        guard bytes.isEmpty == false else {
            return nil
        }
        let digitsStart: Int
        if bytes[0] == 0x2D {
            digitsStart = 1
        } else {
            digitsStart = 0
        }
        guard digitsStart < bytes.count else {
            return nil
        }
        guard bytes[digitsStart...].allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        return Int64(value)
    }

    static func parseCookieDate(_ value: String) -> Date? {
        let tokens = cookieDateTokens(value)
        var time: (hour: Int, minute: Int, second: Int)?
        var day: Int?
        var month: Int?
        var year: Int?

        for token in tokens {
            if time == nil, let parsedTime = parseTime(token) {
                time = parsedTime
                continue
            }
            if day == nil, let parsedDay = parseLeadingDecimal(token, minimumDigits: 1, maximumDigits: 2) {
                day = parsedDay
                continue
            }
            if month == nil, let parsedMonth = parseMonth(token) {
                month = parsedMonth
                continue
            }
            if year == nil, let parsedYear = parseLeadingDecimal(token, minimumDigits: 2, maximumDigits: 4) {
                year = parsedYear
            }
        }

        guard
            let time,
            let day,
            let month,
            var year
        else {
            return nil
        }
        if (70...99).contains(year) {
            year += 1900
        } else if (0...69).contains(year) {
            year += 2000
        }
        guard
            (1...31).contains(day),
            year >= 1601,
            (0...23).contains(time.hour),
            (0...59).contains(time.minute),
            (0...59).contains(time.second)
        else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        guard let date = calendar.date(from: components) else {
            return nil
        }
        let resolved = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard
            resolved.year == year,
            resolved.month == month,
            resolved.day == day,
            resolved.hour == time.hour,
            resolved.minute == time.minute,
            resolved.second == time.second
        else {
            return nil
        }
        return date
    }

    static func cookieDateTokens(_ value: String) -> [[UInt8]] {
        let bytes = Array(value.utf8)
        var tokens: [[UInt8]] = []
        var index = 0
        while index < bytes.count {
            while index < bytes.count, isCookieDateDelimiter(bytes[index]) {
                index += 1
            }
            let tokenStart = index
            while index < bytes.count, isCookieDateDelimiter(bytes[index]) == false {
                index += 1
            }
            if tokenStart < index {
                tokens.append(Array(bytes[tokenStart..<index]))
            }
        }
        return tokens
    }

    static func isCookieDateDelimiter(_ byte: UInt8) -> Bool {
        byte == 0x09 ||
            (0x20...0x2F).contains(byte) ||
            (0x3B...0x40).contains(byte) ||
            (0x5B...0x60).contains(byte) ||
            (0x7B...0x7E).contains(byte)
    }

    static func parseTime(_ token: [UInt8]) -> (hour: Int, minute: Int, second: Int)? {
        var index = 0
        guard let hour = parseTimeField(token, index: &index) else {
            return nil
        }
        guard index < token.count, token[index] == 0x3A else {
            return nil
        }
        index += 1
        guard let minute = parseTimeField(token, index: &index) else {
            return nil
        }
        guard index < token.count, token[index] == 0x3A else {
            return nil
        }
        index += 1
        guard let second = parseTimeField(token, index: &index) else {
            return nil
        }
        guard index == token.count || isASCIIDigit(token[index]) == false else {
            return nil
        }
        return (hour, minute, second)
    }

    static func parseTimeField(_ token: [UInt8], index: inout Int) -> Int? {
        let start = index
        while index < token.count, isASCIIDigit(token[index]) {
            index += 1
        }
        let digitCount = index - start
        guard (1...2).contains(digitCount) else {
            return nil
        }
        return decimalValue(token[start..<index])
    }

    static func parseLeadingDecimal(
        _ token: [UInt8],
        minimumDigits: Int,
        maximumDigits: Int
    ) -> Int? {
        var digitCount = 0
        while digitCount < token.count, isASCIIDigit(token[digitCount]) {
            digitCount += 1
        }
        guard (minimumDigits...maximumDigits).contains(digitCount) else {
            return nil
        }
        return decimalValue(token[0..<digitCount])
    }

    static func decimalValue(_ digits: ArraySlice<UInt8>) -> Int {
        digits.reduce(into: 0) { value, digit in
            value = value * 10 + Int(digit - 48)
        }
    }

    static func parseMonth(_ token: [UInt8]) -> Int? {
        guard token.count >= 3 else {
            return nil
        }
        let prefix = String(decoding: token.prefix(3).map(lowercaseASCII), as: UTF8.self)
        switch prefix {
        case "jan": return 1
        case "feb": return 2
        case "mar": return 3
        case "apr": return 4
        case "may": return 5
        case "jun": return 6
        case "jul": return 7
        case "aug": return 8
        case "sep": return 9
        case "oct": return 10
        case "nov": return 11
        case "dec": return 12
        default: return nil
        }
    }

    static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }
}
