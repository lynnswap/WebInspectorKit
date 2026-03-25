import Foundation
import Testing
import WebKit
@testable import WebInspectorBridge
@testable import WebInspectorKitSPI

@MainActor
@Suite(.serialized)
struct WIImageCacheSPITests {
    @Test
    func symbolResolverResolvesRequiredWebKitFrameSymbols() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        throw Skip("The runtime smoke test is covered separately on device-backed flows.")
        #else
        let resolutionSucceeded = unsafe WISPIWebKitFrameSymbolResolver.symbols() != nil
        #expect(resolutionSucceeded)
        #endif
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
    func frameInfoProviderUsesFrameTreesWhenFramesSelectorIsUnavailable() async throws {
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

        let realFrameInfos = try #require(await WISPIFrameBridge.frameInfos(for: webView))
        let mainFrameInfo = try #require(realFrameInfos.first(where: { $0.isMainFrame }))
        let childFrameInfo = try #require(realFrameInfos.first(where: { !$0.isMainFrame }))
        let fallbackWebView = FrameTreesFallbackWebView(
            rootNodes: [
                FrameTreeNodeStub(info: mainFrameInfo, childFrames: [
                    FrameTreeNodeStub(info: childFrameInfo),
                ]),
            ]
        )

        let frameInfos = try #require(await WISPIFrameBridge.frameInfos(for: fallbackWebView))

        #expect(frameInfos.count == 2)
        #expect(frameInfos.first?.isMainFrame == true)
        #expect(frameInfos.compactMap(WISPIFrameBridge.frameID).count == 2)
    }

