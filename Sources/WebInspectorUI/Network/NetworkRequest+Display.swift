import WebInspectorCore
import Foundation

extension NetworkRequest {
    package var displayName: String {
        if let url = URL(string: request.url) {
            let last = url.lastPathComponent
            if !last.isEmpty {
                return last
            }
            if let host = url.host {
                return host
            }
        }
        return request.url
    }

    package var host: String? {
        URL(string: request.url)?.host
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
        if let mimeType = response?.mimeType,
           let subtype = mimeType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .split(separator: "/")
            .last,
           subtype.isEmpty == false {
            return subtype.lowercased()
        }
        if let pathExtension = URL(string: request.url)?.pathExtension,
           pathExtension.isEmpty == false {
            return pathExtension.lowercased()
        }
        if let resourceType {
            return resourceType.displayLabel
        }
        return "-"
    }

    package var statusSeverity: NetworkStatusSeverity {
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

    package var resourceFilter: NetworkResourceFilter {
        guard let response else {
            if let resourceType {
                return NetworkResourceFilter(resourceType: resourceType)
            }
            return NetworkResourceFilter(mimeType: nil, url: request.url)
        }

        if let resourceType, shouldKeepResourceTypeForURLInferredMedia(resourceType) {
            if case .previewable = NetworkMediaPreviewSupport.classification(mimeType: response.mimeType, url: nil) {
                return .media
            }
            return NetworkResourceFilter(resourceType: resourceType)
        }

        let responseURL = response.url
        switch NetworkMediaPreviewSupport.classification(mimeType: response.mimeType, url: responseURL) {
        case .previewable:
            return .media
        case .notPreviewable:
            if resourceType == .media {
                return .media
            }
            return NetworkResourceFilter(mimeType: response.mimeType, url: responseURL)
        case .unknown:
            break
        }
        if let resourceType {
            return NetworkResourceFilter(resourceType: resourceType)
        }
        return NetworkResourceFilter(
            mimeType: response.mimeType,
            url: responseURL
        )
    }

    package func matchesSearchText(_ query: String) -> Bool {
        if query.isEmpty {
            return true
        }
        let statusCodeLabel = response.map { String($0.status) } ?? ""
        let candidates = [
            request.url,
            request.method,
            statusCodeLabel,
            response?.statusText ?? "",
            fileTypeLabel,
        ]
        return candidates.contains { $0.localizedStandardContains(query) }
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

private func shouldKeepResourceTypeForURLInferredMedia(_ resourceType: NetworkResourceType) -> Bool {
    switch resourceType {
    case .image, .media, .xhr, .fetch, .other:
        return false
    default:
        return true
    }
}

extension NetworkResourceType {
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
