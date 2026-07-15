#if canImport(UIKit)
import Testing
import UIKit
import WebInspectorDataKit
import WebInspectorTestSupport
@testable import WebInspectorKit

@MainActor
@Suite
struct CustomTabResourceTests {
    private struct FactoryFailure: LocalizedError {
        var errorDescription: String? {
            "Custom tab bootstrap failed."
        }
    }

    @Test
    func concurrentHostsJoinOneFactoryAndMoveReadyContent() async throws {
        let key = WebInspectorTab.ContentKey(
            tabID: .init(rawValue: "console"),
            contentID: "root"
        )
        let started = WebInspectorTestGate()
        let release = WebInspectorTestGate()
        let session = WebInspectorSession(
            modelContainer: WebInspectorModelContainer(
                configuration: .init(enabledFeatures: [])
            )
        )
        let context = WebInspectorTab.Context(session: session)
        let store = PresentationContentStore(context: context)
        let content = UIViewController()
        var factoryCallCount = 0
        let make: @MainActor (WebInspectorTab.Context) async throws -> UIViewController = { _ in
            factoryCallCount += 1
            started.open()
            await release.waiter.wait()
            return content
        }

        let firstHost = store.customViewController(
            for: key,
            context: context,
            requiredFeatures: [],
            makeViewController: make
        )
        let secondHost = store.customViewController(
            for: key,
            context: context,
            requiredFeatures: [],
            makeViewController: make
        )

        #expect(firstHost.phase == .loading)
        #expect(secondHost.phase == .loading)
        await started.waiter.wait()
        #expect(factoryCallCount == 1)

        release.open()
        await store.waitForCustomResourceTaskForTesting(for: key)

        #expect(firstHost.phase == .ready)
        #expect(secondHost.phase == .ready)
        #expect(firstHost.readyViewControllerForTesting == nil)
        #expect(secondHost.readyViewControllerForTesting === content)
        #expect(content.parent === secondHost)

        let replacementHost = store.customViewController(
            for: key,
            context: context,
            requiredFeatures: [],
            makeViewController: make
        )
        #expect(factoryCallCount == 1)
        #expect(replacementHost.readyViewControllerForTesting === content)
        #expect(content.parent === replacementHost)

        await store.clear()
    }

    @Test
    func failureRendersRetryAndRetryPublishesReadyContent() async {
        let key = WebInspectorTab.ContentKey(
            tabID: .init(rawValue: "failing"),
            contentID: "root"
        )
        let session = WebInspectorSession(
            modelContainer: WebInspectorModelContainer(
                configuration: .init(enabledFeatures: [])
            )
        )
        let context = WebInspectorTab.Context(session: session)
        let store = PresentationContentStore(context: context)
        let content = UIViewController()
        var factoryCallCount = 0
        let make: @MainActor (WebInspectorTab.Context) async throws -> UIViewController = { _ in
            factoryCallCount += 1
            if factoryCallCount == 1 {
                throw FactoryFailure()
            }
            return content
        }

        let host = store.customViewController(
            for: key,
            context: context,
            requiredFeatures: [],
            makeViewController: make
        )
        await store.waitForCustomResourceTaskForTesting(for: key)

        #expect(host.phase == .failed("Custom tab bootstrap failed."))
        #expect(
            (host.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?
                .button.title == "Retry"
        )

        host.retryForTesting()
        await store.waitForCustomResourceTaskForTesting(for: key)

        #expect(factoryCallCount == 2)
        #expect(host.phase == .ready)
        #expect(host.readyViewControllerForTesting === content)
        await store.clear()
    }

    @Test
    func nonRetryableFeatureFailureDoesNotExposeRetryAction() async {
        let key = WebInspectorTab.ContentKey(
            tabID: .init(rawValue: "network-dependent"),
            contentID: "root"
        )
        let container = WebInspectorModelContainer(
            configuration: .init(enabledFeatures: [.network])
        )
        container.publishState(.attached(generation: .init(rawValue: 1)))
        container.featureRegistry.publish(
            .unavailable(
                generation: .init(rawValue: 1),
                error: .bootstrap(
                    WebInspectorFailureDescription(
                        code: "network.bootstrap.failed",
                        phase: "bootstrap",
                        message: "Injected Network failure."
                    )
                )
            ),
            for: .network
        )
        let session = WebInspectorSession(modelContainer: container)
        let context = WebInspectorTab.Context(session: session)
        let store = PresentationContentStore(context: context)
        var factoryCallCount = 0
        let host = store.customViewController(
            for: key,
            context: context,
            requiredFeatures: [.network]
        ) { _ in
            factoryCallCount += 1
            return UIViewController()
        }
        await store.waitForCustomResourceTaskForTesting(for: key)

        guard case .failed = host.phase else {
            Issue.record("The Network-dependent resource did not publish failure.")
            await store.clear()
            await container.close()
            return
        }
        #expect(factoryCallCount == 0)
        #expect(
            (host.contentUnavailableConfiguration
                as? UIContentUnavailableConfiguration)?
                .buttonProperties.primaryAction == nil
        )

