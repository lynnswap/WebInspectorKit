#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

enum NetworkHeadersTextSectionRuleKind: Hashable {
    case system
    case header

    var color: UIColor {
        switch self {
        case .system:
            NetworkHeadersWebKitStyle.networkSystemColor
        case .header:
            NetworkHeadersWebKitStyle.networkHeaderColor
        }
    }
}

enum NetworkHeadersTextRowStyle: Hashable {
    case summary
    case header
    case pseudoHeader
    case message
    case warning
    case action
}

struct NetworkHeadersTextSectionRule: Equatable {
    var range: NSRange
    var kind: NetworkHeadersTextSectionRuleKind
}

enum NetworkHeadersTextAttributeStyle: Equatable {
    case sectionTitle
    case requestHeading
    case rowKey(NetworkHeadersTextRowStyle)
    case rowValue(NetworkHeadersTextRowStyle)
}

struct NetworkHeadersTextAttributeRun: Equatable {
    var range: NSRange
    var style: NetworkHeadersTextAttributeStyle
}

struct NetworkHeadersTextTag: Equatable {
    var identifier: String
    var range: NSRange
}

struct NetworkHeadersTextDocumentSignature: Equatable {
    var visibleText: String
    var attributeRuns: [NetworkHeadersTextAttributeRun]
    var sectionRules: [NetworkHeadersTextSectionRule]
    var tag: NetworkHeadersTextTag?
}

struct NetworkHeadersTextDocument {
    var attributedString: NSAttributedString
    var sectionRules: [NetworkHeadersTextSectionRule]
    var signature: NetworkHeadersTextDocumentSignature
}

@MainActor
struct NetworkHeadersTextDocumentBuilder {
    private struct Row {
        var key: String
        var value: String?
        var style: NetworkHeadersTextRowStyle
        var alwaysShowsValueSeparator = false
        var tagIdentifier: String?
    }

    private struct Section {
        var title: String
        var rows: [Row]
        var ruleKind: NetworkHeadersTextSectionRuleKind
    }

    var requests: [NetworkRequest]
    var activeRequest: NetworkRequest
    var traitCollection: UITraitCollection

    func makeDocument() -> NetworkHeadersTextDocument {
        let text = NSMutableAttributedString()
        var rules: [NetworkHeadersTextSectionRule] = []
        var attributeRuns: [NetworkHeadersTextAttributeRun] = []
        var tag: NetworkHeadersTextTag?
        for (index, request) in requests.enumerated() {
            if requests.count > 1 {
                appendRequestHeading(
                    request: request,
                    index: index,
                    to: text,
                    attributeRuns: &attributeRuns
                )
            }
            for section in sections(for: request) where section.rows.isEmpty == false {
                append(
                    section: section,
                    to: text,
                    rules: &rules,
                    attributeRuns: &attributeRuns,
                    tag: &tag
                )
            }
        }
        let signature = NetworkHeadersTextDocumentSignature(
            visibleText: text.string,
            attributeRuns: attributeRuns,
            sectionRules: rules,
            tag: tag
        )
        return NetworkHeadersTextDocument(
            attributedString: text,
            sectionRules: rules,
            signature: signature
        )
    }

    private func sections(for request: NetworkRequest) -> [Section] {
        let context = request.headersContext
        var sections = [summarySection(for: request, context: context)]
        for (index, redirect) in request.redirects.enumerated() {
            sections.append(redirectRequestSection(redirect.request, index: index))
            sections.append(redirectResponseSection(redirect.response, index: index))
        }
        sections.append(requestSection(for: request))
        if let responseSection = responseSection(for: request) {
            sections.append(responseSection)
        }
        if let queryParameters = context.queryParameters {
            sections.append(
                parameterSection(
                    title: String(
                        localized: "network.headers.section.query",
                        defaultValue: "Query String Parameters",
                        bundle: WebInspectorUILocalization.bundle
                    ),
                    report: queryParameters
                ))
        }
        if let requestData = context.requestData {
            sections.append(
                requestDataSection(
                    requestData,
                    exposesPreviewAction: request === activeRequest && request.webSocket == nil
                ))
        }
        return sections
    }

