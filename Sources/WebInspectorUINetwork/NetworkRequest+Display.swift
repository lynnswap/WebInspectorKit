import WebInspectorUIBase
import WebInspectorCore
import Foundation

package enum NetworkDisplay {}

extension NetworkDisplay {
    package typealias MediaPreviewClassifier = @Sendable (String?, String?) -> NetworkDisplay.MediaPreviewClassification

    package struct Projection {
        package var requestURLSummary: NetworkDisplay.URLSummary
        package var responseURLSummary: NetworkDisplay.URLSummary?
        package var fileTypeLabel: String
        package var searchTokens: [String]

        package init(
            requestURLSummary: NetworkDisplay.URLSummary,
            responseURLSummary: NetworkDisplay.URLSummary?,
            fileTypeLabel: String,
            searchTokens: [String]
        ) {
            self.requestURLSummary = requestURLSummary
            self.responseURLSummary = responseURLSummary
            self.fileTypeLabel = fileTypeLabel
            self.searchTokens = searchTokens
        }
    }
}

extension NetworkRequest {
    package var displayName: String {
        NetworkDisplay.URLSummary(url: request.url).displayName
    }

    package var statusLabel: String {
        if let status = response?.status, status > 0 {
            return String(status)
        }
        switch state {
        case .failed:
            return "Failed"
        case .pending:
            return "Pending"
        case .responded:
            return "Pending"
        case .finished:
            return "Finished"
        }
    }

    package var fileTypeLabel: String {
        NetworkDisplay.fileTypeLabel(
            mimeType: response?.mimeType,
            resourceType: resourceType,
            urlSummary: NetworkDisplay.URLSummary(url: request.url)
        )
    }

    package var statusSeverity: NetworkDisplay.StatusSeverity {
        if case .failed = state {
            return .error
        }
        if let status = response?.status {
            if status >= 500 {
                return .error
            }
            if status >= 400 {
                return .warning
            }
            if status >= 300 {
                return .notice
            }
            return .success
        }
        if state == .finished {
            return .success
        }
        return .neutral
    }

    package func matchesDisplaySearchText(_ query: String) -> Bool {
        guard query.isEmpty == false else {
            return true
        }
        return displayProjection().searchTokens.contains { $0.localizedStandardContains(query) }
    }

    package func displayResourceFilter(
        mediaPreviewClassifier: NetworkDisplay.MediaPreviewClassifier
    ) -> NetworkDisplay.ResourceFilter {
        let requestURLSummary = NetworkDisplay.URLSummary(url: request.url)
        let responseURLSummary = response.map { NetworkDisplay.URLSummary(url: $0.url) }
        return NetworkDisplay.resourceFilter(
            resourceType: resourceType,
            response: response,
            requestURLSummary: requestURLSummary,
            responseURLSummary: responseURLSummary,
            mediaPreviewClassifier: mediaPreviewClassifier
        )
    }

    package func displayProjection() -> NetworkDisplay.Projection {
        let requestURLSummary = NetworkDisplay.URLSummary(url: request.url)
        let responseURLSummary = response.map { NetworkDisplay.URLSummary(url: $0.url) }
        let fileTypeLabel = NetworkDisplay.fileTypeLabel(
            mimeType: response?.mimeType,
            resourceType: resourceType,
            urlSummary: requestURLSummary
        )
        let statusCodeLabel = response.map { String($0.status) } ?? ""
        return NetworkDisplay.Projection(
            requestURLSummary: requestURLSummary,
            responseURLSummary: responseURLSummary,
            fileTypeLabel: fileTypeLabel,
            searchTokens: NetworkDisplay.searchTokens(
                requestURLSummary: requestURLSummary,
                responseURLSummary: responseURLSummary,
                requestMethod: request.method,
                statusCodeLabel: statusCodeLabel,
                statusText: response?.statusText ?? "",
                fileTypeLabel: fileTypeLabel
            )
        )
    }

    package var duration: TimeInterval? {
        guard let end = finishedOrFailedTimestamp ?? lastDataReceivedTimestamp ?? responseReceivedTimestamp else {
            return nil
        }
        return max(0, end - requestSentTimestamp)
    }

    package func durationText(for value: TimeInterval) -> String {
        if value < 1 {
            let milliseconds = Int((value * 1000).rounded())
            return "\(milliseconds) ms"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        let seconds = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return "\(seconds) s"
    }

    package func sizeText(for length: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(length))
    }
}