        host.retryForTesting()
        await store.waitForCustomResourceTaskForTesting(for: key)
        #expect(factoryCallCount == 0)

        await store.clear()
        await container.close()
    }

    @Test
    func factoryTaskDoesNotRetainStoreAndLateCompletionCannotPublish() async throws {
        let key = WebInspectorTab.ContentKey(
            tabID: .init(rawValue: "lifecycle"),
            contentID: "root"
        )
        let started = WebInspectorTestGate()
        let release = WebInspectorTestGate()
        let finished = WebInspectorTestGate()
        let session = WebInspectorSession(
            modelContainer: WebInspectorModelContainer(
                configuration: .init(enabledFeatures: [])
            )
        )
        let context = WebInspectorTab.Context(session: session)
        var store: PresentationContentStore? = PresentationContentStore(
            context: context
        )
        weak let weakStore = store
        let host = try #require(store).customViewController(
            for: key,
            context: context,
            requiredFeatures: []
        ) { _ in
            started.open()
            await release.waiter.wait()
            finished.open()
            return UIViewController()
        }
        await started.waiter.wait()

        store = nil

        #expect(weakStore == nil)
        #expect(host.phase == .loading)
        #expect(host.readyViewControllerForTesting == nil)

        release.open()
        await finished.waiter.wait()
        #expect(host.readyViewControllerForTesting == nil)
    }

    @Test
    func dismissalJoinsFactoryRetirementAlreadyStartedByConnectionFailure()
        async throws
    {
        let key = WebInspectorTab.ContentKey(
            tabID: .init(rawValue: "lifecycle-race"),
            contentID: "root"
        )
        let factoryStarted = WebInspectorTestGate()
        let factoryRelease = WebInspectorContextReply<Void>()
        let container = WebInspectorModelContainer(
            configuration: .init(enabledFeatures: [])
        )
        let session = WebInspectorSession(modelContainer: container)
        let context = WebInspectorTab.Context(session: session)
        let store = PresentationContentStore(context: context)
        let host = store.customViewController(
            for: key,
            context: context,
            requiredFeatures: []
        ) { _ in
            factoryStarted.open()
            try await factoryRelease.value()
            return UIViewController()
        }
        await factoryStarted.waiter.wait()

        let failure = WebInspectorConnectionFailure.native(
            WebInspectorFailureDescription(
                code: "test.connection.failed",
                phase: "test",
                message: "Injected connection failure."
            )
        )
        container.publishState(
            .failed(generation: .init(rawValue: 1), failure: failure)
        )
        while host.phase != .closed {
            await Task.yield()
        }

        var didClear = false
        let clear = Task { @MainActor in
            await store.clear()
            didClear = true
        }
        for _ in 0..<100 {
            if didClear { break }
            await Task.yield()
        }
        #expect(didClear == false)

        factoryRelease.succeed(())
        await clear.value
        #expect(didClear)
        await container.close()
    }

    @Test
    func catalogAndContainerExposeTheSameFeatureContract() throws {
        let console = WebInspectorTab(
            id: .init(rawValue: "console"),
            title: "Console",
            requiredFeatures: [.consoleRuntime]
        ) { _ in
            UIViewController()
        }
        let catalog = try WebInspectorTabCatalog([.network, console])
        let container = WebInspectorModelContainer(
            configuration: .init(
                enabledFeatures: [.network, .consoleRuntime]
            )
        )
        let viewController = WebInspectorViewController(
            session: WebInspectorSession(modelContainer: container),
            catalog: catalog
        )

        let requiredFeatures: [Set<WebInspectorFeatureID>] = [
            [.network],
            [.consoleRuntime],
        ]
        #expect(
            viewController.interfaceForTesting.tabs.map(\.requiredFeatures)
                == requiredFeatures
        )
        #expect(container.configuration.enabledFeatures == [.network, .consoleRuntime])
    }
}
#endif
