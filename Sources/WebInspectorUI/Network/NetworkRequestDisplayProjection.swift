import WebInspectorCore
import Foundation

extension NetworkRequest {
    package enum Display {}
}

extension NetworkRequest.Display {
    package typealias MediaPreviewClassifier = (String?, String?) -> NetworkRequest.Display.MediaPreviewClassification
}

extension NetworkRequest.Display {
    package struct Projection: Equatable, Identifiable {
        package var id: NetworkRequest.ID
        package var displayName: String
        package var fileTypeLabel: String
        package var statusSeverity: NetworkRequest.Display.StatusSeverity
        package var resourceFilter: NetworkRequest.Display.ResourceFilter?
        package var searchTokens: [String]

        package func matchesSearchText(_ query: String) -> Bool {
            if query.isEmpty {
                return true
            }
            return searchTokens.contains { $0.localizedStandardContains(query) }
        }
    }
}

extension NetworkRequest.Display {
    package struct Fingerprint: Equatable {
        package var requestURL: String
        package var requestMethod: String
        package var resourceType: NetworkRequest.ResourceType?
        package var responseURL: String?
        package var responseMIMEType: String?
        package var responseDisplayMIMEType: String?
        package var responseStatus: Int?
        package var responseStatusText: String?
        package var state: NetworkRequest.State

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
}

extension NetworkRequest.Display {
    private struct ProjectionInputs {
        var requestURLSummary: NetworkRequest.Display.URLSummary
        var responseURLSummary: NetworkRequest.Display.URLSummary?
        var responseDisplayMIMEType: String?
        var fileTypeLabel: String

        @MainActor
        init(request: NetworkRequest) {
            requestURLSummary = NetworkRequest.Display.URLSummary(url: request.request.url)
            responseURLSummary = request.response.map { NetworkRequest.Display.URLSummary(url: $0.url) }
            if let response = request.response {
                responseDisplayMIMEType = networkDisplayMIMEType(from: response)
            } else {
                responseDisplayMIMEType = nil
            }
            fileTypeLabel = NetworkRequest.Display.fileTypeLabel(
                mimeType: request.response?.mimeType,
                resourceType: request.resourceType,
                urlSummary: requestURLSummary
            )
        }
    }

