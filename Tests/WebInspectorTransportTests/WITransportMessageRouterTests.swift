import Foundation
import Testing
@testable import WebInspectorTransport

struct WITransportMessageRouterTests {
    @Test
    func routerCorrelatesMultipleInFlightRootRequests() async throws {
        let router = WITransportMessageRouter(configuration: .init(responseTimeout: .seconds(1)))

        await router.connect(
            rootDispatcher: { [router] message in
                let identifier = try Self.identifier(from: message)
                let method = try Self.method(from: message)
                Task {
                    await router.handleIncomingRootMessage(
                        Self.jsonString([
                            "id": identifier,
                            "result": ["method": method],
                        ])
                    )
                }
            },
            pageDispatcher: { _, _, _ in
                Issue.record("Unexpected page dispatch in root correlation test.")
            }
        )

        async let firstData = router.send(scope: .root, method: WITransportCommands.Target.Enable.method, parametersData: nil)
        async let secondData = router.send(scope: .root, method: "Browser.getVersion", parametersData: nil)

        let first = try Self.decode(MethodEcho.self, from: try await firstData)
        let second = try Self.decode(MethodEcho.self, from: try await secondData)

        #expect(first.method == WITransportCommands.Target.Enable.method)
        #expect(second.method == "Browser.getVersion")
    }

    @Test
    func pageCommandsFollowCommittedProvisionalTarget() async throws {
        let router = WITransportMessageRouter(configuration: .init(responseTimeout: .seconds(1)))
        let recorder = PageDispatchRecorder()

        await router.connect(
            rootDispatcher: { _ in },
            pageDispatcher: { [router, recorder] message, targetIdentifier, _ in
                await recorder.record(targetIdentifier: targetIdentifier)
                let identifier = try Self.identifier(from: message)
                Task {
                    await router.handleIncomingPageMessage(
                        Self.jsonString([
                            "id": identifier,
                            "result": ["targetIdentifier": targetIdentifier],
                        ]),
                        targetIdentifier: targetIdentifier
                    )
                }
            }
        )

        await router.handleIncomingRootMessage(
            Self.jsonString([
                "method": "Target.targetCreated",
                "params": [
                    "targetInfo": [
                        "targetId": "page-A",
                        "type": "page",
                        "isProvisional": false,
                    ],
                ],
            ])
        )

        let first = try Self.decode(
            TargetEcho.self,
            from: try await router.send(scope: .page, method: "Network.enable", parametersData: nil)
        )
        #expect(first.targetIdentifier == "page-A")

        await router.handleIncomingRootMessage(
            Self.jsonString([
                "method": "Target.didCommitProvisionalTarget",
                "params": [
                    "oldTargetId": "page-A",
                    "newTargetId": "page-B",
                ],
            ])
        )

        let second = try Self.decode(
            TargetEcho.self,
            from: try await router.send(scope: .page, method: "DOM.getDocument", parametersData: nil)
        )
        #expect(second.targetIdentifier == "page-B")
        #expect(await recorder.snapshot() == ["page-A", "page-B"])
    }

    @Test
    func pageCommandsFollowCommittedTargetWithoutOldIdentifier() async throws {
        let router = WITransportMessageRouter(configuration: .init(responseTimeout: .seconds(1)))
        let recorder = PageDispatchRecorder()

        await router.connect(
            rootDispatcher: { _ in },
            pageDispatcher: { [router, recorder] message, targetIdentifier, _ in
                await recorder.record(targetIdentifier: targetIdentifier)
                let identifier = try Self.identifier(from: message)
                Task {
                    await router.handleIncomingPageMessage(
                        Self.jsonString([
                            "id": identifier,
                            "result": ["targetIdentifier": targetIdentifier],
                        ]),
                        targetIdentifier: targetIdentifier
                    )
                }
            }
        )

        await router.handleIncomingRootMessage(
            Self.jsonString([
                "method": "Target.didCommitProvisionalTarget",
                "params": [
                    "newTargetId": "page-C",
                ],
            ])
        )

        let response = try Self.decode(
            TargetEcho.self,
            from: try await router.send(scope: .page, method: "DOM.getDocument", parametersData: nil)
        )

        #expect(response.targetIdentifier == "page-C")
        #expect(await recorder.snapshot() == ["page-C"])
    }

