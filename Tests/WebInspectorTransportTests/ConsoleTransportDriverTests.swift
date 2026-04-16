import Foundation
import Testing
import WebInspectorTestSupport
import WebKit
#if canImport(UIKit)
import UIKit
#endif
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
    func initialEnableFollowsReplacementPageTargetDuringTargetChurn() async {
        let backend = FakeConsoleRegistryBackend(
            pageResultProvider: { method, _, backend in
                guard method == WITransportMethod.Console.enable else {
                    return nil
                }

                let consoleEnableAttempts = backend.sentPageMessages.filter {
                    $0.method == WITransportMethod.Console.enable
                }
                if consoleEnableAttempts.count == 1 {
                    #expect(consoleEnableAttempts.last?.targetIdentifier == "page-A")
                    backend.emitRootEvent(
                        method: "Target.targetCreated",
                        params: [
                            "targetInfo": [
                                "targetId": "page-B",
                                "type": "page",
                                "isProvisional": false,
                            ]
                        ]
                    )
                    throw WITransportError.remoteError(
                        scope: .root,
                        method: "Target.sendMessageToTarget",
                        message: "Target closed"
                    )
                }

                #expect(consoleEnableAttempts.last?.targetIdentifier == "page-B")
                return [:]
            }
        )
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForEnableForTesting()

        #expect(driver.isReadyToReceiveConsole)
        let consoleEnableTargets = backend.sentPageMessages
            .filter { $0.method == WITransportMethod.Console.enable }
            .map(\.targetIdentifier)
        #expect(consoleEnableTargets.prefix(2) == ["page-A", "page-B"])
        #expect(consoleEnableTargets.allSatisfy { $0 == "page-A" || $0 == "page-B" })

        await driver.detachPageWebView()
    }

    @Test
    func transportClosedDuringInitialEnableMarksConsoleUnavailable() async {
        let backend = FakeConsoleRegistryBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.Console.enable else {
                    return nil
                }
                throw WITransportError.transportClosed
            }
        )
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForEnableForTesting()

        #expect(driver.isReadyToReceiveConsole == false)
        #expect(driver.support.availability == .unsupported)
        #expect(driver.support.failureReason == WITransportError.transportClosed.localizedDescription)
        #expect(backend.attachCallCount == 1)

        await driver.detachPageWebView()
    }

    #if canImport(UIKit)
    @Test
    func iOSConsoleNativeDriverEnablesPersistentAboutBlankPage() async {
        let driver = ConsoleTransportDriver()
        let webView = makeIsolatedTestWebView(frame: UIScreen.main.bounds)
        let window = makeHostWindow(with: webView)
        defer {
            tearDownHostWindow(window)
        }

        await driver.attachPageWebView(webView)
        await loadHTML(
            """
            <html><body><script>console.log('blank-load')</script></body></html>
            """,
            baseURL: nil,
            in: webView
        )

        #expect(await waitForCondition {
            driver.isReadyToReceiveConsole
        })
        await driver.evaluate("1 + 2")
        #expect(await waitForCondition {
            driver.store.entries.contains { $0.renderedText.contains("3") }
        })

        await driver.detachPageWebView()
    }

    @Test
    func iOSConsoleNativeDriverReceivesMessagesAcrossMainFrameNavigation() async {
        let driver = ConsoleTransportDriver()
        let webView = makeIsolatedTestWebView(frame: UIScreen.main.bounds)
        let window = makeHostWindow(with: webView)
        defer {
            tearDownHostWindow(window)
        }

        await driver.attachPageWebView(webView)
        await loadHTML(
            """
            <html><body><script>console.log('first-load')</script></body></html>
            """,
            baseURL: URL(string: "https://example.com/first"),
            in: webView
        )

        #expect(await waitForCondition {
            driver.isReadyToReceiveConsole
        })
        await driver.evaluate("1 + 1")
        #expect(await waitForCondition {
            driver.store.entries.contains { $0.renderedText.contains("2") }
        })

        await loadHTML(
            """
            <html><body><script>console.log('second-load')</script></body></html>
            """,
            baseURL: URL(string: "https://example.com/second"),
            in: webView
        )

        #expect(await waitForCondition {
            driver.isReadyToReceiveConsole
        })
        await driver.evaluate("3 + 4")
        #expect(await waitForCondition {
            driver.store.entries.contains { $0.renderedText.contains("7") }
        })

        await driver.detachPageWebView()
    }

    @Test
    func iOSConsoleStaysUsableAlongsideNativeNetworkAcrossMainFrameNavigation() async {
        let consoleDriver = ConsoleTransportDriver()
        let networkDriver = NetworkTransportDriver()
        let webView = makeIsolatedTestWebView(frame: UIScreen.main.bounds)
        let window = makeHostWindow(with: webView)
        defer {
            tearDownHostWindow(window)
        }

        await networkDriver.attachPageWebView(webView)
        await networkDriver.waitForAttachForTesting()
        await consoleDriver.attachPageWebView(webView)

        await loadHTML(
            """
            <html><body><script>console.log('network-console-first')</script></body></html>
            """,
            baseURL: URL(string: "https://example.com/network-first"),
            in: webView
        )

        #expect(await waitForCondition {
            consoleDriver.isReadyToReceiveConsole
        })
        await consoleDriver.evaluate("10 + 5")
        #expect(await waitForCondition {
            consoleDriver.store.entries.contains { $0.renderedText.contains("15") }
        })

        await loadHTML(
            """
            <html><body><script>console.log('network-console-second')</script></body></html>
            """,
            baseURL: URL(string: "https://example.com/network-second"),
            in: webView
        )

        #expect(await waitForCondition {
            consoleDriver.isReadyToReceiveConsole
        })
        await consoleDriver.evaluate("20 + 2")
        #expect(await waitForCondition {
            consoleDriver.store.entries.contains { $0.renderedText.contains("22") }
        })

        await consoleDriver.detachPageWebView()
        await networkDriver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func consoleRuntimeDoesNotClearOnSameDocumentURLChange() async {
        let backend = SpyConsoleBackend()
        let runtime = WIConsoleRuntime(backend: backend)
        let webView = makeIsolatedTestWebView(frame: UIScreen.main.bounds)
        let window = makeHostWindow(with: webView)
        defer {
            tearDownHostWindow(window)
        }

        await loadHTML(
            """
            <html><body>same document</body></html>
            """,
            baseURL: URL(string: "https://example.com/first")!,
            in: webView
        )

        await runtime.attach(pageWebView: webView)
        await runJavaScript(
            "history.pushState({}, '', '/second#fragment')",
            in: webView
        )
        await runtime.attach(pageWebView: webView)

        #expect(backend.clearCallCount == 0)
        await runtime.detach()
    }
    #endif

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
        await driver.waitForEnableForTesting()

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
    func switchingWebViewsClearsPreviousEntries() async {
        let backend = FakeConsoleRegistryBackend()
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let firstWebView = makeIsolatedTestWebView()
        let secondWebView = makeIsolatedTestWebView()

        await driver.attachPageWebView(firstWebView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Console.messageAdded",
            params: [
                "message": [
                    "source": "javascript",
                    "level": "log",
                    "text": "first page entry",
                    "type": "log",
                ]
            ]
        )
        #expect(await waitForCondition {
            driver.store.entries.count == 1
        })

        await driver.attachPageWebView(secondWebView)
        await driver.waitForAttachForTesting()

        #expect(driver.store.entries.isEmpty)

        await driver.detachPageWebView()
    }

    @Test
    func reattachingAfterPreviousWebViewReleaseClearsPreviousEntries() async {
        let backend = FakeConsoleRegistryBackend()
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        var firstWebView: WKWebView? = makeIsolatedTestWebView()

        await driver.attachPageWebView(firstWebView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Console.messageAdded",
            params: [
                "message": [
                    "source": "javascript",
                    "level": "log",
                    "text": "released page entry",
                    "type": "log",
                ]
            ]
        )
        #expect(await waitForCondition {
            driver.store.entries.count == 1
        })

        await driver.detachPageWebView()
        firstWebView = nil

        let secondWebView = makeIsolatedTestWebView()
        await driver.attachPageWebView(secondWebView)
        await driver.waitForAttachForTesting()

        #expect(driver.store.entries.isEmpty)

        await driver.detachPageWebView()
    }

    @Test
    func reattachingSameWebViewClearsEntriesCollectedBeforeDetach() async {
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
                    "text": "before detach",
                    "type": "log",
                ]
            ]
        )
        #expect(await waitForCondition {
            driver.store.entries.count == 1
        })

        await driver.detachPageWebView()
        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(driver.store.entries.isEmpty)

        await driver.detachPageWebView()
    }

    @Test
    func provisionalTargetCommitClearsExistingEntries() async {
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
                    "text": "before navigation",
                    "type": "log",
                ]
            ]
        )
        #expect(await waitForCondition {
            driver.store.entries.count == 1
        })

        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-A",
                "newTargetId": "page-B",
            ]
        )

        #expect(await waitForCondition {
            driver.store.entries.isEmpty
        })

        await driver.detachPageWebView()
    }

    @Test
    func provisionalTargetCreationDoesNotReplayCurrentPageBacklog() async {
        let backend = FakeConsoleRegistryBackend()
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForEnableForTesting()
        backend.emitPageEvent(
            method: "Console.messageAdded",
            params: [
                "message": [
                    "source": "javascript",
                    "level": "log",
                    "text": "current page message",
                    "type": "log",
                ]
            ]
        )
        #expect(await waitForCondition {
            driver.store.entries.map(\.renderedText) == ["current page message"]
        })

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-B",
                    "type": "page",
                    "isProvisional": true,
                ]
            ]
        )

        #expect(await waitForCondition {
            driver.store.entries.map(\.renderedText) == ["current page message"]
        })

        await driver.detachPageWebView()
    }

    @Test
    func clearConsoleReleasesObjectGroupBeforeClearingMessages() async {
        let backend = FakeConsoleRegistryBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.Runtime.evaluate else {
                    return nil
                }
                return [
                    "result": [
                        "type": "object",
                        "objectId": "object-1",
                        "className": "Object",
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
        await driver.evaluate("({ value: 1 })")
        await driver.clearConsole()

        #expect(backend.sentPageMethods.contains(WITransportMethod.Runtime.releaseObjectGroup))
        #expect(backend.sentPageMethods.contains(WITransportMethod.Console.clearMessages))

        await driver.detachPageWebView()
    }

    @Test
    func clearWithoutCurrentPageTargetSkipsBackendCommands() async {
        let backend = FakeConsoleRegistryBackend(
            attachHandler: { _ in }
        )
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()
        await driver.clearConsole()

        #expect(backend.sentPageMethods.contains(WITransportMethod.Runtime.releaseObjectGroup) == false)
        #expect(backend.sentPageMethods.contains(WITransportMethod.Console.clearMessages) == false)

        await driver.detachPageWebView()
    }

    @Test
    func frontendClearEchoDoesNotRemoveMessagesAddedAfterClear() async {
        let backend = FakeConsoleRegistryBackend()
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()
        await driver.clearConsole()

        backend.emitPageEvent(
            method: "Console.messageAdded",
            params: [
                "message": [
                    "source": "javascript",
                    "level": "log",
                    "text": "after clear",
                    "type": "log",
                ]
            ]
        )
        backend.emitPageEvent(
            method: "Console.messagesCleared",
            params: [
                "reason": "frontend",
            ]
        )

        #expect(await waitForCondition {
            driver.store.entries.map(\.renderedText) == ["after clear"]
        })

        await driver.detachPageWebView()
    }

    @Test
    func repeatedFrontendClearEchoesDoNotRemoveMessagesAddedAfterLaterClear() async {
        let backend = FakeConsoleRegistryBackend()
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()
        await driver.clearConsole()
        await driver.clearConsole()

        backend.emitPageEvent(
            method: "Console.messageAdded",
            params: [
                "message": [
                    "source": "javascript",
                    "level": "log",
                    "text": "after second clear",
                    "type": "log",
                ]
            ]
        )
        backend.emitPageEvent(
            method: "Console.messagesCleared",
            params: [
                "reason": "frontend",
            ]
        )
        backend.emitPageEvent(
            method: "Console.messagesCleared",
            params: [
                "reason": "frontend",
            ]
        )

        #expect(await waitForCondition {
            driver.store.entries.map(\.renderedText) == ["after second clear"]
        })

        await driver.detachPageWebView()
    }

    @Test
    func deferredClearSurvivesDetachUntilNextEnable() async {
        let backend = FakeConsoleRegistryBackend(
            attachHandler: { _ in }
        )
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let firstWebView = makeIsolatedTestWebView()
        let secondWebView = makeIsolatedTestWebView()

        await driver.clearConsole()

        await driver.attachPageWebView(firstWebView)
        await driver.waitForAttachForTesting()
        await driver.detachPageWebView()

        await driver.attachPageWebView(secondWebView)
        await driver.waitForAttachForTesting()

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-A",
                    "type": "page",
                    "isProvisional": false,
                ]
            ]
        )
        await driver.waitForEnableForTesting()

        #expect(
            backend.sentPageMessages.contains {
                $0.method == WITransportMethod.Console.clearMessages && $0.targetIdentifier == "page-A"
            }
        )

        await driver.detachPageWebView()
    }

    @Test
    func detachReleasesConsoleObjectGroup() async {
        let backend = FakeConsoleRegistryBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.Runtime.evaluate else {
                    return nil
                }
                return [
                    "result": [
                        "type": "object",
                        "objectId": "object-1",
                        "className": "Object",
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
        await driver.evaluate("({ value: 1 })")
        await driver.detachPageWebView()

        #expect(await waitForCondition {
            backend.sentPageMethods.contains(WITransportMethod.Runtime.releaseObjectGroup)
        })
    }

    @Test
    func detachWithoutResolvedPageTargetSkipsObjectGroupRelease() async {
        let backend = FakeConsoleRegistryBackend(
            attachHandler: { _ in }
        )
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()
        await driver.detachPageWebView()

        #expect(backend.sentPageMethods.contains(WITransportMethod.Runtime.releaseObjectGroup) == false)
    }

    @Test
    func ignoresEventsFromNonCurrentPageTarget() async {
        let backend = FakeConsoleRegistryBackend()
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-A",
                "newTargetId": "page-B",
            ]
        )

        backend.emitPageEvent(
            method: "Console.messageAdded",
            params: [
                "message": [
                    "source": "javascript",
                    "level": "log",
                    "text": "old target message",
                    "type": "log",
                ]
            ],
            targetIdentifier: "page-A"
        )
        backend.emitPageEvent(
            method: "Console.messageAdded",
            params: [
                "message": [
                    "source": "javascript",
                    "level": "log",
                    "text": "current target message",
                    "type": "log",
                ]
            ],
            targetIdentifier: "page-B"
        )

        #expect(await waitForCondition {
            driver.store.entries.map(\.renderedText) == ["current target message"]
        })

        await driver.detachPageWebView()
    }

    @Test
    func repeatCountUpdatesLastRemoteEntryAcrossLocalCommandAndResultEntries() async throws {
        let backend = FakeConsoleRegistryBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.Runtime.evaluate else {
                    return nil
                }
                return [
                    "result": [
                        "type": "number",
                        "value": 2,
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

        backend.emitPageEvent(
            method: "Console.messageAdded",
            params: [
                "message": [
                    "source": "javascript",
                    "level": "log",
                    "text": "remote entry",
                    "type": "log",
                ]
            ]
        )
        #expect(await waitForCondition {
            driver.store.entries.count == 1
        })

        await driver.evaluate("1 + 1")
        let pageEntry = try #require(driver.store.entries.first)
        let resultEntry = try #require(driver.store.entries.last)

        backend.emitPageEvent(
            method: "Console.messageRepeatCountUpdated",
            params: [
                "count": 3,
            ]
        )

        #expect(await waitForCondition {
            pageEntry.repeatCount == 3 && resultEntry.repeatCount == 1
        })

        await driver.detachPageWebView()
    }

    @Test
    func evaluateLargeWholeNumberFallsBackToDoubleString() async throws {
        let backend = FakeConsoleRegistryBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.Runtime.evaluate else {
                    return nil
                }
                return [
                    "result": [
                        "type": "number",
                        "value": 1.0e20,
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
        await driver.evaluate("1e20")

        let lastEntry = try #require(driver.store.entries.last)
        #expect(lastEntry.renderedText == "1e+20")

        await driver.detachPageWebView()
    }

    @Test
    func evaluateWithoutCurrentPageTargetStaysLocalAndDoesNotRunLater() async {
        let backend = FakeConsoleRegistryBackend(
            attachHandler: { _ in }
        )
        let driver = ConsoleTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()
        await driver.evaluate("1 + 1")

        #expect(backend.sentPageMethods.contains(WITransportMethod.Runtime.evaluate) == false)
        #expect(await waitForCondition {
            driver.store.entries.last?.level == .error
        })

        await driver.detachPageWebView()
    }

    @Test
    func evaluateQuotesStringResults() async throws {
        let backend = FakeConsoleRegistryBackend(
            pageResultProvider: { method, _, _ in
                guard method == WITransportMethod.Runtime.evaluate else {
                    return nil
                }
                return [
                    "result": [
                        "type": "string",
                        "value": "1",
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
        await driver.evaluate("'1'")

        let lastEntry = try #require(driver.store.entries.last)
        #expect(lastEntry.renderedText == "\"1\"")

        await driver.detachPageWebView()
    }

    @Test
    func jsonStringSummaryEscapesEmbeddedContent() {
        let value = ConsoleWire.Transport.JSONValue.string("a\"b\nc\\")

        #expect(value.summary == "\"a\\\"b\\nc\\\\\"")
    }

    @Test
    func messageParametersKeepStringValuesUnquoted() async throws {
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
                    "text": "",
                    "type": "log",
                    "parameters": [
                        [
                            "type": "string",
                            "value": "hello",
                        ]
                    ]
                ]
            ]
        )

        #expect(await waitForCondition {
            driver.store.entries.last?.renderedText == "hello"
        })

        await driver.detachPageWebView()
    }

    @Test
    func messageParametersAvoidDuplicateLeadingStringAndFormatSubstitutions() async throws {
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
                    "source": "console-api",
                    "level": "log",
                    "text": "%d",
                    "type": "log",
                    "parameters": [
                        [
                            "type": "string",
                            "value": "%d",
                        ],
                        [
                            "type": "number",
                            "value": 3,
                        ]
                    ]
                ]
            ]
        )

        #expect(await waitForCondition {
            driver.store.entries.last?.renderedText == "3"
        })

        await driver.detachPageWebView()
    }

    @Test
    func messageParametersConsumePercentCStyleArguments() async {
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
                    "source": "console-api",
                    "level": "log",
                    "text": "%cHello",
                    "type": "log",
                    "parameters": [
                        [
                            "type": "string",
                            "value": "%cHello",
                        ],
                        [
                            "type": "string",
                            "value": "color:red",
                        ]
                    ]
                ]
            ]
        )

        #expect(await waitForCondition {
            driver.store.entries.last?.renderedText == "Hello"
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

    #if canImport(UIKit)
    func loadHTML(_ html: String, baseURL: URL?, in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func runJavaScript(_ script: String, in webView: WKWebView) async {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { _, _ in
                continuation.resume()
            }
        }
    }

    func makeHostWindow(with webView: WKWebView) -> UIWindow {
        let viewController = UIViewController()
        viewController.loadViewIfNeeded()
        webView.translatesAutoresizingMaskIntoConstraints = false
        viewController.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: viewController.view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
        ])

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = viewController
        window.isHidden = false
        return window
    }

    func tearDownHostWindow(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }
    #endif
}

