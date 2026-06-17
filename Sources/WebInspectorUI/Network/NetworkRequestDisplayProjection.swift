import WebInspectorCore
import Foundation

extension NetworkRequest {
    package enum Display {}
}

extension NetworkRequest.Display {
    package typealias MediaPreviewClassifier = @Sendable (String?, String?) -> NetworkRequest.Display.MediaPreviewClassification
}

extension NetworkRequest.Display {
    package struct Projection: Equatable, Identifiable, Sendable {
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
    package struct RequestSnapshot: Equatable, Identifiable, Sendable {
        package var id: NetworkRequest.ID
        package var requestURL: String
        package var requestMethod: String
        package var resourceType: NetworkRequest.ResourceType?
        package var responseURL: String?
        package var responseMIMEType: String?
        package var responseHeaders: [String: String]
        package var responseStatus: Int?
        package var responseStatusText: String?
        package var state: NetworkRequest.State

        @MainActor
        package init(request: NetworkRequest) {
            id = request.id
            requestURL = request.request.url
            requestMethod = request.request.method
            resourceType = request.resourceType
            responseURL = request.response?.url
            responseMIMEType = request.response?.mimeType
            responseHeaders = request.response?.headers ?? [:]
            responseStatus = request.response?.status
            responseStatusText = request.response?.statusText
            state = request.state
        }

        var statusSeverity: NetworkRequest.Display.StatusSeverity {
            if case .failed = state {
                return .error
            }
            if let responseStatus {
                if responseStatus >= 500 {
                    return .error
                }
                if responseStatus >= 400 {
                    return .warning
                }
                if responseStatus >= 300 {
                    return .notice
                }
                return .success
            }
            if state == .finished {
                return .success
            }
            return .neutral
        }
    }

    package struct RowsProjectionInput: Equatable, Sendable {
        package var requestSnapshots: [NetworkRequest.Display.RequestSnapshot]
        package var searchText: String
        package var resourceFilters: Set<NetworkRequest.Display.ResourceFilter>

        package init(
            requestSnapshots: [NetworkRequest.Display.RequestSnapshot],
            searchText: String,
            resourceFilters: Set<NetworkRequest.Display.ResourceFilter>
        ) {
            self.requestSnapshots = requestSnapshots
            self.searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.resourceFilters = resourceFilters
        }
    }
}

extension NetworkRequest.Display {
    package struct Fingerprint: Equatable, Sendable {
        package var requestURL: String
        package var requestMethod: String
        package var resourceType: NetworkRequest.ResourceType?
        package var responseURL: String?
        package var responseMIMEType: String?
        package var responseDisplayMIMEType: String?
        package var responseStatus: Int?
        package var responseStatusText: String?
        package var state: NetworkRequest.State

        package init(snapshot: NetworkRequest.Display.RequestSnapshot) {
            requestURL = snapshot.requestURL
            requestMethod = snapshot.requestMethod
            resourceType = snapshot.resourceType
            responseURL = snapshot.responseURL
            responseMIMEType = snapshot.responseMIMEType
            if snapshot.responseURL != nil {
                responseDisplayMIMEType = networkDisplayMIMEType(
                    mimeType: snapshot.responseMIMEType,
                    headers: snapshot.responseHeaders
                )
            } else {
                responseDisplayMIMEType = nil
            }
            responseStatus = snapshot.responseStatus
            responseStatusText = snapshot.responseStatusText
            state = snapshot.state
        }
    }
}

extension NetworkRequest.Display {
    private struct ProjectionInputs: Sendable {
        var requestURLSummary: NetworkRequest.Display.URLSummary
        var responseURLSummary: NetworkRequest.Display.URLSummary?
        var responseDisplayMIMEType: String?
        var fileTypeLabel: String

        init(snapshot: NetworkRequest.Display.RequestSnapshot) {
            requestURLSummary = NetworkRequest.Display.URLSummary(url: snapshot.requestURL)
            responseURLSummary = snapshot.responseURL.map { NetworkRequest.Display.URLSummary(url: $0) }
            if snapshot.responseURL != nil {
                responseDisplayMIMEType = networkDisplayMIMEType(
                    mimeType: snapshot.responseMIMEType,
                    headers: snapshot.responseHeaders
                )
            } else {
                self.responseDisplayMIMEType = nil
            }
            fileTypeLabel = NetworkRequest.Display.fileTypeLabel(
                mimeType: snapshot.responseMIMEType,
                resourceType: snapshot.resourceType,
                urlSummary: requestURLSummary
            )
        }
    }

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

        package func rows(for input: NetworkRequest.Display.RowsProjectionInput) throws -> [NetworkRequest.Display.Projection] {
            try Task.checkCancellation()
            prune(keeping: Set(input.requestSnapshots.map(\.id)))

            var rows: [NetworkRequest.Display.Projection] = []
            rows.reserveCapacity(input.requestSnapshots.count)
            for snapshot in input.requestSnapshots {
                try Task.checkCancellation()
                if input.resourceFilters.isEmpty == false {
                    let resourceFilter = resourceFilter(for: snapshot)
                    guard input.resourceFilters.contains(resourceFilter) else {
                        continue
                    }
                }
                let projection = projection(for: snapshot)
                guard projection.matchesSearchText(input.searchText) else {
                    continue
                }
                rows.append(projection)
            }
            return Array(rows.reversed())
        }

