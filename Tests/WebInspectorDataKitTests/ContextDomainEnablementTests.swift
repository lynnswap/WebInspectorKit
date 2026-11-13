import Foundation
import Observation
import ObservationBridge
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

@MainActor
@Test
func domainEnablementReleaseDuringPendingEnableDisablesAfterEnableCompletes() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()
    let gate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "Runtime", method: "enable", gate: gate)

    let acquireTask = Task {
        try await registry.acquire(.runtime, on: target)
    }

    try await waitForRecordedCommands(on: runtime.backend, expected: [
            RecordedCommand(domain: "Runtime", method: "enable")
        ])

    let releaseTask = Task {
        await registry.release(.runtime, on: target)
    }

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await gate.open()

    try await acquireTask.value
    #expect(await releaseTask.value == nil)

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
    ])
}

@MainActor
@Test
func domainEnablementKeepsPageAliveForCSSLeaseInDependencyOrder() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()

    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    try await registry.acquireStyleAccess(on: target)

    await runtime.backend.enqueue((), for: "CSS", method: "disable")
    await runtime.backend.enqueue((), for: "Page", method: "disable")
    #expect(await registry.releaseStyleAccess(on: target) == nil)

    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "CSS", method: "disable"),
        RecordedCommand(domain: "Page", method: "disable"),
    ])
}

@MainActor
@Test
func domainEnablementFrameCSSLeaseNeverSendsPageCommands() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let registry = WebInspectorDomainEnablementRegistry()
    let target = WebInspectorTarget(
        id: WebInspectorTarget.ID("frame-css-agent"),
        kind: .frame,
        frameID: nil,
        isProvisional: false,
        proxy: runtime.proxy,
        route: RoutingTargetID("frame-css-agent")
    )

    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    try await registry.acquireStyleAccess(on: target)
    await runtime.backend.enqueue((), for: "CSS", method: "disable")
    #expect(await registry.releaseStyleAccess(on: target) == nil)

    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "CSS", method: "disable"),
    ])
}

@MainActor
@Test
func domainEnablementFrameCSSFailureStaysLocalWithoutPageOrRetry() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let registry = WebInspectorDomainEnablementRegistry()
    let target = WebInspectorTarget(
        id: WebInspectorTarget.ID("frame-css-agent"),
        kind: .frame,
        frameID: nil,
        isProvisional: false,
        proxy: runtime.proxy,
        route: RoutingTargetID("frame-css-agent")
    )
    let failure = WebInspectorProxyError.commandFailed(
        domain: "CSS",
        method: "enable",
        message: "CSS unavailable"
    )

    await runtime.backend.enqueueFailure(failure, for: "CSS", method: "enable")

    await #expect(throws: failure) {
        try await registry.acquireStyleAccess(on: target)
    }
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "CSS", method: "enable"),
    ])
}

@MainActor
@Test
func domainEnablementCSSFailureRollsBackPageWithoutRetrying() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()
    let failure = WebInspectorProxyError.commandFailed(
        domain: "CSS",
        method: "enable",
        message: "CSS unavailable"
    )

    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueueFailure(failure, for: "CSS", method: "enable")
    await runtime.backend.enqueue((), for: "Page", method: "disable")

    await #expect(throws: failure) {
        try await registry.acquireStyleAccess(on: target)
    }
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "Page", method: "disable"),
    ])
}

@MainActor
@Test
func domainEnablementReacquiresCSSForCommittedPageBinding() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let registry = WebInspectorDomainEnablementRegistry()
    let oldPage = WebInspectorTarget(
        id: .currentPage,
        kind: .page,
        frameID: nil,
        isProvisional: false,
        proxy: runtime.proxy,
        route: .currentPage,
        pageBindingID: "page-old"
    )
    let newPage = WebInspectorTarget(
        id: .currentPage,
        kind: .page,
        frameID: nil,
        isProvisional: false,
        proxy: runtime.proxy,
        route: .currentPage,
        pageBindingID: "page-new"
    )

    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    try await registry.acquireStyleAccess(on: oldPage)
    await registry.discardStyleAccess(on: oldPage)

    await runtime.backend.enqueue((), for: "Page", method: "enable")
    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    try await registry.acquireStyleAccess(on: newPage)

    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
        RecordedCommand(domain: "Page", method: "enable"),
        RecordedCommand(domain: "CSS", method: "enable"),
    ])
}

