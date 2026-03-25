import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit
import WebInspectorBridgeObjCShim

package struct WISPIFetchedResource: Sendable, Equatable {
    package let data: Data
    package let mimeType: String?
}

package enum WISPIResourceLookupBridgeError: Int {
    package static let domain = "WebInspectorBridge.WIKRuntimeBridge"

    case invalidArgument = 1
    case pageUnavailable = 2
    case frameHandleUnavailable = 3
    case frameUnavailable = 4
    case urlCreationFailed = 5
    case symbolUnavailable = 6

    package init?(_ error: NSError) {
        guard error.domain == Self.domain else {
            return nil
        }
        self.init(rawValue: error.code)
    }
}

private final class WISPIResourceRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WISPIFetchedResource?, Error>?

    func install(_ continuation: CheckedContinuation<WISPIFetchedResource?, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(with result: Result<WISPIFetchedResource?, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}

private final class WISPIResolvedResourceRequestContext: @unchecked Sendable {
    let symbols: WISPIWebKitFrameSymbols
    let allowsEmptyPayload: Bool
    let completionHandler: @Sendable (Result<WISPIFetchedResource?, NSError>) -> Void
    var mimeTypeOverride: String?

    init(
        symbols: WISPIWebKitFrameSymbols,
        allowsEmptyPayload: Bool,
        completionHandler: @escaping @Sendable (Result<WISPIFetchedResource?, NSError>) -> Void
    ) {
        self.symbols = symbols
        self.allowsEmptyPayload = allowsEmptyPayload
        self.completionHandler = completionHandler
    }
}

private func WISPIMakeBridgeError(
    _ code: WISPIResourceLookupBridgeError,
    description: String
) -> NSError {
    NSError(
        domain: WISPIResourceLookupBridgeError.domain,
        code: code.rawValue,
        userInfo: [NSLocalizedDescriptionKey: description]
    )
}

private func WISPIStringFromCopiedWKString(
    _ stringRef: WISPIWebKitFrameSymbols.WKStringRefRaw?,
    using symbols: WISPIWebKitFrameSymbols
) -> String? {
    guard let stringRef else {
        return nil
    }

    let maximumSize = symbols.stringGetMaximumUTF8CStringSize(stringRef)
    guard maximumSize > 0 else {
        symbols.release(stringRef)
        return ""
    }

    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: maximumSize)
    defer {
        buffer.deallocate()
    }

    _ = symbols.stringGetUTF8CString(stringRef, buffer, maximumSize)
    let string = String(cString: buffer)
    symbols.release(stringRef)
    return string
}

private func WISPIURLFromCopiedWKURL(
    _ urlRef: WISPIWebKitFrameSymbols.WKURLRefRaw?,
    using symbols: WISPIWebKitFrameSymbols
) -> URL? {
    guard let urlRef else {
        return nil
    }

    let stringRef = symbols.urlCopyString(urlRef)
    symbols.release(urlRef)
    guard let urlString = WISPIStringFromCopiedWKString(stringRef, using: symbols) else {
        return nil
    }
    return URL(string: urlString)
}

private func WISPINSErrorFromWKError(
    _ errorRef: WISPIWebKitFrameSymbols.WKErrorRefRaw?,
    using symbols: WISPIWebKitFrameSymbols
) -> NSError {
    let domain = WISPIStringFromCopiedWKString(symbols.errorCopyDomain(errorRef), using: symbols)
        ?? WISPIResourceLookupBridgeError.domain
    let description = WISPIStringFromCopiedWKString(symbols.errorCopyLocalizedDescription(errorRef), using: symbols)
    var userInfo: [String: Any] = [:]
    if let description {
        userInfo[NSLocalizedDescriptionKey] = description
    }
    return NSError(
        domain: domain,
        code: Int(symbols.errorGetErrorCode(errorRef)),
        userInfo: userInfo.isEmpty ? nil : userInfo
    )
}

private func WISPICanonicalURL(_ url: URL?) -> URL? {
    guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: true) }) else {
        return nil
    }
    components.fragment = nil
    return components.url?.absoluteURL
}

private let WISPIResourceDataCallback: WISPIWebKitFrameSymbols.FrameGetResourceDataCallback = { dataRef, errorRef, context in
    guard let context else {
        return
    }

    let requestContext = Unmanaged<WISPIResolvedResourceRequestContext>.fromOpaque(context).takeRetainedValue()
    let symbols = requestContext.symbols

    if let errorRef {
        requestContext.completionHandler(.failure(WISPINSErrorFromWKError(errorRef, using: symbols)))
        return
    }

    guard let dataRef else {
        requestContext.completionHandler(.success(nil))
        return
    }

    let dataSize = symbols.dataGetSize(dataRef)
    if dataSize == 0 {
        requestContext.completionHandler(.success(nil))
        return
    }

    guard let bytes = symbols.dataGetBytes(dataRef) else {
        requestContext.completionHandler(.success(nil))
        return
    }

    let data = Data(bytes: bytes, count: dataSize)
    requestContext.completionHandler(.success(.init(data: data, mimeType: requestContext.mimeTypeOverride)))
}