    private func summarySection(
        for request: NetworkRequest,
        context: NetworkRequestHeadersContext
    ) -> Section {
        var rows: [Row] = [
            Row(
                key: String(
                    localized: "network.headers.summary.url", defaultValue: "URL",
                    bundle: WebInspectorUILocalization.bundle), value: request.url, style: .summary),
            Row(
                key: String(
                    localized: "network.headers.summary.status", defaultValue: "Status",
                    bundle: WebInspectorUILocalization.bundle), value: statusText(for: request), style: .summary),
            Row(
                key: String(
                    localized: "network.headers.summary.source", defaultValue: "Source",
                    bundle: WebInspectorUILocalization.bundle), value: sourceText(for: request), style: .summary),
        ]
        if request.redirects.isEmpty == false {
            rows.append(
                Row(
                    key: String(
                        localized: "network.headers.summary.redirects", defaultValue: "Redirects",
                        bundle: WebInspectorUILocalization.bundle),
                    value: String(request.redirects.count),
                    style: .summary
                ))
        }
        if let remoteAddress = request.metrics?.remoteAddress, remoteAddress.isEmpty == false {
            rows.append(
                Row(
                    key: String(
                        localized: "network.headers.summary.address", defaultValue: "Address",
                        bundle: WebInspectorUILocalization.bundle),
                    value: remoteAddress,
                    style: .summary
                )
            )
        }
        if let outcome = context.outcome {
            let outcomeText: String
            let reason: String
            switch outcome {
            case .canceled(let rawReason):
                outcomeText = String(
                    localized: "network.headers.summary.outcome.canceled",
                    defaultValue: "Canceled",
                    bundle: WebInspectorUILocalization.bundle
                )
                reason = rawReason
            case .failed(let rawReason):
                outcomeText = String(
                    localized: "network.headers.summary.outcome.failed",
                    defaultValue: "Failed",
                    bundle: WebInspectorUILocalization.bundle
                )
                reason = rawReason
            }
            rows.append(
                Row(
                    key: String(
                        localized: "network.headers.summary.outcome",
                        defaultValue: "Outcome",
                        bundle: WebInspectorUILocalization.bundle
                    ),
                    value: outcomeText,
                    style: .warning
                ))
            rows.append(
                Row(
                    key: String(
                        localized: "network.headers.summary.failure_reason",
                        defaultValue: "Failure Reason",
                        bundle: WebInspectorUILocalization.bundle
                    ),
                    value: reason,
                    style: .warning,
                    alwaysShowsValueSeparator: true
                ))
        }
        if let resourceType = context.resourceType {
            rows.append(
                Row(
                    key: String(
                        localized: "network.headers.summary.resource_type",
                        defaultValue: "Resource Type",
                        bundle: WebInspectorUILocalization.bundle
                    ),
                    value: resourceType,
                    style: .summary
                ))
        }
        if let effectiveMIMEType = context.effectiveMIMEType {
            rows.append(
                Row(
                    key: String(
                        localized: "network.headers.summary.mime_type",
                        defaultValue: "MIME Type",
                        bundle: WebInspectorUILocalization.bundle
                    ),
                    value: effectiveMIMEType,
                    style: .summary
                ))
        }
        if let initiator = context.initiator {
            rows.append(
                Row(
                    key: String(
                        localized: "network.headers.summary.initiator_kind",
                        defaultValue: "Initiator Kind",
                        bundle: WebInspectorUILocalization.bundle
                    ),
                    value: initiator.kind,
                    style: .summary,
                    alwaysShowsValueSeparator: true
                ))
            if let url = initiator.url {
                rows.append(
                    Row(
                        key: String(
                            localized: "network.headers.summary.initiator_url",
                            defaultValue: "Initiator URL",
                            bundle: WebInspectorUILocalization.bundle
                        ),
                        value: url,
                        style: .summary,
                        alwaysShowsValueSeparator: true
                    ))
            }
            if let line = initiator.line {
                // Do not add one: WebKit reports this Network initiator coordinate one-based.
                // Its frontend subtracts one only when creating a zero-based editor location.
                rows.append(
                    Row(
                        key: String(
                            localized: "network.headers.summary.initiator_line",
                            defaultValue: "Initiator Line",
                            bundle: WebInspectorUILocalization.bundle
                        ),
                        value: String(line),
                        style: .summary
                    ))
            }
            if let nodeIDRawValue = initiator.nodeIDRawValue {
                rows.append(
                    Row(
                        key: String(
                            localized: "network.headers.summary.initiator_node",
                            defaultValue: "Initiator Node",
                            bundle: WebInspectorUILocalization.bundle
                        ),
                        value: nodeIDRawValue,
                        style: .summary
                    ))
            }
        }
        return Section(
            title: String(localized: "network.detail.section.overview", bundle: WebInspectorUILocalization.bundle),
            rows: rows,
            ruleKind: .system
        )
    }

