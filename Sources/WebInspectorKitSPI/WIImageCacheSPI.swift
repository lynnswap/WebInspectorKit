import Foundation
import WebKit
import WebInspectorBridge

public struct WIDisplayedImageCacheEntry: Sendable, Equatable {
    public let data: Data
    public let mimeType: String?
    public let resolvedURL: URL
    public let frameID: UInt64

    public init(data: Data, mimeType: String?, resolvedURL: URL, frameID: UInt64) {
        self.data = data
        self.mimeType = mimeType
        self.resolvedURL = resolvedURL
        self.frameID = frameID
    }
}

public enum WIImageCacheSPIError: Error, Sendable, Equatable {
    case frameEnumerationUnavailable
    case webArchiveCreationFailed
    case webArchiveDecodeFailed
    case resourceFetchFailed
}

@MainActor
public enum WIImageCacheSPI {
    /// Returns cached bytes for the first loaded image subresource in the current page
    /// whose resource URL exactly matches `imageURL`.
    ///
    /// This lookup does not evaluate JavaScript and does not determine whether the
    /// image is currently rendered or visible. It queries the current page's loaded
    /// subresources by walking the main frame before subframes and returning the
    /// first currently fetchable match.
    public static func displayedImageCache(
        for imageURL: URL,
        in webView: WKWebView
    ) async throws -> WIDisplayedImageCacheEntry? {
        try await WIImageCacheLoader().displayedImageCache(for: imageURL, in: webView)
    }
}

@MainActor
package protocol WIFrameInfoProviding {
    func frameInfos(in webView: WKWebView) async -> [WKFrameInfo]?
}

package typealias WIFrameResourceLookup = (URL, WKFrameInfo, WKWebView) async throws -> WISPIFetchedResource?

private enum WIDirectImageLookupError: Error {
    case fallbackToArchive
}

private final class WIArchiveRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(with result: Result<Data, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}

