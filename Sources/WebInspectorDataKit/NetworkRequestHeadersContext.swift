import Foundation
import WebInspectorProxyKit

package enum NetworkParameterParseStatus: Hashable, Sendable {
    case complete
    case partial
    case unparsed
}

package struct NetworkParameterParseDiagnostic: Hashable, Sendable {
    package enum Field: Hashable, Sendable {
        case name
        case value
    }

    package let ordinal: Int
    package let field: Field
    package let rawValue: String
    package let reason: NetworkParameter.Component.MalformedReason

    package init(
        ordinal: Int,
        field: Field,
        rawValue: String,
        reason: NetworkParameter.Component.MalformedReason
    ) {
        self.ordinal = ordinal
        self.field = field
        self.rawValue = rawValue
        self.reason = reason
    }
}

package struct NetworkParameterParseReport: Hashable, Sendable {
    package let rawValue: String
    package let parameters: [NetworkParameter]

    package var diagnostics: [NetworkParameterParseDiagnostic] {
        parameters.flatMap { parameter in
            var diagnostics: [NetworkParameterParseDiagnostic] = []
            if case let .malformed(rawValue, reason) = parameter.name {
                diagnostics.append(
                    NetworkParameterParseDiagnostic(
                        ordinal: parameter.ordinal,
                        field: .name,
                        rawValue: rawValue,
                        reason: reason
                    ))
            }
            if case let .malformed(rawValue, reason) = parameter.value {
                diagnostics.append(
                    NetworkParameterParseDiagnostic(
                        ordinal: parameter.ordinal,
                        field: .value,
                        rawValue: rawValue,
                        reason: reason
                    ))
            }
            return diagnostics
        }
    }

    package var status: NetworkParameterParseStatus {
        let malformedComponentCount = parameters.reduce(into: 0) { count, parameter in
            count += parameter.name.isMalformed ? 1 : 0
            count += parameter.value.isMalformed ? 1 : 0
        }
        guard malformedComponentCount > 0 else {
            return .complete
        }
        return malformedComponentCount == parameters.count * 2 ? .unparsed : .partial
    }

    package init(rawValue: String, parameters: [NetworkParameter]) {
        self.rawValue = rawValue
        self.parameters = parameters
    }
}

package struct NetworkParameter: Identifiable, Hashable, Sendable {
    package enum Component: Hashable, Sendable {
        package enum MalformedReason: Hashable, Sendable {
            case malformedPercentEscape
            case invalidUTF8
        }

        case decoded(rawValue: String, value: String)
        case malformed(rawValue: String, reason: MalformedReason)

        package var rawValue: String {
            switch self {
            case let .decoded(rawValue, _), let .malformed(rawValue, _):
                rawValue
            }
        }

        package var decodedValue: String? {
            guard case let .decoded(_, value) = self else {
                return nil
            }
            return value
        }

        package var displayValue: String {
            decodedValue ?? rawValue
        }

        fileprivate var isMalformed: Bool {
            guard case .malformed = self else {
                return false
            }
            return true
        }
    }

    package var id: Int { ordinal }
    package let ordinal: Int
    package let rawFragment: String
    package let hadEqualsSign: Bool
    package let name: Component
    package let value: Component

    package init(
        ordinal: Int,
        rawFragment: String,
        hadEqualsSign: Bool,
        name: Component,
        value: Component
    ) {
        self.ordinal = ordinal
        self.rawFragment = rawFragment
        self.hadEqualsSign = hadEqualsSign
        self.name = name
        self.value = value
    }
}

