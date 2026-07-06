#if canImport(UIKit)
import ObservationBridge
import Testing
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import UIKit
import WebKit
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
    func sessionUpdatesPageUserInterfaceStyleFromUnderPageBackgroundColor() async throws {
        let session = makeSessionWithNoOpAttachment()
        let webView = WKWebView(frame: .zero)

        try await attach(session, to: webView)
        let styleObservation = await observePageUserInterfaceStyle(in: session)
        defer { styleObservation.cancel() }

        webView.underPageBackgroundColor = .black

        #expect(await styleObservation.values.waitUntilValue(UIUserInterfaceStyle.dark.rawValue))

        webView.underPageBackgroundColor = .white
        #expect(await styleObservation.values.waitUntilValue(UIUserInterfaceStyle.light.rawValue))
    }

    @Test
    func sessionClearsPageUserInterfaceStyleAndStopsObservingOnDetach() async throws {
        let observerRecorder = PageUserInterfaceStyleObserverRecorder(styleOnStart: .dark)
        let session = makeSessionWithNoOpAttachment(
            makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
        )
        let webView = WKWebView(frame: .zero)

        try await attach(session, to: webView)
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
        let observedWebView = WKWebView(frame: .zero)
        let observedWebViewID = ObjectIdentifier(observedWebView)
        let observerRecorder = PageUserInterfaceStyleObserverRecorder(styleOnStart: .dark)
        let attachAction: @MainActor (WKWebView) async throws -> Void = { webView in
            if ObjectIdentifier(webView) != observedWebViewID {
                throw AttachmentFailure()
            }
        }
        let session = makeSessionWithNoOpAttachment(
            makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
        )

        try await attach(session, to: observedWebView, perform: attachAction)
        let observer = try #require(observerRecorder.observers.first)
        #expect(observer.isStarted)
        #expect(session.pageUserInterfaceStyle == .dark)

        do {
            try await attach(session, to: WKWebView(frame: .zero), perform: attachAction)
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
        let session = makeSessionWithNoOpAttachment(
            makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
        )
        let firstWebView = WKWebView(frame: .zero)
        let secondWebView = WKWebView(frame: .zero)
        let firstAttachStarted = WebInspectorTestGate()
        let firstAttachGate = WebInspectorTestGate()

        let firstAttach = Task { @MainActor in
            try await session.attach(to: firstWebView) { [self] _ in
                await firstAttachStarted.open()
                await firstAttachGate.wait()
                return try await makeFakeContainer()
            }
        }
        await firstAttachStarted.wait()

        var secondContext: WebInspectorContext?
        try await session.attach(to: secondWebView) { [self] _ in
            let container = try await makeFakeContainer()
            secondContext = container.mainContext
            return container
        }
        let installedSecondContext = try #require(secondContext)

        await firstAttachGate.open()
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
        let session = makeSessionWithNoOpAttachment(
            makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
        )
        let webView = WKWebView(frame: .zero)
        let attachStarted = WebInspectorTestGate()
        let attachGate = WebInspectorTestGate()

        let attachTask = Task { @MainActor in
            try await session.attach(to: webView) { [self] _ in
                await attachStarted.open()
                await attachGate.wait()
                return try await makeFakeContainer()
            }
        }
        await attachStarted.wait()

        await session.detach()
        let detachedContext = session.context

        await attachGate.open()
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
    func attachClearsCachedTabContentForPreviousContext() async throws {
        let session = makeSessionWithNoOpAttachment()
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        #expect(session.interface.contentCacheCountForTesting > 0)

        var installedContext: WebInspectorContext?
        try await session.attach(to: WKWebView(frame: .zero)) { [self] _ in
            let container = try await makeFakeContainer()
            installedContext = container.mainContext
            return container
        }

        let context = try #require(installedContext)
        #expect(session.context === context)
        #expect(session.interface.contentCacheCountForTesting == 0)
    }

    @Test
    func installingDataContextClearsCachedTabContent() {
        let session = makeSessionWithNoOpAttachment()
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        #expect(session.interface.contentCacheCountForTesting > 0)

        let context = makeContext()
        session.installDataContext(context)

        #expect(session.context === context)
        #expect(session.interface.contentCacheCountForTesting == 0)
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

        let didRebuildTabs = await waitUntil {
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

        let didRebuildContent = await waitUntil {
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
        let session = makeSessionWithNoOpAttachment(
            makePageUserInterfaceStyleObserver: observerRecorder.makeObserver
        )
        let viewController = WebInspectorViewController(session: session)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        let webView = WKWebView(frame: .zero)

        try await attach(session, to: webView)

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
    func viewControllerPreviewSessionInjectsMockDOMAndNetworkModels() throws {
        let session = WebInspectorViewControllerPreviewFixtures.makeSession()
        let model = session.interface.networkPanelModel(for: session.context)

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
            hostLayout: .compact,
            tabs: session.interface.tabs
        )
        let regularContent = WebInspectorTab.ContentFactory.makeViewController(
            for: .customTab(customTab.id),
            session: session,
            hostLayout: .regular,
            tabs: session.interface.tabs
        )
        regularContent.loadViewIfNeeded()
        #expect(regularContent !== customViewController)
        #expect(customViewController.parent === regularContent)

        let reparentedContent = WebInspectorTab.ContentFactory.makeViewController(
            for: .customTab(customTab.id),
            session: session,
            hostLayout: .compact,
            tabs: session.interface.tabs
        )

        #expect(compactContent === customViewController)
        #expect(reparentedContent === customViewController)
        #expect(reparentedContent.parent == nil)
        #expect(factorySession === session)
        #expect(factoryCallCount == 1)
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
            hostLayout: .compact,
            tabs: session.interface.tabs
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
        let host = RegularTabContentViewController(session: session)

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

        let compactHost = CompactTabBarController(session: session)
        #expect(
            compactHost.displayedTabIdentifiersForTesting
                == [
                    WebInspectorTab.dom.id,
                    WebInspectorTab.DisplayItem.domElementID,
                    WebInspectorTab.DisplayItem.customTabID(customTab.id),
                ]
        )

        let regularHost = RegularTabContentViewController(session: session)
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
        #expect(await waitUntil { presenter.presentedViewController === viewController })

        viewController.dismiss(animated: false)
        #expect(await waitUntil { session.detachCountForTesting == 1 })

        viewController.finishRootPresentationLifecycleForTesting()
        _ = await waitUntil { session.detachCountForTesting == 1 }
        #expect(session.detachCountForTesting == 1)
    }

    @Test
    func rootPresentationFallbacksDetachOnlyOnce() async throws {
        let session = makeSessionWithNoOpAttachment()
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let viewController = WebInspectorViewController(session: session)
        viewController.loadViewIfNeeded()
        #expect(session.interface.contentCacheCountForTesting > 0)
        let contentRevisionBeforeRetirement = session.interface.contextBoundContentRevision

        viewController.finishRootPresentationLifecycleForTesting()
        #expect(await waitUntil { session.detachCountForTesting == 1 })
        viewController.finishRootPresentationLifecycleForTesting()
        _ = await waitUntil { session.detachCountForTesting == 1 }

        #expect(session.detachCountForTesting == 1)
        #expect(session.interface.contentCacheCountForTesting == 0)
        #expect(session.interface.contextBoundContentRevision > contentRevisionBeforeRetirement)
    }

    @Test
    func hiddenNavigationControllerRemovalFinishesRootPresentationLifecycle() async throws {
        let session = makeSessionWithNoOpAttachment()
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let viewController = WebInspectorViewController(session: session)
        let navigationController = UINavigationController(rootViewController: viewController)
        let window = showInWindow(navigationController)
        defer { window.isHidden = true }

        #expect(navigationController.view.window === window)
        #expect(session.interface.contentCacheCountForTesting > 0)

        let coveringViewController = UIViewController()
        navigationController.pushViewController(coveringViewController, animated: false)
        #expect(await waitUntil { navigationController.topViewController === coveringViewController })
        #expect(session.detachCountForTesting == 0)
        #expect(session.interface.contentCacheCountForTesting > 0)

        window.rootViewController = UIViewController()
        window.layoutIfNeeded()
        #expect(navigationController.view.window == nil)
        #expect(await waitUntil { session.detachCountForTesting == 1 })
        #expect(session.interface.contentCacheCountForTesting == 0)
    }

    @Test
    func directWindowRootRemovalFinishesRootPresentationLifecycle() async throws {
        let session = makeSessionWithNoOpAttachment()
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let viewController = WebInspectorViewController(session: session)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(viewController.view.window === window)
        #expect(session.interface.contentCacheCountForTesting > 0)

        window.rootViewController = UIViewController()
        window.layoutIfNeeded()

        #expect(viewController.view.window == nil)
        #expect(await waitUntil { session.detachCountForTesting == 1 })
        #expect(session.interface.contentCacheCountForTesting == 0)
    }

    @Test
    func viewControllerDoesNotReplaceExternalPresentationControllerDelegate() async throws {
        let presenter = UIViewController()
        let viewController = WebInspectorViewController(session: makeSessionWithNoOpAttachment())
        let window = showInWindow(presenter)
        defer { window.isHidden = true }

        presenter.present(viewController, animated: false)
        #expect(await waitUntil { presenter.presentedViewController === viewController })
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
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .compact
        )
        let viewController = WebInspectorViewController(session: session)
        viewController.loadViewIfNeeded()
        let cacheCountBeforeCancel = session.interface.contentCacheCountForTesting

        viewController.finishRootPresentationLifecycleForTesting(cancelled: true)
        await Task.yield()

        #expect(session.detachCountForTesting == 0)
        #expect(viewController.hasFinishedRootPresentationLifecycleForTesting == false)
        #expect(session.interface.contentCacheCountForTesting == cacheCountBeforeCancel)
    }

    @Test
    func hostReplacementAndCompactTabSwitchDoNotDetachRootSession() async throws {
        let session = makeSessionWithNoOpAttachment()
        let viewController = WebInspectorViewController(session: session)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        viewController.horizontalSizeClassOverrideForTesting = .compact
        let compactHost = try #require(viewController.activeHostViewControllerForTesting as? CompactTabBarController)
        compactHost.loadViewIfNeeded()
        session.interface.selectItem(withID: WebInspectorTab.DisplayItem.domElementID)
        await Task.yield()
        viewController.horizontalSizeClassOverrideForTesting = .regular
        await Task.yield()

        #expect(session.detachCountForTesting == 0)
        #expect(viewController.hasFinishedRootPresentationLifecycleForTesting == false)
    }

    @Test
    func rootDismissDropsContentCacheWithoutAutomaticDetach() async throws {
        let session = makeSessionWithNoOpAttachment()
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        _ = WebInspectorTab.ContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
        )
        let viewController = WebInspectorViewController(session: session)
        viewController.automaticallyDetachesOnDismiss = false
        viewController.loadViewIfNeeded()
        #expect(session.interface.contentCacheCountForTesting > 0)
        let contentRevisionBeforeRetirement = session.interface.contextBoundContentRevision

        viewController.finishRootPresentationLifecycleForTesting()
        await Task.yield()

        #expect(session.detachCountForTesting == 0)
        #expect(session.interface.contentCacheCountForTesting == 0)
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
        let host = CompactTabBarController(session: session)

        #expect(
            host.displayedTabIdentifiersForTesting
                == [WebInspectorTab.dom.id, WebInspectorTab.DisplayItem.domElementID, WebInspectorTab.network.id]
        )
    }

    @Test
    func compactFactoryUsesDomainNavigationControllers() throws {
        let session = WebInspectorSession(context: makeContext())

        let domViewController = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let domNavigationController = try #require(domViewController as? DOMCompactNavigationController)
        #expect(domNavigationController.viewControllers.first is DOMTreeViewController)

        let elementViewController = WebInspectorTab.ContentFactory.makeViewController(
            for: .domElement(parent: WebInspectorTab.dom.id),
            session: session,
            hostLayout: .compact
        )
        let elementNavigationController = try #require(elementViewController as? DOMCompactNavigationController)
        #expect(elementNavigationController.viewControllers.first is DOMElementViewController)

        let networkViewController = WebInspectorTab.ContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .compact
        )
        let networkNavigationController = try #require(networkViewController as? NetworkCompactNavigationController)
        #expect(networkNavigationController.viewControllers.first is NetworkListViewController)
    }

    @Test
    func regularHostWrapsDomainSplitControllersBeforeInstallingInNavigationStack() throws {
        let session = WebInspectorSession()
        let host = RegularTabContentViewController(session: session)

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
        let compactViewController = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
            hostLayout: .compact
        )
        let compactNavigationController = try #require(compactViewController as? DOMCompactNavigationController)
        let compactTreeViewController = try #require(
            compactNavigationController.viewControllers.first as? DOMTreeViewController
        )

        let regularRoot = WebInspectorTab.ContentFactory.makeViewController(
            for: .dom,
            session: session,
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
        let requestID = applyRequest(
            to: context,
            requestID: "1",
            url: "https://example.com/app.js"
        )
        let request = try #require(context.registeredRequest(for: requestID))
        let model = session.interface.networkPanelModel(for: context)
        let compactNavigationController = try #require(
            WebInspectorTab.ContentFactory.makeViewController(
                for: .network,
                session: session,
                hostLayout: .compact
            ) as? NetworkCompactNavigationController
        )
        let window = showInWindow(compactNavigationController)
        defer { window.isHidden = true }

        model.selectRequest(request)

        let didPushDetail = await waitUntilNetworkStackSynced(in: compactNavigationController) {
            compactNavigationController.viewControllers.last is NetworkDetailViewController
        }
        #expect(didPushDetail)

        let regularRoot = WebInspectorTab.ContentFactory.makeViewController(
            for: .network,
            session: session,
            hostLayout: .regular
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
    ) -> WebInspectorDataKit.NetworkRequest.ID {
        let requestID = WebInspectorProxyKit.Network.Request.ID(rawRequestID)
        context.apply(
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
        context.apply(
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
        context.apply(
            .loadingFinished(
                id: requestID,
                timestamp: 3,
                sourceMapURL: nil,
                metrics: nil
            ),
        )
        return context.registeredRequest(forProxyID: requestID)!.id
    }

    private func showInWindow(_ viewController: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.loadViewIfNeeded()
        window.layoutIfNeeded()
        return window
    }

    private func makeFakeContainer() async throws -> WebInspectorContainer {
        let runtime = try await WebInspectorProxyTestRuntime.start()
        return WebInspectorContainer(proxy: runtime.proxy)
    }

    private func attach(
        _ session: WebInspectorSession,
        to webView: WKWebView,
        perform attachAction: @escaping @MainActor (WKWebView) async throws -> Void = { _ in }
    ) async throws {
        try await session.attach(to: webView) { [self] webView in
            try await attachAction(webView)
            return try await makeFakeContainer()
        }
    }

    private func makeSessionWithNoOpAttachment(
        makePageUserInterfaceStyleObserver: @escaping @MainActor (
            WKWebView,
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> any WebInspectorPageUserInterfaceStyleObserving = { webView, apply in
            WebInspectorPageUserInterfaceStyleObserver(webView: webView, apply: apply)
        }
    ) -> WebInspectorSession {
        WebInspectorSession(
            context: makeContext(),
            makePageUserInterfaceStyleObserver: makePageUserInterfaceStyleObserver
        )
    }

    @MainActor
    private final class PageUserInterfaceStyleObserverRecorder {
        private let styleOnStart: UIUserInterfaceStyle
        private(set) var observers: [PageUserInterfaceStyleObserverDouble] = []

        init(styleOnStart: UIUserInterfaceStyle) {
            self.styleOnStart = styleOnStart
        }

        func makeObserver(
            webView: WKWebView,
            apply: @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> any WebInspectorPageUserInterfaceStyleObserving {
            let observer = PageUserInterfaceStyleObserverDouble(
                styleOnStart: styleOnStart,
                apply: apply
            )
            observers.append(observer)
            return observer
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

    private func waitUntil(
        timeoutAttempts: Int = 50,
        predicate: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<timeoutAttempts {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

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

    private func waitUntilNetworkStackSynced(
        in navigationController: NetworkCompactNavigationController,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async -> Bool {
        await waitForObservedCondition(
            deliveries: {
                [navigationController.selectionObservationDeliveryForTesting].compactMap { $0 }
            },
            sample: {
                condition()
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
