import Testing
@testable import WebInspectorDataKit

private actor ModelContainerContextOwner {
    private var context: WebInspectorModelContext?

    func createContext(from container: WebInspectorModelContainer) async throws {
        context = try await container.makeContext(isolation: self)
    }

    func appliedRevision() -> UInt64? {
        context?.appliedContainerRevisionForTesting
    }

    func state() -> WebInspectorModelContext.State? {
        context?.state
    }

    func closeContext() async {
        await context?.close()
    }

    func releaseContext() {
        context = nil
    }
}

@MainActor
@Test
func modelContainerMainContextIsStableAndClosesWithItsContainer() async {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )

    let first = container.mainContext
    let second = container.mainContext

    #expect(first === second)
    await expectEventually {
        first.appliedContainerRevisionForTesting == 0
    }
    #expect(await container.core.metrics.activeContextRegistrationCount == 1)

    await container.close()

    #expect(first.state == .closed)
    #expect(await container.core.metrics.activeContextRegistrationCount == 0)
}

@MainActor
@Test
func modelContainerCreatesIndependentActorConfinedContexts() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let firstOwner = ModelContainerContextOwner()
    let secondOwner = ModelContainerContextOwner()

    try await firstOwner.createContext(from: container)
    try await secondOwner.createContext(from: container)

    #expect(await firstOwner.appliedRevision() == 0)
    #expect(await secondOwner.appliedRevision() == 0)
    #expect(await container.core.metrics.activeContextRegistrationCount == 2)

    await firstOwner.closeContext()
    #expect(await firstOwner.state() == .closed)
    #expect(await container.core.metrics.activeContextRegistrationCount == 1)

    await container.close()
    #expect(await secondOwner.state() == .closed)
    #expect(await container.core.metrics.activeContextRegistrationCount == 0)
}

@MainActor
@Test
func modelContainerRejectsCustomContextCreationAfterClose() async {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let owner = ModelContainerContextOwner()

    await container.close()

    await #expect(throws: WebInspectorModelContainer.Failure.closed) {
        try await owner.createContext(from: container)
    }
}

@MainActor
@Test
func firstMainContextAccessAfterCloseReturnsOneClosedContext() async {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )

    await container.close()

    let first = container.mainContext
    let second = container.mainContext
    #expect(first === second)
    #expect(first.state == .closed)
    #expect(await container.core.metrics.activeContextRegistrationCount == 0)
}

@MainActor
@Test
func releasedCustomContextUnregistersItsSubscription() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(domains: [])
    )
    let owner = ModelContainerContextOwner()

    try await owner.createContext(from: container)
    #expect(await container.core.metrics.activeContextRegistrationCount == 1)

    await owner.releaseContext()
    for _ in 0..<1_000 {
        if await container.core.metrics.activeContextRegistrationCount == 0 {
            break
        }
        await Task.yield()
    }
    #expect(await container.core.metrics.activeContextRegistrationCount == 0)

    await container.close()
}

@MainActor
private func expectEventually(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<1_000 {
        if condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("The expected context state was not committed.", sourceLocation: sourceLocation)
}
