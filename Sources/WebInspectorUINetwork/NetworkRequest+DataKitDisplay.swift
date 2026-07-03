import Foundation
import WebInspectorDataKit

extension NetworkRequest {
    package var displayName: String {
        NetworkDisplay.URLSummary(url: url).displayName
    }

    package var statusLabel: String {
        if let status, status > 0 {
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
            mimeType: mimeType,
            resourceTypeRawValue: resourceType?.rawValue,
            urlSummary: NetworkDisplay.URLSummary(url: url)
        )
    }

    package var statusSeverity: NetworkDisplay.StatusSeverity {
        if case .failed = state {
            return .error
        }
        if let status {
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
        let requestURLSummary = NetworkDisplay.URLSummary(url: url)
        let responseURLSummary = responseURL.map(NetworkDisplay.URLSummary.init(url:))
        return NetworkDisplay.resourceFilter(
            resourceTypeRawValue: resourceType?.rawValue,
            hasResponse: hasResponse,
            responseMIMEType: mimeType,
            responseHeaders: responseHeaders,
            responseURLSummary: responseURLSummary,
            requestURLSummary: requestURLSummary,
            mediaPreviewClassifier: mediaPreviewClassifier
        )
    }

    package func displayProjection() -> NetworkDisplay.Projection {
        let requestURLSummary = NetworkDisplay.URLSummary(url: url)
        let responseURLSummary = responseURL.map(NetworkDisplay.URLSummary.init(url:))
        let fileTypeLabel = NetworkDisplay.fileTypeLabel(
            mimeType: mimeType,
            resourceTypeRawValue: resourceType?.rawValue,
            urlSummary: requestURLSummary
        )
        let statusCodeLabel = status.map(String.init) ?? ""
        return NetworkDisplay.Projection(
            requestURLSummary: requestURLSummary,
            responseURLSummary: responseURLSummary,
            fileTypeLabel: fileTypeLabel,
            searchTokens: NetworkDisplay.searchTokens(
                requestURLSummary: requestURLSummary,
                responseURLSummary: responseURLSummary,
                requestMethod: method,
                statusCodeLabel: statusCodeLabel,
                statusText: statusText ?? "",
                fileTypeLabel: fileTypeLabel
            )
        )
    }

    package var duration: TimeInterval? {
        guard let start = requestSentTimestamp,
              let end = finishedOrFailedTimestamp ?? lastDataReceivedTimestamp ?? responseReceivedTimestamp else {
            return nil
        }
        return max(0, end - start)
    }

    package func durationText(for value: TimeInterval) -> String {
        NetworkDisplay.durationText(for: value)
    }

    package func sizeText(for length: Int) -> String {
        NetworkDisplay.sizeText(for: length)
    }
}

extension NetworkDisplay {
    package static func durationText(for value: TimeInterval) -> String {
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

    package static func sizeText(for length: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(length))
    }
}