    @Test
    func pageCommandsPreferNewestPageTargetWhenNoCommittedTargetExists() async throws {
        let router = WITransportMessageRouter(configuration: .init(responseTimeout: .seconds(1)))
        let recorder = PageDispatchRecorder()

        await router.connect(
            rootDispatcher: { _ in },
            pageDispatcher: { [router, recorder] message, targetIdentifier, _ in
                await recorder.record(targetIdentifier: targetIdentifier)
                let identifier = try Self.identifier(from: message)
                Task {
                    await router.handleIncomingPageMessage(
                        Self.jsonString([
                            "id": identifier,
                            "result": ["targetIdentifier": targetIdentifier],
                        ]),
                        targetIdentifier: targetIdentifier
                    )
                }
            }
        )

        await router.handleIncomingRootMessage(
            Self.jsonString([
                "method": "Target.targetCreated",
                "params": [
                    "targetInfo": [
                        "targetId": "page-old",
                        "type": "page",
                        "isProvisional": false,
                    ],
                ],
            ])
        )

        await router.handleIncomingRootMessage(
            Self.jsonString([
                "method": "Target.targetCreated",
                "params": [
                    "targetInfo": [
                        "targetId": "page-new",
                        "type": "page",
                        "isProvisional": false,
                    ],
                ],
            ])
        )

        let response = try Self.decode(
            TargetEcho.self,
            from: try await router.send(scope: .page, method: "DOM.getDocument", parametersData: nil)
        )

        #expect(response.targetIdentifier == "page-new")
        #expect(await recorder.snapshot() == ["page-new"])
    }

    @Test
    func pageTargetLifecycleStreamIncludesProvisionalCreation() async throws {
        let router = WITransportMessageRouter(configuration: .init(responseTimeout: .seconds(1)))
        let stream = await router.pageTargetLifecycles(bufferingLimit: 4)
        let iterator = IteratorBox(stream: stream)

        await router.handleIncomingRootMessage(
            Self.jsonString([
                "method": "Target.targetCreated",
                "params": [
                    "targetInfo": [
                        "targetId": "page-provisional",
                        "type": "page",
                        "isProvisional": true,
                    ],
                ],
            ])
        )

        let event = try await Self.nextValue(from: iterator)
        #expect(event?.kind == .created)
        #expect(event?.targetIdentifier == "page-provisional")
        #expect(event?.targetType == "page")
        #expect(event?.isProvisional == true)
    }

    @Test
    func explicitTargetPageCommandsDoNotRequireCurrentPageTarget() async throws {
        let router = WITransportMessageRouter(configuration: .init(responseTimeout: .seconds(1)))
        let recorder = PageDispatchRecorder()

        await router.connect(
            rootDispatcher: { _ in },
            pageDispatcher: { [router, recorder] message, targetIdentifier, _ in
                await recorder.record(targetIdentifier: targetIdentifier)
                let identifier = try Self.identifier(from: message)
                Task {
                    await router.handleIncomingPageMessage(
                        Self.jsonString([
                            "id": identifier,
                            "result": ["targetIdentifier": targetIdentifier],
                        ]),
                        targetIdentifier: targetIdentifier
                    )
                }
            }
        )

        let response = try Self.decode(
            TargetEcho.self,
            from: try await router.send(
                scope: .page,
                method: "Network.enable",
                parametersData: nil,
                targetIdentifierOverride: "page-provisional"
            )
        )

        #expect(response.targetIdentifier == "page-provisional")
        #expect(await recorder.snapshot() == ["page-provisional"])
    }