    private func parameterSection(
        title: String,
        report: NetworkParameterParseReport
    ) -> Section {
        var rows = parameterRows(report)
        if rows.isEmpty {
            rows.append(
                Row(
                    key: String(
                        localized: "network.headers.parameters.empty",
                        defaultValue: "None",
                        bundle: WebInspectorUILocalization.bundle
                    ),
                    value: nil,
                    style: .message
                ))
        }
        return Section(title: title, rows: rows, ruleKind: .system)
    }

    private func requestDataSection(
        _ requestData: NetworkRequestHeadersContext.RequestData,
        exposesPreviewAction: Bool
    ) -> Section {
        let title = String(
            localized: "network.headers.section.request_data",
            defaultValue: "Request Data",
            bundle: WebInspectorUILocalization.bundle
        )
        var rows: [Row]
        switch requestData {
        case let .form(contentType, parameters):
            rows = contentTypeRows(contentType)
            let parametersSection = parameterSection(title: title, report: parameters)
            rows.append(contentsOf: parametersSection.rows)
        case .body(let contentType):
            rows = contentTypeRows(contentType)
            if exposesPreviewAction {
                rows.append(
                    Row(
                        key: String(
                            localized: "network.headers.request_data.view_preview.inline",
                            defaultValue: "View Preview",
                            bundle: WebInspectorUILocalization.bundle
                        ),
                        value: nil,
                        style: .action,
                        tagIdentifier: NetworkHeadersTextView.requestPreviewTagIdentifier
                    ))
            }
        }
        return Section(title: title, rows: rows, ruleKind: .system)
    }

    private func parameterRows(_ report: NetworkParameterParseReport) -> [Row] {
        report.parameters.map { parameter in
            guard case let .decoded(_, name) = parameter.name,
                case let .decoded(_, value) = parameter.value
            else {
                return Row(
                    key: parameter.rawFragment,
                    value: malformedReasonText(for: parameter),
                    style: .warning,
                    alwaysShowsValueSeparator: true
                )
            }
            return Row(
                key: name,
                value: value,
                style: .summary,
                alwaysShowsValueSeparator: true
            )
        }
    }

    private func malformedReasonText(for parameter: NetworkParameter) -> String {
        var reasons: [NetworkParameter.Component.MalformedReason] = []
        if case let .malformed(_, reason) = parameter.name {
            reasons.append(reason)
        }
        if case let .malformed(_, reason) = parameter.value,
            reasons.contains(reason) == false
        {
            reasons.append(reason)
        }
        return reasons.map(malformedReasonText).joined(separator: ", ")
    }