@MainActor
package struct WIImageCacheLoader {
    package let frameInfoProvider: any WIFrameInfoProviding
    package let resourceLookup: WIFrameResourceLookup

    package init(
        frameInfoProvider: any WIFrameInfoProviding = WIFrameInfoProvider(),
        resourceLookup: @escaping WIFrameResourceLookup = { resourceURL, frameInfo, webView in
            try await WISPIFrameBridge.resourceData(for: resourceURL, in: frameInfo, webView: webView)
        }
    ) {
        self.frameInfoProvider = frameInfoProvider
        self.resourceLookup = resourceLookup
    }

    package func displayedImageCache(
        for imageURL: URL,
        in webView: WKWebView
    ) async throws -> WIDisplayedImageCacheEntry? {
        guard let frameInfos = await frameInfoProvider.frameInfos(in: webView), !frameInfos.isEmpty else {
            throw WIImageCacheSPIError.frameEnumerationUnavailable
        }

        guard let mainFrameInfo = frameInfos.first(where: \.isMainFrame) else {
            throw WIImageCacheSPIError.frameEnumerationUnavailable
        }
        let subframeInfos = frameInfos.filter { frameInfo in
            return frameInfo !== mainFrameInfo
        }
        var shouldTryArchiveFallback = false

        func lookupResource(in frameInfo: WKFrameInfo) async throws -> WISPIFetchedResource? {
            do {
                return try await resourceLookup(imageURL, frameInfo, webView)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NSError {
                if let code = WISPIResourceLookupBridgeError(error) {
                    switch code {
                    case .invalidArgument:
                        throw WIImageCacheSPIError.resourceFetchFailed
                    case .urlCreationFailed,
                         .pageUnavailable,
                         .frameHandleUnavailable,
                         .frameUnavailable,
                         .symbolUnavailable:
                        throw WIDirectImageLookupError.fallbackToArchive
                    }
                }
                throw WIDirectImageLookupError.fallbackToArchive
            } catch {
                return nil
            }
        }

        do {
            if let resource = try await lookupResource(in: mainFrameInfo) {
                return try Self.makeEntry(resource: resource, frameInfo: mainFrameInfo, resolvedURL: imageURL)
            }
        } catch WIDirectImageLookupError.fallbackToArchive {
            shouldTryArchiveFallback = true
        }

        var firstSubframeMatch: (resource: WISPIFetchedResource, frameInfo: WKFrameInfo)?
        for frameInfo in subframeInfos {
            do {
                if let resource = try await lookupResource(in: frameInfo) {
                    firstSubframeMatch = (resource, frameInfo)
                    break
                }
            } catch WIDirectImageLookupError.fallbackToArchive {
                shouldTryArchiveFallback = true
            }
        }

        if let firstSubframeMatch {
            do {
                if let resource = try await lookupResource(in: mainFrameInfo) {
                    return try Self.makeEntry(resource: resource, frameInfo: mainFrameInfo, resolvedURL: imageURL)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch WIDirectImageLookupError.fallbackToArchive {
                shouldTryArchiveFallback = true
            } catch {
                // Keep an already-fetched subframe hit if the re-check races with frame teardown.
            }
            return try Self.makeEntry(
                resource: firstSubframeMatch.resource,
                frameInfo: firstSubframeMatch.frameInfo,
                resolvedURL: imageURL
            )
        }

        let shouldUseArchiveFallback = shouldTryArchiveFallback || firstSubframeMatch == nil
        if shouldUseArchiveFallback {
            return try await Self.fallbackArchiveEntry(for: imageURL, frameInfos: frameInfos, webView: webView)
        }

        return nil
    }

    private static func makeEntry(
        resource: WISPIFetchedResource,
        frameInfo: WKFrameInfo,
        resolvedURL: URL
    ) throws -> WIDisplayedImageCacheEntry {
        guard let frameID = WISPIFrameBridge.frameID(for: frameInfo) else {
            throw WIImageCacheSPIError.frameEnumerationUnavailable
        }

        return WIDisplayedImageCacheEntry(
            data: resource.data,
            mimeType: resource.mimeType,
            resolvedURL: resolvedURL,
            frameID: frameID
        )
    }

    private static func fallbackArchiveEntry(
        for imageURL: URL,
        frameInfos: [WKFrameInfo],
        webView: WKWebView
    ) async throws -> WIDisplayedImageCacheEntry? {
        let archiveData: Data
        do {
            archiveData = try await createWebArchiveData(from: webView)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WIImageCacheSPIError.webArchiveCreationFailed
        }

        guard let matchedResource = try WIWebArchiveResourceLookup.matchingResource(
            for: imageURL,
            in: archiveData
        ) else {
            return nil
        }

        guard let frameID = resolveArchiveFrameID(for: matchedResource, frameInfos: frameInfos) else {
            throw WIImageCacheSPIError.frameEnumerationUnavailable
        }

        return WIDisplayedImageCacheEntry(
            data: matchedResource.data,
            mimeType: matchedResource.mimeType,
            resolvedURL: imageURL,
            frameID: frameID
        )
    }

    private static func createWebArchiveData(from webView: WKWebView) async throws -> Data {
        try await requestArchiveData { completionHandler in
            webView.createWebArchiveData { result in
                completionHandler(result.mapError { $0 as Error })
            }
        }
    }

    package static func requestArchiveData(
        _ startRequest: (@escaping @Sendable (Result<Data, Error>) -> Void) -> Void
    ) async throws -> Data {
        let state = WIArchiveRequestState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)

                if Task.isCancelled {
                    state.resume(with: .failure(CancellationError()))
                    return
                }

                startRequest { result in
                    state.resume(with: result)
                }
            }
        } onCancel: {
            state.resume(with: .failure(CancellationError()))
        }
    }

    private static func resolveArchiveFrameID(
        for matchedResource: WIWebArchiveResourceLookup.MatchedResource,
        frameInfos: [WKFrameInfo]
    ) -> UInt64? {
        let frameInfo: WKFrameInfo?
        if matchedResource.isMainFrame {
            frameInfo = frameInfos.first(where: { $0.isMainFrame })
        } else if let frameURL = matchedResource.frameURL {
            frameInfo = frameInfos.first(where: {
                !$0.isMainFrame && $0.request.url?.absoluteString == frameURL
            }) ?? frameInfos.first(where: {
                $0.request.url?.absoluteString == frameURL
            })
        } else {
            frameInfo = nil
        }

        guard let frameInfo else {
            return nil
        }
        return WISPIFrameBridge.frameID(for: frameInfo)
    }
}