    @Test
    func eventSubscriptionsSkipNonMatchingMethods() async throws {
        let router = WITransportMessageRouter(configuration: .init(responseTimeout: .seconds(1)))
        let stream = await router.events(
            scope: .page,
            methods: ["DOM.documentUpdated"],
            bufferingLimit: 4
        )
        let iterator = IteratorBox(stream: stream)

        await router.handleIncomingPageMessage(
            Self.jsonString([
                "method": "DOM.setChildNodes",
                "params": ["nodeId": 1],
            ]),
            targetIdentifier: "page-A"
        )
        await router.handleIncomingPageMessage(
            Self.jsonString([
                "method": "DOM.documentUpdated",
                "params": ["reason": "reload"],
            ]),
            targetIdentifier: "page-A"
        )

        let event = try await Self.nextValue(from: iterator)
        #expect(event?.method == "DOM.documentUpdated")
        #expect(event?.targetIdentifier == "page-A")

        await router.disconnect()
        if let unexpected = try await Self.nextValue(from: iterator) {
            Issue.record("Expected no additional filtered event, but received \(unexpected.method).")
        }
    }

    @Test
    func eventBufferKeepsNewestEnvelopesForLateSubscribers() async throws {
        let router = WITransportMessageRouter(
            configuration: .init(
                responseTimeout: .seconds(1),
                eventBufferLimit: 2,
                dropEventsWithoutSubscribers: false
            )
        )

        await router.handleIncomingRootMessage(
            Self.jsonString([
                "method": "Target.targetCreated",
                "params": ["targetInfo": ["targetId": "page-A", "type": "page", "isProvisional": false]],
            ])
        )
        await router.handleIncomingRootMessage(
            Self.jsonString([
                "method": "Target.didCommitProvisionalTarget",
                "params": ["oldTargetId": "page-A", "newTargetId": "page-B"],
            ])
        )
        await router.handleIncomingRootMessage(
            Self.jsonString([
                "method": "Target.targetDestroyed",
                "params": ["targetId": "page-B"],
            ])
        )

        let stream = await router.events(scope: .root, methods: nil, bufferingLimit: 2)
        let iterator = IteratorBox(stream: stream)
        let first = try await Self.nextValue(from: iterator)
        let second = try await Self.nextValue(from: iterator)

        #expect(first?.method == "Target.didCommitProvisionalTarget")
        #expect(second?.method == "Target.targetDestroyed")
    }

    @Test
    func parsedObjectEventsLazyMaterializeParamsData() async throws {
        let router = WITransportMessageRouter(configuration: .init(responseTimeout: .seconds(1)))
        let stream = await router.events(scope: .page, methods: ["DOM.documentUpdated"], bufferingLimit: 1)
        let iterator = IteratorBox(stream: stream)

        await router.handleIncomingPageMessage(
            "{}",
            parsedPayload: .object([
                "method": "DOM.documentUpdated",
                "params": [
                    "reason": "reload",
                ],
            ]),
            targetIdentifier: "page-A"
        )

        let event = try await Self.nextValue(from: iterator)
        guard let event,
              let paramsObject = try JSONSerialization.jsonObject(with: event.paramsData) as? [String: Any] else {
            Issue.record("Expected a DOM.documentUpdated event with JSON params.")
            return
        }
        #expect(event.method == "DOM.documentUpdated")
        #expect(event.targetIdentifier == "page-A")
        #expect(paramsObject["reason"] as? String == "reload")
    }

    @Test
    func commandChannelDecodesCustomTypedPageResponse() async throws {
        let channel = WITransportCommandChannel(
            scope: .page,
            sender: { scope, method, parametersPayload in
                #expect(scope == .page)
                #expect(method == CustomPageCommand.method)
                #expect(parametersPayload != nil)
                return .data(try JSONEncoder().encode(CustomPageCommand.Response(value: "ok")))
            },
            subscriber: { _, _, _ in AsyncStream { $0.finish() } }
        )

        let response = try await channel.send(CustomPageCommand(value: "hello"))
        #expect(response.value == "ok")
    }

