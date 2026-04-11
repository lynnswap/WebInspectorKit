import Foundation
import Testing
import WebInspectorTestSupport
import WebKit
@testable import WebInspectorEngine
@testable import WebInspectorTransport

@MainActor
@Suite(.serialized, .webKitIsolated)
struct ConsoleTransportDriverTests {
    @Test
    func attachEnablesRuntimeAndConsoleDomains() async {
        let backend = FakeConsoleRegistryBackend()
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(await waitForCondition {
            backend.sentPageMethods.contains(WITransportMethod.Runtime.enable)
                && backend.sentPageMethods.contains(WITransportMethod.Console.enable)
                && backend.sentPageMethods.contains(WITransportMethod.Console.setConsoleClearAPIEnabled)
        })

        await driver.detachPageWebView()
    }

    @Test
    func consoleEnableReplaysBufferedMessagesIntoStore() async {
        let backend = FakeConsoleRegistryBackend(
            pageResultProvider: { method, _, backend in
                guard method == WITransportMethod.Console.enable else {
                    return nil
                }
                backend.emitPageEvent(
                    method: "Console.messageAdded",
                    params: [
                        "message": [
                            "source": "javascript",
                            "level": "log",
                            "text": "backlog message",
                            "type": "log",
                        ]
                    ]
                )
                return [:]
            }
        )
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(await waitForCondition {
            driver.store.entries.contains { $0.renderedText == "backlog message" }
        })

        await driver.detachPageWebView()
    }

    @Test
    func repeatCountUpdatesPreviousMessage() async {
        let backend = FakeConsoleRegistryBackend()
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Console.messageAdded",
            params: [
                "message": [
                    "source": "javascript",
                    "level": "warning",
                    "text": "repeat me",
                    "type": "log",
                ]
            ]
        )
        backend.emitPageEvent(
            method: "Console.messageRepeatCountUpdated",
            params: [
                "count": 3,
            ]
        )

        #expect(await waitForCondition {
            driver.store.entries.last?.repeatCount == 3
        })

        await driver.detachPageWebView()
    }

    @Test
    func messagesClearedEmptiesStore() async {
        let backend = FakeConsoleRegistryBackend()
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Console.messageAdded",
            params: [
                "message": [
                    "source": "javascript",
                    "level": "log",
                    "text": "before clear",
                    "type": "log",
                ]
            ]
        )
        #expect(await waitForCondition {
            driver.store.entries.count == 1
        })

        backend.emitPageEvent(
            method: "Console.messagesCleared",
            params: [
                "reason": "frontend"
            ]
        )

        #expect(await waitForCondition {
            driver.store.entries.isEmpty
        })

        await driver.detachPageWebView()
    }

    @Test
    func evaluateUsesExpectedFlagsAndRendersPrimitiveResult() async throws {
        let backend = FakeConsoleRegistryBackend(
            pageResultProvider: { method, payload, _ in
                guard method == WITransportMethod.Runtime.evaluate else {
                    return nil
                }
                let parameters = payload["params"] as? [String: Any]
                #expect(parameters?["includeCommandLineAPI"] as? Bool == true)
                #expect(parameters?["returnByValue"] as? Bool == false)
                #expect(parameters?["generatePreview"] as? Bool == false)
                #expect(parameters?["saveResult"] as? Bool == true)
                #expect(parameters?["emulateUserGesture"] as? Bool == false)
                return [
                    "result": [
                        "type": "number",
                        "value": 2,
                    ],
                    "wasThrown": false,
                    "savedResultIndex": 1,
                ]
            }
        )
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()
        await driver.evaluate("1 + 1")

        let lastEntry = try #require(driver.store.entries.last)
        #expect(lastEntry.kind == .result)
        #expect(lastEntry.renderedText == "$1 = 2")
        #expect(lastEntry.wasThrown == false)

        await driver.detachPageWebView()
    }

    @Test
    func evaluateFallsBackToClassNameForObjectResult() async throws {
        let backend = FakeConsoleRegistryBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.Runtime.evaluate else {
                    return nil
                }
                return [
                    "result": [
                        "type": "object",
                        "className": "URL",
                    ],
                    "wasThrown": false,
                ]
            }
        )
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()
        await driver.evaluate("new URL('https://example.com')")

        let lastEntry = try #require(driver.store.entries.last)
        #expect(lastEntry.renderedText == "URL")
        #expect(lastEntry.level == .log)

        await driver.detachPageWebView()
    }

    @Test
    func evaluateMarksThrownResultsAsErrors() async throws {
        let backend = FakeConsoleRegistryBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.Runtime.evaluate else {
                    return nil
                }
                return [
                    "result": [
                        "type": "object",
                        "description": "ReferenceError: missingValue is not defined",
                    ],
                    "wasThrown": true,
                ]
            }
        )
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()
        await driver.evaluate("missingValue")

        let lastEntry = try #require(driver.store.entries.last)
        #expect(lastEntry.kind == .result)
        #expect(lastEntry.level == .error)
        #expect(lastEntry.wasThrown)

        await driver.detachPageWebView()
    }
}

