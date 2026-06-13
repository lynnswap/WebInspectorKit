import Foundation
import Testing
import WebInspectorTestSupport
import WebInspectorTransport
@testable import WebInspectorCore

@Test
func transportReceiverBuffersMessagesUntilTransportIsSetAndPreservesOrder() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    let stream = await transport.orderedEvents()
    let receiver = TransportReceiver()

    let eventsTask = Task {
        var methods: [String] = []
        for await event in stream {
            methods.append(event.method)
            if methods.count == 2 {
                break
            }
        }
        return methods
    }

    receiver.receive(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#)
    receiver.receive(#"{"method":"Runtime.executionContextCreated","params":{"context":{"id":1,"origin":"https://example.test","name":"main","auxData":{"frameId":"main-frame","isDefault":true}}}}"#)

    #expect(await transport.snapshot().targetsByID.isEmpty)

    receiver.setTransport(transport)

    let methods = try #require(await value(of: eventsTask))
    #expect(methods == [
        "Target.targetCreated",
        "Runtime.executionContextCreated",
    ])
    #expect(await transport.snapshot().targetsByID[ProtocolTargetIdentifier("page-main")]?.frameID?.rawValue == "main-frame")
}

private func value<Value: Sendable>(
    of task: Task<Value, Never>,
    timeout: Duration = .milliseconds(750)
) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let value = await group.next() ?? nil
        group.cancelAll()
        return value
    }
}
