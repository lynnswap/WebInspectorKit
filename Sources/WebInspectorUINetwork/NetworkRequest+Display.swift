import WebInspectorUIBase
import Foundation

package enum NetworkDisplay {}

extension NetworkDisplay {
    package typealias MediaPreviewClassifier = @Sendable (String?, String?) -> NetworkDisplay.MediaPreviewClassification

    package struct Projection: Equatable {
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

extension NetworkDisplay {
    package static func resourceFilter(
        resourceTypeRawValue: String?,
        hasResponse: Bool,
        responseMIMEType: String?,
        responseHeaders: [String: String],
        responseURLSummary: NetworkDisplay.URLSummary?,
        requestURLSummary: NetworkDisplay.URLSummary,
        mediaPreviewClassifier: NetworkDisplay.MediaPreviewClassifier
    ) -> NetworkDisplay.ResourceFilter {
        guard hasResponse else {
            if let resourceTypeRawValue {
                return NetworkDisplay.ResourceFilter(resourceTypeRawValue: resourceTypeRawValue)
            }
            return NetworkDisplay.ResourceFilter.inferred(
                mimeType: nil,
                pathExtension: requestURLSummary.pathExtension,
                mediaPreviewClassification: mediaPreviewClassifier(nil, requestURLSummary.rawURL)
            )
        }

        let responseMIMEType = NetworkDisplay.displayMIMEType(
            mimeType: responseMIMEType,
            headers: responseHeaders
        )
        if let resourceTypeRawValue,
           NetworkDisplay.shouldKeepResourceTypeForURLInferredMedia(rawValue: resourceTypeRawValue) {
            if case .previewable = mediaPreviewClassifier(responseMIMEType, nil) {
                return .media
            }
            return NetworkDisplay.ResourceFilter(resourceTypeRawValue: resourceTypeRawValue)
        }

        let responseURLSummary = responseURLSummary ?? requestURLSummary
        switch mediaPreviewClassifier(responseMIMEType, responseURLSummary.rawURL) {
        case .previewable:
            return .media
        case .notPreviewable:
            if NetworkDisplay.isMediaResourceType(rawValue: resourceTypeRawValue) {
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
        if let resourceTypeRawValue {
            return NetworkDisplay.ResourceFilter(resourceTypeRawValue: resourceTypeRawValue)
        }
        return NetworkDisplay.ResourceFilter.inferred(
            mimeType: responseMIMEType,
            pathExtension: responseURLSummary.pathExtension,
            mediaPreviewClassification: mediaPreviewClassifier(responseMIMEType, responseURLSummary.rawURL)
        )
    }

    package static func fileTypeLabel(
        mimeType: String?,
        resourceTypeRawValue: String?,
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
        if let resourceTypeRawValue {
            return resourceTypeDisplayLabel(rawValue: resourceTypeRawValue)
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

    fileprivate static func shouldKeepResourceTypeForURLInferredMedia(rawValue: String) -> Bool {
        switch rawValue.lowercased() {
        case "image", "media", "xhr", "fetch", "other":
            false
        default:
            true
        }
    }

    private static func isMediaResourceType(rawValue: String?) -> Bool {
        switch rawValue?.lowercased() {
        case "image", "media":
            true
        default:
            false
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

    private static func resourceTypeDisplayLabel(rawValue: String) -> String {
        switch rawValue.lowercased() {
        case "document":
            "document"
        case "stylesheet":
            "stylesheet"
        case "image":
            "image"
        case "media":
            "media"
        case "font":
            "font"
        case "script":
            "script"
        case "xhr":
            "xhr"
        case "fetch":
            "fetch"
        case "ping":
            "ping"
        case "beacon":
            "beacon"
        case "websocket":
            "websocket"
        case "eventsource":
            "eventsource"
        case "other":
            "other"
        default:
            rawValue.lowercased()
        }
    }
}