    private func malformedReasonText(
        _ reason: NetworkParameter.Component.MalformedReason
    ) -> String {
        switch reason {
        case .malformedPercentEscape:
            String(
                localized: "network.headers.parameters.error.percent_escape",
                defaultValue: "Malformed percent escape",
                bundle: WebInspectorUILocalization.bundle
            )
        case .invalidUTF8:
            String(
                localized: "network.headers.parameters.error.utf8",
                defaultValue: "Invalid UTF-8",
                bundle: WebInspectorUILocalization.bundle
            )
        }
    }

    private func contentTypeRows(_ header: NetworkContentTypeHeader) -> [Row] {
        let contentTypeLabel = String(
            localized: "network.headers.request_data.content_type",
            defaultValue: "Content Type",
            bundle: WebInspectorUILocalization.bundle
        )
        switch header {
        case .absent:
            return [
                Row(
                    key: contentTypeLabel,
                    value: "-",
                    style: .message
                )
            ]
        case .ambiguous(let rawValues):
            return [
                Row(
                    key: String(
                        localized: "network.headers.request_data.content_type_ambiguous",
                        defaultValue: "Ambiguous Content Type",
                        bundle: WebInspectorUILocalization.bundle
                    ),
                    value: rawValues.joined(separator: "\n"),
                    style: .warning,
                    alwaysShowsValueSeparator: true
                )
            ]
        case .value(let contentType):
            var rows = [
                Row(
                    key: contentTypeLabel,
                    value: contentType.rawValue,
                    style: contentType.normalizedMediaType == nil ? .warning : .summary,
                    alwaysShowsValueSeparator: true
                )
            ]
            if contentType.mediaType.isEmpty == false {
                rows.append(
                    Row(
                        key: String(
                            localized: "network.headers.request_data.media_type",
                            defaultValue: "Media Type",
                            bundle: WebInspectorUILocalization.bundle
                        ),
                        value: contentType.mediaType,
                        style: contentType.normalizedMediaType == nil ? .warning : .summary
                    ))
            }
            rows.append(
                contentsOf: contentType.boundary.map { boundary in
                    Row(
                        key: String(
                            localized: "network.headers.request_data.boundary",
                            defaultValue: "Boundary",
                            bundle: WebInspectorUILocalization.bundle
                        ),
                        value: boundary,
                        style: .summary,
                        alwaysShowsValueSeparator: true
                    )
                })
            rows.append(
                contentsOf: contentType.charset.map { charset in
                    Row(
                        key: String(
                            localized: "network.headers.request_data.encoding",
                            defaultValue: "Encoding",
                            bundle: WebInspectorUILocalization.bundle
                        ),
                        value: charset,
                        style: .summary,
                        alwaysShowsValueSeparator: true
                    )
                })
            let unparsedParameters = contentType.parameters.compactMap { parameter in
                parameter.issue == nil ? nil : parameter.rawFragment
            }
            if unparsedParameters.isEmpty == false {
                rows.append(
                    Row(
                        key: String(
                            localized: "network.headers.request_data.content_type_parameter_unparsed",
                            defaultValue: "Unparsed Content-Type Parameters",
                            bundle: WebInspectorUILocalization.bundle
                        ),
                        value: unparsedParameters.joined(separator: "\n"),
                        style: .warning,
                        alwaysShowsValueSeparator: true
                    )
                )
            }
            return rows
        }
    }

    private func requestSection(for request: NetworkRequest) -> Section {
        let headers = request.requestHeaders
        var rows: [Row] = requestProtocolRows(
            url: request.url,
            method: request.method,
            protocolName: request.metrics?.networkProtocol
        )
        rows.append(contentsOf: headerRows(headers))
        if rows.isEmpty {
            rows.append(
                Row(
                    key: String(
                        localized: "network.headers.request.empty", defaultValue: "None",
                        bundle: WebInspectorUILocalization.bundle),
                    value: nil,
                    style: .message
                )
            )
        }
        return Section(
            title: String(localized: "network.section.request", bundle: WebInspectorUILocalization.bundle),
            rows: rows,
            ruleKind: .header
        )
    }

