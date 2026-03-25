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

private func WISPICanonicalURL(_ url: URL?) -> URL? {
    guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: true) }) else {
        return nil
    }
    components.fragment = nil
    return components.url?.absoluteURL
}

@unsafe private let WISPIResourceDataCallback: WISPIWebKitFrameSymbols.FrameGetResourceDataCallback = { dataRef, errorRef, context in
    unsafe WISPIFrameBridgeUnsafe.resourceDataCallback(dataRef, errorRef, context)
}

@unsafe private enum WISPIFrameBridgeUnsafe {
    @unsafe final class CallbackContext: @unchecked Sendable {
        let symbols: WISPIWebKitFrameSymbols
        let completionHandler: @Sendable (Result<WISPIFetchedResource?, NSError>) -> Void
        var mimeTypeOverride: String?

        init(
            symbols: WISPIWebKitFrameSymbols,
            completionHandler: @escaping @Sendable (Result<WISPIFetchedResource?, NSError>) -> Void
        ) {
            unsafe self.symbols = symbols
            unsafe self.completionHandler = completionHandler
        }
    }

    static func makeBridgeError(
        _ code: WISPIResourceLookupBridgeError,
        description: String
    ) -> NSError {
        NSError(
            domain: WISPIResourceLookupBridgeError.domain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    static func stringFromCopiedWKString(
        _ stringRef: WISPIWebKitFrameSymbols.WKStringRefRaw?,
        using symbols: WISPIWebKitFrameSymbols
    ) -> String? {
        guard let stringRef = unsafe stringRef else {
            return nil
        }

        let maximumSize = unsafe symbols.stringGetMaximumUTF8CStringSize(stringRef)
        guard maximumSize > 0 else {
            unsafe symbols.release(stringRef)
            return ""
        }

        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: maximumSize)
        defer {
            unsafe buffer.deallocate()
        }

        _ = unsafe symbols.stringGetUTF8CString(stringRef, buffer, maximumSize)
        let string = unsafe String(cString: buffer)
        unsafe symbols.release(stringRef)
        return string
    }

    static func urlFromCopiedWKURL(
        _ urlRef: WISPIWebKitFrameSymbols.WKURLRefRaw?,
        using symbols: WISPIWebKitFrameSymbols
    ) -> URL? {
        guard let urlRef = unsafe urlRef else {
            return nil
        }

        let stringRef = unsafe symbols.urlCopyString(urlRef)
        unsafe symbols.release(urlRef)
        guard let urlString = unsafe stringFromCopiedWKString(stringRef, using: symbols) else {
            return nil
        }
        return URL(string: urlString)
    }

    static func nsErrorFromWKError(
        _ errorRef: WISPIWebKitFrameSymbols.WKErrorRefRaw?,
        using symbols: WISPIWebKitFrameSymbols
    ) -> NSError {
        let domain = unsafe stringFromCopiedWKString(unsafe symbols.errorCopyDomain(errorRef), using: symbols)
            ?? WISPIResourceLookupBridgeError.domain
        let description = unsafe stringFromCopiedWKString(
            unsafe symbols.errorCopyLocalizedDescription(errorRef),
            using: symbols
        )
        var userInfo: [String: Any] = [:]
        if let description {
            userInfo[NSLocalizedDescriptionKey] = description
        }
        return NSError(
            domain: domain,
            code: unsafe Int(symbols.errorGetErrorCode(errorRef)),
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
    }

    static func resourceDataCallback(
        _ dataRef: WISPIWebKitFrameSymbols.WKDataRefRaw?,
        _ errorRef: WISPIWebKitFrameSymbols.WKErrorRefRaw?,
        _ context: UnsafeMutableRawPointer?
    ) {
        guard let context = unsafe context else {
            return
        }

        let requestContext = unsafe Unmanaged<CallbackContext>.fromOpaque(context).takeRetainedValue()
        let symbols = unsafe requestContext.symbols

        if let errorRef = unsafe errorRef {
            unsafe requestContext.completionHandler(.failure(unsafe nsErrorFromWKError(errorRef, using: symbols)))
            return
        }

        guard let dataRef = unsafe dataRef else {
            unsafe requestContext.completionHandler(.success(nil))
            return
        }

        let dataSize = unsafe symbols.dataGetSize(dataRef)
        if dataSize == 0 {
            unsafe requestContext.completionHandler(.success(nil))
            return
        }

        guard let bytes = unsafe symbols.dataGetBytes(dataRef) else {
            unsafe requestContext.completionHandler(.success(nil))
            return
        }

        let data = unsafe Data(bytes: bytes, count: dataSize)
        let mimeTypeOverride = unsafe requestContext.mimeTypeOverride
        unsafe requestContext.completionHandler(.success(.init(data: data, mimeType: mimeTypeOverride)))
    }
    static func beginLookup(
        for resourceURL: URL,
        in frameInfo: WKFrameInfo,
        webView: WKWebView,
        completionHandler: @escaping @Sendable (Result<WISPIFetchedResource?, NSError>) -> Void
    ) {
        guard let pageRef = unsafe WIKRuntimeBridge.pageRefValue(for: webView)?.pointerValue else {
            completionHandler(.failure(unsafe makeBridgeError(.pageUnavailable, description: "Unable to resolve WKPageRef from WKWebView.")))
            return
        }
        guard let frameHandleWrapper = unsafe WIKRuntimeBridge.frameHandleValue(for: frameInfo)?.pointerValue else {
            completionHandler(.failure(unsafe makeBridgeError(.frameHandleUnavailable, description: "Unable to resolve WKFrameHandleRef from WKFrameInfo.")))
            return
        }
        guard let symbols = unsafe WISPIWebKitFrameSymbolResolver.symbols() else {
            completionHandler(.failure(unsafe makeBridgeError(.symbolUnavailable, description: "Required WebKit frame resource lookup symbols are unavailable.")))
            return
        }

        let pageRefPointer = UnsafeRawPointer(pageRef)
        let frameHandlePointer = UnsafeRawPointer(frameHandleWrapper)
        guard let frameRef = unsafe symbols.pageLookUpFrameFromHandle(pageRefPointer, frameHandlePointer) else {
            completionHandler(.failure(unsafe makeBridgeError(.frameUnavailable, description: "Unable to resolve WKFrameRef from the frame handle.")))
            return
        }

        let absoluteString = resourceURL.absoluteString
        let utf8Length = absoluteString.lengthOfBytes(using: .utf8)
        let wkURLRef = unsafe absoluteString.withCString { buffer in
            unsafe symbols.urlCreateWithUTF8String(buffer, utf8Length)
        }
        guard let wkURLRef = unsafe wkURLRef else {
            completionHandler(.failure(unsafe makeBridgeError(.urlCreationFailed, description: "Unable to create a WKURLRef from the resource URL.")))
            return
        }

        let canonicalTargetURL = WISPICanonicalURL(resourceURL)
        let canonicalFrameURL = WISPICanonicalURL(
            unsafe urlFromCopiedWKURL(unsafe symbols.frameCopyURL(frameRef), using: symbols)
        )
        let shouldUseMainResource = unsafe symbols.frameIsDisplayingStandaloneImageDocument(frameRef)
            && canonicalTargetURL != nil
            && canonicalFrameURL != nil
            && canonicalFrameURL == canonicalTargetURL

        let requestContext = unsafe CallbackContext(
            symbols: symbols,
            completionHandler: { result in
                switch result {
                case let .success(resource):
                    guard let resource else {
                        completionHandler(.success(nil))
                        return
                    }
                    let resolvedMIMEType = resource.mimeType
                        ?? WISPIFrameBridge.inferredMIMEType(for: resourceURL, data: resource.data)
                    completionHandler(.success(.init(data: resource.data, mimeType: resolvedMIMEType)))
                case let .failure(error):
                    completionHandler(.failure(error))
                }
            }
        )

        if shouldUseMainResource {
            unsafe requestContext.mimeTypeOverride = unsafe stringFromCopiedWKString(
                unsafe symbols.frameCopyMIMEType(frameRef),
                using: symbols
            )
            unsafe symbols.frameGetMainResourceData(
                frameRef,
                WISPIResourceDataCallback,
                unsafe Unmanaged.passRetained(requestContext).toOpaque()
            )
        } else {
            unsafe symbols.frameGetResourceData(
                frameRef,
                wkURLRef,
                WISPIResourceDataCallback,
                unsafe Unmanaged.passRetained(requestContext).toOpaque()
            )
        }
        unsafe symbols.release(wkURLRef)
    }
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
            unsafe WISPIFrameBridgeUnsafe.beginLookup(
                for: resourceURL,
                in: frameInfo,
                webView: webView,
                completionHandler: completionHandler
            )
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

    nonisolated fileprivate static func inferredMIMEType(for resourceURL: URL, data: Data) -> String? {
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
