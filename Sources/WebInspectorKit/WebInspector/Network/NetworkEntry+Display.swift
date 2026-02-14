import Foundation
import SwiftUI
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

    var statusTint: Color {
        if phase == .failed {
            return .red
        }
        if let statusCode {
            if statusCode >= 500 {
                return .red
            }
            if statusCode >= 400 {
                return .orange
            }
            if statusCode >= 300 {
                return .yellow
            }
            return .green
        }
        if phase == .completed {
            return .green
        }
        return .secondary
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