    private func responseSection(for request: NetworkRequest) -> Section? {
        guard request.hasResponse else {
            return nil
        }
        let headers = request.responseHeaders
        var rows: [Row] = responseProtocolRows(
            status: request.status,
            statusText: request.statusText,
            protocolName: request.metrics?.networkProtocol
        )
        rows.append(contentsOf: headerRows(headers))
        if rows.isEmpty {
            rows.append(
                Row(
                    key: String(
                        localized: "network.headers.response.empty", defaultValue: "None",
                        bundle: WebInspectorUILocalization.bundle),
                    value: nil,
                    style: .message
                )
            )
        }
        return Section(
            title: String(localized: "network.section.response", bundle: WebInspectorUILocalization.bundle),
            rows: rows,
            ruleKind: .header
        )
    }

    private func redirectRequestSection(
        _ request: NetworkRequestSnapshot,
        index: Int
    ) -> Section {
        var rows = requestProtocolRows(url: request.url, method: request.method, protocolName: nil)
        rows.append(contentsOf: headerRows(request.headers))
        return Section(
            title: String(
                localized: "network.section.redirect_request",
                defaultValue: "Redirect Request",
                bundle: WebInspectorUILocalization.bundle
            ) + " \(index + 1)",
            rows: rows,
            ruleKind: .header
        )
    }

    private func redirectResponseSection(
        _ response: NetworkResponseSnapshot,
        index: Int
    ) -> Section {
        var rows = responseProtocolRows(
            status: response.status,
            statusText: response.statusText,
            protocolName: nil
        )
        rows.append(contentsOf: headerRows(response.headers))
        return Section(
            title: String(
                localized: "network.section.redirect_response",
                defaultValue: "Redirect Response",
                bundle: WebInspectorUILocalization.bundle
            ) + " \(index + 1)",
            rows: rows,
            ruleKind: .header
        )
    }

    private func requestProtocolRows(
        url: String,
        method: String,
        protocolName rawProtocolName: String?
    ) -> [Row] {
        let protocolName = rawProtocolName ?? ""
        let components = URLComponents(string: url)
        if protocolName == "h2" {
            return [
                Row(key: ":method", value: method, style: .pseudoHeader),
                Row(key: ":scheme", value: components?.scheme, style: .pseudoHeader),
                Row(key: ":authority", value: authority(from: components), style: .pseudoHeader),
                Row(key: ":path", value: path(from: components), style: .pseudoHeader),
            ].compactMap { row in
                guard row.value?.isEmpty == false else {
                    return nil
                }
                return row
            }
        }
        let path = path(from: components) ?? "/"
        let suffix = protocolName.hasPrefix("http/1") ? " \(protocolName.uppercased())" : ""
        return [
            Row(key: "\(method) \(path)\(suffix)", value: nil, style: .pseudoHeader)
        ]
    }

    private func responseProtocolRows(
        status: Int?,
        statusText: String?,
        protocolName rawProtocolName: String?
    ) -> [Row] {
        guard let status else {
            return []
        }
        let protocolName = rawProtocolName ?? ""
        if protocolName == "h2" {
            return [Row(key: ":status", value: "\(status)", style: .pseudoHeader)]
        }
        if protocolName.hasPrefix("http/1") {
            let resolvedStatusText = statusText ?? ""
            let suffix = resolvedStatusText.isEmpty ? "" : " \(resolvedStatusText)"
            return [Row(key: "\(protocolName.uppercased()) \(status)\(suffix)", value: nil, style: .pseudoHeader)]
        }
        let resolvedStatusText = statusText ?? ""
        let suffix = resolvedStatusText.isEmpty ? "" : " \(resolvedStatusText)"
        return [Row(key: "\(status)\(suffix)", value: nil, style: .pseudoHeader)]
    }

