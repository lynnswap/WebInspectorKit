#if canImport(UIKit)
import ObservationBridge
import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport
import UIKit
@testable import WebInspectorUI
@testable import WebInspectorUISyntaxBody
@testable import WebInspectorUINetwork
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct ParentContainerTests {
    private struct AttachmentFailure: Error {}

    private struct NetworkResourceFailure: LocalizedError {
        var errorDescription: String? {
            "Network bootstrap failed."
        }
    }

    @Test
    func sessionAndViewControllerUseDOMAndNetworkTabsByDefault() {
        let session = WebInspectorSession()
        let viewController = WebInspectorViewController()

        #expect(session.interface.tabs.map(\.id) == [WebInspectorTab.dom.id, WebInspectorTab.network.id])
        #expect(viewController.session.interface.tabs.map(\.id) == [WebInspectorTab.dom.id, WebInspectorTab.network.id])
        #expect(session.pageUserInterfaceStyle == .unspecified)
        if #available(iOS 26.0, *) {
            #expect(viewController.drawsBackground)
        }
    }

    @Test
    func pageUserInterfaceStyleUsesWebKitLightnessThreshold() {
        let traits = UITraitCollection(userInterfaceStyle: .light)

        #expect(WebInspectorPageUserInterfaceStyle.style(for: .white, in: traits) == .light)
        #expect(WebInspectorPageUserInterfaceStyle.style(for: .black, in: traits) == .dark)
        #expect(WebInspectorPageUserInterfaceStyle.style(for: .clear, in: traits) == .unspecified)
        #expect(WebInspectorPageUserInterfaceStyle.style(for: nil, in: traits) == .unspecified)
    }

    @Test
    func pageUserInterfaceStyleResolvesDynamicColorsWithWebViewTraits() {
        let dynamicColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .white
        }

        #expect(
            WebInspectorPageUserInterfaceStyle.style(
                for: dynamicColor,
                in: UITraitCollection(userInterfaceStyle: .light)
            ) == .light
        )
        #expect(
            WebInspectorPageUserInterfaceStyle.style(
                for: dynamicColor,
                in: UITraitCollection(userInterfaceStyle: .dark)
            ) == .dark
        )
    }

    @Test
    func sessionUpdatesPageUserInterfaceStyleFromPageObserver() async throws {
        let observerRecorder = PageUserInterfaceStyleObserverRecorder(styleOnStart: .dark)
        let session = makeSessionWithNoOpAttachment()

        try await attach(
            session,
            makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
        )
        let styleObservation = await observePageUserInterfaceStyle(in: session)
        defer { styleObservation.cancel() }

        #expect(await styleObservation.values.waitUntilValue(UIUserInterfaceStyle.dark.rawValue))

        let observer = try #require(observerRecorder.observers.first)
        observer.publish(.light)
        #expect(await styleObservation.values.waitUntilValue(UIUserInterfaceStyle.light.rawValue))
    }

    @Test
    func sessionClearsPageUserInterfaceStyleAndStopsObservingOnDetach() async throws {
        let observerRecorder = PageUserInterfaceStyleObserverRecorder(styleOnStart: .dark)
        let session = makeSessionWithNoOpAttachment()

        try await attach(
            session,
            makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
        )
        let observer = try #require(observerRecorder.observers.first)
        #expect(observer.isStarted)
        #expect(session.pageUserInterfaceStyle == .dark)

        await session.detach()

        #expect(observer.isInvalidated)
        #expect(session.hasPageUserInterfaceStyleObserverForTesting == false)
        #expect(session.pageUserInterfaceStyle == .unspecified)
        observer.publish(.light)
        #expect(session.pageUserInterfaceStyle == .unspecified)
    }

    @Test
    func sessionClearsPageUserInterfaceStyleAndStopsObservingWhenAttachFails() async throws {
        let observerRecorder = PageUserInterfaceStyleObserverRecorder(styleOnStart: .dark)
        let session = makeSessionWithNoOpAttachment()

        try await attach(
            session,
            makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
        )
        let observer = try #require(observerRecorder.observers.first)
        #expect(observer.isStarted)
        #expect(session.pageUserInterfaceStyle == .dark)

        do {
            try await attach(
                session,
                perform: {
                    throw AttachmentFailure()
                },
                makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
            )
            Issue.record("Expected attach to fail")
        } catch {
            #expect(error is AttachmentFailure)
        }

        #expect(observerRecorder.observers.count == 1)
        #expect(observer.isInvalidated)
        #expect(session.hasPageUserInterfaceStyleObserverForTesting == false)
        #expect(session.pageUserInterfaceStyle == .unspecified)
        observer.publish(.light)
        #expect(session.pageUserInterfaceStyle == .unspecified)
    }

    @Test
    func staleAttachCompletionDoesNotReplaceNewerAttach() async throws {
        let observerRecorder = PageUserInterfaceStyleObserverRecorder(styleOnStart: .dark)
        let session = makeSessionWithNoOpAttachment()
        let firstAttachStarted = WebInspectorTestGate()
        let firstAttachGate = WebInspectorTestGate()

        let firstAttach = Task { @MainActor in
            try await session.attachForTesting(
                makeContainer: { [self] in
                    firstAttachStarted.open()
                    await firstAttachGate.waiter.wait()
                    return try await makeFakeContainer()
                },
                makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
            )
        }
        await firstAttachStarted.waiter.wait()

        var secondContext: WebInspectorContext?
        try await session.attachForTesting(
            makeContainer: { [self] in
                let container = try await makeFakeContainer()
                secondContext = container.mainContext
                return container
            },
            makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
        )
        let installedSecondContext = try #require(secondContext)

        firstAttachGate.open()
        do {
            try await firstAttach.value
            Issue.record("Expected superseded attach to be cancelled.")
        } catch is CancellationError {
        }

        #expect(session.context === installedSecondContext)
        #expect(observerRecorder.observers.count == 1)
        #expect(observerRecorder.observers.first?.isStarted == true)
        #expect(observerRecorder.observers.first?.isInvalidated == false)
        #expect(session.pageUserInterfaceStyle == .dark)
    }

    @Test
    func detachInvalidatesInFlightAttachCompletion() async throws {
        let observerRecorder = PageUserInterfaceStyleObserverRecorder(styleOnStart: .dark)
        let session = makeSessionWithNoOpAttachment()
        let attachStarted = WebInspectorTestGate()
        let attachGate = WebInspectorTestGate()

        let attachTask = Task { @MainActor in
            try await session.attachForTesting(
                makeContainer: { [self] in
                    attachStarted.open()
                    await attachGate.waiter.wait()
                    return try await makeFakeContainer()
                },
                makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
            )
        }
        await attachStarted.waiter.wait()

        await session.detach()
        let detachedContext = session.context

        attachGate.open()
        do {
            try await attachTask.value
            Issue.record("Expected attach completion after detach to be cancelled.")
        } catch is CancellationError {
        }

        #expect(session.context === detachedContext)
        #expect(session.context.state == .detached)
        #expect(observerRecorder.observers.isEmpty)
        #expect(session.hasPageUserInterfaceStyleObserverForTesting == false)
        #expect(session.pageUserInterfaceStyle == .unspecified)
    }

    @Test
    func attachAdvancesContextEpochAndEvictsRootPresentationContent() async throws {
        let session = makeSessionWithNoOpAttachment()
        let viewController = WebInspectorViewController(session: session)
        let contentStore = viewController.presentationContentStoreForTesting
        let initialContextRevision = session.interface.contextBoundContentRevision
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .network,
            session: session,
            contentStore: contentStore,
            hostLayout: .regular
        )
        #expect(contentStore.contentCountForTesting > 0)

        var installedContext: WebInspectorContext?
        try await session.attachForTesting {
            let container = try await makeFakeContainer()
            installedContext = container.mainContext
            return container
        }

        let context = try #require(installedContext)
        #expect(session.context === context)
        #expect(session.interface.contextBoundContentRevision > initialContextRevision)
        contentStore.prepare(for: session.interface.contextBoundContentRevision)
        #expect(contentStore.contentCountForTesting == 0)
    }

    @Test
    func installingDataContextAdvancesContextEpochAndEvictsRootPresentationContent() {
        let session = makeSessionWithNoOpAttachment()
        let viewController = WebInspectorViewController(session: session)
        let contentStore = viewController.presentationContentStoreForTesting
        let initialContextRevision = session.interface.contextBoundContentRevision
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .network,
            session: session,
            contentStore: contentStore,
            hostLayout: .regular
        )
        #expect(contentStore.contentCountForTesting > 0)

        let context = makeContext()
        session.installDataContext(context)

        #expect(session.context === context)
        #expect(session.interface.contextBoundContentRevision > initialContextRevision)
        contentStore.prepare(for: session.interface.contextBoundContentRevision)
        #expect(contentStore.contentCountForTesting == 0)
    }

    @Test
    func presentationContentStoreEvictsEntriesFromPreviousContextEpoch() {
        let contentStore = PresentationContentStore()
        let key = WebInspectorTab.ContentKey(tabID: "epoch-tab", contentID: "root")

        let first = contentStore.viewController(for: key, contextEpoch: 0) { UIViewController() }
        #expect(contentStore.viewController(for: key, contextEpoch: 0) { UIViewController() } === first)

        let second = contentStore.viewController(for: key, contextEpoch: 1) { UIViewController() }
        #expect(second !== first)
        #expect(contentStore.viewController(for: key, contextEpoch: 1) { UIViewController() } === second)
        #expect(contentStore.contentCountForTesting == 1)
    }

    @Test
    func networkResourceTransitionsFromNativeLoadingToReadyInPlace() async throws {
        let context = makeContext()
        let factoryStarted = WebInspectorTestGate()
        let factoryRelease = WebInspectorTestGate()
        let contentStore = PresentationContentStore { context in
            factoryStarted.open()
            await factoryRelease.waiter.wait()
            return try await NetworkPanelModel.make(context: context)
        }
        let observation = withPortableContinuousObservation { _ in
            _ = contentStore.networkResourceRevision
        }
        let statuses = await observation.values {
            contentStore.networkResourceStatus
        }
        defer {
            statuses.cancel()
            observation.cancel()
        }

        let resourceViewController = contentStore.networkViewController(
            context: context,
            contextEpoch: 1
        ) { _ in
            UIViewController()
        }

        #expect(resourceViewController.phase == .loading)
        #expect(resourceViewController.readyViewControllerForTesting == nil)
        #expect(resourceViewController.contentUnavailableConfiguration != nil)
        #expect(contentStore.networkResourceStatus == .loading)

        await factoryStarted.waiter.wait()
        factoryRelease.open()
        await contentStore.waitForNetworkResourceTaskForTesting()

        #expect(await statuses.waitUntilValue(.ready))
        #expect(resourceViewController.phase == .ready)
        #expect(resourceViewController.readyViewControllerForTesting != nil)
        #expect(resourceViewController.contentUnavailableConfiguration == nil)

        await contentStore.clear()
    }

    @Test
    func networkResourceWrappersAreHostOwnedWhileModelRetirementIsRootOwned() async throws {
        let context = makeContext()
        let contentStore = PresentationContentStore()
        let firstResourceViewController = contentStore.networkViewController(
            context: context,
            contextEpoch: 1
        ) { _ in
            UIViewController()
        }
        await contentStore.waitForNetworkResourceTaskForTesting()
        let model = try #require(contentStore.networkPanelModelForTesting)

        let secondResourceViewController = contentStore.networkViewController(
            context: context,
            contextEpoch: 1
        ) { _ in
            UIViewController()
        }

        #expect(secondResourceViewController !== firstResourceViewController)
        #expect(firstResourceViewController.phase == .ready)
        #expect(secondResourceViewController.phase == .ready)
        #expect(contentStore.networkPanelModelForTesting === model)
        #expect(model.isRetiredForTesting == false)

        await contentStore.clear()

        #expect(model.isRetiredForTesting)
        #expect(contentStore.networkResourceStatus == .idle)
        #expect(firstResourceViewController.phase == .loading)
        #expect(secondResourceViewController.phase == .loading)
        #expect(firstResourceViewController.readyViewControllerForTesting == nil)
        #expect(secondResourceViewController.readyViewControllerForTesting == nil)
    }

    @Test
    func contextReplacementRejectsLateNetworkModelBeforePublishingNewReadyState() async throws {
        let firstContext = makeContext()
        let secondContext = makeContext()
        let firstFactoryStarted = WebInspectorTestGate()
        let firstFactoryRelease = WebInspectorTestGate()
        let secondFactoryStarted = WebInspectorTestGate()
        let secondFactoryRelease = WebInspectorTestGate()
        var firstModel: NetworkPanelModel?
        let contentStore = PresentationContentStore { context in
            let model = try await NetworkPanelModel.make(context: context)
            if context === firstContext {
                firstModel = model
                firstFactoryStarted.open()
                await firstFactoryRelease.waiter.wait()
            } else {
                #expect(context === secondContext)
                secondFactoryStarted.open()
                await secondFactoryRelease.waiter.wait()
            }
            return model
        }

        let firstResourceViewController = contentStore.networkViewController(
            context: firstContext,
            contextEpoch: 1
        ) { _ in
            UIViewController()
        }
        await firstFactoryStarted.waiter.wait()
        let withheldFirstModel = try #require(firstModel)

        let secondResourceViewController = contentStore.networkViewController(
            context: secondContext,
            contextEpoch: 2
        ) { _ in
            UIViewController()
        }

        #expect(firstResourceViewController.phase == .loading)
        #expect(secondResourceViewController.phase == .loading)
        #expect(contentStore.contextEpoch == 2)

        firstFactoryRelease.open()
        await secondFactoryStarted.waiter.wait()

        #expect(withheldFirstModel.isRetiredForTesting)
        #expect(contentStore.networkResourceStatus == .loading)
        #expect(secondResourceViewController.readyViewControllerForTesting == nil)

        secondFactoryRelease.open()
        await contentStore.waitForNetworkResourceTaskForTesting()

        let secondModel = try #require(contentStore.networkPanelModelForTesting)
        #expect(secondModel.context === secondContext)
        #expect(secondResourceViewController.phase == .ready)
        #expect(firstResourceViewController.phase == .loading)

        await contentStore.clear()
    }

    @Test
    func networkResourceFailureReplacesLoadingWithoutCreatingPlaceholderContent() async {
        let context = makeContext()
        let contentStore = PresentationContentStore { _ in
            throw NetworkResourceFailure()
        }
        let resourceViewController = contentStore.networkViewController(
            context: context,
            contextEpoch: 1
        ) { _ in
            Issue.record("A failed Network resource must not create ready content.")
            return UIViewController()
        }

        #expect(resourceViewController.phase == .loading)
        #expect(resourceViewController.readyViewControllerForTesting == nil)

        await contentStore.waitForNetworkResourceTaskForTesting()

        #expect(contentStore.networkResourceStatus == .failed("Network bootstrap failed."))
        #expect(resourceViewController.phase == .failed("Network bootstrap failed."))
        #expect(resourceViewController.readyViewControllerForTesting == nil)
        #expect(
            (resourceViewController.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?
                .secondaryText
                == "Network bootstrap failed."
        )

        await contentStore.clear()
    }

    @Test
    func networkResourceLoadDoesNotRetainStore() async throws {
        let context = makeContext()
        let factoryStarted = WebInspectorTestGate()
        let factoryRelease = WebInspectorTestGate()
        var contentStore: PresentationContentStore? = PresentationContentStore { context in
            let model = try await NetworkPanelModel.make(context: context)
            factoryStarted.open()
            await factoryRelease.waiter.wait()
            return model
        }
        weak var retainedStore = contentStore
        let resourceViewController = try #require(contentStore).networkViewController(
            context: context,
            contextEpoch: 1
        ) { _ in
            UIViewController()
        }
        await factoryStarted.waiter.wait()

        contentStore = nil

        #expect(retainedStore == nil)
        #expect(resourceViewController.phase == .loading)

        factoryRelease.open()
        #expect(resourceViewController.readyViewControllerForTesting == nil)
    }

    @Test
    func networkResourceStoreDeinitSynchronouslyRetiresReadyBackstop() async throws {
        let context = makeContext()
        var contentStore: PresentationContentStore? = PresentationContentStore()
        weak var retainedStore = contentStore
        let resourceViewController = try #require(contentStore).networkViewController(
            context: context,
            contextEpoch: 1
        ) { _ in
            UIViewController()
        }
        await contentStore?.waitForNetworkResourceTaskForTesting()
        let model = try #require(contentStore?.networkPanelModelForTesting)

        #expect(resourceViewController.phase == .ready)
        #expect(model.isRetiredForTesting == false)

        contentStore = nil

        #expect(retainedStore == nil)
        #expect(model.isRetiredForTesting)
        #expect(resourceViewController.phase == .loading)
        #expect(resourceViewController.readyViewControllerForTesting == nil)
    }

    @Test
    func representationBeforeDeferredRetirementKeepsContentAndSkipsDetach() async throws {
        let session = makeSessionWithNoOpAttachment()
        let viewController = WebInspectorViewController(session: session)
        let contentStore = viewController.presentationContentStoreForTesting
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        viewController.loadViewIfNeeded()
        #expect(contentStore.contentCountForTesting > 0)

        let retirementBaseline = viewController.rootPresentationRetirementTaskCompletionCountForTesting
        viewController.finishRootPresentationLifecycleForTesting()
        // Begin the next presentation before the deferred retirement task runs.
        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()

        #expect(await viewController.waitForRootPresentationRetirementTaskCompletionForTesting(after: retirementBaseline))

        #expect(session.detachCountForTesting == 0)
        #expect(contentStore.contentCountForTesting > 0)
    }

    @Test
    func compactHostRebuildsActiveTabsWhenDataContextChanges() async throws {
        let session = makeSessionWithNoOpAttachment()
        let viewController = WebInspectorViewController(session: session)
        viewController.horizontalSizeClassOverrideForTesting = .compact
        viewController.loadViewIfNeeded()
        let compactHost = try #require(viewController.activeHostViewControllerForTesting as? CompactTabBarController)
        let initialTabs = compactHost.currentUITabsForTesting
        let initialTabIdentities = initialTabs.map(ObjectIdentifier.init)
        #expect(initialTabs.isEmpty == false)

        session.installDataContext(makeContext())

        let didRebuildTabs = await waitUntilCompactHostRendered(in: compactHost) {
            let rebuiltTabs = compactHost.currentUITabsForTesting
            return rebuiltTabs.count == initialTabs.count
                && rebuiltTabs.map(ObjectIdentifier.init) != initialTabIdentities
        }
        #expect(didRebuildTabs)
    }

    @Test
    func regularHostRebuildsVisibleContentWhenDataContextChanges() async throws {
        let session = makeSessionWithNoOpAttachment()
        let viewController = WebInspectorViewController(session: session)
        viewController.horizontalSizeClassOverrideForTesting = .regular
        viewController.loadViewIfNeeded()
        let regularHost = try #require(
            viewController.activeHostViewControllerForTesting as? RegularTabContentViewController
        )
        let initialRootViewController = try #require(regularHost.viewControllers.first)

        session.installDataContext(makeContext())

        let didRebuildContent = await waitUntilRegularHostRendered(in: regularHost) {
            guard let currentRootViewController = regularHost.viewControllers.first else {
                return false
            }
            return currentRootViewController !== initialRootViewController
        }
        #expect(didRebuildContent)
    }

    @Test
    func viewControllerDoesNotApplyPageUserInterfaceStyle() async throws {
        let observerRecorder = PageUserInterfaceStyleObserverRecorder(styleOnStart: .dark)
        let session = makeSessionWithNoOpAttachment()
        let viewController = WebInspectorViewController(session: session)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        try await attach(
            session,
            makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
        )

        #expect(session.pageUserInterfaceStyle == .dark)
        #expect(viewController.overrideUserInterfaceStyle == .unspecified)
    }

    @Test
    func viewControllerBackgroundDrawingDefaultsToSystemBackground() {
        let viewController = WebInspectorViewController()

        viewController.loadViewIfNeeded()

        if #available(iOS 26.0, *) {
            #expect(viewController.drawsBackground)
        }
        #expect(viewController.view.backgroundColor == .systemBackground)
    }

    @Test
    func viewControllerCanDisableBackgroundDrawingAfterInitialization() {
        guard #available(iOS 26.0, *) else {
            return
        }

        let viewController = WebInspectorViewController(session: WebInspectorSession())
        viewController.drawsBackground = false
        viewController.loadViewIfNeeded()

        #expect(viewController.drawsBackground == false)
        #expect(viewController.view.backgroundColor == .clear)
    }

    @Test
    func tabsInitializerKeepsBackgroundDrawingEnabledByDefault() {
        let viewController = WebInspectorViewController(tabs: [.network])

        viewController.loadViewIfNeeded()

        if #available(iOS 26.0, *) {
            #expect(viewController.drawsBackground)
        }
        #expect(viewController.session.interface.tabs.map(\.id) == [WebInspectorTab.network.id])
        #expect(viewController.view.backgroundColor == .systemBackground)
    }

    @Test
    func viewControllerPreviewSessionInjectsMockDOMAndNetworkModels() async throws {
        let session = WebInspectorViewControllerPreviewFixtures.makeSession()
        let model = try await NetworkPanelModel.make(context: session.context)

        #expect(session.context.rootNode?.nodeName == "#document")
        #expect(model.displayRequests.count >= 2)
    }

    @Test
    func displayProjectionKeepsCompactElementTabAndRegularCombinedDOM() {
        let tabs: [WebInspectorTab] = [.dom, .network]
        let projection = WebInspectorTab.DisplayProjection()

        #expect(
            projection.displayItems(for: .compact, tabs: tabs).map(\.id)
                == [WebInspectorTab.dom.id, WebInspectorTab.DisplayItem.domElementID, WebInspectorTab.network.id]
        )
        #expect(
            projection.displayItems(for: .regular, tabs: tabs).map(\.id)
                == [WebInspectorTab.dom.id, WebInspectorTab.network.id]
        )
    }

    @Test
    func customTabUsesPublicDescriptorAndCachedViewControllerFactory() throws {
        let customViewController = UIViewController()
        var factoryCallCount = 0
        var factorySession: WebInspectorSession?
        let customTab = WebInspectorTab(
            id: "webinspector_custom_console",
            title: "Console",
            systemImage: "terminal"
        ) { session in
            factoryCallCount += 1
            factorySession = session
            return customViewController
        }
        let session = WebInspectorSession(tabs: [.dom, customTab, .network])
        let contentStore = PresentationContentStore()
        let projection = WebInspectorTab.DisplayProjection()

        #expect(
            projection.displayItems(for: .compact, tabs: session.interface.tabs).map(\.id)
                == [
                    WebInspectorTab.dom.id,
                    WebInspectorTab.DisplayItem.domElementID,
                    WebInspectorTab.DisplayItem.customTabID(customTab.id),
                    WebInspectorTab.network.id,
                ]
        )
        #expect(
            projection.displayItems(for: .regular, tabs: session.interface.tabs).map(\.id)
                == [
                    WebInspectorTab.dom.id,
                    WebInspectorTab.DisplayItem.customTabID(customTab.id),
                    WebInspectorTab.network.id,
                ]
        )
        #expect(
            projection.descriptor(
                for: .customTab(customTab.id),
                tabs: session.interface.tabs
            )?.title == "Console"
        )

        let compactContent = WebInspectorTab.ContentFactory.makeViewController(
            for: .customTab(customTab.id),
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        let regularContent = WebInspectorTab.ContentFactory.makeViewController(
            for: .customTab(customTab.id),
            session: session,
            contentStore: contentStore,
            hostLayout: .regular
        )
        regularContent.loadViewIfNeeded()
        #expect(regularContent !== customViewController)
        #expect(customViewController.parent === regularContent)

        let reparentedContent = WebInspectorTab.ContentFactory.makeViewController(
            for: .customTab(customTab.id),
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )

        #expect(compactContent === customViewController)
        #expect(reparentedContent === customViewController)
        #expect(reparentedContent.parent == nil)
        #expect(factorySession === session)
        #expect(factoryCallCount == 1)
    }

    @Test
    func rootContentStoreDoesNotCloseCycleThroughSessionRetainingCustomController() throws {
        weak var retainedRoot: WebInspectorViewController?
        weak var retainedStore: PresentationContentStore?
        weak var retainedCache: WebInspectorTab.ContentCache?
        weak var retainedSession: WebInspectorSession?
        weak var retainedContent: UIViewController?

        autoreleasepool {
            let customTab = WebInspectorTab(
                id: "webinspector_custom_retaining_session",
                title: "Retaining Session",
                image: nil
            ) { session in
                SessionRetainingViewController(session: session)
            }
            let session = WebInspectorSession(tabs: [customTab])
            let root = WebInspectorViewController(session: session)
            let contentStore = root.presentationContentStoreForTesting
            let content = WebInspectorTab.ContentFactory.makeViewController(
                for: .customTab(customTab.id),
                session: session,
                contentStore: contentStore,
                hostLayout: .compact
            )
            let retainingContent = try? #require(content as? SessionRetainingViewController)

            #expect(retainingContent?.session === session)
            retainedRoot = root
            retainedStore = contentStore
            retainedCache = contentStore.contentCacheForTesting
            retainedSession = session
            retainedContent = content
        }

        #expect(retainedRoot == nil)
        #expect(retainedStore == nil)
        #expect(retainedCache == nil)
        #expect(retainedSession == nil)
        #expect(retainedContent == nil)
    }

    @Test
    func presentationContentStoreDeinitDetachesExternallyRetainedCustomController() throws {
        let customViewController = UIViewController()
        let customTab = WebInspectorTab(
            id: "webinspector_custom_store_deinit",
            title: "Store Deinit",
            image: nil
        ) { _ in
            customViewController
        }
        let session = WebInspectorSession(tabs: [customTab])
        var contentStore: PresentationContentStore? = PresentationContentStore()
        weak let retainedStore = contentStore
        let regularContent = WebInspectorTab.ContentFactory.makeViewController(
            for: .customTab(customTab.id),
            session: session,
            contentStore: try #require(contentStore),
            hostLayout: .regular
        )
        regularContent.loadViewIfNeeded()
        #expect(customViewController.parent === regularContent)

        contentStore = nil

        #expect(retainedStore == nil)
        #expect(customViewController.parent == nil)
    }

    @Test
    func customTabDisplayItemDoesNotCollideWithInternalDOMElementIdentifier() throws {
        let customViewController = UIViewController()
        let customTab = WebInspectorTab(
            id: WebInspectorTab.DisplayItem.domElementID,
            title: "Custom Element",
            image: nil
        ) { _ in
            customViewController
        }
        let session = WebInspectorSession(tabs: [.dom, customTab])
        let contentStore = PresentationContentStore()
        let projection = WebInspectorTab.DisplayProjection()
        let compactDisplayItems = projection.displayItems(for: .compact, tabs: session.interface.tabs)
        let displayItemIDs = compactDisplayItems.map(\.id)
        let customDisplayID = WebInspectorTab.DisplayItem.customTabID(customTab.id)

        #expect(
            displayItemIDs == [
                WebInspectorTab.dom.id,
                WebInspectorTab.DisplayItem.domElementID,
                customDisplayID,
            ]
        )
        #expect(Set(displayItemIDs).count == displayItemIDs.count)

        let initiallySelectedCustomSession = WebInspectorSession(tabs: [customTab, .dom])
        #expect(initiallySelectedCustomSession.interface.selectedItemID == customDisplayID)
        #expect(initiallySelectedCustomSession.interface.resolvedSelection(for: .compact) == .customTab(customTab.id))
        #expect(initiallySelectedCustomSession.interface.selectedTab == customTab)

        session.interface.selectItem(withID: customDisplayID)

        #expect(session.interface.resolvedSelection(for: .compact) == .customTab(customTab.id))
        #expect(session.interface.selectedTab == customTab)

        let customContent = WebInspectorTab.ContentFactory.makeViewController(
            for: .customTab(customTab.id),
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        #expect(customContent === customViewController)
    }

    @Test
    func regularCustomTabWrapsNavigationControllerContent() throws {
        let customRootViewController = UIViewController()
        let customNavigationController = UINavigationController(rootViewController: customRootViewController)
        let customTab = WebInspectorTab(
            id: "webinspector_custom_navigation",
            title: "Custom",
            image: nil
        ) { _ in
            customNavigationController
        }
        let session = WebInspectorSession(tabs: [customTab])
        let host = RegularTabContentViewController(
            session: session,
            contentStore: PresentationContentStore()
        )

        host.loadViewIfNeeded()

        let installedRoot = try #require(host.viewControllers.first)
        installedRoot.loadViewIfNeeded()
        #expect(installedRoot !== customNavigationController)
        #expect(installedRoot is UINavigationController == false)
        #expect(customNavigationController.parent === installedRoot)
    }

    @Test
    func compactAndRegularHostsDisplayCustomTabs() throws {
        let customTab = WebInspectorTab(
            id: "webinspector_custom_console",
            title: "Console",
            systemImage: "terminal"
        ) { _ in
            UIViewController()
        }
        let session = WebInspectorSession(tabs: [.dom, customTab])
        let contentStore = PresentationContentStore()

        let compactHost = CompactTabBarController(
            session: session,
            contentStore: contentStore
        )
        #expect(
            compactHost.displayedTabIdentifiersForTesting
                == [
                    WebInspectorTab.dom.id,
                    WebInspectorTab.DisplayItem.domElementID,
                    WebInspectorTab.DisplayItem.customTabID(customTab.id),
                ]
        )

        let regularHost = RegularTabContentViewController(
            session: session,
            contentStore: contentStore
        )
        regularHost.loadViewIfNeeded()
        let segmentedControl = regularHost.segmentedControlForTesting

        #expect(segmentedControl.numberOfSegments == 2)
        #expect(segmentedControl.titleForSegment(at: 0) == "DOM")
        #expect(segmentedControl.titleForSegment(at: 1) == "Console")
    }

    @Test
    func topLevelContainerSwitchesBetweenCompactAndRegularHosts() throws {
        let viewController = WebInspectorViewController()
        viewController.loadViewIfNeeded()

        viewController.horizontalSizeClassOverrideForTesting = .compact
        #expect(viewController.activeHostViewControllerForTesting is CompactTabBarController)

        viewController.horizontalSizeClassOverrideForTesting = .regular
        #expect(viewController.activeHostViewControllerForTesting is RegularTabContentViewController)
    }

    @Test
    func programmaticDismissAutomaticallyDetachesOnce() async throws {
        let session = makeSessionWithNoOpAttachment()
        let presenter = UIViewController()
        let viewController = WebInspectorViewController(session: session)
        let window = showInWindow(presenter)
        defer { window.isHidden = true }

        presenter.present(viewController, animated: false)
        #expect(presenter.presentedViewController === viewController)

        viewController.dismiss(animated: false)
        #expect(await waitUntilDetachCount(1, in: session))

        viewController.finishRootPresentationLifecycleForTesting()
        #expect(session.detachCountForTesting == 1)
    }

    @Test
    func rootPresentationFallbacksDetachOnlyOnce() async throws {
        let session = makeSessionWithNoOpAttachment()
        let viewController = WebInspectorViewController(session: session)
        let contentStore = viewController.presentationContentStoreForTesting
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        viewController.loadViewIfNeeded()
        #expect(contentStore.contentCountForTesting > 0)
        let contentRevisionBeforeRetirement = session.interface.contextBoundContentRevision

        viewController.finishRootPresentationLifecycleForTesting()
        #expect(await waitUntilDetachCount(1, in: session))
        viewController.finishRootPresentationLifecycleForTesting()

        #expect(session.detachCountForTesting == 1)
        #expect(contentStore.contentCountForTesting == 0)
        #expect(session.interface.contextBoundContentRevision > contentRevisionBeforeRetirement)
    }

    @Test
    func hiddenNavigationControllerRemovalFinishesRootPresentationLifecycle() async throws {
        let tab = makeNoOpTab(id: "webinspector_test_lifecycle_hidden")
        let session = makeSessionWithNoOpAttachment(tabs: [tab])
        let viewController = WebInspectorViewController(session: session)
        let contentStore = viewController.presentationContentStoreForTesting
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .customTab(tab.id),
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        let navigationController = UINavigationController(rootViewController: viewController)
        let window = showInWindow(navigationController)
        defer { window.isHidden = true }

        #expect(navigationController.view.window === window)
        #expect(contentStore.contentCountForTesting > 0)

        let coveringViewController = UIViewController()
        navigationController.pushViewController(coveringViewController, animated: false)
        #expect(navigationController.topViewController === coveringViewController)
        #expect(session.detachCountForTesting == 0)
        #expect(contentStore.contentCountForTesting > 0)

        window.rootViewController = UIViewController()
        window.layoutIfNeeded()
        #expect(navigationController.view.window == nil)
        #expect(await waitUntilDetachCount(1, in: session))
        #expect(contentStore.contentCountForTesting == 0)
    }

    @Test
    func directWindowRootRemovalFinishesRootPresentationLifecycle() async throws {
        let tab = makeNoOpTab(id: "webinspector_test_lifecycle_direct")
        let session = makeSessionWithNoOpAttachment(tabs: [tab])
        let viewController = WebInspectorViewController(session: session)
        let contentStore = viewController.presentationContentStoreForTesting
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .customTab(tab.id),
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(viewController.view.window === window)
        #expect(contentStore.contentCountForTesting > 0)

        window.rootViewController = UIViewController()
        window.layoutIfNeeded()

        #expect(viewController.view.window == nil)
        #expect(await waitUntilDetachCount(1, in: session))
        #expect(contentStore.contentCountForTesting == 0)
    }

    @Test
    func viewControllerDoesNotReplaceExternalPresentationControllerDelegate() async throws {
        let presenter = UIViewController()
        let viewController = WebInspectorViewController(session: makeSessionWithNoOpAttachment())
        let window = showInWindow(presenter)
        defer { window.isHidden = true }

        presenter.present(viewController, animated: false)
        #expect(presenter.presentedViewController === viewController)
        let presentationController = try #require(viewController.presentationController)
        let externalDelegate = PresentationDelegateRecorder()
        presentationController.delegate = externalDelegate

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()

        #expect(presentationController.delegate === externalDelegate)
    }

    @Test
    func interactiveDismissCancelDoesNotDetachOrDropContentCache() async throws {
        let session = makeSessionWithNoOpAttachment()
        let viewController = WebInspectorViewController(session: session)
        let contentStore = viewController.presentationContentStoreForTesting
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .network,
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        viewController.loadViewIfNeeded()
        let cacheCountBeforeCancel = contentStore.contentCountForTesting

        viewController.finishRootPresentationLifecycleForTesting(cancelled: true)

        #expect(session.detachCountForTesting == 0)
        #expect(viewController.hasFinishedRootPresentationLifecycleForTesting == false)
        #expect(contentStore.contentCountForTesting == cacheCountBeforeCancel)
    }

    @Test
    func hostReplacementAndCompactTabSwitchDoNotDetachRootSession() async throws {
        let session = makeSessionWithNoOpAttachment()
        let viewController = WebInspectorViewController(session: session)
        let window = showInWindow(viewController, useUIKitVisibility: false)
        defer { window.isHidden = true }

        viewController.horizontalSizeClassOverrideForTesting = .compact
        let compactHost = try #require(viewController.activeHostViewControllerForTesting as? CompactTabBarController)
        compactHost.loadViewIfNeeded()
        session.interface.selectItem(withID: WebInspectorTab.DisplayItem.domElementID)
        #expect(await waitUntilCompactHostRendered(in: compactHost) {
            compactHost.selectedDisplayItemIDForTesting == WebInspectorTab.DisplayItem.domElementID
        })
        viewController.horizontalSizeClassOverrideForTesting = .regular
        #expect(viewController.activeHostViewControllerForTesting is RegularTabContentViewController)

        #expect(session.detachCountForTesting == 0)
        #expect(viewController.hasFinishedRootPresentationLifecycleForTesting == false)
    }

    @Test
    func rootDismissDropsContentCacheWithoutAutomaticDetach() async throws {
        let session = makeSessionWithNoOpAttachment()
        let viewController = WebInspectorViewController(session: session)
        let contentStore = viewController.presentationContentStoreForTesting
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .network,
            session: session,
            contentStore: contentStore,
            hostLayout: .regular
        )
        viewController.automaticallyDetachesOnDismiss = false
        viewController.loadViewIfNeeded()
        #expect(contentStore.contentCountForTesting > 0)
        let contentRevisionBeforeRetirement = session.interface.contextBoundContentRevision

        let retirementBaseline = viewController.rootPresentationRetirementTaskCompletionCountForTesting
        viewController.finishRootPresentationLifecycleForTesting()
        #expect(await viewController.waitForRootPresentationRetirementTaskCompletionForTesting(after: retirementBaseline))

        #expect(session.detachCountForTesting == 0)
        #expect(contentStore.contentCountForTesting == 0)
        #expect(session.interface.contextBoundContentRevision == contentRevisionBeforeRetirement)
    }

    @Test
    func topLevelContainerPropagatesBackgroundDrawingTraitToHosts() throws {
        guard #available(iOS 26.0, *) else {
            return
        }

        let viewController = WebInspectorViewController()
        viewController.drawsBackground = false
        viewController.loadViewIfNeeded()

        viewController.horizontalSizeClassOverrideForTesting = .compact
        let compactHost = try #require(viewController.activeHostViewControllerForTesting as? CompactTabBarController)
        compactHost.loadViewIfNeeded()
        #expect(compactHost.view.backgroundColor == .clear)

        viewController.drawsBackground = true
        viewController.horizontalSizeClassOverrideForTesting = .regular
        let regularHost = try #require(viewController.activeHostViewControllerForTesting as? RegularTabContentViewController)
        regularHost.loadViewIfNeeded()
        #expect(regularHost.view.backgroundColor == .systemBackground)
    }

    @Test
    func compactHostDisplaysDOMElementAndNetworkTabs() {
        let session = WebInspectorSession()
        let host = CompactTabBarController(
            session: session,
            contentStore: PresentationContentStore()
        )

        #expect(
            host.displayedTabIdentifiersForTesting
                == [WebInspectorTab.dom.id, WebInspectorTab.DisplayItem.domElementID, WebInspectorTab.network.id]
        )
    }

    @Test
    func compactFactoryUsesDomainNavigationControllers() async throws {
        let session = WebInspectorSession(context: makeContext())
        let contentStore = PresentationContentStore()

        let domViewController = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        let domNavigationController = try #require(domViewController as? DOMCompactNavigationController)
        #expect(domNavigationController.viewControllers.first is DOMTreeViewController)

        let elementViewController = WebInspectorTab.ContentFactory.makeViewController(
            for: .domElement(parent: WebInspectorTab.dom.id),
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        let elementNavigationController = try #require(elementViewController as? DOMCompactNavigationController)
        #expect(elementNavigationController.viewControllers.first is DOMElementViewController)

        let networkResourceViewController = try #require(
            WebInspectorTab.ContentFactory.makeViewController(
                for: .network,
                session: session,
                contentStore: contentStore,
                hostLayout: .compact
            ) as? NetworkTabResourceViewController
        )
        await contentStore.waitForNetworkResourceTaskForTesting()
        let networkNavigationController = try #require(
            networkResourceViewController.readyViewControllerForTesting
                as? NetworkCompactNavigationController
        )
        #expect(networkNavigationController.viewControllers.first is NetworkListViewController)
    }

    @Test
    func regularHostWrapsDomainSplitControllersBeforeInstallingInNavigationStack() throws {
        let session = WebInspectorSession()
        let host = RegularTabContentViewController(
            session: session,
            contentStore: PresentationContentStore()
        )

        host.loadViewIfNeeded()

        let rootViewController = try #require(host.viewControllers.first)
        rootViewController.loadViewIfNeeded()

        #expect(rootViewController is UISplitViewController == false)
        #expect(rootViewController.children.contains { $0 is DOMSplitViewController })
        #expect(rootViewController.navigationItem.centerItemGroups.isEmpty == false)
        #expect(
            rootViewController.navigationItem.trailingItemGroups
                .flatMap(\.barButtonItems)
                .contains { $0.accessibilityIdentifier == "WebInspector.DOM.PickButton" }
        )
    }

    @Test
    func cachedDOMTreeControllerIsSharedAcrossCompactAndRegularHosts() throws {
        let session = WebInspectorSession()
        let contentStore = PresentationContentStore()
        let compactViewController = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            contentStore: contentStore,
            hostLayout: .compact
        )
        let compactNavigationController = try #require(compactViewController as? DOMCompactNavigationController)
        let compactTreeViewController = try #require(
            compactNavigationController.viewControllers.first as? DOMTreeViewController
        )

        let regularRoot = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            contentStore: contentStore,
            hostLayout: .regular
        )
        regularRoot.loadViewIfNeeded()

        let splitViewController = try childViewController(
            ofType: DOMSplitViewController.self,
            in: regularRoot
        )
        let regularTreeViewController = try #require(
            splitRootViewController(
                ofType: DOMTreeViewController.self,
                in: splitViewController
            )
        )

        #expect(regularTreeViewController === compactTreeViewController)
    }

    @Test
    func networkPanelModelSelectionIsSharedAcrossParentHosts() async throws {
        let context = makeContext()
        let session = WebInspectorSession(context: context)
        let contentStore = PresentationContentStore()
        let requestID = await applyRequest(
            to: context,
            requestID: "1",
            url: "https://example.com/app.js"
        )
        let request = try #require(context.registeredRequest(for: requestID))
        let compactResourceViewController = try #require(
            WebInspectorTab.ContentFactory.makeViewController(
                for: .network,
                session: session,
                contentStore: contentStore,
                hostLayout: .compact
            ) as? NetworkTabResourceViewController
        )
        await contentStore.waitForNetworkResourceTaskForTesting()
        let model = try #require(contentStore.networkPanelModelForTesting)
        let compactNavigationController = try #require(
            compactResourceViewController.readyViewControllerForTesting
                as? NetworkCompactNavigationController
        )
        let window = showInWindow(compactNavigationController, useUIKitVisibility: false)
        defer { window.isHidden = true }

        model.selectRequest(request)

        let didPushDetail = await waitUntilNetworkStackSynced(in: compactNavigationController) {
            compactNavigationController.viewControllers.last is NetworkDetailViewController
        }
        #expect(didPushDetail)

        let regularResourceViewController = try #require(
            WebInspectorTab.ContentFactory.makeViewController(
                for: .network,
                session: session,
                contentStore: contentStore,
                hostLayout: .regular
            ) as? NetworkTabResourceViewController
        )
        await contentStore.waitForNetworkResourceTaskForTesting()
        let regularRoot = try #require(
            regularResourceViewController.readyViewControllerForTesting
        )
        regularRoot.loadViewIfNeeded()
        let splitViewController = try childViewController(
            ofType: NetworkSplitViewController.self,
            in: regularRoot
        )
        let detailViewController = try #require(
            splitRootViewController(
                ofType: NetworkDetailViewController.self,
                in: splitViewController
            )
        )
        detailViewController.loadViewIfNeeded()

        let didRenderDetail = await waitUntilNetworkDetailRendered(in: detailViewController) {
            detailViewController.headersTextViewForTesting.renderedTextForTesting.contains("GET /app.js")
        }
        #expect(didRenderDetail)
    }

    private func childViewController<T: UIViewController>(
        ofType type: T.Type,
        in rootViewController: UIViewController
    ) throws -> T {
        try #require(rootViewController.children.first { $0 is T } as? T)
    }

    private func splitRootViewController<T: UIViewController>(
        ofType type: T.Type,
        in splitViewController: UISplitViewController
    ) -> T? {
        for column in splitColumns {
            guard let navigationController = splitViewController.viewController(for: column) as? UINavigationController,
                  let rootViewController = navigationController.viewControllers.first as? T else {
                continue
            }
            return rootViewController
        }
        return nil
    }

    private var splitColumns: [UISplitViewController.Column] {
        if #available(iOS 26.0, *) {
            [.primary, .supplementary, .secondary, .inspector]
        } else {
            [.primary, .supplementary, .secondary]
        }
    }

    private func makeContext() -> WebInspectorContext {
        WebInspectorContext.preview(isolation: MainActor.shared)
    }

    @discardableResult
    private func applyRequest(
        to context: WebInspectorContext,
        requestID rawRequestID: String,
        url: String
    ) async -> WebInspectorDataKit.NetworkRequest.ID {
        let requestID = WebInspectorProxyKit.Network.Request.ID(rawRequestID)
        await context.apply(
            .requestWillBeSent(
                id: requestID,
                request: WebInspectorProxyKit.Network.Request(
                    id: requestID,
                    url: url,
                    method: "GET"
                ),
                resourceType: .script,
                redirectResponse: nil,
                timestamp: 1
            )
        )
        await context.apply(
            .responseReceived(
                id: requestID,
                response: WebInspectorProxyKit.Network.Response(
                    url: url,
                    status: 200,
                    statusText: "OK",
                    mimeType: "text/javascript",
                    headers: ["content-type": "text/javascript"]
                ),
                resourceType: .script,
                timestamp: 2
            )
        )
        await context.apply(
            .loadingFinished(
                id: requestID,
                timestamp: 3,
                sourceMapURL: nil,
                metrics: nil
            ),
        )
        return context.registeredRequest(forProxyID: requestID)!.id
    }

    private func showInWindow(
        _ viewController: UIViewController,
        useUIKitVisibility: Bool = true
    ) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        viewController.loadViewIfNeeded()
        viewController.view.frame = window.bounds
        if useUIKitVisibility {
            window.makeKeyAndVisible()
        } else {
            activateNetworkRenderingForTesting(in: viewController)
        }
        window.layoutIfNeeded()
        return window
    }

    private func activateNetworkRenderingForTesting(in viewController: UIViewController) {
        if let navigationController = viewController as? NetworkCompactNavigationController {
            navigationController.resumeSelectionObservationForTesting()
            for child in navigationController.viewControllers {
                activateNetworkRenderingForTesting(in: child)
            }
            return
        }

        if let navigationController = viewController as? UINavigationController {
            for child in navigationController.viewControllers {
                activateNetworkRenderingForTesting(in: child)
            }
            return
        }

        if let listViewController = viewController as? NetworkListViewController {
            listViewController.resumeRenderingForTesting()
        }

        if let detailViewController = viewController as? NetworkDetailViewController {
            detailViewController.resumeRenderingForTesting()
        }
    }

    private func makeFakeContainer() async throws -> WebInspectorContainer {
        let runtime = try await WebInspectorProxyTestRuntime.start()
        return WebInspectorContainer(proxy: runtime.proxy)
    }

    private func attach(
        _ session: WebInspectorSession,
        perform attachAction: @escaping @MainActor () async throws -> Void = {},
        makePageUserInterfaceStyleObserver: @escaping @MainActor (
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> (any WebInspectorPageUserInterfaceStyleObserving)? = { _ in nil }
    ) async throws {
        try await session.attachForTesting(
            makeContainer: { [self] in
                try await attachAction()
                return try await makeFakeContainer()
            },
            makePageUserInterfaceStyleObserver: makePageUserInterfaceStyleObserver
        )
    }

    private func makeSessionWithNoOpAttachment(
        tabs: [WebInspectorTab] = [.dom, .network]
    ) -> WebInspectorSession {
        WebInspectorSession(context: makeContext(), tabs: tabs)
    }

    private func makeNoOpTab(
        id: WebInspectorTab.ID = "webinspector_test_noop",
        title: String = "Test"
    ) -> WebInspectorTab {
        WebInspectorTab(id: id, title: title) { _ in
            UIViewController()
        }
    }

    @MainActor
    private final class PageUserInterfaceStyleObserverRecorder {
        private let styleOnStart: UIUserInterfaceStyle
        private(set) var observers: [PageUserInterfaceStyleObserverDouble] = []

        init(styleOnStart: UIUserInterfaceStyle) {
            self.styleOnStart = styleOnStart
        }

        func makeObserver(
            apply: @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> (any WebInspectorPageUserInterfaceStyleObserving)? {
            let observer = PageUserInterfaceStyleObserverDouble(
                styleOnStart: styleOnStart,
                apply: apply
            )
            observers.append(observer)
            return observer
        }
    }

    @MainActor
    private final class SessionRetainingViewController: UIViewController {
        let session: WebInspectorSession

        init(session: WebInspectorSession) {
            self.session = session
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }
    }

    @MainActor
    private final class PageUserInterfaceStyleObserverDouble: WebInspectorPageUserInterfaceStyleObserving {
        private let styleOnStart: UIUserInterfaceStyle
        private let apply: @MainActor (UIUserInterfaceStyle) -> Void
        private(set) var isStarted = false
        private(set) var isInvalidated = false

        init(
            styleOnStart: UIUserInterfaceStyle,
            apply: @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) {
            self.styleOnStart = styleOnStart
            self.apply = apply
        }

        func start() {
            guard isInvalidated == false else {
                return
            }
            isStarted = true
            publish(styleOnStart)
        }

        func invalidate() {
            isInvalidated = true
        }

        func publish(_ style: UIUserInterfaceStyle) {
            guard isInvalidated == false else {
                return
            }
            apply(style)
        }
    }

    private final class PresentationDelegateRecorder: NSObject, UIAdaptivePresentationControllerDelegate {}

    private struct PageUserInterfaceStyleObservation {
        var token: PortableObservationTracking.Token
        var values: ObservedValues<Int>

        func cancel() {
            values.cancel()
            token.cancel()
        }
    }

    private func observePageUserInterfaceStyle(
        in session: WebInspectorSession
    ) async -> PageUserInterfaceStyleObservation {
        let token = withPortableContinuousObservation { _ in
            _ = session.pageUserInterfaceStyle
        }
        let values = await token.values {
            session.pageUserInterfaceStyle.rawValue
        }
        return PageUserInterfaceStyleObservation(token: token, values: values)
    }

    private func waitUntilDetachCount(_ count: Int, in session: WebInspectorSession) async -> Bool {
        if session.detachCountForTesting >= count {
            return true
        }
        let token = withPortableContinuousObservation { _ in
            _ = session.detachCountForTesting
        }
        defer {
            token.cancel()
        }
        let values = await token.values {
            session.detachCountForTesting
        }
        defer {
            values.cancel()
        }
        if values.latestValue.map({ $0 >= count }) == true {
            return true
        }
        return await values.waitUntil { $0 >= count } != nil
    }

    private func waitUntilCompactHostRendered(
        in viewController: CompactTabBarController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        await waitForObservedCondition(
            deliveries: {
                [viewController.interfaceObservationDeliveryForTesting].compactMap { $0 }
            },
            sample: {
                condition()
            }
        )
    }

    private func waitUntilRegularHostRendered(
        in viewController: RegularTabContentViewController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        await waitForObservedCondition(
            deliveries: {
                [viewController.interfaceObservationDeliveryForTesting].compactMap { $0 }
            },
            sample: {
                condition()
            }
        )
    }

    private func waitUntilNetworkStackSynced(
        in navigationController: NetworkCompactNavigationController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        await waitForObservedCondition(
            deliveries: {
                [navigationController.selectionObservationDeliveryForTesting].compactMap { $0 }
            },
            sample: {
                if navigationController.view.window?.isHidden != false {
                    navigationController.syncStackForTesting()
                    for child in navigationController.viewControllers {
                        activateNetworkRenderingForTesting(in: child)
                    }
                }
                return condition()
            }
        )
    }

    private func waitUntilNetworkDetailRendered(
        in viewController: NetworkDetailViewController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        await waitForObservedCondition(
            deliveries: {
                [
                    viewController.modelObservationDeliveryForTesting,
                    viewController.selectedRequestRenderObservationDeliveryForTesting,
                    viewController.responseBodyFetchObservationDeliveryForTesting,
                    viewController.syntaxBodyViewControllerForTesting.bodyObservationDeliveryForTesting,
                    viewController.syntaxBodyViewControllerForTesting.previewRenderObservationDeliveryForTesting,
                ].compactMap { $0 }
            },
            sample: {
                viewController.view.layoutIfNeeded()
                return condition()
            }
        )
    }
}
}

@MainActor
private extension NetworkDetailViewController {
    var syntaxBodyViewControllerForTesting: NetworkBodyViewController {
        guard let viewController = bodyViewControllerForTesting as? NetworkBodyViewController else {
            preconditionFailure("Expected NetworkDetailViewController to use NetworkBodyViewController in tests.")
        }
        return viewController
    }
}
#endif
