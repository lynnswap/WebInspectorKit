import Foundation
import V2_WebInspectorCore

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

    package var statusSeverity: V2_NetworkStatusSeverity {
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

    package var resourceFilter: V2_NetworkResourceFilter {
        if let resourceType {
            return V2_NetworkResourceFilter(resourceType: resourceType)
        }
        return V2_NetworkResourceFilter(
            mimeType: response?.mimeType,
            url: request.url
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

extension NetworkResourceType {
    fileprivate var displayLabel: String {
        switch self {
        case .document:
            "document"
        case .styleSheet:
            "stylesheet"
        case .image:
            "image"
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