    private func headerRows(_ headers: [String: String]) -> [Row] {
        headers
            .map { Row(key: $0.key, value: $0.value, style: .header) }
            .sorted {
                let nameComparison = $0.key.localizedCaseInsensitiveCompare($1.key)
                if nameComparison == .orderedSame {
                    return ($0.value ?? "") < ($1.value ?? "")
                }
                return nameComparison == .orderedAscending
            }
    }

    private func statusText(for request: NetworkRequest) -> String {
        guard request.hasResponse else {
            return "-"
        }
        let statusText = request.statusText ?? ""
        let suffix = statusText.isEmpty ? "" : " \(statusText)"
        return request.status.map { "\($0)\(suffix)" } ?? (statusText.isEmpty ? "-" : statusText)
    }

    private func sourceText(for request: NetworkRequest) -> String {
        guard let source = request.responseSource else {
            return "-"
        }
        switch source {
        case "network":
            return String(
                localized: "network.headers.source.network", defaultValue: "Network",
                bundle: WebInspectorUILocalization.bundle)
        case "memory-cache":
            return String(
                localized: "network.headers.source.memory_cache", defaultValue: "Memory Cache",
                bundle: WebInspectorUILocalization.bundle)
        case "disk-cache":
            return String(
                localized: "network.headers.source.disk_cache", defaultValue: "Disk Cache",
                bundle: WebInspectorUILocalization.bundle)
        case "service-worker":
            return String(
                localized: "network.headers.source.service_worker", defaultValue: "Service Worker",
                bundle: WebInspectorUILocalization.bundle)
        case "inspector-override":
            return String(
                localized: "network.headers.source.local_override", defaultValue: "Local Override",
                bundle: WebInspectorUILocalization.bundle)
        default:
            return source
        }
    }

    private func authority(from components: URLComponents?) -> String? {
        guard let host = components?.host, host.isEmpty == false else {
            return nil
        }
        guard let port = components?.port else {
            return host
        }
        return "\(host):\(port)"
    }

    private func path(from components: URLComponents?) -> String? {
        guard let components else {
            return nil
        }
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery, query.isEmpty == false {
            path += "?\(query)"
        }
        return path
    }

    private func appendRequestHeading(
        request: NetworkRequest,
        index: Int,
        to text: NSMutableAttributedString,
        attributeRuns: inout [NetworkHeadersTextAttributeRun]
    ) {
        if text.length > 0 {
            append(
                "\n",
                attributes: rowAttributes(style: .message).value,
                style: .rowValue(.message),
                to: text,
                attributeRuns: &attributeRuns
            )
        }
        append(
            "\(index + 1). \(request.displayName)\n",
            attributes: requestHeadingAttributes(),
            style: .requestHeading,
            to: text,
            attributeRuns: &attributeRuns
        )
    }

    private func append(
        section: Section,
        to text: NSMutableAttributedString,
        rules: inout [NetworkHeadersTextSectionRule],
        attributeRuns: inout [NetworkHeadersTextAttributeRun],
        tag: inout NetworkHeadersTextTag?
    ) {
        if text.length > 0 {
            append(
                "\n",
                attributes: rowAttributes(style: .message).value,
                style: .rowValue(.message),
                to: text,
                attributeRuns: &attributeRuns
            )
        }

        append(
            section.title + "\n",
            attributes: sectionTitleAttributes(),
            style: .sectionTitle,
            to: text,
            attributeRuns: &attributeRuns
        )
        let ruleStart = text.length
        for row in section.rows {
            append(
                row: row,
                to: text,
                attributeRuns: &attributeRuns,
                tag: &tag
            )
        }
        let ruleLength = text.length - ruleStart
        if ruleLength > 0 {
            rules.append(
                NetworkHeadersTextSectionRule(
                    range: NSRange(location: ruleStart, length: ruleLength),
                    kind: section.ruleKind
                ))
        }
    }