@MainActor
private extension ConsoleTransportDriverTests {
    func makeTransportSessionFactory(
        using backend: FakeConsoleRegistryBackend,
        configuration: WITransportConfiguration = .init(responseTimeout: .seconds(1))
    ) -> @MainActor () -> WITransportSession {
        {
            WITransportSession(
                configuration: configuration,
                backendFactory: { _ in backend }
            )
        }
    }

    func waitForCondition(
        maxTurns: Int = 8_192,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        if await condition() {
            return true
        }
        for _ in 0..<maxTurns {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
            if await condition() {
                return true
            }
        }
        return await condition()
    }
}

@MainActor
private final class FakeConsoleRegistryBackend: WITransportPlatformBackend {
    typealias PageResultProvider = (String, [String: Any], FakeConsoleRegistryBackend) throws -> [String: Any]?

    var supportSnapshot: WITransportSupportSnapshot

    private(set) var sentPageMethods: [String] = []
    private var messageSink: (any WITransportBackendMessageSink)?
    private let pageResultProvider: PageResultProvider?
    private let attachHandler: ((any WITransportBackendMessageSink) async -> Void)?
    private var ownsWebKitTestIsolation = false

    init(
        capabilities: Set<WITransportCapability> = [.rootMessaging, .pageMessaging, .pageTargetRouting, .consoleDomain],
        pageResultProvider: PageResultProvider? = nil,
        attachHandler: ((any WITransportBackendMessageSink) async -> Void)? = nil
    ) {
        supportSnapshot = .supported(
            backendKind: .macOSNativeInspector,
            capabilities: capabilities
        )
        self.pageResultProvider = pageResultProvider
        self.attachHandler = attachHandler
    }

    deinit {
        guard ownsWebKitTestIsolation else {
            return
        }
        Task { @MainActor in
            await releaseWebKitTestIsolation()
        }
    }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) async throws {
        if isWebKitTestIsolationActive {
            ownsWebKitTestIsolation = false
        } else {
            await acquireWebKitTestIsolation()
            ownsWebKitTestIsolation = true
        }
        self.messageSink = messageSink
        if let attachHandler {
            await attachHandler(messageSink)
        } else {
            emitRootEvent(
                method: "Target.targetCreated",
                params: [
                    "targetInfo": [
                        "targetId": "page-A",
                        "type": "page",
                        "isProvisional": false,
                    ]
                ]
            )
        }
        _ = webView
    }

    func detach() {
        messageSink = nil
        guard ownsWebKitTestIsolation else {
            return
        }
        ownsWebKitTestIsolation = false
        Task { @MainActor in
            await releaseWebKitTestIsolation()
        }
    }

    func sendRootMessage(_ message: String) throws {
        _ = message
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        _ = outerIdentifier
        let payload = try decodeMessagePayload(message)
        guard let method = payload["method"] as? String else {
            return
        }
        sentPageMethods.append(method)

        let result = try pageResultProvider?(method, payload, self) ?? [:]
        guard let identifier = payload["id"] as? Int else {
            return
        }

        guard JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result),
              let resultString = String(data: data, encoding: .utf8) else {
            messageSink?.didReceivePageMessage(
                #"{"id":\#(identifier),"result":{}}"#,
                targetIdentifier: targetIdentifier
            )
            return
        }

        messageSink?.didReceivePageMessage(
            #"{"id":\#(identifier),"result":\#(resultString)}"#,
            targetIdentifier: targetIdentifier
        )
    }

    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> Data? {
        _ = scope
        _ = method
        return nil
    }

    func emitPageEvent(method: String, params: [String: Any], targetIdentifier: String = "page-A") {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsString = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to encode page event params for \(method)")
            return
        }
        messageSink?.didReceivePageMessage(
            #"{"method":"\#(method)","params":\#(paramsString)}"#,
            targetIdentifier: targetIdentifier
        )
    }

    func emitRootEvent(method: String, params: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsString = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to encode root event params for \(method)")
            return
        }
        messageSink?.didReceiveRootMessage(
            #"{"method":"\#(method)","params":\#(paramsString)}"#
        )
    }

    private func decodeMessagePayload(_ message: String) throws -> [String: Any] {
        let data = Data(message.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }
}
