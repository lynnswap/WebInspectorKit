import Foundation
import Testing
import WebInspectorTestSupport
@testable import WebInspectorProxyKit

@Test(arguments: [
    ("8619.1.26.30.1", WebInspectorProtocolProfile.Generation.released18),
    ("8620.2.4.10.7", WebInspectorProtocolProfile.Generation.released18),
    ("8621.3.11.10.3", WebInspectorProtocolProfile.Generation.released18),
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
func unknownWebKitBundleVersionIsExplicitlyUnsupported(bundleVersion: String) {
    #expect(throws: WebInspectorProxyError.self) {
        try WebInspectorProtocolProfile.profile(
            forWebKitBundleVersion: bundleVersion
        )
    }
}

@Test
func releasedAndLatestProfilesOwnDomainSupport() {
    let common: [ProtocolDomain: [ProtocolTarget.Kind]] = [
        .css: [.page],
        .dom: [.page],
        .console: [.page, .serviceWorker, .worker],
        .runtime: [.page, .serviceWorker, .worker],
        .network: [.page, .serviceWorker],
        .page: [.page],
    ]
    let targetKinds: [ProtocolTarget.Kind] = [
        .page, .frame, .serviceWorker, .worker,
    ]
    let profiles: [(
        WebInspectorProtocolProfile,
        [ProtocolDomain: [ProtocolTarget.Kind]]
    )] = [
        (
            .released18,
            common.merging([.inspector: [.page]]) { _, new in new }
        ),
        (
            .released26,
            common.merging([.inspector: [.page, .serviceWorker]]) { _, new in new }
        ),
    ]

    for (profile, expected) in profiles {
        for (domain, supportedKinds) in expected {
            for targetKind in targetKinds {
                #expect(
                    profile.supports(domain, on: targetKind)
                        == supportedKinds.contains(targetKind)
                )
            }
        }
    }

    for domain in [
        ProtocolDomain.css,
        .dom,
        .console,
        .runtime,
    ] {
        #expect(!WebInspectorProtocolProfile.released26.supports(domain, on: .frame))
        #expect(WebInspectorProtocolProfile.latest.supports(domain, on: .frame))
    }
    for domain in [
        ProtocolDomain.network,
        .page,
        .inspector,
    ] {
        #expect(!WebInspectorProtocolProfile.latest.supports(domain, on: .frame))
    }
}

@Test
func onlyLatestProfileAcceptsRootPageTopologyDelivery() {
    #expect(!WebInspectorProtocolProfile.released18.pageTopologyMayArriveAtRoot)
    #expect(!WebInspectorProtocolProfile.released26.pageTopologyMayArriveAtRoot)
    #expect(WebInspectorProtocolProfile.latest.pageTopologyMayArriveAtRoot)
}

@Test
func latestFrameNetworkIdentityUsesTheRootProxyingAgent() {
    #expect(WebInspectorProtocolProfile.latest.usesRootAgent(.network, for: .frame))
    #expect(!WebInspectorProtocolProfile.latest.usesRootAgent(.dom, for: .frame))
    #expect(!WebInspectorProtocolProfile.released26.usesRootAgent(.network, for: .frame))
    #expect(!WebInspectorProtocolProfile.latest.usesRootAgent(.network, for: .page))
    #expect(
        WebInspectorProtocolProfile.latest.usesRootNetworkAgent(
            forFrameTargetID: ProtocolTarget.ID("frame-42-7")
        )
    )
    #expect(
        !WebInspectorProtocolProfile.latest.usesRootNetworkAgent(
            forFrameTargetID: ProtocolTarget.ID("frame-42")
        )
    )
    #expect(
        !WebInspectorProtocolProfile.released26.usesRootNetworkAgent(
            forFrameTargetID: ProtocolTarget.ID("frame-42")
        )
    )
}

@Test
func latestProfileDerivesProtocolFrameIDFromFrameTargetID() throws {
    #expect(
        try WebInspectorProtocolProfile.latest.semanticFrameID(
            for: ProtocolTarget.ID("frame-42-7"),
            targetKind: .frame
        ) == ProtocolFrame.ID("frame-7.42")
    )
    #expect(
        try WebInspectorProtocolProfile.released26.semanticFrameID(
            for: ProtocolTarget.ID("frame-42-7"),
            targetKind: .frame
        ) == nil
    )
}

@Test(arguments: [
    "frame-one",
    "frame-1",
    "frame-1-2-3",
    "frame-01-2",
    "frame-1-02",
])
func latestProfileRejectsUnknownFrameTargetIdentity(targetID: String) {
    #expect(throws: WebInspectorProtocolProfile.Error.self) {
        try WebInspectorProtocolProfile.latest.semanticFrameID(
            for: ProtocolTarget.ID(targetID),
            targetKind: .frame
        )
    }
}