    private func append(
        row: Row,
        to text: NSMutableAttributedString,
        attributeRuns: inout [NetworkHeadersTextAttributeRun],
        tag: inout NetworkHeadersTextTag?
    ) {
        let attributes = rowAttributes(style: row.style)
        let keyRange = append(
            row.key,
            attributes: attributes.key,
            style: .rowKey(row.style),
            to: text,
            attributeRuns: &attributeRuns
        )
        if let tagIdentifier = row.tagIdentifier {
            precondition(tag == nil, "Network headers may expose only one active request preview action.")
            text.addAttributes(
                [
                    .textItemTag: tagIdentifier,
                    .foregroundColor: UIColor.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: keyRange)
            tag = NetworkHeadersTextTag(identifier: tagIdentifier, range: keyRange)
        }
        if let value = row.value, value.isEmpty == false || row.alwaysShowsValueSeparator {
            append(
                ": ",
                attributes: attributes.key,
                style: .rowKey(row.style),
                to: text,
                attributeRuns: &attributeRuns
            )
            append(
                value,
                attributes: attributes.value,
                style: .rowValue(row.style),
                to: text,
                attributeRuns: &attributeRuns
            )
        } else if row.value == nil, row.alwaysShowsValueSeparator {
            append(
                ": ",
                attributes: attributes.key,
                style: .rowKey(row.style),
                to: text,
                attributeRuns: &attributeRuns
            )
        }
        append(
            "\n",
            attributes: attributes.value,
            style: .rowValue(row.style),
            to: text,
            attributeRuns: &attributeRuns
        )
    }

    @discardableResult
    private func append(
        _ string: String,
        attributes: [NSAttributedString.Key: Any],
        style: NetworkHeadersTextAttributeStyle,
        to text: NSMutableAttributedString,
        attributeRuns: inout [NetworkHeadersTextAttributeRun]
    ) -> NSRange {
        let range = NSRange(location: text.length, length: string.utf16.count)
        text.append(NSAttributedString(string: string, attributes: attributes))
        if range.length > 0 {
            attributeRuns.append(NetworkHeadersTextAttributeRun(range: range, style: style))
        }
        return range
    }

    private func sectionTitleAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.paragraphSpacing = NetworkHeadersWebKitStyle.sectionTitleBottomSpacing
        return [
            .font: NetworkHeadersWebKitStyle.sectionTitleFont(compatibleWith: traitCollection),
            .foregroundColor: NetworkHeadersWebKitStyle.textColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private func requestHeadingAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.paragraphSpacing = NetworkHeadersWebKitStyle.sectionTitleBottomSpacing
        return [
            .font: UIFont.preferredFont(
                forTextStyle: .headline,
                compatibleWith: traitCollection
            ),
            .foregroundColor: NetworkHeadersWebKitStyle.textColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private func rowAttributes(
        style: NetworkHeadersTextRowStyle
    ) -> (key: [NSAttributedString.Key: Any], value: [NSAttributedString.Key: Any]) {
        let font = NetworkHeadersWebKitStyle.bodyFont(compatibleWith: traitCollection)
        let keyFont = NetworkHeadersWebKitStyle.keyFont(compatibleWith: traitCollection)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.firstLineHeadIndent = NetworkHeadersWebKitStyle.rowFirstLineHeadIndent
        paragraphStyle.headIndent = NetworkHeadersWebKitStyle.rowWrappedLineHeadIndent
        paragraphStyle.paragraphSpacingBefore = NetworkHeadersWebKitStyle.rowVerticalPadding
        paragraphStyle.paragraphSpacing = NetworkHeadersWebKitStyle.rowVerticalPadding

        let keyColor: UIColor
        switch style {
        case .summary:
            keyColor = NetworkHeadersWebKitStyle.networkSystemColor
        case .header:
            keyColor = NetworkHeadersWebKitStyle.networkHeaderColor
        case .pseudoHeader:
            keyColor = NetworkHeadersWebKitStyle.networkPseudoHeaderColor
        case .message:
            keyColor = NetworkHeadersWebKitStyle.consoleSecondaryTextColor
        case .warning:
            keyColor = .systemOrange
        case .action:
            keyColor = .link
        }

        let keyAttributes: [NSAttributedString.Key: Any] = [
            .font: keyFont,
            .foregroundColor: keyColor,
            .paragraphStyle: paragraphStyle,
        ]
        let valueColor: UIColor =
            switch style {
            case .message:
                NetworkHeadersWebKitStyle.consoleSecondaryTextColor
            case .warning:
                .systemOrange
            case .action:
                .link
            default:
                NetworkHeadersWebKitStyle.textColor
            }
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: valueColor,
            .paragraphStyle: paragraphStyle,
        ]
        return (keyAttributes, valueAttributes)
    }
}

enum NetworkHeadersWebKitStyle {
    static let textInsets = UIEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
    static let ruleWidth: CGFloat = 2
    static let ruleGap = detailsTextPadding
    static let sectionTitleBottomSpacing: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 2
    private static let detailsMarginStart: CGFloat = 12
    private static let detailsTextPadding: CGFloat = 12
    private static let detailsValueIndent: CGFloat = 12
    static let rowFirstLineHeadIndent = detailsMarginStart + detailsTextPadding
    static let rowWrappedLineHeadIndent = rowFirstLineHeadIndent + detailsValueIndent

    static func bodyFont(compatibleWith traitCollection: UITraitCollection) -> UIFont {
        UIFont.preferredFont(forTextStyle: .callout, compatibleWith: traitCollection)
    }

    static func keyFont(compatibleWith traitCollection: UITraitCollection) -> UIFont {
        bodyFont(compatibleWith: traitCollection).withWeight(.medium)
    }

    static func sectionTitleFont(compatibleWith traitCollection: UITraitCollection) -> UIFont {
        UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traitCollection)
    }

    static var textColor: UIColor {
        dynamic(light: .black, dark: hsl(0, 0, 88))
    }

    static var consoleSecondaryTextColor: UIColor {
        dynamic(
            light: hsl(0, 0, 0, alpha: 0.33),
            dark: hsl(0, 0, 100, alpha: 0.45)
        )
    }

    static var networkSystemColor: UIColor {
        dynamic(light: hsl(79, 32, 50), dark: hsl(79, 95, 50))
    }

    static var networkHeaderColor: UIColor {
        hsl(204, 52, 55)
    }

    static var networkPseudoHeaderColor: UIColor {
        dynamic(light: hsl(312, 35, 51), dark: hsl(312, 55, 61))
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        }
    }

    private static func hsl(
        _ hue: CGFloat,
        _ saturation: CGFloat,
        _ lightness: CGFloat,
        alpha: CGFloat = 1
    ) -> UIColor {
        let hue = hue / 360
        let saturation = saturation / 100
        let lightness = lightness / 100
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let huePrime = hue * 6
        let secondary = chroma * (1 - abs(huePrime.truncatingRemainder(dividingBy: 2) - 1))
        let match = lightness - chroma / 2

        let components: (red: CGFloat, green: CGFloat, blue: CGFloat)
        switch huePrime {
        case 0..<1:
            components = (chroma, secondary, 0)
        case 1..<2:
            components = (secondary, chroma, 0)
        case 2..<3:
            components = (0, chroma, secondary)
        case 3..<4:
            components = (0, secondary, chroma)
        case 4..<5:
            components = (secondary, 0, chroma)
        default:
            components = (chroma, 0, secondary)
        }

        return UIColor(
            red: components.red + match,
            green: components.green + match,
            blue: components.blue + match,
            alpha: alpha
        )
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
#endif