    @MainActor
    package final class ProjectionCache {
        private struct Entry {
            var fingerprint: NetworkRequest.Display.Fingerprint
            var projection: NetworkRequest.Display.Projection
            var resourceFilter: NetworkRequest.Display.ResourceFilter?
        }

        private let mediaPreviewClassifier: NetworkRequest.Display.MediaPreviewClassifier
        private var entries: [NetworkRequest.ID: Entry] = [:]

        package init(mediaPreviewClassifier: @escaping NetworkRequest.Display.MediaPreviewClassifier) {
            self.mediaPreviewClassifier = mediaPreviewClassifier
        }

        package func projection(for request: NetworkRequest) -> NetworkRequest.Display.Projection {
            let fingerprint = NetworkRequest.Display.Fingerprint(request: request)
            if let entry = entries[request.id], entry.fingerprint == fingerprint {
                return entry.projection
            }

            let inputs = NetworkRequest.Display.ProjectionInputs(request: request)
            let projection = Self.projection(for: request, inputs: inputs)
            entries[request.id] = Entry(fingerprint: fingerprint, projection: projection, resourceFilter: nil)
            return projection
        }

        package func resourceFilter(for request: NetworkRequest) -> NetworkRequest.Display.ResourceFilter {
            let fingerprint = NetworkRequest.Display.Fingerprint(request: request)
            if let entry = entries[request.id],
               entry.fingerprint == fingerprint,
               let resourceFilter = entry.resourceFilter {
                return resourceFilter
            }

            let inputs = NetworkRequest.Display.ProjectionInputs(request: request)
            let resourceFilter = Self.resourceFilter(for: request, inputs: inputs, classifier: mediaPreviewClassifier)
            var projection: NetworkRequest.Display.Projection
            if let entry = entries[request.id], entry.fingerprint == fingerprint {
                projection = entry.projection
            } else {
                projection = Self.projection(for: request, inputs: inputs)
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

        private static func projection(
            for request: NetworkRequest,
            inputs: NetworkRequest.Display.ProjectionInputs
        ) -> NetworkRequest.Display.Projection {
            NetworkRequest.Display.Projection(
                id: request.id,
                displayName: inputs.requestURLSummary.displayName,
                fileTypeLabel: inputs.fileTypeLabel,
                statusSeverity: request.statusSeverity,
                resourceFilter: nil,
                searchTokens: Self.searchTokens(for: request, inputs: inputs)
            )
        }

        private static func searchTokens(
            for request: NetworkRequest,
            inputs: NetworkRequest.Display.ProjectionInputs
        ) -> [String] {
            let statusCodeLabel = request.response.map { String($0.status) } ?? ""
            return uniqueNonEmpty(
                inputs.requestURLSummary.searchTokens
                + (inputs.responseURLSummary?.searchTokens ?? [])
                + [
                    request.request.method,
                    statusCodeLabel,
                    request.response?.statusText ?? "",
                    inputs.fileTypeLabel,
                ]
            )
        }

        private static func resourceFilter(
            for request: NetworkRequest,
            inputs: NetworkRequest.Display.ProjectionInputs,
            classifier: NetworkRequest.Display.MediaPreviewClassifier
        ) -> NetworkRequest.Display.ResourceFilter {
            guard let response = request.response else {
                if let resourceType = request.resourceType {
                    return NetworkRequest.Display.ResourceFilter(resourceType: resourceType)
                }
                return Self.resourceFilter(mimeType: nil, urlSummary: inputs.requestURLSummary, classifier: classifier)
            }

            let responseMimeType = inputs.responseDisplayMIMEType
            if let resourceType = request.resourceType,
               shouldKeepResourceTypeForURLInferredMedia(resourceType) {
                if case .previewable = classifier(responseMimeType, nil) {
                    return .media
                }
                return NetworkRequest.Display.ResourceFilter(resourceType: resourceType)
            }

            let responseURLSummary = inputs.responseURLSummary ?? NetworkRequest.Display.URLSummary(url: response.url)
            switch classifier(responseMimeType, responseURLSummary.rawURL) {
            case .previewable:
                return .media
            case .notPreviewable:
                if request.resourceType == .image || request.resourceType == .media {
                    return .media
                }
                return Self.resourceFilter(mimeType: responseMimeType, urlSummary: responseURLSummary, classifier: classifier)
            case .unknown:
                break
            }
            if let resourceType = request.resourceType {
                return NetworkRequest.Display.ResourceFilter(resourceType: resourceType)
            }
            return Self.resourceFilter(mimeType: responseMimeType, urlSummary: responseURLSummary, classifier: classifier)
        }

        private static func resourceFilter(
            mimeType: String?,
            urlSummary: NetworkRequest.Display.URLSummary,
            classifier: NetworkRequest.Display.MediaPreviewClassifier
        ) -> NetworkRequest.Display.ResourceFilter {
            NetworkRequest.Display.ResourceFilter.inferred(
                mimeType: mimeType,
                pathExtension: urlSummary.pathExtension,
                mediaPreviewClassification: classifier(mimeType, urlSummary.rawURL)
            )
        }

        private static func uniqueNonEmpty(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            var result: [String] = []
            for value in values where value.isEmpty == false && seen.insert(value).inserted {
                result.append(value)
            }
            return result
        }
    }
}

private func shouldKeepResourceTypeForURLInferredMedia(_ resourceType: NetworkRequest.ResourceType) -> Bool {
    switch resourceType {
    case .image, .media, .xhr, .fetch, .other:
        return false
    default:
        return true
    }
}

private func networkDisplayMIMEType(from response: NetworkRequest.Response.Payload) -> String? {
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
