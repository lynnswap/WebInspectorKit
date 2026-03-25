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
}

@MainActor
public enum WIImageCacheSPI {
    /// Returns cached bytes for the first loaded image subresource in the current page
    /// whose resource URL exactly matches `imageURL`.
    ///
    /// This lookup does not evaluate JavaScript and does not attempt to determine whether
    /// the image is currently rendered or visible in the DOM. It searches the current
    /// page archive across the main frame and subframes, preferring the main frame when
    /// duplicate URLs exist.
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

@MainActor
package protocol WIWebArchiveCreating {
    func createWebArchiveData(in webView: WKWebView) async throws -> Data
}

@MainActor
package struct WIImageCacheLoader {
    package let frameInfoProvider: any WIFrameInfoProviding
    package let webArchiveCreator: any WIWebArchiveCreating

    package init(
        frameInfoProvider: any WIFrameInfoProviding = WIFrameInfoProvider(),
        webArchiveCreator: any WIWebArchiveCreating = WIWebArchiveCreator()
    ) {
        self.frameInfoProvider = frameInfoProvider
        self.webArchiveCreator = webArchiveCreator
    }

    package func displayedImageCache(
        for imageURL: URL,
        in webView: WKWebView
    ) async throws -> WIDisplayedImageCacheEntry? {
        guard let frameInfos = await frameInfoProvider.frameInfos(in: webView), !frameInfos.isEmpty else {
            throw WIImageCacheSPIError.frameEnumerationUnavailable
        }

        let archiveData: Data
        do {
            archiveData = try await webArchiveCreator.createWebArchiveData(in: webView)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WIImageCacheSPIError.webArchiveCreationFailed
        }

        guard let resource = try WIWebArchiveParser.resource(matching: imageURL, in: archiveData) else {
            return nil
        }
        guard let frameID = Self.resolveFrameID(for: resource, in: frameInfos) else {
            throw WIImageCacheSPIError.frameEnumerationUnavailable
        }

        return WIDisplayedImageCacheEntry(
            data: resource.data,
            mimeType: resource.mimeType,
            resolvedURL: imageURL,
            frameID: frameID
        )
    }

    package static func resolveFrameID(
        for matchedResource: WIWebArchiveParser.MatchedResource,
        in frameInfos: [WKFrameInfo]
    ) -> UInt64? {
        let matchedFrame: WKFrameInfo?
        if matchedResource.isMainFrame {
            matchedFrame = frameInfos.first(where: \.isMainFrame)
        } else {
            matchedFrame =
                frameInfos.first(where: {
                    !$0.isMainFrame && $0.request.url?.absoluteString == matchedResource.frameURL
                })
                ?? frameInfos.first(where: {
                    $0.request.url?.absoluteString == matchedResource.frameURL
                })
        }

        guard let matchedFrame else {
            return nil
        }
        return WISPIFrameBridge.frameID(for: matchedFrame)
    }
}

@MainActor
package struct WIFrameInfoProvider: WIFrameInfoProviding {
    package init() {}

    package func frameInfos(in webView: WKWebView) async -> [WKFrameInfo]? {
        await WISPIFrameBridge.frameInfos(for: webView)
    }
}

@MainActor
package struct WIWebArchiveCreator: WIWebArchiveCreating {
    package init() {}

    package func createWebArchiveData(in webView: WKWebView) async throws -> Data {
        try await requestArchiveData { completionHandler in
            webView.createWebArchiveData { result in
                completionHandler(result)
            }
        }
    }

    package func requestArchiveData(
        _ startRequest: (@escaping @Sendable (Result<Data, Error>) -> Void) -> Void
    ) async throws -> Data {
        let state = ArchiveRequestState()

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
}

private final class ArchiveRequestState: @unchecked Sendable {
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

package enum WIWebArchiveParser {
    package struct MatchedResource: Equatable {
        package let data: Data
        package let mimeType: String?
        package let frameURL: String?
        package let isMainFrame: Bool
    }

    private static let mainResourceKey = "WebMainResource"
    private static let subresourcesKey = "WebSubresources"
    private static let subframeArchivesKey = "WebSubframeArchives"
    private static let resourceDataKey = "WebResourceData"
    private static let resourceURLKey = "WebResourceURL"
    private static let resourceMIMETypeKey = "WebResourceMIMEType"

    package static func resource(matching imageURL: URL, in archiveData: Data) throws -> MatchedResource? {
        let propertyList: Any
        do {
            propertyList = try unsafe PropertyListSerialization.propertyList(from: archiveData, options: [], format: nil)
        } catch {
            throw WIImageCacheSPIError.webArchiveDecodeFailed
        }

        guard let root = propertyList as? [String: Any] else {
            throw WIImageCacheSPIError.webArchiveDecodeFailed
        }

        return matchedResource(matching: imageURL.absoluteString, inArchiveDictionary: root, isMainFrame: true)
    }

    private static func matchedResource(
        matching targetURL: String,
        inArchiveDictionary archive: [String: Any],
        isMainFrame: Bool
    ) -> MatchedResource? {
        let currentFrameURL = mainResourceURL(in: archive)

        if let mainResource = archive[mainResourceKey] as? [String: Any],
           let resource = makeResource(
               from: mainResource,
               matching: targetURL,
               frameURL: currentFrameURL,
               isMainFrame: isMainFrame
           ) {
            return resource
        }

        if let subresources = archive[subresourcesKey] as? [[String: Any]] {
            for subresource in subresources {
                if let resource = makeResource(
                    from: subresource,
                    matching: targetURL,
                    frameURL: currentFrameURL,
                    isMainFrame: isMainFrame
                ) {
                    return resource
                }
            }
        }

        if let subframeArchives = archive[subframeArchivesKey] as? [[String: Any]] {
            for subframeArchive in subframeArchives {
                if let matched = matchedResource(
                    matching: targetURL,
                    inArchiveDictionary: subframeArchive,
                    isMainFrame: false
                ) {
                    return matched
                }
            }
        }

        return nil
    }

    private static func mainResourceURL(in archive: [String: Any]) -> String? {
        guard let mainResource = archive[mainResourceKey] as? [String: Any] else {
            return nil
        }
        return mainResource[resourceURLKey] as? String
    }

    private static func makeResource(
        from resource: [String: Any],
        matching targetURL: String,
        frameURL: String?,
        isMainFrame: Bool
    ) -> MatchedResource? {
        guard let resourceURL = resource[resourceURLKey] as? String, resourceURL == targetURL else {
            return nil
        }
        guard let data = resource[resourceDataKey] as? Data else {
            return nil
        }
        return MatchedResource(
            data: data,
            mimeType: resource[resourceMIMETypeKey] as? String,
            frameURL: frameURL,
            isMainFrame: isMainFrame
        )
    }
}