package enum NetworkParameterParser {
    package static func parseQuery(in rawURL: String) -> NetworkParameterParseReport? {
        // URLComponents may reject or normalize the malformed escapes this report must preserve.
        let querySearchEnd = rawURL.firstIndex(of: "#") ?? rawURL.endIndex
        guard let questionMark = rawURL[..<querySearchEnd].firstIndex(of: "?") else {
            return nil
        }
        let queryStart = rawURL.index(after: questionMark)
        return parse(String(rawURL[queryStart..<querySearchEnd]))
    }

    package static func parseForm(_ rawValue: String) -> NetworkParameterParseReport {
        parse(rawValue)
    }

    private static func parse(_ rawValue: String) -> NetworkParameterParseReport {
        guard rawValue.isEmpty == false else {
            return NetworkParameterParseReport(rawValue: rawValue, parameters: [])
        }

        let fragments = rawValue.split(separator: "&", omittingEmptySubsequences: false)
        let parameters = fragments.enumerated().map { ordinal, fragment in
            let rawFragment = String(fragment)
            let parts = rawFragment.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let hadEqualsSign = parts.count == 2
            let rawName = parts.first.map(String.init) ?? ""
            let rawValue = hadEqualsSign ? String(parts[1]) : ""
            return NetworkParameter(
                ordinal: ordinal,
                rawFragment: rawFragment,
                hadEqualsSign: hadEqualsSign,
                name: decode(rawName),
                value: decode(rawValue)
            )
        }
        return NetworkParameterParseReport(rawValue: rawValue, parameters: parameters)
    }

    private static func decode(_ rawValue: String) -> NetworkParameter.Component {
        let source = Array(rawValue.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            switch source[index] {
            case 0x2B:
                decoded.append(0x20)
                index += 1
            case 0x25:
                guard index + 2 < source.count,
                    let high = hexadecimalValue(source[index + 1]),
                    let low = hexadecimalValue(source[index + 2])
                else {
                    return .malformed(rawValue: rawValue, reason: .malformedPercentEscape)
                }
                decoded.append((high << 4) | low)
                index += 3
            default:
                decoded.append(source[index])
                index += 1
            }
        }
        guard let value = String(bytes: decoded, encoding: .utf8) else {
            return .malformed(rawValue: rawValue, reason: .invalidUTF8)
        }
        return .decoded(rawValue: rawValue, value: value)
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            byte - 48
        case 65...70:
            byte - 55
        case 97...102:
            byte - 87
        default:
            nil
        }
    }
}

package enum NetworkContentTypeHeader: Hashable, Sendable {
    case absent
    case value(NetworkContentType)
    case ambiguous(rawValues: [String])

    package var contentType: NetworkContentType? {
        guard case let .value(contentType) = self else {
            return nil
        }
        return contentType
    }
}

package struct NetworkContentType: Hashable, Sendable {
    package struct Parameter: Identifiable, Hashable, Sendable {
        package enum Issue: Hashable, Sendable {
            case missingEqualsSign
            case invalidName
            case invalidValue
            case malformedQuotedValue
        }

        package var id: Int { ordinal }
        package let ordinal: Int
        package let rawFragment: String
        package let rawName: String?
        package let normalizedName: String?
        package let rawValue: String?
        package let value: String?
        package let issue: Issue?

        package init(
            ordinal: Int,
            rawFragment: String,
            rawName: String?,
            normalizedName: String?,
            rawValue: String?,
            value: String?,
            issue: Issue?
        ) {
            self.ordinal = ordinal
            self.rawFragment = rawFragment
            self.rawName = rawName
            self.normalizedName = normalizedName
            self.rawValue = rawValue
            self.value = value
            self.issue = issue
        }
    }

    package let rawValue: String
    package let mediaType: String
    package let normalizedMediaType: String?
    package let parameters: [Parameter]

    package var boundary: [String] {
        parameterValues(named: "boundary")
    }

    package var charset: [String] {
        parameterValues(named: "charset")
    }

    package init(
        rawValue: String,
        mediaType: String,
        normalizedMediaType: String?,
        parameters: [Parameter]
    ) {
        self.rawValue = rawValue
        self.mediaType = mediaType
        self.normalizedMediaType = normalizedMediaType
        self.parameters = parameters
    }

    private func parameterValues(named name: String) -> [String] {
        parameters.compactMap { parameter in
            guard parameter.normalizedName == name, parameter.issue == nil else {
                return nil
            }
            return parameter.value
        }
    }
}