extension NetworkDisplay {
    package static func resourceFilter(
        resourceType: NetworkRequest.ResourceType?,
        response: NetworkRequest.Response.Payload?,
        requestURLSummary: NetworkDisplay.URLSummary,
        responseURLSummary: NetworkDisplay.URLSummary?,
        mediaPreviewClassifier: NetworkDisplay.MediaPreviewClassifier
    ) -> NetworkDisplay.ResourceFilter {
        guard let response else {
            if let resourceType {
                return NetworkDisplay.ResourceFilter(resourceType: resourceType)
            }
            return NetworkDisplay.ResourceFilter.inferred(
                mimeType: nil,
                pathExtension: requestURLSummary.pathExtension,
                mediaPreviewClassification: mediaPreviewClassifier(nil, requestURLSummary.rawURL)
            )
        }

        let responseMIMEType = NetworkDisplay.displayMIMEType(
            mimeType: response.mimeType,
            headers: response.headers
        )
        if let resourceType,
           NetworkDisplay.shouldKeepResourceTypeForURLInferredMedia(resourceType) {
            if case .previewable = mediaPreviewClassifier(responseMIMEType, nil) {
                return .media
            }
            return NetworkDisplay.ResourceFilter(resourceType: resourceType)
        }

        let responseURLSummary = responseURLSummary ?? NetworkDisplay.URLSummary(url: response.url)
        switch mediaPreviewClassifier(responseMIMEType, responseURLSummary.rawURL) {
        case .previewable:
            return .media
        case .notPreviewable:
            if resourceType == .image || resourceType == .media {
                return .media
            }
            return NetworkDisplay.ResourceFilter.inferred(
                mimeType: responseMIMEType,
                pathExtension: responseURLSummary.pathExtension,
                mediaPreviewClassification: mediaPreviewClassifier(responseMIMEType, responseURLSummary.rawURL)
            )
        case .unknown:
            break
        }
        if let resourceType {
            return NetworkDisplay.ResourceFilter(resourceType: resourceType)
        }
        return NetworkDisplay.ResourceFilter.inferred(
            mimeType: responseMIMEType,
            pathExtension: responseURLSummary.pathExtension,
            mediaPreviewClassification: mediaPreviewClassifier(responseMIMEType, responseURLSummary.rawURL)
        )
    }

    package static func fileTypeLabel(
        mimeType: String?,
        resourceType: NetworkRequest.ResourceType?,
        urlSummary: NetworkDisplay.URLSummary
    ) -> String {
        if let mimeType,
           let subtype = mimeType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .split(separator: "/")
            .last,
           subtype.isEmpty == false {
            return subtype.lowercased()
        }
        if let pathExtension = urlSummary.pathExtension,
           pathExtension.isEmpty == false {
            return pathExtension
        }
        if let resourceType {
            return resourceType.displayLabel
        }
        return "-"
    }

    package static func displayMIMEType(mimeType: String?, headers: [String: String]) -> String? {
        let rawMimeType = mimeType ?? headerValue(named: "content-type", in: headers)
        let mimeType = rawMimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mimeType, mimeType.isEmpty == false else {
            return nil
        }
        return mimeType
    }

    package static func searchTokens(
        requestURLSummary: NetworkDisplay.URLSummary,
        responseURLSummary: NetworkDisplay.URLSummary?,
        requestMethod: String,
        statusCodeLabel: String,
        statusText: String,
        fileTypeLabel: String
    ) -> [String] {
        uniqueNonEmpty(
            requestURLSummary.searchTokens
            + (responseURLSummary?.searchTokens ?? [])
            + [
                requestMethod,
                statusCodeLabel,
                statusText,
                fileTypeLabel,
            ]
        )
    }

    fileprivate static func shouldKeepResourceTypeForURLInferredMedia(_ resourceType: NetworkRequest.ResourceType) -> Bool {
        switch resourceType {
        case .image, .media, .xhr, .fetch, .other:
            return false
        default:
            return true
        }
    }

    fileprivate static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where value.isEmpty == false && seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private static func headerValue(named name: String, in headers: [String: String]) -> String? {
        if let value = headers[name] {
            return value
        }
        return headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

extension NetworkRequest.ResourceType {
    fileprivate var displayLabel: String {
        switch self {
        case .document:
            "document"
        case .styleSheet:
            "stylesheet"
        case .image:
            "image"
        case .media:
            "media"
        case .font:
            "font"
        case .script:
            "script"
        case .xhr:
            "xhr"
        case .fetch:
            "fetch"
        case .ping:
            "ping"
        case .beacon:
            "beacon"
        case .webSocket:
            "websocket"
        case .eventSource:
            "eventsource"
        case .other:
            "other"
        default:
            rawValue.lowercased()
        }
    }
}
