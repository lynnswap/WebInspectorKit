#if os(iOS) && DEBUG
import Foundation
import WebKit

enum NativeInspectorProbeStatus {
    case running
    case succeeded
    case failed

    init(rawValue: String) {
        switch rawValue {
        case "succeeded":
            self = .succeeded
        case "failed":
            self = .failed
        default:
            self = .running
        }
    }
}

struct NativeInspectorProbeResult {
    let status: NativeInspectorProbeStatus
    let stage: String
    let message: String
    let urlString: String?
    let requestIdentifier: String?
    let bodyPreview: String?
    let base64Encoded: Bool
    let rawBackendError: String?
    let rawMessage: String?

    var isTerminal: Bool {
        status != .running
    }

    init(
        status: NativeInspectorProbeStatus,
        stage: String,
        message: String,
        urlString: String? = nil,
        requestIdentifier: String? = nil,
        bodyPreview: String? = nil,
        base64Encoded: Bool = false,
        rawBackendError: String? = nil,
        rawMessage: String? = nil
    ) {
        self.status = status
        self.stage = stage
        self.message = message
        self.urlString = urlString
        self.requestIdentifier = requestIdentifier
        self.bodyPreview = bodyPreview
        self.base64Encoded = base64Encoded
        self.rawBackendError = rawBackendError
        self.rawMessage = rawMessage
    }

    init(record: WIKNativeInspectorProbeRecord) {
        status = NativeInspectorProbeStatus(rawValue: record.status)
        stage = record.stage
        message = record.message
        urlString = record.urlString
        requestIdentifier = record.requestIdentifier
        bodyPreview = record.bodyPreview
        base64Encoded = record.base64Encoded
        rawBackendError = record.rawBackendError
        rawMessage = record.rawMessage
    }
}

@MainActor
final class NativeInspectorProbe {
    private let targetURL = URL(string: "https://example.com/")!

    func run(
        on webView: WKWebView,
        loadInitialPage: @escaping @MainActor (URL) async throws -> Void,
        update: @escaping @MainActor (NativeInspectorProbeResult) -> Void
    ) async -> NativeInspectorProbeResult {
        let initial = NativeInspectorProbeResult(
            status: .running,
            stage: "event",
            message: "Loading https://example.com/ before attaching the native inspector probe.",
            urlString: targetURL.absoluteString
        )
        update(initial)

        do {
            try await loadInitialPage(targetURL)
        } catch {
            let failure = NativeInspectorProbeResult(
                status: .failed,
                stage: "event",
                message: "The initial https://example.com/ load failed before attach.",
                urlString: targetURL.absoluteString,
                rawBackendError: error.localizedDescription
            )
            update(failure)
            return failure
        }

        let session = WIKNativeInspectorProbeSession(webView: webView)
        return await withCheckedContinuation { continuation in
            var didResume = false
            session.start(for: targetURL) { record in
                let result = NativeInspectorProbeResult(record: record)
                update(result)

                guard result.isTerminal, !didResume else {
                    return
                }

                didResume = true
                session.cancel()
                continuation.resume(returning: result)
            }
        }
    }
}
#endif
