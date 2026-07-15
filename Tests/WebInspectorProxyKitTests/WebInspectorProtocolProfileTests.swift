import Foundation
import Testing
import WebInspectorProxyKitTesting
@testable import WebInspectorProxyKit

@Test
func releasedWebKitProfileDoesNotActivateFrameAgents() throws {
    let profile = try WebInspectorProtocolProfile.profile(
        forWebKitBundleVersion: "8624.2.5.10.4"
    )

    for domain in ["CSS", "DOM", "Console", "Runtime"] {
        #expect(!profile.supports(
            WebInspectorProtocolDomainToken(rawValue: domain),
            on: .frame
        ))
    }
}

@Test
func releasedProfilesMatchTheLegacyWebInspectorUIDomainTables() {
    let common: [String: Set<ProtocolTarget.Kind>] = [
        "CSS": [.page],
        "DOM": [.page],
        "Console": [.page, .serviceWorker, .worker],
        "Runtime": [.page, .serviceWorker, .worker],
        "Network": [.page, .serviceWorker],
        "Page": [.page],
    ]
    let allKinds: Set<ProtocolTarget.Kind> = [
        .page, .frame, .serviceWorker, .worker,
    ]
    let profiles: [(
        WebInspectorProtocolProfile,
        [String: Set<ProtocolTarget.Kind>]
    )] = [
        (.released18, common.merging(["Inspector": [.page]]) { _, new in new }),
        (
            .released26,
            common.merging(["Inspector": [.page, .serviceWorker]]) { _, new in new }
        ),
    ]

    for (profile, expected) in profiles {
        for (domain, supportedKinds) in expected {
            let token = WebInspectorProtocolDomainToken(rawValue: domain)
            for kind in allKinds {
                #expect(
                    profile.supports(token, on: kind)
                        == supportedKinds.contains(kind)
                )
            }
        }
    }
}

@Test
func latestWebKitProfileActivatesOnlyTheUpstreamFrameDomains() throws {
    let profile = try WebInspectorProtocolProfile.profile(
        forWebKitBundleVersion: "8625.1.22.10.2"
    )

    for domain in ["CSS", "DOM", "Console", "Runtime"] {
        #expect(profile.supports(
            WebInspectorProtocolDomainToken(rawValue: domain),
            on: .frame
        ))
    }
    for domain in ["Network", "Page", "Inspector"] {
        #expect(!profile.supports(
            WebInspectorProtocolDomainToken(rawValue: domain),
            on: .frame
        ))
    }
}

@Test(arguments: [
    ("8619.1.26.30.1", WebInspectorProtocolProfile.Generation.released18),
    ("8620.2.4.10.7", WebInspectorProtocolProfile.Generation.released18),
    ("8621.1.15.10.7", WebInspectorProtocolProfile.Generation.released18),
    ("8622.1.1", WebInspectorProtocolProfile.Generation.released26),
    ("8623.1.1", WebInspectorProtocolProfile.Generation.released26),
    ("8624.2.5.10.4", WebInspectorProtocolProfile.Generation.released26),
    ("21624.2.5.11.8", WebInspectorProtocolProfile.Generation.released26),
    ("8625.1.22.10.2", WebInspectorProtocolProfile.Generation.latest),
])
func webKitBundleVersionSelectsTheMatchingProtocolProfile(
    bundleVersion: String,
    generation: WebInspectorProtocolProfile.Generation
) throws {
    #expect(
        try WebInspectorProtocolProfile.profile(
            forWebKitBundleVersion: bundleVersion
        ).generation == generation
    )
}

@Test(arguments: ["", "not-a-version", "8618.2.4.10.7", "8626.0.1"])
func unknownWebKitBundleVersionDoesNotFallBackToAnOlderProfile(
    bundleVersion: String
) {
    #expect(throws: WebInspectorProxyError.self) {
        try WebInspectorProtocolProfile.profile(
            forWebKitBundleVersion: bundleVersion
        )
    }
}

@Test
func latestWebKitProfileDecodesItsFrameTargetIdentity() throws {
    let frameID = try WebInspectorProtocolProfile.latest.semanticFrameID(
        for: ProtocolTarget.ID("frame-42-7"),
        targetKind: .frame
    )

    #expect(frameID?.rawValue == "frame-7.42")
    #expect(try WebInspectorProtocolProfile.released26.semanticFrameID(
        for: ProtocolTarget.ID("frame-42-7"),
        targetKind: .frame
    ) == nil)
}

