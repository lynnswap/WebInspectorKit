import Foundation
import Testing
import WebInspectorTestSupport
import WebInspectorTransport
@testable import WebInspectorCore
@testable import WebInspectorCoreConsoleNetwork
@testable import WebInspectorCoreDOMCSS
@testable import WebInspectorCoreRuntime
@testable import WebInspectorCoreSupport

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
    #expect(await transport.snapshot().targetsByID[ProtocolTarget.ID("page-main")]?.frameID?.rawValue == "main-frame")
}

@Test
func transportReceiverCloseDropsBufferedAndFutureMessages() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend, responseTimeout: .milliseconds(750))
    let receiver = TransportReceiver()

    receiver.receive(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"buffered-page","type":"page","frameId":"buffered-frame","isProvisional":false}}}"#)
    receiver.close()
    receiver.setTransport(transport)
    receiver.receive(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"late-page","type":"page","frameId":"late-frame","isProvisional":false}}}"#)

    #expect(await transport.snapshot().targetsByID.isEmpty)
}

@Test
func closedReceiverDoesNotDirtyReplacementTransport() async throws {
    let oldBackend = FakeTransportBackend()
    let oldTransport = TransportSession(backend: oldBackend, responseTimeout: .milliseconds(750))
    let oldReceiver = TransportReceiver()
    oldReceiver.setTransport(oldTransport)
    oldReceiver.close()

    let newBackend = FakeTransportBackend()
    let newTransport = TransportSession(backend: newBackend, responseTimeout: .milliseconds(750))
    let stream = await newTransport.orderedEvents()
    let newReceiver = TransportReceiver()
    newReceiver.setTransport(newTransport)

    let eventsTask = Task {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()?.method
    }

    oldReceiver.receive(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"old-page","type":"page","frameId":"old-frame","isProvisional":false}}}"#)
    newReceiver.receive(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"new-page","type":"page","frameId":"new-frame","isProvisional":false}}}"#)

    #expect(try #require(await value(of: eventsTask)) == "Target.targetCreated")
    #expect(await oldTransport.snapshot().targetsByID.isEmpty)
    #expect(await newTransport.snapshot().targetsByID[ProtocolTarget.ID("new-page")]?.frameID?.rawValue == "new-frame")
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
