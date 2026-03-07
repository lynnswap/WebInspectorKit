#if os(iOS) && DEBUG
import Foundation
import WebInspectorTransport
import WebKit

enum NativeInspectorProbeStatus {
    case running
    case succeeded
    case failed
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
        switch status {
        case .running:
            false
        case .succeeded, .failed:
            true
        }
    }
}

@MainActor
final class NativeInspectorProbe {
    private let targetURL = URL(string: "https://example.com/")!
    private let bodyPreviewLimit = 4 * 1024

    func run(
        on webView: WKWebView,
        loadInitialPage: @escaping @MainActor (URL) async throws -> Void,
        update: @escaping @MainActor (NativeInspectorProbeResult) -> Void
    ) async -> NativeInspectorProbeResult {
        update(
            makeResult(
                status: .running,
                stage: "event",
                message: "Loading https://example.com/ before attaching the inspector transport.",
                urlString: targetURL.absoluteString
            )
        )

        do {
            try await loadInitialPage(targetURL)
        } catch {
            let failure = makeFailure(
                stage: "event",
                message: "The initial https://example.com/ load failed before attach.",
                error: error,
                urlString: targetURL.absoluteString
            )
            update(failure)
            return failure
        }

        let session = WITransportSession(
            configuration: .init(
                responseTimeout: .seconds(15),
                eventBufferLimit: 256,
                dropEventsWithoutSubscribers: true,
                logHandler: { NSLog("%@", $0) }
            )
        )

        do {
            update(
                makeResult(
                    status: .running,
                    stage: "attach",
                    message: "Attaching the native-only inspector transport.",
                    urlString: targetURL.absoluteString
                )
            )
            try await session.attach(to: webView)
        } catch {
            let failure = makeFailure(
                stage: stage(for: error),
                message: "The inspector transport could not attach.",
                error: error,
                urlString: targetURL.absoluteString
            )
            update(failure)
            return failure
        }

        defer {
            session.detach()
        }

        do {
            let bodyTask = Task { @MainActor in
                await self.awaitBodyResult(session: session, update: update)
            }

            update(
                makeResult(
                    status: .running,
                    stage: "event",
                    message: "Enabling the Network domain and reloading https://example.com/.",
                    urlString: targetURL.absoluteString
                )
            )
            _ = try await session.page.send(WITransportCommands.Network.Enable())
            try await loadInitialPage(targetURL)
            let finalResult = await bodyTask.value
            update(finalResult)
            return finalResult
        } catch {
            let failure = makeFailure(
                stage: stage(for: error),
                message: "The native-only inspector probe failed during reload.",
                error: error,
                urlString: targetURL.absoluteString
            )
            update(failure)
            return failure
        }
    }
}

private extension NativeInspectorProbe {
    struct ResponseReceivedParams: Decodable, Sendable {
        let requestId: String
        let type: String?
        let response: Response

        struct Response: Decodable, Sendable {
            let url: String
        }
    }

    struct LoadingFinishedParams: Decodable, Sendable {
        let requestId: String
    }

    struct LoadingFailedParams: Decodable, Sendable {
        let requestId: String
        let errorText: String?
    }

    func awaitBodyResult(
        session: WITransportSession,
        update: @escaping @MainActor (NativeInspectorProbeResult) -> Void
    ) async -> NativeInspectorProbeResult {
        let eventMethods: Set<String> = [
            "Network.responseReceived",
            "Network.loadingFinished",
            "Network.loadingFailed",
        ]
        let stream = session.page.events(methods: eventMethods, bufferingLimit: 32)
        let bodyTask = Task { @MainActor in
            await self.consumeNetworkEvents(stream: stream, session: session, update: update)
        }
        let timeoutResult = makeFailure(
            stage: "event",
            message: "Timed out while waiting for the main document response body.",
            rawBackendError: WITransportError.requestTimedOut(scope: .page, method: WITransportCommands.Network.GetResponseBody.method).localizedDescription,
            urlString: targetURL.absoluteString
        )

        return await withTaskGroup(of: NativeInspectorProbeResult.self) { group in
            group.addTask {
                await bodyTask.value
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return timeoutResult
            }

            let first = await group.next() ?? timeoutResult
            bodyTask.cancel()
            group.cancelAll()
            return first
        }
    }

