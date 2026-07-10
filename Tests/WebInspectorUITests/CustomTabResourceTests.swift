#if canImport(UIKit)
import Testing
import UIKit
import WebInspectorDataKit
import WebInspectorTestSupport
@testable import WebInspectorUI

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
        let key = WebInspectorTab.ContentKey(tabID: "console", contentID: "root")
        let started = WebInspectorTestGate()
        let release = WebInspectorTestGate()
        let session = WebInspectorSession(tabs: [])
        let store = PresentationContentStore()
        let content = UIViewController()
        var factoryCallCount = 0
        let make: @MainActor (WebInspectorSession) async throws -> UIViewController = { _ in
            factoryCallCount += 1
            started.open()
            await release.waiter.wait()
            return content
        }

        let firstHost = store.customViewController(
            for: key,
            session: session,
            makeViewController: make
        )
        let secondHost = store.customViewController(
            for: key,
            session: session,
            makeViewController: make
        )

        #expect(firstHost.phase == .loading)
        #expect(secondHost.phase == .loading)
        await started.waiter.wait()
        #expect(factoryCallCount == 1)

        release.open()
        await store.waitForCustomResourceTaskForTesting(for: key)

        #expect(store.customResourceStatusForTesting(for: key) == .ready)
        #expect(store.customReadyViewControllerForTesting(for: key) === content)
        #expect(firstHost.phase == .ready)
        #expect(secondHost.phase == .ready)
        #expect(firstHost.readyViewControllerForTesting == nil)
        #expect(secondHost.readyViewControllerForTesting === content)
        #expect(content.parent === secondHost)

        let replacementHost = store.customViewController(
            for: key,
            session: session,
            makeViewController: make
        )
        #expect(factoryCallCount == 1)
        #expect(replacementHost.readyViewControllerForTesting === content)
        #expect(content.parent === replacementHost)

        await store.clear()
    }

    @Test
    func failureRendersRetryAndRetryPublishesReadyContent() async {
        let key = WebInspectorTab.ContentKey(tabID: "failing", contentID: "root")
        let session = WebInspectorSession(tabs: [])
        let store = PresentationContentStore()
        let content = UIViewController()
        var factoryCallCount = 0
        let make: @MainActor (WebInspectorSession) async throws -> UIViewController = { _ in
            factoryCallCount += 1
            if factoryCallCount == 1 {
                throw FactoryFailure()
            }
            return content
        }

        let host = store.customViewController(
            for: key,
            session: session,
            makeViewController: make
        )
        await store.waitForCustomResourceTaskForTesting(for: key)

        #expect(host.phase == .failed("Custom tab bootstrap failed."))
        #expect(
            store.customResourceStatusForTesting(for: key)
                == .failed("Custom tab bootstrap failed.")
        )
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
    func factoryTaskDoesNotRetainStoreAndLateCompletionCannotPublish() async throws {
        let key = WebInspectorTab.ContentKey(tabID: "lifecycle", contentID: "root")
        let started = WebInspectorTestGate()
        let release = WebInspectorTestGate()
        let finished = WebInspectorTestGate()
        let session = WebInspectorSession(tabs: [])
        var store: PresentationContentStore? = PresentationContentStore()
        weak let weakStore = store
        let host = try #require(store).customViewController(
            for: key,
            session: session
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
    func sessionConfigurationUnionsTabAndAdditionalDomains() {
        let console = WebInspectorTab(
            id: "console",
            title: "Console",
            requiredDomains: [.console, .css]
        ) { _ in
            UIViewController()
        }
        let session = WebInspectorSession(
            tabs: [.network, console],
            additionalDomains: [.runtime]
        )

        #expect(
            session.model.configuredDomains
                == [.network, .console, .css, .dom, .runtime]
        )
    }
}
#endif