@Test(arguments: [
    "frame-one",
    "frame-1",
    "frame-1-2-3",
    "frame-01-2",
    "frame-1-02",
])
func latestWebKitProfileRejectsUnknownFrameTargetIdentity(
    targetID: String
) {
    #expect(throws: WebInspectorProxyError.self) {
        try WebInspectorProtocolProfile.latest.semanticFrameID(
            for: ProtocolTarget.ID(targetID),
            targetKind: .frame
        )
    }
}

@Test
func allUnsupportedSelectedTargetsProduceAnInertScope() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start(
        configuration: .init(responseTimeout: .milliseconds(50)),
        protocolProfile: .released26
    )
    defer { Task { await runtime.close() } }
    try await runtime.peer.createTarget(.init(id: "frame-42-7", type: "frame"))

    let scope = try await runtime.page.orderedScope(
        descriptor: WebInspectorOrderedScopeDescriptor(
            selection: .descendants(
                of: .currentPage,
                kinds: [.frame]
            ),
            decoders: [ConsoleWireCoding.eventDecoder],
            capabilities: [ConsoleWireCoding.capability]
        ),
        buffering: .bounded(4)
    )

    await scope.close()
}

@Test
func unsupportedDescendantDoesNotFailASupportedSiblingTarget() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start(
        protocolProfile: .released26
    )
    defer { Task { await runtime.close() } }
    try await runtime.peer.createTarget(.init(id: "frame-42-7", type: "frame"))

    let scopeTask = Task {
        try await runtime.page.orderedScope(
            descriptor: WebInspectorOrderedScopeDescriptor(
                decoders: [ConsoleWireCoding.eventDecoder],
                capabilities: [ConsoleWireCoding.capability]
            ),
            buffering: .bounded(4)
        )
    }
    let enable = try await runtime.peer.commands.next()
    #expect(enable.destination == .target("page-main"))
    #expect(enable.method == "Console.enable")
    try await runtime.peer.reply(to: enable)
    let scope = try await scopeTask.value

    let closeTask = Task { await scope.close() }
    let disable = try await runtime.peer.commands.next()
    #expect(disable.destination == .target("page-main"))
    #expect(disable.method == "Console.disable")
    try await runtime.peer.reply(to: disable)
    await closeTask.value
}

@Test
func latestProfileActivatesAnAvailableFrameCapability() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start(
        protocolProfile: .latest
    )
    defer { Task { await runtime.close() } }
    try await runtime.peer.createTarget(.init(id: "frame-42-7", type: "frame"))

    let scopeTask = Task {
        try await runtime.page.orderedScope(
            descriptor: WebInspectorOrderedScopeDescriptor(
                selection: .descendants(
                    of: .currentPage,
                    kinds: [.frame]
                ),
                decoders: [ConsoleWireCoding.eventDecoder],
                capabilities: [ConsoleWireCoding.capability]
            ),
            buffering: .bounded(4)
        )
    }
    let command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("frame-42-7"))
    #expect(command.method == "Console.enable")
    try await runtime.peer.reply(to: command)

    let scope = try await scopeTask.value
    let closeTask = Task { await scope.close() }
    let disable = try await runtime.peer.commands.next()
    #expect(disable.destination == .target("frame-42-7"))
    #expect(disable.method == "Console.disable")
    try await runtime.peer.reply(to: disable)
    await closeTask.value
}

@Test
func targetCreatedDecodesTheFourFieldWebKitShape() async throws {
    let peer = WebInspectorTestPeer()
    let core = await peer.makeConnection(
        configuration: .init(),
        protocolProfile: .latest
    )
    defer { Task { await core.close() } }

    try await peer.emitRootEvent(
        method: "Target.targetCreated",
        parameters: try WebInspectorTestJSONObject(json: #"""
        {
            "targetInfo": {
                "targetId": "page-main",
                "type": "page",
                "isProvisional": false,
                "isPaused": false
            }
        }
        """#)
    )

    let record = await core.currentMainPageRecord()
    #expect(record?.id == ProtocolTarget.ID("page-main"))
    #expect(record?.kind == .page)
    #expect(record?.isProvisional == false)
    #expect(record?.isPaused == false)
}