@MainActor
package struct WIFrameInfoProvider: WIFrameInfoProviding {
    package init() {}

    package func frameInfos(in webView: WKWebView) async -> [WKFrameInfo]? {
        await WISPIFrameBridge.frameInfos(for: webView)
    }
}

private enum WIWebArchiveResourceLookup {
    struct MatchedResource {
        let data: Data
        let mimeType: String?
        let frameURL: String?
        let isMainFrame: Bool
    }

    private static let mainResourceKey = "WebMainResource"
    private static let subresourcesKey = "WebSubresources"
    private static let subframeArchivesKey = "WebSubframeArchives"
    private static let resourceURLKey = "WebResourceURL"
    private static let resourceDataKey = "WebResourceData"
    private static let resourceMIMETypeKey = "WebResourceMIMEType"

    static func matchingResource(for targetURL: URL, in archiveData: Data) throws -> MatchedResource? {
        let propertyList: Any
        do {
            propertyList = try unsafe PropertyListSerialization.propertyList(from: archiveData, options: [], format: nil)
        } catch {
            throw WIImageCacheSPIError.webArchiveDecodeFailed
        }

        guard let archive = propertyList as? [String: Any] else {
            throw WIImageCacheSPIError.webArchiveDecodeFailed
        }

        return matchingResource(
            forAbsoluteURL: targetURL.absoluteString,
            in: archive,
            frameURL: archiveFrameURL(from: archive),
            isMainFrame: true
        )
    }

    private static func matchingResource(
        forAbsoluteURL targetURL: String,
        in archive: [String: Any],
        frameURL: String?,
        isMainFrame: Bool
    ) -> MatchedResource? {
        if let mainResource = archive[mainResourceKey] as? [String: Any],
           let matchedResource = matchedResource(
            in: mainResource,
            targetURL: targetURL,
            frameURL: frameURL,
            isMainFrame: isMainFrame
           ) {
            return matchedResource
        }

        if let subresources = archive[subresourcesKey] as? [[String: Any]] {
            for subresource in subresources {
                if let matchedResource = matchedResource(
                    in: subresource,
                    targetURL: targetURL,
                    frameURL: frameURL,
                    isMainFrame: isMainFrame
                ) {
                    return matchedResource
                }
            }
        }

        if let subframeArchives = archive[subframeArchivesKey] as? [[String: Any]] {
            for subframeArchive in subframeArchives {
                if let matchedResource = matchingResource(
                    forAbsoluteURL: targetURL,
                    in: subframeArchive,
                    frameURL: archiveFrameURL(from: subframeArchive),
                    isMainFrame: false
                ) {
                    return matchedResource
                }
            }
        }

        return nil
    }

    private static func matchedResource(
        in resource: [String: Any],
        targetURL: String,
        frameURL: String?,
        isMainFrame: Bool
    ) -> MatchedResource? {
        guard resource[resourceURLKey] as? String == targetURL,
              let data = resource[resourceDataKey] as? Data else {
            return nil
        }

        return MatchedResource(
            data: data,
            mimeType: resource[resourceMIMETypeKey] as? String,
            frameURL: frameURL,
            isMainFrame: isMainFrame
        )
    }

    private static func archiveFrameURL(from archive: [String: Any]) -> String? {
        guard let mainResource = archive[mainResourceKey] as? [String: Any] else {
            return nil
        }
        return mainResource[resourceURLKey] as? String
    }
}
