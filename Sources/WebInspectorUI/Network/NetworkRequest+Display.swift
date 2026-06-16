import WebInspectorCore
import Foundation

extension NetworkRequest {
    package var displayName: String {
        NetworkRequest.Display.URLSummary(url: request.url).displayName
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
        NetworkRequest.Display.fileTypeLabel(
            mimeType: response?.mimeType,
            resourceType: resourceType,
            urlSummary: NetworkRequest.Display.URLSummary(url: request.url)
        )
    }

    package var statusSeverity: NetworkRequest.Display.StatusSeverity {
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

extension NetworkRequest.Display {
    package static func fileTypeLabel(
        mimeType: String?,
        resourceType: NetworkRequest.ResourceType?,
        urlSummary: NetworkRequest.Display.URLSummary
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