    @Test
    func frameBridgeReturnsDataFromWKFrameGetResourceData() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><img src="main.png"></body></html>
            """,
            files: ["main.png": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)

        let frameInfo = try #require(await WISPIFrameBridge.frameInfos(for: webView)?.first)
        let resource = try await waitUntilFrameResourceData(
            for: fixture.directory.appendingPathComponent("main.png"),
            in: frameInfo,
            webView: webView
        )

        #expect(resource?.data == Self.pngData)
        #expect(resource?.mimeType == "image/png")
    }

    @Test
    func frameBridgeRequestResourceStopsAwaitingWhenTaskIsCancelled() async throws {
        let state = SlowResourceRequestState()

        let task = Task {
            try await WISPIFrameBridge.requestResource { completionHandler in
                state.completionHandler = completionHandler
            }
        }

        let requestStarted = await waitUntil {
            state.completionHandler != nil
        }
        #expect(requestStarted)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        state.completionHandler?(.success(.init(data: Self.pngData, mimeType: nil)))
    }

    @Test
    func archiveFallbackRequestStopsAwaitingWhenTaskIsCancelled() async throws {
        let state = SlowArchiveRequestState()

        let task = Task {
            try await WIImageCacheLoader.requestArchiveData { completionHandler in
                state.completionHandler = completionHandler
            }
        }

        let requestStarted = await waitUntil {
            state.completionHandler != nil
        }
        #expect(requestStarted)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        state.completionHandler?(.success(Data()))
    }

    @Test
    func frameBridgeThrowsWhenDirectLookupCannotResolvePage() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><img src="main.png"></body></html>
            """,
            files: ["main.png": Self.pngData]
        )
        let workingWebView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: workingWebView)
        let mainURL = fixture.directory.appendingPathComponent("main.png")
        _ = try await waitUntilDisplayedImageCache(for: mainURL, in: workingWebView)

        let frameInfo = try #require(await WISPIFrameBridge.frameInfos(for: workingWebView)?.first)
        let brokenWebView = BrokenPageTestWebView()

        await #expect(throws: Error.self) {
            try await WISPIFrameBridge.resourceData(for: mainURL, in: frameInfo, webView: brokenWebView)
        }
    }

    @Test
    func displayedImageCacheFallsBackToArchiveWhenDirectSymbolsAreUnavailable() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><img src="main.png"></body></html>
            """,
            files: ["main.png": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)
        let frameInfos = try #require(await WISPIFrameBridge.frameInfos(for: webView))
        let loader = WIImageCacheLoader(
            frameInfoProvider: StubFrameInfoProvider(frameInfos: frameInfos),
            resourceLookup: { _, _, _ in
                throw NSError(
                    domain: WISPIResourceLookupBridgeError.domain,
                    code: WISPIResourceLookupBridgeError.symbolUnavailable.rawValue
                )
            }
        )

        let entry = try await loader.displayedImageCache(
            for: fixture.directory.appendingPathComponent("main.png"),
            in: webView
        )

        #expect(entry?.data == Self.pngData)
        #expect(entry?.mimeType == "image/png")
    }

    @Test
    func displayedImageCacheFallsBackToArchiveWhenPageLookupFails() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><img src="main.png"></body></html>
            """,
            files: ["main.png": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)
        let frameInfos = try #require(await WISPIFrameBridge.frameInfos(for: webView))
        let loader = WIImageCacheLoader(
            frameInfoProvider: StubFrameInfoProvider(frameInfos: frameInfos),
            resourceLookup: { _, _, _ in
                throw NSError(
                    domain: WISPIResourceLookupBridgeError.domain,
                    code: WISPIResourceLookupBridgeError.pageUnavailable.rawValue
                )
            }
        )

        let entry = try await loader.displayedImageCache(
            for: fixture.directory.appendingPathComponent("main.png"),
            in: webView
        )

        #expect(entry?.data == Self.pngData)
        #expect(entry?.mimeType == "image/png")
    }

    @Test
    func displayedImageCacheFallsBackToArchiveWhenDirectLookupReturnsGenericNSError() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><img src="main.png"></body></html>
            """,
            files: ["main.png": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)
        let frameInfos = try #require(await WISPIFrameBridge.frameInfos(for: webView))
        let loader = WIImageCacheLoader(
            frameInfoProvider: StubFrameInfoProvider(frameInfos: frameInfos),
            resourceLookup: { _, _, _ in
                throw NSError(domain: "WebKitErrorDomain", code: 1)
            }
        )

        let entry = try await loader.displayedImageCache(
            for: fixture.directory.appendingPathComponent("main.png"),
            in: webView
        )

        #expect(entry?.data == Self.pngData)
        #expect(entry?.mimeType == "image/png")
    }

    @Test
    func displayedImageCacheThrowsResourceFetchFailedForInvalidLookupArguments() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><img src="main.png"></body></html>
            """,
            files: ["main.png": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)
        let frameInfos = try #require(await WISPIFrameBridge.frameInfos(for: webView))
        let loader = WIImageCacheLoader(
            frameInfoProvider: StubFrameInfoProvider(frameInfos: frameInfos),
            resourceLookup: { _, _, _ in
                throw NSError(
                    domain: WISPIResourceLookupBridgeError.domain,
                    code: WISPIResourceLookupBridgeError.invalidArgument.rawValue
                )
            }
        )

        await #expect(throws: WIImageCacheSPIError.resourceFetchFailed) {
            _ = try await loader.displayedImageCache(
                for: fixture.directory.appendingPathComponent("main.png"),
                in: webView
            )
        }
    }

    @Test
    func displayedImageCacheContinuesPastStaleFrameLookupFailureToLaterFrameHit() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: { directory in
                let imageURL = directory.appendingPathComponent("frame.png").absoluteString
                return """
                <!doctype html>
                <html><body><iframe srcdoc="<img src='\(imageURL)'>"></iframe></body></html>
                """
            },
            files: ["frame.png": Self.pngData]
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
        let mainFrameInfo = try #require(frameInfos.first(where: { $0.isMainFrame }))
        let subframeInfo = try #require(frameInfos.first(where: { !$0.isMainFrame }))
        let loader = WIImageCacheLoader(
            frameInfoProvider: StubFrameInfoProvider(frameInfos: frameInfos),
            resourceLookup: { _, frameInfo, _ in
                if frameInfo === mainFrameInfo {
                    throw NSError(
                        domain: WISPIResourceLookupBridgeError.domain,
                        code: WISPIResourceLookupBridgeError.frameUnavailable.rawValue
                    )
                }
                if frameInfo === subframeInfo {
                    return WISPIFetchedResource(data: Self.pngData, mimeType: "image/png")
                }
                return nil
            }
        )

        let entry = try await loader.displayedImageCache(
            for: fixture.directory.appendingPathComponent("frame.png"),
            in: webView
        )

        #expect(entry?.data == Self.pngData)
        #expect(entry?.frameID == WISPIFrameBridge.frameID(for: subframeInfo))
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
    func displayedImageCacheUsesSelectedPictureResourceURL() async throws {
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
    func displayedImageCacheReturnsImageDocumentMainResourceFromIframe() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><iframe src="frame.png"></iframe></body></html>
            """,
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
    func displayedImageCacheReturnsImageDocumentMainResourceWhenTargetURLDiffersOnlyByFragment() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><iframe src="frame.png#viewer"></iframe></body></html>
            """,
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

        var targetURLComponents = URLComponents(
            url: fixture.directory.appendingPathComponent("frame.png"),
            resolvingAgainstBaseURL: false
        )
        targetURLComponents?.fragment = "viewer"
        let targetURL = try #require(targetURLComponents?.url)

        let entry = try await waitUntilDisplayedImageCache(for: targetURL, in: webView)

        #expect(entry?.data == Self.pngData)
        #expect(entry?.mimeType == "image/png")
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
    func displayedImageCacheInfersMIMETypeForExtensionlessImageResource() async throws {
        let fixture = try makeFixtureSite(
            indexHTML: """
            <!doctype html>
            <html><body><img src="blob"></body></html>
            """,
            files: ["blob": Self.pngData]
        )
        let webView = makeTestWebView()
        try await loadFile(named: "index.html", from: fixture, in: webView)

        let entry = try await waitUntilDisplayedImageCache(
            for: fixture.directory.appendingPathComponent("blob"),
            in: webView
        )

        #expect(entry?.data == Self.pngData)
        #expect(entry?.mimeType == "image/png")
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

    private func waitUntilFrameResourceData(
        for imageURL: URL,
        in frameInfo: WKFrameInfo,
        webView: WKWebView,
        maxAttempts: Int = 250,
        intervalNanoseconds: UInt64 = 20_000_000
    ) async throws -> WISPIFetchedResource? {
        var lastResource: WISPIFetchedResource?
        for _ in 0..<maxAttempts {
            lastResource = try await WISPIFrameBridge.resourceData(for: imageURL, in: frameInfo, webView: webView)
            if lastResource != nil {
                return lastResource
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return try await WISPIFrameBridge.resourceData(for: imageURL, in: frameInfo, webView: webView)
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
private final class SlowResourceRequestState {
    var completionHandler: ((Result<WISPIFetchedResource?, NSError>) -> Void)?
}

@MainActor
private final class SlowArchiveRequestState {
    var completionHandler: ((Result<Data, Error>) -> Void)?
}

@MainActor
private struct StubFrameInfoProvider: WIFrameInfoProviding {
    let frameInfos: [WKFrameInfo]?

    func frameInfos(in webView: WKWebView) async -> [WKFrameInfo]? {
        frameInfos
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
        guard handle === fallbackHandle else {
            completionHandler(nil)
            return
        }
        completionHandler(fallbackFrameInfo)
    }
}

private final class BrokenPageTestWebView: WKWebView {
    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc(_pageForTesting)
    func test_pageForTesting() -> UnsafeMutableRawPointer? {
        nil
    }
}

@objcMembers
private final class FrameTreeNodeStub: NSObject {
    let info: WKFrameInfo
    let childFrames: [FrameTreeNodeStub]

    init(info: WKFrameInfo, childFrames: [FrameTreeNodeStub] = []) {
        self.info = info
        self.childFrames = childFrames
    }
}

private final class FrameTreesFallbackWebView: WKWebView {
    private let rootNodes: [FrameTreeNodeStub]

    init(rootNodes: [FrameTreeNodeStub]) {
        self.rootNodes = rootNodes
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc(_frameTrees:)
    func test_frameTrees(_ completionHandler: @escaping (NSSet?) -> Void) {
        completionHandler(NSSet(array: rootNodes))
    }
}