    func consumeNetworkEvents(
        stream: AsyncStream<WITransportEventEnvelope>,
        session: WITransportSession,
        update: @escaping @MainActor (NativeInspectorProbeResult) -> Void
    ) async -> NativeInspectorProbeResult {
        var mainDocumentRequestID: String?

        for await event in stream {
            switch event.method {
            case "Network.responseReceived":
                do {
                    let params = try event.decodeParams(ResponseReceivedParams.self)
                    guard isMainDocumentResponse(params) else {
                        continue
                    }

                    mainDocumentRequestID = params.requestId
                    update(
                        makeResult(
                            status: .running,
                            stage: "event",
                            message: "Observed the main document response on the page target.",
                            urlString: params.response.url,
                            requestIdentifier: params.requestId,
                            rawMessage: decodeJSONString(from: event.paramsData)
                        )
                    )
                } catch {
                    return makeFailure(
                        stage: "event",
                        message: "Failed to decode Network.responseReceived.",
                        error: error,
                        urlString: targetURL.absoluteString,
                        rawMessage: decodeJSONString(from: event.paramsData)
                    )
                }

            case "Network.loadingFinished":
                do {
                    let params = try event.decodeParams(LoadingFinishedParams.self)
                    guard params.requestId == mainDocumentRequestID else {
                        continue
                    }

                    update(
                        makeResult(
                            status: .running,
                            stage: "body fetch",
                            message: "The main document finished loading. Fetching the response body.",
                            urlString: targetURL.absoluteString,
                            requestIdentifier: params.requestId,
                            rawMessage: decodeJSONString(from: event.paramsData)
                        )
                    )

                    do {
                        let response = try await session.page.send(
                            WITransportCommands.Network.GetResponseBody(requestId: params.requestId)
                        )
                        return makeResult(
                            status: .succeeded,
                            stage: "body fetch",
                            message: "Fetched the response body through native-only target messaging.",
                            urlString: targetURL.absoluteString,
                            requestIdentifier: params.requestId,
                            bodyPreview: preview(from: response.body),
                            base64Encoded: response.base64Encoded,
                            rawMessage: decodeJSONString(from: event.paramsData)
                        )
                    } catch {
                        return makeFailure(
                            stage: "body fetch",
                            message: "Network.getResponseBody failed for the main document request.",
                            error: error,
                            urlString: targetURL.absoluteString,
                            requestIdentifier: params.requestId,
                            rawMessage: decodeJSONString(from: event.paramsData)
                        )
                    }
                } catch {
                    return makeFailure(
                        stage: "event",
                        message: "Failed to decode Network.loadingFinished.",
                        error: error,
                        urlString: targetURL.absoluteString,
                        rawMessage: decodeJSONString(from: event.paramsData)
                    )
                }

            case "Network.loadingFailed":
                do {
                    let params = try event.decodeParams(LoadingFailedParams.self)
                    guard params.requestId == mainDocumentRequestID else {
                        continue
                    }

                    return makeFailure(
                        stage: "event",
                        message: "The main document request failed before the response body could be fetched.",
                        rawBackendError: params.errorText,
                        urlString: targetURL.absoluteString,
                        requestIdentifier: params.requestId,
                        rawMessage: decodeJSONString(from: event.paramsData)
                    )
                } catch {
                    return makeFailure(
                        stage: "event",
                        message: "Failed to decode Network.loadingFailed.",
                        error: error,
                        urlString: targetURL.absoluteString,
                        rawMessage: decodeJSONString(from: event.paramsData)
                    )
                }

            default:
                continue
            }
        }

        return makeFailure(
            stage: "event",
            message: "The page event stream closed before the probe completed.",
            rawBackendError: WITransportError.transportClosed.localizedDescription,
            urlString: targetURL.absoluteString
        )
    }

    func isMainDocumentResponse(_ params: ResponseReceivedParams) -> Bool {
        guard matchesTargetURL(params.response.url) else {
            return false
        }

        guard let type = params.type?.lowercased() else {
            return true
        }
        return type == "document"
    }

    func matchesTargetURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else {
            return false
        }

        return url.absoluteString == targetURL.absoluteString
            || (url.scheme == targetURL.scheme && url.host == targetURL.host)
    }

    func makeResult(
        status: NativeInspectorProbeStatus,
        stage: String,
        message: String,
        urlString: String? = nil,
        requestIdentifier: String? = nil,
        bodyPreview: String? = nil,
        base64Encoded: Bool = false,
        rawBackendError: String? = nil,
        rawMessage: String? = nil
    ) -> NativeInspectorProbeResult {
        NativeInspectorProbeResult(
            status: status,
            stage: stage,
            message: message,
            urlString: urlString,
            requestIdentifier: requestIdentifier,
            bodyPreview: bodyPreview,
            base64Encoded: base64Encoded,
            rawBackendError: rawBackendError,
            rawMessage: rawMessage
        )
    }

    func makeFailure(
        stage: String,
        message: String,
        error: Error,
        urlString: String? = nil,
        requestIdentifier: String? = nil,
        rawMessage: String? = nil
    ) -> NativeInspectorProbeResult {
        makeFailure(
            stage: stage,
            message: message,
            rawBackendError: error.localizedDescription,
            urlString: urlString,
            requestIdentifier: requestIdentifier,
            rawMessage: rawMessage
        )
    }

    func makeFailure(
        stage: String,
        message: String,
        rawBackendError: String?,
        urlString: String? = nil,
        requestIdentifier: String? = nil,
        rawMessage: String? = nil
    ) -> NativeInspectorProbeResult {
        makeResult(
            status: .failed,
            stage: stage,
            message: message,
            urlString: urlString,
            requestIdentifier: requestIdentifier,
            rawBackendError: rawBackendError,
            rawMessage: rawMessage
        )
    }

    func preview(from body: String) -> String {
        String(body.prefix(bodyPreviewLimit))
    }

    func decodeJSONString(from data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func stage(for error: Error) -> String {
        guard let error = error as? WITransportError else {
            return "attach"
        }

        switch error {
        case .unsupported:
            return "symbol"
        case .attachFailed:
            return "attach"
        case .pageTargetUnavailable:
            return "event"
        case .requestTimedOut(_, let method):
            return method == WITransportCommands.Network.GetResponseBody.method ? "body fetch" : "event"
        case .remoteError(_, let method, _):
            return method == WITransportCommands.Network.GetResponseBody.method ? "body fetch" : "event"
        case .alreadyAttached, .notAttached, .invalidResponse, .invalidCommandEncoding, .invalidChannelScope, .transportClosed:
            return "attach"
        }
    }
}
#endif