    @Test
    func builtInDOMCommandsDecodeReadOnlyResponses() async throws {
        let channel = WITransportCommandChannel(
            scope: .page,
            sender: { scope, method, _ in
                #expect(scope == .page)
                switch method {
                case WITransportCommands.DOM.GetDocument.method:
                    return .object([
                        "root": [
                            "nodeId": 1,
                            "nodeType": 9,
                            "nodeName": "#document",
                            "localName": "",
                            "nodeValue": "",
                            "attributes": [],
                            "children": [],
                            "documentURL": "https://example.com/",
                            "baseURL": "https://example.com/",
                            "frameId": "frame-A",
                        ],
                    ])
                case WITransportCommands.DOM.GetOuterHTML.method:
                    return .object([
                        "outerHTML": "<html><body>Example</body></html>",
                    ])
                default:
                    Issue.record("Unexpected DOM command method: \(method)")
                    return .object([:])
                }
            },
            subscriber: { _, _, _ in AsyncStream { $0.finish() } }
        )

        let document = try await channel.send(WITransportCommands.DOM.GetDocument())
        let html = try await channel.send(WITransportCommands.DOM.GetOuterHTML(nodeId: 1))

        #expect(document.root.nodeName == "#document")
        #expect(document.root.documentURL == "https://example.com/")
        #expect(html.outerHTML.contains("Example"))
    }
}

private extension WITransportMessageRouterTests {
    struct MethodEcho: Codable, Sendable {
        let method: String
    }

    struct TargetEcho: Codable, Sendable {
        let targetIdentifier: String
    }

    struct CustomPageCommand: WITransportPageCommand, Sendable {
        struct Parameters: Encodable, Sendable {
            let value: String
        }

        struct Response: Codable, Sendable {
            let value: String
        }

        static let method = "Custom.echo"
        let parameters: Parameters

        init(value: String) {
            parameters = Parameters(value: value)
        }
    }

    actor PageDispatchRecorder {
        private(set) var targetIdentifiers: [String] = []

        func record(targetIdentifier: String) {
            targetIdentifiers.append(targetIdentifier)
        }

        func snapshot() -> [String] {
            targetIdentifiers
        }
    }

    actor IteratorBox<Element: Sendable> {
        private var values: [Element] = []
        private var waiters: [UUID: CheckedContinuation<Element?, Never>] = [:]
        private var isFinished = false

        init(stream: AsyncStream<Element>) {
            Task {
                for await value in stream {
                    await enqueue(value)
                }
                await finish()
            }
        }

        func next() async -> Element? {
            if !values.isEmpty {
                return values.removeFirst()
            }
            if isFinished {
                return nil
            }
            let identifier = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiters[identifier] = continuation
                }
            } onCancel: {
                Task {
                    await cancelWaiter(identifier)
                }
            }
        }

        private func enqueue(_ value: Element) {
            if let identifier = waiters.keys.first, let waiter = waiters.removeValue(forKey: identifier) {
                waiter.resume(returning: value)
                return
            }
            values.append(value)
        }

        private func cancelWaiter(_ identifier: UUID) {
            guard let waiter = waiters.removeValue(forKey: identifier) else {
                return
            }
            waiter.resume(returning: nil)
        }

        private func finish() {
            isFinished = true
            let currentWaiters = waiters.values
            waiters.removeAll()
            for waiter in currentWaiters {
                waiter.resume(returning: nil)
            }
        }
    }

    static func identifier(from message: String) throws -> Int {
        guard
            let object = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
            let identifier = object["id"] as? Int
        else {
            throw TestError.invalidMessage
        }
        return identifier
    }

    static func method(from message: String) throws -> String {
        guard
            let object = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
            let method = object["method"] as? String
        else {
            throw TestError.invalidMessage
        }
        return method
    }

    static func jsonString(_ object: [String: Any]) -> String {
        String(decoding: jsonData(object), as: UTF8.self)
    }

    static func jsonData(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: WITransportPayload) throws -> T {
        try JSONDecoder().decode(T.self, from: payload.jsonData())
    }

    static func nextValue<T: Sendable>(
        from iterator: IteratorBox<T>
    ) async throws -> T? {
        await iterator.next()
    }

    enum TestError: Error {
        case invalidMessage
    }
}