@MainActor
@Test
func domainEnablementAcquireWaitsForFinalReleaseDisable() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()
    let disableGate = WebInspectorTestGate()

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    try await registry.acquire(.runtime, on: target)
    await runtime.backend.hold(domain: "Runtime", method: "disable", gate: disableGate)
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")

    let releaseTask = Task {
        await registry.release(.runtime, on: target)
    }
    try await waitForRecordedCommands(on: runtime.backend, expected: [
            RecordedCommand(domain: "Runtime", method: "enable"),
            RecordedCommand(domain: "Runtime", method: "disable"),
        ])

    let acquireWaitBaseline = await registry.acquireWaitingForDisableSequenceForTesting
    let acquireTask = Task {
        try await registry.acquire(.runtime, on: target)
    }
    await registry.waitForAcquireWaitingForDisableForTesting(after: acquireWaitBaseline)
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
    ])

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await disableGate.open()

    #expect(await releaseTask.value == nil)
    try await acquireTask.value
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Runtime", method: "enable"),
    ])
}

@MainActor
@Test
func domainEnablementAcquireWaitsForPendingReleaseDisable() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()
    let enableGate = WebInspectorTestGate()
    let disableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "Runtime", method: "enable", gate: enableGate)
    await runtime.backend.hold(domain: "Runtime", method: "disable", gate: disableGate)

    let firstAcquireTask = Task {
        try await registry.acquire(.runtime, on: target)
    }
    try await waitForRecordedCommands(on: runtime.backend, expected: [
            RecordedCommand(domain: "Runtime", method: "enable")
        ])

    let releaseTask = Task {
        await registry.release(.runtime, on: target)
    }
    let acquireWaitBaseline = await registry.acquireWaitingForDisableSequenceForTesting
    let secondAcquireTask = Task {
        try await registry.acquire(.runtime, on: target)
    }
    await registry.waitForAcquireWaitingForDisableForTesting(after: acquireWaitBaseline)

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    await enableGate.open()
    try await waitForRecordedCommands(on: runtime.backend, expected: [
            RecordedCommand(domain: "Runtime", method: "enable"),
            RecordedCommand(domain: "Runtime", method: "disable"),
        ])
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
    ])

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    await disableGate.open()

    try await firstAcquireTask.value
    #expect(await releaseTask.value == nil)
    try await secondAcquireTask.value
    #expect(await runtime.backend.recordedCommands() == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
        RecordedCommand(domain: "Runtime", method: "enable"),
    ])
}

@MainActor
@Test
func domainEnablementDiscardLeasePreservesSharedEnabledLease() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registry = WebInspectorDomainEnablementRegistry()

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    try await registry.acquire(.runtime, on: target)
    try await registry.acquire(.runtime, on: target)

    await registry.discardLease(.runtime, on: target)

    await runtime.backend.enqueue((), for: "Runtime", method: "disable")
    #expect(await registry.release(.runtime, on: target) == nil)

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "disable"),
    ])
}

@MainActor
@Test
func domainLeaseRetargetInterleavingReenablesCommittedPageBinding() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let registry = WebInspectorDomainEnablementRegistry()
    let oldPage = WebInspectorTarget(
        id: .currentPage,
        kind: .page,
        frameID: nil,
        isProvisional: false,
        proxy: runtime.proxy,
        route: .currentPage,
        pageBindingID: "page-old"
    )
    let newPage = WebInspectorTarget(
        id: .currentPage,
        kind: .page,
        frameID: nil,
        isProvisional: false,
        proxy: runtime.proxy,
        route: .currentPage,
        pageBindingID: "page-new"
    )

    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    try await registry.acquire(.runtime, on: oldPage)
    try await registry.acquire(.runtime, on: oldPage)

    await registry.discardLease(.runtime, on: oldPage)
    await runtime.backend.enqueue((), for: "Runtime", method: "enable")
    try await registry.acquire(.runtime, on: newPage)

    await registry.discardLease(.runtime, on: oldPage)
    try await registry.acquire(.runtime, on: newPage)

    let commands = await runtime.backend.recordedCommands()
    #expect(commands == [
        RecordedCommand(domain: "Runtime", method: "enable"),
        RecordedCommand(domain: "Runtime", method: "enable"),
    ])
}