        package func projection(for snapshot: NetworkRequest.Display.RequestSnapshot) -> NetworkRequest.Display.Projection {
            let fingerprint = NetworkRequest.Display.Fingerprint(snapshot: snapshot)
            if let entry = entries[snapshot.id], entry.fingerprint == fingerprint {
                return entry.projection
            }

            let inputs = NetworkRequest.Display.ProjectionInputs(snapshot: snapshot)
            let projection = Self.projection(for: snapshot, inputs: inputs)
            entries[snapshot.id] = Entry(fingerprint: fingerprint, projection: projection, resourceFilter: nil)
            return projection
        }

        package func resourceFilter(for snapshot: NetworkRequest.Display.RequestSnapshot) -> NetworkRequest.Display.ResourceFilter {
            let fingerprint = NetworkRequest.Display.Fingerprint(snapshot: snapshot)
            if let entry = entries[snapshot.id],
               entry.fingerprint == fingerprint,
               let resourceFilter = entry.resourceFilter {
                return resourceFilter
            }

            let inputs = NetworkRequest.Display.ProjectionInputs(snapshot: snapshot)
            let resourceFilter = Self.resourceFilter(for: snapshot, inputs: inputs, classifier: mediaPreviewClassifier)
            var projection: NetworkRequest.Display.Projection
            if let entry = entries[snapshot.id], entry.fingerprint == fingerprint {
                projection = entry.projection
            } else {
                projection = Self.projection(for: snapshot, inputs: inputs)
            }
            projection.resourceFilter = resourceFilter
            entries[snapshot.id] = Entry(
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
            for snapshot: NetworkRequest.Display.RequestSnapshot,
            inputs: NetworkRequest.Display.ProjectionInputs
        ) -> NetworkRequest.Display.Projection {
            NetworkRequest.Display.Projection(
                id: snapshot.id,
                displayName: inputs.requestURLSummary.displayName,
                fileTypeLabel: inputs.fileTypeLabel,
                statusSeverity: snapshot.statusSeverity,
                resourceFilter: nil,
                searchTokens: Self.searchTokens(for: snapshot, inputs: inputs)
            )
        }

        private static func searchTokens(
            for snapshot: NetworkRequest.Display.RequestSnapshot,
            inputs: NetworkRequest.Display.ProjectionInputs
        ) -> [String] {
            let statusCodeLabel = snapshot.responseStatus.map(String.init) ?? ""
            return uniqueNonEmpty(
                inputs.requestURLSummary.searchTokens
                + (inputs.responseURLSummary?.searchTokens ?? [])
                + [
                    snapshot.requestMethod,
                    statusCodeLabel,
                    snapshot.responseStatusText ?? "",
                    inputs.fileTypeLabel,
                ]
            )
        }

        private static func resourceFilter(
            for snapshot: NetworkRequest.Display.RequestSnapshot,
            inputs: NetworkRequest.Display.ProjectionInputs,
            classifier: NetworkRequest.Display.MediaPreviewClassifier
        ) -> NetworkRequest.Display.ResourceFilter {
            guard let responseURL = snapshot.responseURL else {
                if let resourceType = snapshot.resourceType {
                    return NetworkRequest.Display.ResourceFilter(resourceType: resourceType)
                }
                return Self.resourceFilter(mimeType: nil, urlSummary: inputs.requestURLSummary, classifier: classifier)
            }

            let responseMimeType = inputs.responseDisplayMIMEType
            if let resourceType = snapshot.resourceType,
               shouldKeepResourceTypeForURLInferredMedia(resourceType) {
                if case .previewable = classifier(responseMimeType, nil) {
                    return .media
                }
                return NetworkRequest.Display.ResourceFilter(resourceType: resourceType)
            }

            let responseURLSummary = inputs.responseURLSummary ?? NetworkRequest.Display.URLSummary(url: responseURL)
            switch classifier(responseMimeType, responseURLSummary.rawURL) {
            case .previewable:
                return .media
            case .notPreviewable:
                if snapshot.resourceType == .image || snapshot.resourceType == .media {
                    return .media
                }
                return Self.resourceFilter(mimeType: responseMimeType, urlSummary: responseURLSummary, classifier: classifier)
            case .unknown:
                break
            }
            if let resourceType = snapshot.resourceType {
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

extension NetworkRequest.Display {
    package actor RowsProjector {
        private let cache: NetworkRequest.Display.ProjectionCache

        package init(mediaPreviewClassifier: @escaping NetworkRequest.Display.MediaPreviewClassifier) {
            cache = NetworkRequest.Display.ProjectionCache(mediaPreviewClassifier: mediaPreviewClassifier)
        }

        package func rows(
            for input: NetworkRequest.Display.RowsProjectionInput
        ) throws -> [NetworkRequest.Display.Projection] {
            try cache.rows(for: input)
        }

        package func removeAll() {
            cache.removeAll()
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

private func networkDisplayMIMEType(mimeType: String?, headers: [String: String]) -> String? {
    let rawMimeType = mimeType ?? networkHeaderValue(named: "content-type", in: headers)
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
