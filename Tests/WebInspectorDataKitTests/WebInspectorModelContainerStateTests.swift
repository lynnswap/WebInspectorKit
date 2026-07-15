import Testing
@testable import WebInspectorDataKit

@MainActor
@Test
func featureConfigurationAndStateStreamsUseFeatureIDs() async {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom, .network])
    )

    #expect(container.configuration.enabledFeatures == [.dom, .network])
    #expect(container.dom.state == .disabled)
    #expect(container.network.state == .disabled)
    #expect(container.console.state == .disabled)
    #expect(container.runtime.state == .disabled)

    var domStates = container.dom.stateUpdates.makeAsyncIterator()
    var networkStates = container.featureStateUpdates(for: .network)
        .makeAsyncIterator()
    #expect(await domStates.next() == .disabled)
    #expect(await networkStates.next() == .disabled)

    await container.close()
    #expect(await domStates.next() == .disabled)
    #expect(await networkStates.next() == .disabled)
    #expect(await domStates.next() == nil)
    #expect(await networkStates.next() == nil)
}

@Test
func featureTransitionLoggingSkipsReadyRevisionChurn() {
    let firstGeneration = WebInspectorPageGeneration(rawValue: 1)
    let secondGeneration = WebInspectorPageGeneration(rawValue: 2)
    let firstRevision = WebInspectorStoreRevision(rawValue: 10)
    let secondRevision = WebInspectorStoreRevision(rawValue: 11)

    #expect(
        !webInspectorShouldLogFeatureTransition(
            from: .ready(
                generation: firstGeneration,
                revision: firstRevision
            ),
            to: .ready(
                generation: firstGeneration,
                revision: secondRevision
            )
        )
    )
    #expect(
        webInspectorShouldLogFeatureTransition(
            from: .ready(
                generation: firstGeneration,
                revision: secondRevision
            ),
            to: .ready(
                generation: secondGeneration,
                revision: secondRevision
            )
        )
    )
    #expect(
        webInspectorShouldLogFeatureTransition(
            from: .ready(
                generation: firstGeneration,
                revision: secondRevision
            ),
            to: .recovering(
                generation: firstGeneration,
                reason: .targetChanged
            )
        )
    )
}