@MainActor
package enum WISPIFrameBridge {
    package static func frameInfos(for webView: WKWebView) async -> [WKFrameInfo]? {
        await withCheckedContinuation { continuation in
            WIKRuntimeBridge.frameInfos(for: webView) { frameInfos in
                continuation.resume(returning: frameInfos)
            }
        }
    }

    package static func frameID(for frameInfo: WKFrameInfo) -> UInt64? {
        WIKRuntimeBridge.frameID(for: frameInfo)?.uint64Value
    }

    package static func resourceData(
        for resourceURL: URL,
        in frameInfo: WKFrameInfo,
        webView: WKWebView
    ) async throws -> WISPIFetchedResource? {
        try await requestResource { completionHandler in
            guard let pageRef = WIKRuntimeBridge.pageRefValue(for: webView)?.pointerValue else {
                completionHandler(.failure(WISPIMakeBridgeError(.pageUnavailable, description: "Unable to resolve WKPageRef from WKWebView.")))
                return
            }
            guard let frameHandleWrapper = WIKRuntimeBridge.frameHandleValue(for: frameInfo)?.pointerValue else {
                completionHandler(.failure(WISPIMakeBridgeError(.frameHandleUnavailable, description: "Unable to resolve WKFrameHandleRef from WKFrameInfo.")))
                return
            }
            guard let symbols = WISPIWebKitFrameSymbolResolver.symbols() else {
                completionHandler(.failure(WISPIMakeBridgeError(.symbolUnavailable, description: "Required WebKit frame resource lookup symbols are unavailable.")))
                return
            }

            let pageRefPointer = UnsafeRawPointer(pageRef)
            let frameHandlePointer = UnsafeRawPointer(frameHandleWrapper)
            guard let frameRef = symbols.pageLookUpFrameFromHandle(pageRefPointer, frameHandlePointer) else {
                completionHandler(.failure(WISPIMakeBridgeError(.frameUnavailable, description: "Unable to resolve WKFrameRef from the frame handle.")))
                return
            }

            let absoluteString = resourceURL.absoluteString
            let utf8Length = absoluteString.lengthOfBytes(using: .utf8)
            let wkURLRef = absoluteString.withCString { buffer in
                symbols.urlCreateWithUTF8String(buffer, utf8Length)
            }
            guard let wkURLRef else {
                completionHandler(.failure(WISPIMakeBridgeError(.urlCreationFailed, description: "Unable to create a WKURLRef from the resource URL.")))
                return
            }

            let canonicalTargetURL = WISPICanonicalURL(resourceURL)
            let canonicalFrameURL = WISPICanonicalURL(WISPIURLFromCopiedWKURL(symbols.frameCopyURL(frameRef), using: symbols))
            let shouldUseMainResource = symbols.frameIsDisplayingStandaloneImageDocument(frameRef)
                && canonicalTargetURL != nil
                && canonicalFrameURL != nil
                && canonicalFrameURL == canonicalTargetURL
            let requestContext = WISPIResolvedResourceRequestContext(
                symbols: symbols,
                allowsEmptyPayload: shouldUseMainResource,
                completionHandler: { result in
                    switch result {
                    case let .success(resource):
                        guard let resource else {
                            completionHandler(.success(nil))
                            return
                        }
                        let resolvedMIMEType = resource.mimeType
                            ?? inferredMIMEType(for: resourceURL, data: resource.data)
                        completionHandler(.success(.init(data: resource.data, mimeType: resolvedMIMEType)))
                    case let .failure(error):
                        completionHandler(.failure(error))
                    }
                }
            )

            if shouldUseMainResource {
                requestContext.mimeTypeOverride = WISPIStringFromCopiedWKString(symbols.frameCopyMIMEType(frameRef), using: symbols)
                symbols.frameGetMainResourceData(
                    frameRef,
                    WISPIResourceDataCallback,
                    Unmanaged.passRetained(requestContext).toOpaque()
                )
            } else {
                symbols.frameGetResourceData(
                    frameRef,
                    wkURLRef,
                    WISPIResourceDataCallback,
                    Unmanaged.passRetained(requestContext).toOpaque()
                )
            }
            symbols.release(wkURLRef)
        }
    }

    package static func requestResource(
        _ startRequest: (@escaping @Sendable (Result<WISPIFetchedResource?, NSError>) -> Void) -> Void
    ) async throws -> WISPIFetchedResource? {
        let state = WISPIResourceRequestState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)

                if Task.isCancelled {
                    state.resume(with: .failure(CancellationError()))
                    return
                }

                startRequest { result in
                    state.resume(with: result.mapError { $0 as Error })
                }
            }
        } onCancel: {
            state.resume(with: .failure(CancellationError()))
        }
    }

    nonisolated private static func inferredMIMEType(for resourceURL: URL, data: Data) -> String? {
        if let dataURLMIMEType = dataURLMIMEType(for: resourceURL) {
            return dataURLMIMEType
        }
        if let imageSourceMIMEType = imageSourceMIMEType(from: data) {
            return imageSourceMIMEType
        }
        if let sniffedMIMEType = sniffedMIMEType(from: data) {
            return sniffedMIMEType
        }
        guard !resourceURL.pathExtension.isEmpty else {
            return nil
        }
        return UTType(filenameExtension: resourceURL.pathExtension)?.preferredMIMEType
    }

    nonisolated private static func dataURLMIMEType(for resourceURL: URL) -> String? {
        guard resourceURL.scheme == "data" else {
            return nil
        }

        let absoluteString = resourceURL.absoluteString
        guard absoluteString.hasPrefix("data:") else {
            return nil
        }

        let header = absoluteString.dropFirst("data:".count).split(separator: ",", maxSplits: 1).first ?? ""
        let mimeType = header.split(separator: ";", maxSplits: 1).first.map(String.init)
        return mimeType?.isEmpty == false ? mimeType : nil
    }

    nonisolated private static func imageSourceMIMEType(from data: Data) -> String? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(imageSource) as String? else {
            return nil
        }

        return UTType(typeIdentifier)?.preferredMIMEType
    }

    nonisolated private static func sniffedMIMEType(from data: Data) -> String? {
        if let prefix = String(data: data.prefix(4096), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           prefix.contains("<svg") {
            return "image/svg+xml"
        }

        return nil
    }
}
