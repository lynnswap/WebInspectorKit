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
    /// first directly fetchable match.
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
            frameInfo !== mainFrameInfo
        }

        func lookupResource(in frameInfo: WKFrameInfo) async throws -> WISPIFetchedResource? {
            do {
                return try await resourceLookup(imageURL, frameInfo, webView)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NSError {
                if WISPIResourceLookupBridgeError(error) == .invalidArgument {
                    throw WIImageCacheSPIError.resourceFetchFailed
                }
                return nil
            } catch {
                return nil
            }
        }

        if let resource = try await lookupResource(in: mainFrameInfo) {
            return try Self.makeEntry(resource: resource, frameInfo: mainFrameInfo, resolvedURL: imageURL)
        }

        var firstSubframeMatch: (resource: WISPIFetchedResource, frameInfo: WKFrameInfo)?
        for frameInfo in subframeInfos {
            if let resource = try await lookupResource(in: frameInfo) {
                firstSubframeMatch = (resource, frameInfo)
                break
            }
        }

        if let firstSubframeMatch {
            if let resource = try await lookupResource(in: mainFrameInfo) {
                return try Self.makeEntry(resource: resource, frameInfo: mainFrameInfo, resolvedURL: imageURL)
            }
            return try Self.makeEntry(
                resource: firstSubframeMatch.resource,
                frameInfo: firstSubframeMatch.frameInfo,
                resolvedURL: imageURL
            )
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
}

@MainActor
package struct WIFrameInfoProvider: WIFrameInfoProviding {
    package init() {}

    package func frameInfos(in webView: WKWebView) async -> [WKFrameInfo]? {
        await WISPIFrameBridge.frameInfos(for: webView)
    }
}