@Test
func targetCreatedAcceptsTheFourFieldWebKitShape() async throws {
    let session = TransportSession(
        backend: FakeTransportBackend(),
        protocolProfile: .released26
    )

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","isProvisional":false,"isPaused":true}}}"#)

    let record = try #require(await session.snapshot().targetsByID[ProtocolTarget.ID("page-main")])
    #expect(record.kind == .page)
    #expect(record.frameID == nil)
    #expect(record.parentFrameID == nil)
    #expect(record.isProvisional == false)
    #expect(record.isPaused)
}

@Test
func targetCreatedIgnoresNonProtocolMetadataAndUsesProfileCapabilities() async throws {
    let session = TransportSession(
        backend: FakeTransportBackend(),
        protocolProfile: .released26
    )

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"service-worker","type":"service-worker","frameId":"fake-frame","parentFrameId":"fake-parent","domains":["DOM"],"isProvisional":false}}}"#)

    let record = try #require(await session.snapshot().targetsByID[ProtocolTarget.ID("service-worker")])
    #expect(record.frameID == nil)
    #expect(record.parentFrameID == nil)
    #expect(!record.capabilities.contains(.dom))
    #expect(record.capabilities.contains(.network))
    #expect(record.capabilities.contains(.inspector))
}

@Test
func exact8624FrameNotificationKeepsFunctionalDomainsOnThePageTarget() async throws {
    let profile = try WebInspectorProtocolProfile.profile(
        forWebKitBundleVersion: "8624.2.5.10.4"
    )
    let backend = FakeTransportBackend()
    let session = TransportSession(backend: backend, protocolProfile: profile)
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-42")
    await session.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","isProvisional":false,"isPaused":false}}}"#
    )
    await session.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42","type":"frame","isProvisional":false,"isPaused":false}}}"#
    )

    let frameRecord = try #require(
        await session.snapshot().targetsByID[frameTargetID]
    )
    #expect(frameRecord.kind == .frame)
    #expect(frameRecord.frameID == nil)
    #expect(frameRecord.capabilities.isEmpty)

    let commands: [(ProtocolDomain, String)] = [
        (.dom, "DOM.getDocument"),
        (.css, "CSS.enable"),
        (.runtime, "Runtime.enable"),
        (.console, "Console.enable"),
        (.network, "Network.enable"),
    ]
    for (domain, method) in commands {
        let sendTask = Task {
            try await session.send(ProtocolCommand(
                domain: domain,
                method: method,
                routing: .octopus(pageTarget: nil)
            ))
        }
        let sent = try await backend.waitForTargetMessage(method: method)
        #expect(sent.targetIdentifier == pageTargetID)
        try await receiveProfileTargetReply(
            session,
            targetID: pageTargetID,
            messageID: profileTestMessageID(sent.message)
        )
        #expect(try await sendTask.value.targetID == pageTargetID)
    }
}

@Test
func latestTargetCreatedUsesDerivedFrameIdentityInsteadOfFakeMetadata() async throws {
    let session = TransportSession(
        backend: FakeTransportBackend(),
        protocolProfile: .latest
    )

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-42-7","type":"frame","frameId":"fake-frame","parentFrameId":"fake-parent","domains":["Network"],"isProvisional":false}}}"#)

    let snapshot = await session.snapshot()
    let record = try #require(snapshot.targetsByID[ProtocolTarget.ID("frame-42-7")])
    #expect(record.kind == .frame)
    #expect(record.frameID == ProtocolFrame.ID("frame-7.42"))
    #expect(record.parentFrameID == nil)
    #expect(record.capabilities == [.css, .dom, .console, .runtime])
    #expect(snapshot.frameTargetIDsByFrameID[ProtocolFrame.ID("frame-7.42")] == ProtocolTarget.ID("frame-42-7"))
}

@Test
func malformedLatestFrameTargetIsSkippedAtTheRootEventBoundary() async {
    let session = TransportSession(
        backend: FakeTransportBackend(),
        protocolProfile: .latest
    )

    await session.receiveRootMessage(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-unknown","type":"frame","isProvisional":false,"isPaused":false}}}"#)

    #expect(await session.snapshot().targetsByID.isEmpty)
}

private func profileTestMessageID(_ message: String) throws -> UInt64 {
    let object = try JSONSerialization.jsonObject(with: Data(message.utf8))
    let dictionary = try #require(object as? [String: Any])
    return try #require((dictionary["id"] as? NSNumber)?.uint64Value)
}

private func receiveProfileTargetReply(
    _ session: TransportSession,
    targetID: ProtocolTarget.ID,
    messageID: UInt64
) async throws {
    let innerMessage = #"{"id":\#(messageID),"result":{}}"#
    let data = try JSONSerialization.data(withJSONObject: [
        "method": "Target.dispatchMessageFromTarget",
        "params": [
            "targetId": targetID.rawValue,
            "message": innerMessage,
        ],
    ])
    await session.receiveRootMessage(
        try #require(String(data: data, encoding: .utf8))
    )
}
