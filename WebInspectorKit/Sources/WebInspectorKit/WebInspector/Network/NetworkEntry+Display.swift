import Foundation
import WebInspectorKitCore

extension NetworkEntry {
    var displayName: String {
        if let url = URL(string: url) {
            let last = url.lastPathComponent
            if !last.isEmpty {
                return last
            }
            if let host {
                return host
            }
        }
        return url
    }

    var host: String? {
        URL(string: url)?.host
    }

    var statusLabel: String {
        if let statusCode, statusCode > 0 {
            return String(statusCode)
        }
        switch phase {
        case .failed:
            return "Failed"
        case .pending:
            return "Pending"
        case .completed:
            return "Finished"
        }
    }

    var statusSeverity: NetworkStatusSeverity {
        if phase == .failed {
            return .error
        }
        if let statusCode {
            if statusCode >= 500 {
                return .error
            }
            if statusCode >= 400 {
                return .warning
            }
            if statusCode >= 300 {
                return .notice
            }
            return .success
        }
        if phase == .completed {
            return .success
        }
        return .neutral
    }

    func durationText(for value: TimeInterval) -> String {
        if value < 1 {
            return String(format: "%.0f ms", value * 1000)
        }
        return String(format: "%.2f s", value)
    }

    func sizeText(for length: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(length))
    }
}

enum NetworkStatusSeverity {
    case success
    case notice
    case warning
    case error
    case neutral
}
