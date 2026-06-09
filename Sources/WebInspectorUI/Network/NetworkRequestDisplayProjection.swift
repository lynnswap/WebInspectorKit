import WebInspectorCore
import Foundation

package typealias NetworkMediaPreviewClassifier = (String?, String?) -> NetworkMediaPreviewClassification

package struct NetworkRequestDisplayProjection: Equatable {
    package var id: NetworkRequest.ID
    package var displayName: String
    package var fileTypeLabel: String
    package var statusSeverity: NetworkStatusSeverity
    package var resourceFilter: NetworkResourceFilter?
    package var searchTokens: [String]

    package func matchesSearchText(_ query: String) -> Bool {
        if query.isEmpty {
            return true
        }
        return searchTokens.contains { $0.localizedStandardContains(query) }
    }
}

package struct NetworkRequestDisplayFingerprint: Equatable {
    package var requestURL: String
    package var requestMethod: String
    package var resourceType: NetworkResourceType?
    package var responseURL: String?
    package var responseMIMEType: String?
    package var responseDisplayMIMEType: String?
    package var responseStatus: Int?
    package var responseStatusText: String?
    package var state: NetworkRequestState

    @MainActor
    package init(request: NetworkRequest) {
        self.requestURL = request.request.url
        self.requestMethod = request.request.method
        self.resourceType = request.resourceType
        self.responseURL = request.response?.url
        if let response = request.response {
            self.responseMIMEType = response.mimeType
            self.responseDisplayMIMEType = networkDisplayMIMEType(from: response)
        } else {
            self.responseMIMEType = nil
            self.responseDisplayMIMEType = nil
        }
        self.responseStatus = request.response?.status
        self.responseStatusText = request.response?.statusText
        self.state = request.state
    }
}

@MainActor
package final class NetworkRequestDisplayProjectionCache {
    private struct Entry {
        var fingerprint: NetworkRequestDisplayFingerprint
        var projection: NetworkRequestDisplayProjection
        var resourceFilter: NetworkResourceFilter?
    }

    private let mediaPreviewClassifier: NetworkMediaPreviewClassifier
    private var entries: [NetworkRequest.ID: Entry] = [:]

    package init(mediaPreviewClassifier: @escaping NetworkMediaPreviewClassifier) {
        self.mediaPreviewClassifier = mediaPreviewClassifier
    }

    package func projection(for request: NetworkRequest) -> NetworkRequestDisplayProjection {
        let fingerprint = NetworkRequestDisplayFingerprint(request: request)
        if let entry = entries[request.id], entry.fingerprint == fingerprint {
            return entry.projection
        }

        let projection = NetworkRequestDisplayProjection(
            id: request.id,
            displayName: request.displayName,
            fileTypeLabel: request.fileTypeLabel,
            statusSeverity: request.statusSeverity,
            resourceFilter: nil,
            searchTokens: Self.searchTokens(for: request)
        )
        entries[request.id] = Entry(fingerprint: fingerprint, projection: projection, resourceFilter: nil)
        return projection
    }

    package func resourceFilter(for request: NetworkRequest) -> NetworkResourceFilter {
        let fingerprint = NetworkRequestDisplayFingerprint(request: request)
        if let entry = entries[request.id],
           entry.fingerprint == fingerprint,
           let resourceFilter = entry.resourceFilter {
            return resourceFilter
        }

        let resourceFilter = Self.resourceFilter(for: request, classifier: mediaPreviewClassifier)
        var projection: NetworkRequestDisplayProjection
        if let entry = entries[request.id], entry.fingerprint == fingerprint {
            projection = entry.projection
        } else {
            projection = NetworkRequestDisplayProjection(
                id: request.id,
                displayName: request.displayName,
                fileTypeLabel: request.fileTypeLabel,
                statusSeverity: request.statusSeverity,
                resourceFilter: nil,
                searchTokens: Self.searchTokens(for: request)
            )
        }
        projection.resourceFilter = resourceFilter
        entries[request.id] = Entry(
            fingerprint: fingerprint,
            projection: projection,
            resourceFilter: resourceFilter
        )
        return resourceFilter
    }

    package func prune(keeping ids: Set<NetworkRequest.ID>) {
        entries = entries.filter { ids.contains($0.key) }
    }

    package func removeAll() {
        entries.removeAll()
    }

    private static func searchTokens(for request: NetworkRequest) -> [String] {
        let statusCodeLabel = request.response.map { String($0.status) } ?? ""
        return [
            request.request.url,
            request.request.method,
            statusCodeLabel,
            request.response?.statusText ?? "",
            request.fileTypeLabel,
        ]
    }

    private static func resourceFilter(
        for request: NetworkRequest,
        classifier: NetworkMediaPreviewClassifier
    ) -> NetworkResourceFilter {
        guard let response = request.response else {
            if let resourceType = request.resourceType {
                return NetworkResourceFilter(resourceType: resourceType)
            }
            return resourceFilter(mimeType: nil, url: request.request.url, classifier: classifier)
        }

        let responseMimeType = networkDisplayMIMEType(from: response)
        if let resourceType = request.resourceType,
           shouldKeepResourceTypeForURLInferredMedia(resourceType) {
            if case .previewable = classifier(responseMimeType, nil) {
                return .media
            }
            return NetworkResourceFilter(resourceType: resourceType)
        }

        let responseURL = response.url
        switch classifier(responseMimeType, responseURL) {
        case .previewable:
            return .media
        case .notPreviewable:
            if request.resourceType == .image || request.resourceType == .media {
                return .media
            }
            return resourceFilter(mimeType: responseMimeType, url: responseURL, classifier: classifier)
        case .unknown:
            break
        }
        if let resourceType = request.resourceType {
            return NetworkResourceFilter(resourceType: resourceType)
        }
        return resourceFilter(mimeType: responseMimeType, url: responseURL, classifier: classifier)
    }

    private static func resourceFilter(
        mimeType: String?,
        url: String,
        classifier: NetworkMediaPreviewClassifier
    ) -> NetworkResourceFilter {
        let normalizedMimeType = mimeType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .lowercased() ?? ""
        let pathExtension = URL(string: url)?.pathExtension.lowercased() ?? ""

        if case .previewable = classifier(mimeType, url) {
            return .media
        }
        if normalizedMimeType == "text/css" || pathExtension == "css" {
            return .stylesheet
        }
        if normalizedMimeType.hasPrefix("font/") || ["woff", "woff2", "ttf", "otf"].contains(pathExtension) {
            return .font
        }
        if normalizedMimeType.contains("javascript") || ["js", "mjs"].contains(pathExtension) {
            return .script
        }
        if normalizedMimeType.contains("html") {
            return .document
        }
        return .other
    }
}

private func shouldKeepResourceTypeForURLInferredMedia(_ resourceType: NetworkResourceType) -> Bool {
    switch resourceType {
    case .image, .media, .xhr, .fetch, .other:
        return false
    default:
        return true
    }
}

private func networkDisplayMIMEType(from response: NetworkResponsePayload) -> String? {
    let rawMimeType = response.mimeType ?? networkHeaderValue(named: "content-type", in: response.headers)
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

private func networkHeaderValue(named name: String, in headers: [String: String]) -> String? {
    if let value = headers[name] {
        return value
    }
    return headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
}
