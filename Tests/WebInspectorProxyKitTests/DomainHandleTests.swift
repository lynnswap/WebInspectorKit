import Foundation
import Testing
@testable import WebInspectorProxyKit

@Test
func domainHandlesBindCommandsAndEventsToTheirWireDomains() throws {
    let domEvent = WebInspectorProxyEvent.dom(
        .unknown(RawEvent(domain: "DOM", method: "domProbe"))
    )
    let cssEvent = WebInspectorProxyEvent.css(
        .unknown(RawEvent(domain: "CSS", method: "cssProbe"))
    )
    let networkEvent = WebInspectorProxyEvent.network(
        .unknown(RawEvent(domain: "Network", method: "networkProbe"))
    )
    let consoleEvent = WebInspectorProxyEvent.console(
        Console.TargetedEvent(
            event: .unknown(RawEvent(domain: "Console", method: "consoleProbe")),
            targetID: WebInspectorTarget.ID("console-target")
        )
    )
    let runtimeEvent = WebInspectorProxyEvent.runtime(
        .unknown(RawEvent(domain: "Runtime", method: "runtimeProbe"))
    )

    try assertEventDomain(
        DOM.self,
        commandDomain: .dom,
        eventDomain: .dom,
        event: domEvent,
        crossDomainEvent: cssEvent,
        expectedMethod: "domProbe",
        rawEvent: { event in
            guard case let .unknown(rawEvent) = event else { return nil }
            return rawEvent
        }
    )
    try assertEventDomain(
        CSS.self,
        commandDomain: .css,
        eventDomain: .css,
        event: cssEvent,
        crossDomainEvent: networkEvent,
        expectedMethod: "cssProbe",
        rawEvent: { event in
            guard case let .unknown(rawEvent) = event else { return nil }
            return rawEvent
        }
    )
    try assertEventDomain(
        Network.self,
        commandDomain: .network,
        eventDomain: .network,
        event: networkEvent,
        crossDomainEvent: consoleEvent,
        expectedMethod: "networkProbe",
        rawEvent: { event in
            guard case let .unknown(rawEvent) = event else { return nil }
            return rawEvent
        }
    )
    try assertEventDomain(
        Console.self,
        commandDomain: .console,
        eventDomain: .console,
        event: consoleEvent,
        crossDomainEvent: runtimeEvent,
        expectedMethod: "consoleProbe",
        rawEvent: { event in
            guard case let .unknown(rawEvent) = event else { return nil }
            return rawEvent
        }
    )
    try assertEventDomain(
        Runtime.self,
        commandDomain: .runtime,
        eventDomain: .runtime,
        event: runtimeEvent,
        crossDomainEvent: domEvent,
        expectedMethod: "runtimeProbe",
        rawEvent: { event in
            guard case let .unknown(rawEvent) = event else { return nil }
            return rawEvent
        }
    )

    #expect(Page.commandDomain == .page)
    #expect(Inspector.commandDomain == .inspector)
}

private func assertEventDomain<Handle: WebInspectorEventDomainHandle>(
    _ handleType: Handle.Type,
    commandDomain: WebInspectorProxyDomain,
    eventDomain: WebInspectorProxyEventDomain,
    event: WebInspectorProxyEvent,
    crossDomainEvent: WebInspectorProxyEvent,
    expectedMethod: String,
    rawEvent: (Handle.Event) -> RawEvent?
) throws {
    #expect(handleType.commandDomain == commandDomain)
    #expect(handleType.eventDomain == eventDomain)

    let extractedEvent = try #require(handleType.extractEvent(event))
    let extractedRawEvent = try #require(rawEvent(extractedEvent))
    #expect(extractedRawEvent.method == expectedMethod)
    #expect(handleType.extractEvent(crossDomainEvent) == nil)
}
