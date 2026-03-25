import Foundation
import Testing
import WebKit
@testable import WebInspectorBridge
@testable import WebInspectorKitSPI

@MainActor
@Suite(.serialized)
struct WIImageCacheSPITests {
    @Test
    func archiveParserFindsResourceInNestedSubframeArchives() throws {
        let targetURL = URL(string: "https://example.com/target.png")!
        let targetData = Data([0x01, 0x02, 0x03])
        let archive = makeArchiveDictionary(
            mainResourceURL: "https://example.com/index.html",
            subresources: [
                makeResourceDictionary(url: "https://example.com/other.png", data: Data([0x09]), mimeType: "image/png"),
            ],
            subframeArchives: [
                makeArchiveDictionary(
                    mainResourceURL: "https://example.com/frame.html",
                    subresources: [
                        makeResourceDictionary(url: targetURL.absoluteString, data: targetData, mimeType: "image/png"),
                    ]
                ),
            ]
        )
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)

        let resource = try WIWebArchiveParser.resource(matching: targetURL, in: data)

        #expect(
            resource == .init(
                data: targetData,
                mimeType: "image/png",
                frameURL: "https://example.com/frame.html",
                isMainFrame: false
            )
        )
    }

    @Test
    func archiveParserReturnsNilWhenResourceIsMissing() throws {
        let archive = makeArchiveDictionary(mainResourceURL: "https://example.com/index.html")
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)

        let resource = try WIWebArchiveParser.resource(matching: URL(string: "https://example.com/missing.png")!, in: data)

        #expect(resource == nil)
    }

    @Test
    func archiveParserThrowsForMalformedArchiveData() {
        #expect(throws: WIImageCacheSPIError.webArchiveDecodeFailed) {
            try WIWebArchiveParser.resource(
                matching: URL(string: "https://example.com/bad.png")!,
                in: Data("not-a-plist".utf8)
            )
        }
    }

    @Test
    func archiveParserPrefersMainFrameResourceForDuplicateURL() throws {
        let sharedURL = URL(string: "https://example.com/shared.png")!
        let mainData = Data([0x01])
        let childData = Data([0x02])
        let archive = makeArchiveDictionary(
            mainResourceURL: "https://example.com/index.html",
            subresources: [
                makeResourceDictionary(url: sharedURL.absoluteString, data: mainData, mimeType: "image/png"),
            ],
            subframeArchives: [
                makeArchiveDictionary(
                    mainResourceURL: "https://example.com/frame.html",
                    subresources: [
                        makeResourceDictionary(url: sharedURL.absoluteString, data: childData, mimeType: "image/png"),
                    ]
                ),
            ]
        )
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)

        let resource = try WIWebArchiveParser.resource(matching: sharedURL, in: data)

        #expect(
            resource == .init(
                data: mainData,
                mimeType: "image/png",
                frameURL: "https://example.com/index.html",
                isMainFrame: true
            )
        )
    }

    @Test
    func frameInfoProviderFallsBackToMainFrameResolutionWhenFramesSelectorIsUnavailable() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><img src="main.png"></body></html>
            """,
            files: ["main.png": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)
        let mainURL = fixture.directory.appendingPathComponent("main.png")
        _ = try await waitUntilDisplayedImageCache(for: mainURL, in: webView)

        let realFrameInfo = try #require(await WISPIFrameBridge.frameInfos(for: webView)?.first)
        let realFrameID = try #require(WISPIFrameBridge.frameID(for: realFrameInfo))
        let fallbackWebView = FallbackFrameTestWebView(frameInfo: realFrameInfo, frameID: realFrameID)

        let frameInfos = try #require(await WISPIFrameBridge.frameInfos(for: fallbackWebView))

        #expect(frameInfos.count == 1)
        #expect(WISPIFrameBridge.frameID(for: frameInfos[0]) == realFrameID)
    }

    @Test
    func displayedImageCachePropagatesCancellationFromArchiveCreation() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><img src="main.png"></body></html>
            """,
            files: ["main.png": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)
        let mainURL = fixture.directory.appendingPathComponent("main.png")
        _ = try await waitUntilDisplayedImageCache(for: mainURL, in: webView)

        let frameInfos = try #require(await WISPIFrameBridge.frameInfos(for: webView))
        let loader = WIImageCacheLoader(
            frameInfoProvider: StubFrameInfoProvider(frameInfos: frameInfos),
            webArchiveCreator: CancelledWebArchiveCreator()
        )

        await #expect(throws: CancellationError.self) {
            try await loader.displayedImageCache(
                for: fixture.directory.appendingPathComponent("main.png"),
                in: webView
            )
        }
    }

    @Test
    func displayedImageCacheReturnsMainFrameImageData() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><img id="target" src="main.png"></body></html>
            """,
            files: ["main.png": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)
        let entry = try await waitUntilDisplayedImageCache(
            for: fixture.directory.appendingPathComponent("main.png"),
            in: webView
        )

        let resolved = try #require(entry)
        #expect(resolved.data == Self.pngData)
        #expect(resolved.mimeType == "image/png")
        #expect(resolved.resolvedURL == fixture.directory.appendingPathComponent("main.png"))
        #expect(resolved.frameID > 0)
    }

    @Test
    func displayedImageCacheUsesCurrentSrcForPictureSelection() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html>
            <body>
                <picture>
                    <source srcset="selected.png">
                    <img id="target" src="fallback.png">
                </picture>
            </body>
            </html>
            """,
            files: [
                "selected.png": Self.pngData,
                "fallback.png": Data([0xFF, 0xD8, 0xFF, 0xD9]),
            ]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)
        let selectedURL = fixture.directory.appendingPathComponent("selected.png")
        let fallbackURL = fixture.directory.appendingPathComponent("fallback.png")
        let selectedEntry = try await waitUntilDisplayedImageCache(for: selectedURL, in: webView)
        let fallbackEntry = try await WIImageCacheSPI.displayedImageCache(for: fallbackURL, in: webView)

        #expect(selectedEntry?.data == Self.pngData)
        #expect(fallbackEntry == nil)
    }

    @Test
    func displayedImageCacheReturnsDataForHiddenImage() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><img id="target" src="hidden.png" style="display:none"></body></html>
            """,
            files: ["hidden.png": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)
        let entry = try await waitUntilDisplayedImageCache(
            for: fixture.directory.appendingPathComponent("hidden.png"),
            in: webView
        )

        #expect(entry?.data == Self.pngData)
    }

    @Test
    func displayedImageCacheReturnsIframeImageWhenMainFrameDoesNotMatch() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: { directory in
                let imageURL = directory.appendingPathComponent("frame.png").absoluteString
                return """
                <!doctype html>
                <html><body><iframe srcdoc="<img id='target' src='\(imageURL)'>"></iframe></body></html>
                """
            },
            files: ["frame.png": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)
        let frameInfosLoaded = await waitUntil {
            guard let frameInfos = await WISPIFrameBridge.frameInfos(for: webView) else {
                return false
            }
            return frameInfos.count > 1
        }
        #expect(frameInfosLoaded)

        let mainFrameID = try #require(await WISPIFrameBridge.frameInfos(for: webView)?.first.flatMap(WISPIFrameBridge.frameID))
        let entry = try await waitUntilDisplayedImageCache(for: fixture.directory.appendingPathComponent("frame.png"), in: webView)

        let resolved = try #require(entry)
        #expect(resolved.data == Self.pngData)
        #expect(resolved.frameID != mainFrameID)
    }

    @Test
    func displayedImageCachePrefersMainFrameWhenURLExistsInMainFrameAndIframe() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: { directory in
                let imageURL = directory.appendingPathComponent("shared.png").absoluteString
                return """
                <!doctype html>
                <html>
                <body>
                    <img id="main" src="shared.png">
                    <iframe srcdoc="<img id='child' src='\(imageURL)'>"></iframe>
                </body>
                </html>
                """
            },
            files: ["shared.png": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)
        let entry = try await waitUntilDisplayedImageCache(for: fixture.directory.appendingPathComponent("shared.png"), in: webView)

        let frameInfos = try #require(await WISPIFrameBridge.frameInfos(for: webView))
        let mainFrameID = try #require(frameInfos.first.flatMap(WISPIFrameBridge.frameID))

        #expect(entry?.frameID == mainFrameID)
        #expect(entry?.data == Self.pngData)
    }

    @Test
    func resolveFrameIDUsesMatchedResourceFrameURLForSubframe() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><iframe src="frame.html"></iframe></body></html>
            """,
            files: [
                "frame.html": Data("""
                <!doctype html>
                <html><body><img src="frame.png"></body></html>
                """.utf8),
                "frame.png": Self.pngData,
            ]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)

        let framesLoaded = await waitUntil {
            guard let frameInfos = await WISPIFrameBridge.frameInfos(for: webView) else {
                return false
            }
            return frameInfos.count > 1
        }
        #expect(framesLoaded)

        let frameInfos = try #require(await WISPIFrameBridge.frameInfos(for: webView))
        let subframe = try #require(frameInfos.first(where: { !$0.isMainFrame }))
        let subframeID = try #require(WISPIFrameBridge.frameID(for: subframe))

        let resolved = WIImageCacheLoader.resolveFrameID(
            for: .init(
                data: Self.pngData,
                mimeType: "image/png",
                frameURL: subframe.request.url?.absoluteString,
                isMainFrame: false
            ),
            in: frameInfos
        )

        #expect(resolved == subframeID)
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func loadFile(named fileName: String, from fixture: FixtureSite, in webView: WKWebView) async throws {
        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate
        let fileURL = fixture.directory.appendingPathComponent(fileName)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            webView.loadFileURL(fileURL, allowingReadAccessTo: fixture.directory)
        }
    }

    private func waitUntilDisplayedImageCache(
        for imageURL: URL,
        in webView: WKWebView,
        maxAttempts: Int = 250,
        intervalNanoseconds: UInt64 = 20_000_000
    ) async throws -> WIDisplayedImageCacheEntry? {
        var lastEntry: WIDisplayedImageCacheEntry?
        for _ in 0..<maxAttempts {
            lastEntry = try await WIImageCacheSPI.displayedImageCache(for: imageURL, in: webView)
            if lastEntry != nil {
                return lastEntry
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return try await WIImageCacheSPI.displayedImageCache(for: imageURL, in: webView)
    }

    private func waitUntil(
        maxAttempts: Int = 250,
        intervalNanoseconds: UInt64 = 20_000_000,
        predicate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<maxAttempts {
            if await predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return await predicate()
    }

    private func makeFixtureSite(indexHTML: String, files: [String: Data]) throws -> FixtureSite {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(indexHTML.utf8).write(to: directory.appendingPathComponent("index.html"))
        for (fileName, data) in files {
            try data.write(to: directory.appendingPathComponent(fileName))
        }
        return FixtureSite(directory: directory)
    }

    private func makeFixtureSite(indexHTML: (URL) -> String, files: [String: Data]) throws -> FixtureSite {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(indexHTML(directory).utf8).write(to: directory.appendingPathComponent("index.html"))
        for (fileName, data) in files {
            try data.write(to: directory.appendingPathComponent(fileName))
        }
        return FixtureSite(directory: directory)
    }

    private func makeArchiveDictionary(
        mainResourceURL: String,
        subresources: [[String: Any]] = [],
        subframeArchives: [[String: Any]] = []
    ) -> [String: Any] {
        var result: [String: Any] = [
            "WebMainResource": makeResourceDictionary(
                url: mainResourceURL,
                data: Data(mainResourceURL.utf8),
                mimeType: "text/html"
            ),
        ]
        if !subresources.isEmpty {
            result["WebSubresources"] = subresources
        }
        if !subframeArchives.isEmpty {
            result["WebSubframeArchives"] = subframeArchives
        }
        return result
    }

    private func makeResourceDictionary(url: String, data: Data, mimeType: String) -> [String: Any] {
        [
            "WebResourceURL": url,
            "WebResourceData": data,
            "WebResourceMIMEType": mimeType,
        ]
    }

    private struct FixtureSite {
        let directory: URL
    }

    private static let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Zk9cAAAAASUVORK5CYII=")!
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

@MainActor
private struct StubFrameInfoProvider: WIFrameInfoProviding {
    let frameInfos: [WKFrameInfo]

    func frameInfos(in webView: WKWebView) async -> [WKFrameInfo]? {
        frameInfos
    }
}

@MainActor
private struct CancelledWebArchiveCreator: WIWebArchiveCreating {
    func createWebArchiveData(in webView: WKWebView) async throws -> Data {
        throw CancellationError()
    }
}

@objcMembers
private final class FallbackFrameHandle: NSObject {
    let frameID: UInt64

    init(frameID: UInt64) {
        self.frameID = frameID
    }
}

private final class FallbackFrameTestWebView: WKWebView {
    private let fallbackHandle: FallbackFrameHandle
    private let fallbackFrameInfo: WKFrameInfo

    init(frameInfo: WKFrameInfo, frameID: UInt64) {
        fallbackHandle = FallbackFrameHandle(frameID: frameID)
        fallbackFrameInfo = frameInfo
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc(_mainFrame)
    func test_mainFrame() -> AnyObject {
        fallbackHandle
    }

    @objc(_frameInfoFromHandle:completionHandler:)
    func test_frameInfoFromHandle(_ handle: AnyObject, completionHandler: @escaping (WKFrameInfo?) -> Void) {
        completionHandler(fallbackFrameInfo)
    }
}
