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
package protocol WIDisplayedImageMatching {
    func firstMatchingFrame(
        for imageURL: URL,
        in webView: WKWebView,
        frames: [WKFrameInfo]
    ) async -> WKFrameInfo?
}

@MainActor
package protocol WIWebArchiveCreating {
    func createWebArchiveData(in webView: WKWebView) async throws -> Data
}

@MainActor
package struct WIImageCacheLoader {
    package let frameInfoProvider: any WIFrameInfoProviding
    package let imageMatcher: any WIDisplayedImageMatching
    package let webArchiveCreator: any WIWebArchiveCreating

    package init(
        frameInfoProvider: any WIFrameInfoProviding = WIFrameInfoProvider(),
        imageMatcher: any WIDisplayedImageMatching = WIDisplayedImageMatcher(),
        webArchiveCreator: any WIWebArchiveCreating = WIWebArchiveCreator()
    ) {
        self.frameInfoProvider = frameInfoProvider
        self.imageMatcher = imageMatcher
        self.webArchiveCreator = webArchiveCreator
    }

    package func displayedImageCache(
        for imageURL: URL,
        in webView: WKWebView
    ) async throws -> WIDisplayedImageCacheEntry? {
        guard let frameInfos = await frameInfoProvider.frameInfos(in: webView), !frameInfos.isEmpty else {
            throw WIImageCacheSPIError.frameEnumerationUnavailable
        }

        guard let matchedFrame = await imageMatcher.firstMatchingFrame(
            for: imageURL,
            in: webView,
            frames: frameInfos
        ) else {
            return nil
        }
        guard let frameID = WISPIFrameBridge.frameID(for: matchedFrame) else {
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

        guard let resource = try WIWebArchiveParser.resource(
            matching: imageURL,
            in: archiveData,
            frameURL: matchedFrame.request.url?.absoluteString,
            isMainFrame: matchedFrame.isMainFrame
        ) else {
            return nil
        }

        return WIDisplayedImageCacheEntry(
            data: resource.data,
            mimeType: resource.mimeType,
            resolvedURL: imageURL,
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

@MainActor
package struct WIDisplayedImageMatcher: WIDisplayedImageMatching {
    package init() {}

    package func firstMatchingFrame(
        for imageURL: URL,
        in webView: WKWebView,
        frames: [WKFrameInfo]
    ) async -> WKFrameInfo? {
        for frame in frames {
            let rawResult = try? await webView.callAsyncJavaScript(
                Self.script,
                arguments: ["targetURL": imageURL.absoluteString],
                in: frame,
                contentWorld: .page
            )
            let matches = (rawResult as? Bool) ?? (rawResult as? NSNumber)?.boolValue ?? false
            if matches {
                return frame
            }
        }
        return nil
    }

    private static let script = #"""
    return Array.from(document.images).some((img) => {
        if (!img || !img.isConnected) {
            return false;
        }
        if (img.currentSrc !== targetURL) {
            return false;
        }
        return img.getClientRects().length > 0;
    });
    """#
}

@MainActor
package struct WIWebArchiveCreator: WIWebArchiveCreating {
    package init() {}

    package func createWebArchiveData(in webView: WKWebView) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createWebArchiveData { result in
                continuation.resume(with: result)
            }
        }
    }
}

package enum WIWebArchiveParser {
    package struct Resource: Equatable {
        package let data: Data
        package let mimeType: String?
    }

    private static let mainResourceKey = "WebMainResource"
    private static let subresourcesKey = "WebSubresources"
    private static let subframeArchivesKey = "WebSubframeArchives"
    private static let resourceDataKey = "WebResourceData"
    private static let resourceURLKey = "WebResourceURL"
    private static let resourceMIMETypeKey = "WebResourceMIMEType"

    package static func resource(
        matching imageURL: URL,
        in archiveData: Data,
        frameURL: String?,
        isMainFrame: Bool
    ) throws -> Resource? {
        let propertyList: Any
        do {
            propertyList = try unsafe PropertyListSerialization.propertyList(from: archiveData, options: [], format: nil)
        } catch {
            throw WIImageCacheSPIError.webArchiveDecodeFailed
        }

        guard let root = propertyList as? [String: Any] else {
            throw WIImageCacheSPIError.webArchiveDecodeFailed
        }

        if isMainFrame {
            return resourceInCurrentArchive(matching: imageURL.absoluteString, archive: root)
        }

        guard let frameURL else {
            throw WIImageCacheSPIError.frameEnumerationUnavailable
        }

        guard let scopedArchive = scopedArchive(matchingFrameURL: frameURL, inArchiveDictionary: root) else {
            return nil
        }
        return resourceInCurrentArchive(matching: imageURL.absoluteString, archive: scopedArchive)
    }

    private static func resourceInCurrentArchive(matching targetURL: String, archive: [String: Any]) -> Resource? {
        if let mainResource = archive[mainResourceKey] as? [String: Any],
           let resource = makeResource(from: mainResource, matching: targetURL) {
            return resource
        }

        if let subresources = archive[subresourcesKey] as? [[String: Any]] {
            for subresource in subresources {
                if let resource = makeResource(from: subresource, matching: targetURL) {
                    return resource
                }
            }
        }

        return nil
    }

    private static func scopedArchive(
        matchingFrameURL frameURL: String,
        inArchiveDictionary archiveDictionary: [String: Any]
    ) -> [String: Any]? {
        if let mainResource = archiveDictionary[mainResourceKey] as? [String: Any],
           let mainResourceURL = mainResource[resourceURLKey] as? String,
           mainResourceURL == frameURL {
            return archiveDictionary
        }

        guard let subframeArchives = archiveDictionary[subframeArchivesKey] as? [[String: Any]] else {
            return nil
        }

        for subframeArchive in subframeArchives {
            if let matched = scopedArchive(matchingFrameURL: frameURL, inArchiveDictionary: subframeArchive) {
                return matched
            }
        }
        return nil
    }

    private static func makeResource(from resource: [String: Any], matching targetURL: String) -> Resource? {
        guard let resourceURL = resource[resourceURLKey] as? String, resourceURL == targetURL else {
            return nil
        }
        guard let data = resource[resourceDataKey] as? Data else {
            return nil
        }
        return Resource(
            data: data,
            mimeType: resource[resourceMIMETypeKey] as? String
        )
    }
}