@MainActor
private final class FakeConsoleRegistryBackend: WITransportPlatformBackend {
    typealias PageResultProvider = (String, [String: Any], FakeConsoleRegistryBackend) throws -> [String: Any]?

    struct SentPageMessage: Equatable {
        let method: String
        let targetIdentifier: String
    }

    var supportSnapshot: WITransportSupportSnapshot

    private(set) var sentPageMethods: [String] = []
    private(set) var sentPageMessages: [SentPageMessage] = []
    private(set) var attachCallCount = 0
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
        attachCallCount += 1
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
        sentPageMessages.append(
            SentPageMessage(method: method, targetIdentifier: targetIdentifier)
        )

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

@MainActor
private final class SpyConsoleBackend: WIConsoleBackend {
    weak var webView: WKWebView?
    let store = ConsoleStore()
    let support = WIBackendSupport(
        availability: .supported,
        backendKind: .nativeInspectorIOS,
        capabilities: [.consoleDomain]
    )

    private(set) var clearCallCount = 0

    func attachPageWebView(_ newWebView: WKWebView?) async {
        webView = newWebView
    }

    func detachPageWebView(clearsStoreOnNextAttach: Bool) async {
        _ = clearsStoreOnNextAttach
        webView = nil
    }

    func clearConsole() async {
        clearCallCount += 1
    }

    func evaluate(_ expression: String) async {
        _ = expression
    }

    func tearDownForDeinit() {}
}

#if canImport(UIKit)
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }
}
#endif