package enum NetworkContentTypeParser {
    private enum ParameterValueParseResult {
        case value(String)
        case issue(NetworkContentType.Parameter.Issue)
    }

    package static func parseHeader(in headers: [String: String]) -> NetworkContentTypeHeader {
        // Case-variant dictionary keys are distinct protocol fields; choosing one would invent precedence.
        let fields = headers.compactMap { name, value -> (name: String, value: String)? in
            guard NetworkHTTPGrammar.asciiCaseInsensitiveEqual(name, "Content-Type") else {
                return nil
            }
            return (name, value)
        }.sorted { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.value < rhs.value
        }
        switch fields.count {
        case 0:
            return .absent
        case 1:
            return .value(parse(fields[0].value))
        default:
            return .ambiguous(rawValues: fields.map(\.value))
        }
    }

    package static func parse(_ rawValue: String) -> NetworkContentType {
        let fragments = quoteAwareFragments(in: rawValue)
        let rawMediaType = fragments.first ?? ""
        let mediaType = NetworkHTTPGrammar.trimOptionalWhitespace(rawMediaType)
        let normalizedMediaType = normalizedMediaType(mediaType)
        let parameters = fragments.dropFirst().enumerated().map { ordinal, fragment in
            parseParameter(rawFragment: fragment, ordinal: ordinal)
        }
        return NetworkContentType(
            rawValue: rawValue,
            mediaType: mediaType,
            normalizedMediaType: normalizedMediaType,
            parameters: parameters
        )
    }

    package static func effectiveMediaType(
        protocolMIMEType: String?,
        headers: [String: String]
    ) -> String? {
        if let protocolMIMEType {
            let trimmed = NetworkHTTPGrammar.trimOptionalWhitespace(protocolMIMEType)
            if trimmed.isEmpty == false {
                return trimmed
            }
        }
        guard case let .value(contentType) = parseHeader(in: headers),
            contentType.mediaType.isEmpty == false
        else {
            return nil
        }
        return contentType.mediaType
    }

    package static func effectiveNormalizedMediaType(
        protocolMIMEType: String?,
        headers: [String: String]
    ) -> String? {
        if let protocolMIMEType {
            let trimmed = NetworkHTTPGrammar.trimOptionalWhitespace(protocolMIMEType)
            if trimmed.isEmpty == false {
                return parse(trimmed).normalizedMediaType
            }
        }
        return parseHeader(in: headers).contentType?.normalizedMediaType
    }

    private static func normalizedMediaType(_ mediaType: String) -> String? {
        let components = mediaType.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
            NetworkHTTPGrammar.isHTTPToken(String(components[0])),
            NetworkHTTPGrammar.isHTTPToken(String(components[1]))
        else {
            return nil
        }
        return NetworkHTTPGrammar.lowercaseASCII(mediaType)
    }

    private static func parseParameter(rawFragment: String, ordinal: Int) -> NetworkContentType.Parameter {
        let trimmed = NetworkHTTPGrammar.trimOptionalWhitespace(rawFragment)
        guard let equalsIndex = firstUnquotedEquals(in: trimmed) else {
            return NetworkContentType.Parameter(
                ordinal: ordinal,
                rawFragment: rawFragment,
                rawName: trimmed.isEmpty ? nil : trimmed,
                normalizedName: nil,
                rawValue: nil,
                value: nil,
                issue: .missingEqualsSign
            )
        }

        let rawName = NetworkHTTPGrammar.trimOptionalWhitespace(String(trimmed[..<equalsIndex]))
        let valueStart = trimmed.index(after: equalsIndex)
        let rawValue = NetworkHTTPGrammar.trimOptionalWhitespace(String(trimmed[valueStart...]))
        guard NetworkHTTPGrammar.isHTTPToken(rawName) else {
            return NetworkContentType.Parameter(
                ordinal: ordinal,
                rawFragment: rawFragment,
                rawName: rawName,
                normalizedName: nil,
                rawValue: rawValue,
                value: nil,
                issue: .invalidName
            )
        }

        let normalizedName = NetworkHTTPGrammar.lowercaseASCII(rawName)
        switch parseParameterValue(rawValue) {
        case let .value(value):
            return NetworkContentType.Parameter(
                ordinal: ordinal,
                rawFragment: rawFragment,
                rawName: rawName,
                normalizedName: normalizedName,
                rawValue: rawValue,
                value: value,
                issue: nil
            )
        case let .issue(issue):
            return NetworkContentType.Parameter(
                ordinal: ordinal,
                rawFragment: rawFragment,
                rawName: rawName,
                normalizedName: normalizedName,
                rawValue: rawValue,
                value: nil,
                issue: issue
            )
        }
    }

    private static func parseParameterValue(
        _ rawValue: String
    ) -> ParameterValueParseResult {
        guard rawValue.first == "\"" else {
            return NetworkHTTPGrammar.isHTTPToken(rawValue)
                ? .value(rawValue)
                : .issue(.invalidValue)
        }

        let bytes = Array(rawValue.utf8)
        var valueBytes: [UInt8] = []
        valueBytes.reserveCapacity(max(bytes.count - 2, 0))
        var index = 1
        var didClose = false
        while index < bytes.count {
            switch bytes[index] {
            case 0x22:
                didClose = true
                index += 1
            case 0x5C:
                guard index + 1 < bytes.count else {
                    return .issue(.malformedQuotedValue)
                }
                let escapedByte = bytes[index + 1]
                guard isAllowedQuotedValueByte(escapedByte) else {
                    return .issue(.malformedQuotedValue)
                }
                valueBytes.append(escapedByte)
                index += 2
                continue
            default:
                let byte = bytes[index]
                guard isAllowedQuotedValueByte(byte) else {
                    return .issue(.malformedQuotedValue)
                }
                valueBytes.append(byte)
                index += 1
                continue
            }
            break
        }
        guard didClose, index == bytes.count,
            let value = String(bytes: valueBytes, encoding: .utf8)
        else {
            return .issue(.malformedQuotedValue)
        }
        return .value(value)
    }

    private static func isAllowedQuotedValueByte(_ byte: UInt8) -> Bool {
        byte == 0x09 || (byte >= 0x20 && byte != 0x7F)
    }

    private static func quoteAwareFragments(in rawValue: String) -> [String] {
        let bytes = Array(rawValue.utf8)
        var fragments: [String] = []
        var fragmentStart = 0
        var insideQuotes = false
        var escaped = false
        for index in bytes.indices {
            let byte = bytes[index]
            if escaped {
                escaped = false
                continue
            }
            if insideQuotes, byte == 0x5C {
                escaped = true
                continue
            }
            if byte == 0x22 {
                insideQuotes.toggle()
                continue
            }
            if byte == 0x3B, insideQuotes == false {
                fragments.append(String(decoding: bytes[fragmentStart..<index], as: UTF8.self))
                fragmentStart = index + 1
            }
        }
        fragments.append(String(decoding: bytes[fragmentStart...], as: UTF8.self))
        return fragments
    }

    private static func firstUnquotedEquals(in value: String) -> String.Index? {
        var insideQuotes = false
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped {
                escaped = false
                continue
            }
            if insideQuotes, character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" {
                insideQuotes.toggle()
                continue
            }
            if character == "=", insideQuotes == false {
                return index
            }
        }
        return nil
    }
}

package struct NetworkRequestHeadersContext: Hashable, Sendable {
    package enum Outcome: Hashable, Sendable {
        case canceled(reason: String)
        case failed(reason: String)
    }

    package struct Initiator: Hashable, Sendable {
        package let kind: String
        package let url: String?
        package let line: Int?
        package let nodeID: DOM.Node.ID?

        package init(kind: String, url: String?, line: Int?, nodeID: DOM.Node.ID?) {
            self.kind = kind
            self.url = url
            self.line = line
            self.nodeID = nodeID
        }
    }

    package enum RequestData: Hashable, Sendable {
        case form(
            contentType: NetworkContentTypeHeader,
            parameters: NetworkParameterParseReport
        )
        case body(contentType: NetworkContentTypeHeader)
    }

    package let outcome: Outcome?
    package let resourceType: String?
    package let effectiveMIMEType: String?
    package let initiator: Initiator?
    package let queryParameters: NetworkParameterParseReport?
    package let requestData: RequestData?

    fileprivate init(request: NetworkRequest) {
        switch request.state {
        case let .failed(errorText, canceled: true):
            outcome = .canceled(reason: errorText)
        case let .failed(errorText, canceled: false):
            outcome = .failed(reason: errorText)
        case .pending, .responded, .finished:
            outcome = nil
        }
        resourceType = request.resourceType?.rawValue
        effectiveMIMEType = NetworkContentTypeParser.effectiveMediaType(
            protocolMIMEType: request.mimeType,
            headers: request.responseHeaders
        )
        initiator = request.initiator.map {
            Initiator(kind: $0.kind, url: $0.url, line: $0.line, nodeID: $0.nodeID)
        }
        queryParameters = NetworkParameterParser.parseQuery(in: request.url)

        requestData = Self.makeRequestData(
            requestBody: request.requestBody,
            requestHeaders: request.requestHeaders
        )
    }

    static func makeRequestData(
        requestBody: NetworkBody?,
        requestHeaders: [String: String]
    ) -> RequestData? {
        guard let requestBody, let rawBody = requestBody.full else {
            return nil
        }
        let contentType = NetworkContentTypeParser.parseHeader(in: requestHeaders)
        if requestBody.kind == .form,
            requestBody.isBase64Encoded == false
        {
            return .form(
                contentType: contentType,
                parameters: NetworkParameterParser.parseForm(rawBody)
            )
        }
        return .body(contentType: contentType)
    }
}

extension NetworkRequest {
    package var headersContext: NetworkRequestHeadersContext {
        NetworkRequestHeadersContext(request: self)
    }
}

private enum NetworkHTTPGrammar {
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
        (65...90).contains(byte) ? byte + 32 : byte
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

    static func isHTTPToken(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.isEmpty == false && bytes.allSatisfy(isHTTPTokenCharacter)
    }

    private static func isOptionalWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }

    private static func isHTTPTokenCharacter(_ byte: UInt8) -> Bool {
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
}
