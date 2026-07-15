#if canImport(UIKit)
import Testing
import UIKit
import WebKit
import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKitTesting
import WebInspectorTestSupport
@testable import WebInspectorKit
@testable import WebInspectorUIBase
@testable import WebInspectorUIDOM
@testable import WebInspectorUINetwork

extension WebInspectorUIRenderingTests {
    @MainActor
    @Suite
    struct ParentContainerTests {
        @Test
        func catalogOwnsDefaultTabsWhileSessionOwnsOnlyModelContext() {
            let session = WebInspectorSession()
            let viewController = WebInspectorViewController(session: session)

            #expect(
                viewController.interfaceForTesting.tabs.map(\.id)
                    == [WebInspectorTab.dom.id, WebInspectorTab.network.id]
            )
            #expect(session.modelContext === session.modelContainer.mainContext)
            #expect(session.pageUserInterfaceStyle == .unspecified)
            if #available(iOS 26.0, *) {
                #expect(viewController.drawsBackground)
            }
        }

        @Test
        func catalogRejectsEmptyAndDuplicateRegistries() {
            #expect(throws: WebInspectorTabCatalogError.empty) {
                try WebInspectorTabCatalog([])
            }
            #expect(throws: WebInspectorTabCatalogError.duplicateID(WebInspectorTab.dom.id)) {
                try WebInspectorTabCatalog([.dom, .dom])
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
        func presentationContentStoreReusesEntriesUntilRootClear() async {
            let fixture = PresentationFixture(
                container: WebInspectorModelContainer(
                    configuration: .init(enabledFeatures: [])
                )
            )
            let key = WebInspectorTab.ContentKey(
                tabID: WebInspectorTab.ID(rawValue: "cached-tab"),
                contentID: "root"
            )

            let first = fixture.contentStore.viewController(for: key) {
                UIViewController()
            }
            #expect(
                fixture.contentStore.viewController(for: key) {
                    UIViewController()
                } === first
            )

            await fixture.contentStore.clear()

            let second = fixture.contentStore.viewController(for: key) {
                UIViewController()
            }
            #expect(second !== first)
            #expect(
                fixture.contentStore.viewController(for: key) {
                    UIViewController()
                } === second
            )
            #expect(fixture.contentStore.contentCountForTesting == 1)
        }

        @Test
        func DOMResourceOwnsOnePanelModelUntilRootRetirement() async throws {
            let runtime = try await makeRuntime(enabledFeatures: [.dom])
            let session = WebInspectorSession(modelContainer: runtime.container)
            let context = WebInspectorTab.Context(session: session)
            let factoryStarted = WebInspectorTestGate()
            let factoryRelease = WebInspectorTestGate()
            let contentStore = PresentationContentStore(
                context: context,
                makeDOMPanelModel: { context in
                    let model = try await DOMPanelModel.make(context: context)
                    factoryStarted.open()
                    await factoryRelease.waiter.wait()
                    return model
                }
            )
            let firstHost = contentStore.domViewController { _ in
                UIViewController()
            }

            #expect(firstHost.phase == .loading)
            #expect(contentStore.domResourceStatus == .loading)
            await factoryStarted.waiter.wait()
            factoryRelease.open()
            await contentStore.waitForDOMResourceTaskForTesting()

            let model = try #require(contentStore.domPanelModelForTesting)
            let secondHost = contentStore.domViewController { _ in
                UIViewController()
            }
            #expect(firstHost.phase == .ready)
            #expect(secondHost.phase == .ready)
            #expect(contentStore.domPanelModelForTesting === model)
            #expect(model.isRetiredForTesting == false)

            await contentStore.clear()

            #expect(model.isRetiredForTesting)
            #expect(contentStore.domResourceStatus == .idle)
            #expect(firstHost.phase == .loading)
            #expect(secondHost.phase == .loading)
            #expect(firstHost.readyViewControllerForTesting == nil)
            #expect(secondHost.readyViewControllerForTesting == nil)
            await runtime.close()
        }

        @Test
        func networkResourceTransitionsFromLoadingToReadyInPlace() async throws {
            let runtime = try await makeRuntime(enabledFeatures: [.network])
            let session = WebInspectorSession(modelContainer: runtime.container)
            let context = WebInspectorTab.Context(session: session)
            let factoryStarted = WebInspectorTestGate()
            let factoryRelease = WebInspectorTestGate()
            let contentStore = PresentationContentStore(
                context: context,
                makeNetworkPanelModel: { context in
                    factoryStarted.open()
                    await factoryRelease.waiter.wait()
                    return try await NetworkPanelModel.make(context: context)
                }
            )
            let host = contentStore.networkViewController { _ in
                UIViewController()
            }

            #expect(host.phase == .loading)
            #expect(host.readyViewControllerForTesting == nil)
            #expect(host.contentUnavailableConfiguration != nil)
            #expect(contentStore.networkResourceStatus == .loading)

            await factoryStarted.waiter.wait()
            factoryRelease.open()
            await contentStore.waitForNetworkResourceTaskForTesting()

            #expect(contentStore.networkResourceStatus == .ready)
            #expect(host.phase == .ready)
            #expect(host.readyViewControllerForTesting != nil)
            #expect(host.contentUnavailableConfiguration == nil)

            await contentStore.clear()
            await runtime.close()
        }

        @Test
        func networkResourceWrappersAreHostOwnedWhileModelRetirementIsRootOwned() async throws {
            let runtime = try await makeRuntime(enabledFeatures: [.network])
            let fixture = PresentationFixture(container: runtime.container)
            let firstHost = fixture.contentStore.networkViewController { _ in
                UIViewController()
            }
            await fixture.contentStore.waitForNetworkResourceTaskForTesting()
            let model = try #require(fixture.contentStore.networkPanelModelForTesting)

            let secondHost = fixture.contentStore.networkViewController { _ in
                UIViewController()
            }

            #expect(secondHost !== firstHost)
            #expect(firstHost.phase == .ready)
            #expect(secondHost.phase == .ready)
            #expect(fixture.contentStore.networkPanelModelForTesting === model)
            #expect(model.isRetiredForTesting == false)

            await fixture.contentStore.clear()

            #expect(model.isRetiredForTesting)
            #expect(fixture.contentStore.networkResourceStatus == .idle)
            #expect(firstHost.phase == .loading)
            #expect(secondHost.phase == .loading)
            await runtime.close()
        }

        @Test
        func networkResourceClosesWithoutFeatureLocalFailureSurface() async {
            let container = WebInspectorModelContainer(
                configuration: .init(enabledFeatures: [.network])
            )
            let session = WebInspectorSession(modelContainer: container)
            let contentStore = PresentationContentStore(
                context: WebInspectorTab.Context(session: session)
            )
            let host = contentStore.networkViewController { _ in
                Issue.record("A closed Network resource must not create ready content.")
                return UIViewController()
            }

            #expect(contentStore.networkResourceStatus == .loading)
            #expect(host.phase == .loading)
            await container.close()
            await contentStore.waitForNetworkResourceTaskForTesting()

            #expect(contentStore.networkResourceStatus == .closed)
            #expect(host.phase == .closed)
            #expect(host.readyViewControllerForTesting == nil)
            #expect(host.contentUnavailableConfiguration == nil)

            await contentStore.clear()
        }

        @Test
        func requiredNetworkFailureRetiresReadyPresentationResources() async throws {
            let request = WebInspectorDataKitTestRuntime.NetworkRequest(
                id: "presentation-recovery-exhaustion",
                url: "https://example.test/presentation-recovery-exhaustion"
            )
            let runtime = try await WebInspectorDataKitTestRuntime.start(
                scenario: .init(
                    configuration: .init(enabledFeatures: [.dom, .network]),
                    networkReplay: [request]
                )
            )
            let fixture = PresentationFixture(container: runtime.container)
            let domHost = fixture.contentStore.domViewController { _ in
                UIViewController()
            }
            let networkHost = fixture.contentStore.networkViewController { _ in
                UIViewController()
            }
            await fixture.contentStore.waitForDOMResourceTaskForTesting()
            await fixture.contentStore.waitForNetworkResourceTaskForTesting()
            let domModel = try #require(
                fixture.contentStore.domPanelModelForTesting
            )
            let networkModel = try #require(
                fixture.contentStore.networkPanelModelForTesting
            )
            #expect(domHost.phase == .ready)
            #expect(networkHost.phase == .ready)

            let retirementBaseline = fixture.contentStore
                .containerFailureRetirementCountForTesting
            let failure = try await exhaustRequiredNetworkRecovery(
                request,
                in: runtime
            )
            await fixture.contentStore
                .waitForContainerFailureRetirementForTesting(
                    after: retirementBaseline
                )

            guard case let .requiredFeature(
                featureID,
                .recoveryBudgetExhausted(description)
            ) = failure else {
                Issue.record("Expected exhausted required-Network recovery, got \(failure).")
                await fixture.contentStore.clear()
                await runtime.close()
                return
            }
            #expect(featureID == .network)
            #expect(description.code == "network.recovery.exhausted")
            #expect(domModel.isRetiredForTesting)
            #expect(networkModel.isRetiredForTesting)
            #expect(fixture.contentStore.domResourceStatus == .closed)
            #expect(fixture.contentStore.networkResourceStatus == .closed)
            #expect(fixture.contentStore.domPanelModelForTesting == nil)
            #expect(fixture.contentStore.networkPanelModelForTesting == nil)
            #expect(domHost.phase == .closed)
            #expect(networkHost.phase == .closed)
            #expect(domHost.readyViewControllerForTesting == nil)
            #expect(networkHost.readyViewControllerForTesting == nil)
            #expect(domHost.contentUnavailableConfiguration == nil)
            #expect(networkHost.contentUnavailableConfiguration == nil)

            await fixture.contentStore.clear()
            await runtime.close()
        }

        @Test
        func requiredNetworkFailureStopsPageAppearanceObservation() async throws {
            let request = WebInspectorDataKitTestRuntime.NetworkRequest(
                id: "appearance-recovery-exhaustion",
                url: "https://example.test/appearance-recovery-exhaustion"
            )
            let runtime = try await WebInspectorDataKitTestRuntime.start(
                scenario: .init(
                    configuration: .init(enabledFeatures: [.network]),
                    networkReplay: [request]
                )
            )
            let observer = PageUserInterfaceStyleObserverSpy()
            let session = WebInspectorSession(
                modelContainer: runtime.container,
                makePageUserInterfaceStyleObserver: { _, _ in observer }
            )
            session.startPageUserInterfaceStyleObservationForTesting(
                for: WKWebView()
            )
            #expect(observer.startCount == 1)
            #expect(session.hasPageUserInterfaceStyleObserverForTesting)

            _ = try await exhaustRequiredNetworkRecovery(request, in: runtime)
            await observer.invalidated.waiter.wait()

            #expect(observer.invalidateCount == 1)
            #expect(session.hasPageUserInterfaceStyleObserverForTesting == false)
            #expect(session.pageUserInterfaceStyle == .unspecified)
            await runtime.close()
        }

        @Test
        func presentationResourcesRestartAfterContainerReattachment() async throws {
            let container = WebInspectorModelContainer(
                configuration: .init(enabledFeatures: [.network])
            )
            let firstRuntime = try await makeNetworkProxyRuntime()
            try await container.attach(owning: firstRuntime.runtime.proxy)
            let fixture = PresentationFixture(container: container)
            let host = fixture.contentStore.networkViewController { _ in
                UIViewController()
            }
            await fixture.contentStore.waitForNetworkResourceTaskForTesting()
            let firstModel = try #require(
                fixture.contentStore.networkPanelModelForTesting
            )
            #expect(host.phase == .ready)

            let retirementBaseline = fixture.contentStore
                .containerFailureRetirementCountForTesting
            await firstRuntime.runtime.close()
            await fixture.contentStore
                .waitForContainerFailureRetirementForTesting(
                    after: retirementBaseline
                )
            await firstRuntime.wire.stop()
            #expect(firstModel.isRetiredForTesting)
            #expect(host.phase == .closed)

            let secondRuntime = try await makeNetworkProxyRuntime()
            try await container.attach(owning: secondRuntime.runtime.proxy)
            await fixture.contentStore.waitForNetworkResourceTaskForTesting()
            let secondModel = try #require(
                fixture.contentStore.networkPanelModelForTesting
            )

            #expect(secondModel !== firstModel)
            #expect(secondModel.isRetiredForTesting == false)
            #expect(fixture.contentStore.networkResourceStatus == .ready)
            #expect(host.phase == .ready)
            #expect(host.readyViewControllerForTesting != nil)

            await fixture.contentStore.clear()
            await container.close()
            await secondRuntime.runtime.close()
            await secondRuntime.wire.stop()
        }

        @Test
        func networkResourceLoadDoesNotRetainStore() async throws {
            let runtime = try await makeRuntime(enabledFeatures: [.network])
            let session = WebInspectorSession(modelContainer: runtime.container)
            let factoryStarted = WebInspectorTestGate()
            let factoryRelease = WebInspectorTestGate()
            let factoryFinished = WebInspectorTestGate()
            var contentStore: PresentationContentStore? = PresentationContentStore(
                context: WebInspectorTab.Context(session: session),
                makeNetworkPanelModel: { context in
                    let model = try await NetworkPanelModel.make(context: context)
                    factoryStarted.open()
                    await factoryRelease.waiter.wait()
                    factoryFinished.open()
                    return model
                }
            )
            weak let retainedStore = contentStore
            let host = try #require(contentStore).networkViewController { _ in
                UIViewController()
            }
            await factoryStarted.waiter.wait()

            contentStore = nil

            #expect(retainedStore == nil)
            #expect(host.phase == .loading)
            factoryRelease.open()
            await factoryFinished.waiter.wait()
            await Task.yield()
            #expect(host.readyViewControllerForTesting == nil)
            await runtime.close()
        }

        @Test
        func displayProjectionUsesSemanticBuiltInDisplayItems() throws {
            let catalog = WebInspectorTabCatalog.standard
            let projection = WebInspectorTab.DisplayProjection()

            #expect(
                projection.displayItems(for: .compact, tabs: catalog.tabs)
                    == [
                        .tab(WebInspectorTab.dom.id),
                        .domElement(parent: WebInspectorTab.dom.id),
                        .tab(WebInspectorTab.network.id),
                    ]
            )
            #expect(
                projection.displayItems(for: .regular, tabs: catalog.tabs)
                    == [
                        .tab(WebInspectorTab.dom.id),
                        .tab(WebInspectorTab.network.id),
                    ]
            )
            #expect(
                projection.descriptor(
                    for: .domElement(parent: WebInspectorTab.dom.id),
                    catalog: catalog
                )?.title == "Element"
            )
        }

        @Test
        func customTabFactoryReceivesStableContainerContextAndSharesItsResource() async throws {
            let content = UIViewController()
            var factoryCallCount = 0
            var factoryContext: WebInspectorTab.Context?
            let customTab = WebInspectorTab(
                id: WebInspectorTab.ID(rawValue: "webinspector_custom_console"),
                title: "Console",
                systemImage: "terminal"
            ) { context in
                factoryCallCount += 1
                factoryContext = context
                return content
            }
            let catalog = try WebInspectorTabCatalog([.dom, customTab, .network])
            let fixture = PresentationFixture(
                container: WebInspectorModelContainer(
                    configuration: .init(enabledFeatures: [])
                ),
                catalog: catalog
            )
            let displayItem = WebInspectorTab.DisplayItem.tab(customTab.id)
            let compactHost = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: displayItem,
                    session: fixture.session,
                    interface: fixture.interface,
                    contentStore: fixture.contentStore,
                    hostLayout: .compact
                ) as? CustomTabResourceViewController
            )
            let regularContent = WebInspectorTab.ContentFactory.makeViewController(
                for: displayItem,
                session: fixture.session,
                interface: fixture.interface,
                contentStore: fixture.contentStore,
                hostLayout: .regular
            )
            regularContent.loadViewIfNeeded()
            let regularHost = try #require(
                regularContent.children.first as? CustomTabResourceViewController
            )

            await fixture.contentStore.waitForCustomResourceTaskForTesting(
                for: customContentKey(for: customTab.id)
            )

            #expect(compactHost.readyViewControllerForTesting == nil)
            #expect(regularHost.readyViewControllerForTesting === content)
            #expect(factoryContext?.session === fixture.session)
            #expect(factoryContext?.modelContainer === fixture.session.modelContainer)
            #expect(factoryContext?.modelContext === fixture.session.modelContext)
            #expect(factoryCallCount == 1)

            let reparentedHost = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: displayItem,
                    session: fixture.session,
                    interface: fixture.interface,
                    contentStore: fixture.contentStore,
                    hostLayout: .compact
                ) as? CustomTabResourceViewController
            )
            #expect(reparentedHost.readyViewControllerForTesting === content)
            #expect(content.parent === reparentedHost)
            #expect(factoryCallCount == 1)
            await fixture.contentStore.clear()
        }

        @Test
        func presentationContentStoreDeinitDetachesExternallyRetainedCustomContent() async throws {
            let content = UIViewController()
            let customTab = WebInspectorTab(
                id: WebInspectorTab.ID(rawValue: "webinspector_custom_store_deinit"),
                title: "Store Deinit"
            ) { _ in
                content
            }
            let catalog = try WebInspectorTabCatalog([customTab])
            let session = WebInspectorSession(
                modelContainer: WebInspectorModelContainer(
                    configuration: .init(enabledFeatures: [])
                )
            )
            let interface = InterfaceModel(catalog: catalog)
            var contentStore: PresentationContentStore? = PresentationContentStore(
                context: WebInspectorTab.Context(session: session)
            )
            weak let retainedStore = contentStore
            let regularContent = WebInspectorTab.ContentFactory.makeViewController(
                for: .tab(customTab.id),
                session: session,
                interface: interface,
                contentStore: try #require(contentStore),
                hostLayout: .regular
            )
            regularContent.loadViewIfNeeded()
            await contentStore?.waitForCustomResourceTaskForTesting(
                for: customContentKey(for: customTab.id)
            )
            let resourceHost = try #require(
                regularContent.children.first as? CustomTabResourceViewController
            )
            #expect(resourceHost.readyViewControllerForTesting === content)
            #expect(content.parent === resourceHost)

            contentStore = nil

            #expect(retainedStore == nil)
            #expect(content.parent == nil)
        }

        @Test
        func compactAndRegularHostsRenderCatalogOwnedCustomTabs() async throws {
            let customTab = makeNoOpTab(
                id: WebInspectorTab.ID(rawValue: "webinspector_custom_console"),
                title: "Console"
            )
            let catalog = try WebInspectorTabCatalog([.dom, customTab])
            let runtime = try await makeRuntime(enabledFeatures: [.dom])
            let fixture = PresentationFixture(
                container: runtime.container,
                catalog: catalog
            )

            let compactHost = CompactTabBarController(
                session: fixture.session,
                interface: fixture.interface,
                contentStore: fixture.contentStore
            )
            #expect(
                compactHost.displayedTabIdentifiersForTesting
                    == [
                        WebInspectorTab.dom.id.rawValue,
                        WebInspectorTab.DisplayItem.domElementID,
                        customTab.id.rawValue,
                    ]
            )

            let regularHost = RegularTabContentViewController(
                session: fixture.session,
                interface: fixture.interface,
                contentStore: fixture.contentStore
            )
            regularHost.loadViewIfNeeded()
            #expect(regularHost.segmentedControlForTesting.numberOfSegments == 2)
            #expect(regularHost.segmentedControlForTesting.titleForSegment(at: 0) == "DOM")
            #expect(regularHost.segmentedControlForTesting.titleForSegment(at: 1) == "Console")

            await fixture.contentStore.clear()
            await runtime.close()
        }

        @Test
        func topLevelContainerSwitchesBetweenCompactAndRegularHosts() throws {
            let tab = makeNoOpTab()
            let catalog = try WebInspectorTabCatalog([tab])
            let viewController = WebInspectorViewController(catalog: catalog)
            viewController.loadViewIfNeeded()

            viewController.horizontalSizeClassOverrideForTesting = .compact
            #expect(viewController.activeHostViewControllerForTesting is CompactTabBarController)

            viewController.horizontalSizeClassOverrideForTesting = .regular
            #expect(viewController.activeHostViewControllerForTesting is RegularTabContentViewController)
        }

        @Test
        func viewControllerBackgroundDrawingDefaultsToSystemBackground() throws {
            let catalog = try WebInspectorTabCatalog([makeNoOpTab()])
            let viewController = WebInspectorViewController(catalog: catalog)

            viewController.loadViewIfNeeded()

            if #available(iOS 26.0, *) {
                #expect(viewController.drawsBackground)
            }
            #expect(viewController.view.backgroundColor == .systemBackground)
        }

        @Test
        func topLevelContainerPropagatesBackgroundDrawingTraitToHosts() throws {
            guard #available(iOS 26.0, *) else {
                return
            }
            let catalog = try WebInspectorTabCatalog([makeNoOpTab()])
            let viewController = WebInspectorViewController(catalog: catalog)
            viewController.drawsBackground = false
            viewController.loadViewIfNeeded()

            viewController.horizontalSizeClassOverrideForTesting = .compact
            let compactHost = try #require(
                viewController.activeHostViewControllerForTesting
                    as? CompactTabBarController
            )
            compactHost.loadViewIfNeeded()
            #expect(compactHost.view.backgroundColor == .clear)

            viewController.drawsBackground = true
            viewController.horizontalSizeClassOverrideForTesting = .regular
            let regularHost = try #require(
                viewController.activeHostViewControllerForTesting
                    as? RegularTabContentViewController
            )
            regularHost.loadViewIfNeeded()
            #expect(regularHost.view.backgroundColor == .systemBackground)
        }

        @Test
        func representationBeforeDeferredRetirementKeepsBorrowedSessionAndContent() async throws {
            let tab = makeNoOpTab()
            let catalog = try WebInspectorTabCatalog([tab])
            let session = WebInspectorSession(
                modelContainer: WebInspectorModelContainer(
                    configuration: .init(enabledFeatures: [])
                )
            )
            let viewController = WebInspectorViewController(
                session: session,
                catalog: catalog
            )
            let contentStore = viewController.presentationContentStoreForTesting
            let host = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: .tab(tab.id),
                    session: session,
                    interface: viewController.interfaceForTesting,
                    contentStore: contentStore,
                    hostLayout: .compact
                ) as? CustomTabResourceViewController
            )
            viewController.loadViewIfNeeded()
            await contentStore.waitForCustomResourceTaskForTesting(
                for: customContentKey(for: tab.id)
            )
            #expect(host.phase == .ready)

            let baseline = viewController
                .rootPresentationRetirementTaskCompletionCountForTesting
            viewController.finishRootPresentationLifecycleForTesting()
            viewController.beginAppearanceTransition(true, animated: false)
            viewController.endAppearanceTransition()

            #expect(
                await viewController
                    .waitForRootPresentationRetirementTaskCompletionForTesting(
                        after: baseline
                    )
            )
            #expect(session.modelContainer.state == .detached)
            #expect(host.phase == .ready)
        }

        @Test
        func borrowedRootRetirementClearsResourcesWithoutClosingSession() async throws {
            let runtime = try await makeRuntime(enabledFeatures: [.dom, .network])
            let session = WebInspectorSession(modelContainer: runtime.container)
            let viewController = WebInspectorViewController(session: session)
            let contentStore = viewController.presentationContentStoreForTesting
            let domHost = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: .tab(WebInspectorTab.dom.id),
                    session: session,
                    interface: viewController.interfaceForTesting,
                    contentStore: contentStore,
                    hostLayout: .compact
                ) as? DOMTabResourceViewController
            )
            let networkHost = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: .tab(WebInspectorTab.network.id),
                    session: session,
                    interface: viewController.interfaceForTesting,
                    contentStore: contentStore,
                    hostLayout: .regular
                ) as? NetworkTabResourceViewController
            )
            await contentStore.waitForDOMResourceTaskForTesting()
            await contentStore.waitForNetworkResourceTaskForTesting()
            #expect(domHost.phase == .ready)
            #expect(networkHost.phase == .ready)

            let baseline = viewController
                .rootPresentationRetirementTaskCompletionCountForTesting
            viewController.finishRootPresentationLifecycleForTesting()
            #expect(
                await viewController
                    .waitForRootPresentationRetirementTaskCompletionForTesting(
                        after: baseline
                    )
            )

            #expect(contentStore.domResourceStatus == .idle)
            #expect(contentStore.networkResourceStatus == .idle)
            #expect(domHost.phase == .loading)
            #expect(networkHost.phase == .loading)
            #expect(session.modelContainer.state.isAttachedForTesting)
            await runtime.close()
        }

        @Test
        func ownedRootRetirementClosesItsSession() async {
            let viewController = WebInspectorViewController()
            let baseline = viewController
                .rootPresentationRetirementTaskCompletionCountForTesting

            viewController.finishRootPresentationLifecycleForTesting()

            #expect(
                await viewController
                    .waitForRootPresentationRetirementTaskCompletionForTesting(
                        after: baseline
                    )
            )
            #expect(viewController.session.modelContainer.state == .closed)
        }

        @Test
        func viewControllerDoesNotReplaceExternalPresentationControllerDelegate() async throws {
            let tab = makeNoOpTab()
            let catalog = try WebInspectorTabCatalog([tab])
            let presenter = UIViewController()
            let viewController = WebInspectorViewController(catalog: catalog)
            let window = showInWindow(presenter)
            defer { window.isHidden = true }

            presenter.present(viewController, animated: false)
            #expect(presenter.presentedViewController === viewController)
            let presentationController = try #require(
                viewController.presentationController
            )
            let externalDelegate = PresentationDelegateRecorder()
            presentationController.delegate = externalDelegate

            viewController.beginAppearanceTransition(true, animated: false)
            viewController.endAppearanceTransition()

            #expect(presentationController.delegate === externalDelegate)
        }

        @Test
        func hostReplacementAndTabSelectionDoNotCloseBorrowedSession() async throws {
            let runtime = try await makeRuntime(enabledFeatures: [.dom, .network])
            let session = WebInspectorSession(modelContainer: runtime.container)
            let viewController = WebInspectorViewController(session: session)
            let window = showInWindow(viewController, useUIKitVisibility: false)
            defer { window.isHidden = true }

            viewController.horizontalSizeClassOverrideForTesting = .compact
            let compactHost = try #require(
                viewController.activeHostViewControllerForTesting
                    as? CompactTabBarController
            )
            compactHost.loadViewIfNeeded()
            viewController.interfaceForTesting.selectItem(
                .domElement(parent: WebInspectorTab.dom.id)
            )
            #expect(
                await waitUntilCompactHostRendered(in: compactHost) {
                    compactHost.selectedDisplayItemIDForTesting
                        == WebInspectorTab.DisplayItem.domElementID
                }
            )

            viewController.horizontalSizeClassOverrideForTesting = .regular

            #expect(
                viewController.activeHostViewControllerForTesting
                    is RegularTabContentViewController
            )
            #expect(session.modelContainer.state.isAttachedForTesting)

            let baseline = viewController
                .rootPresentationRetirementTaskCompletionCountForTesting
            viewController.finishRootPresentationLifecycleForTesting()
            _ =
                await viewController
                .waitForRootPresentationRetirementTaskCompletionForTesting(
                    after: baseline
                )
            await runtime.close()
        }

        @Test
        func compactFactoryUsesDomainNavigationControllers() async throws {
            let runtime = try await makeRuntime(enabledFeatures: [.dom, .network])
            let fixture = PresentationFixture(container: runtime.container)

            let domHost = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: .tab(WebInspectorTab.dom.id),
                    session: fixture.session,
                    interface: fixture.interface,
                    contentStore: fixture.contentStore,
                    hostLayout: .compact
                ) as? DOMTabResourceViewController
            )
            await fixture.contentStore.waitForDOMResourceTaskForTesting()
            let domNavigationController = try #require(
                domHost.readyViewControllerForTesting
                    as? DOMCompactNavigationController
            )
            #expect(domNavigationController.viewControllers.first is DOMTreeViewController)

            let elementHost = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: .domElement(parent: WebInspectorTab.dom.id),
                    session: fixture.session,
                    interface: fixture.interface,
                    contentStore: fixture.contentStore,
                    hostLayout: .compact
                ) as? DOMTabResourceViewController
            )
            let elementNavigationController = try #require(
                elementHost.readyViewControllerForTesting
                    as? DOMCompactNavigationController
            )
            #expect(
                elementNavigationController.viewControllers.first
                    is DOMElementViewController
            )

            let networkHost = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: .tab(WebInspectorTab.network.id),
                    session: fixture.session,
                    interface: fixture.interface,
                    contentStore: fixture.contentStore,
                    hostLayout: .compact
                ) as? NetworkTabResourceViewController
            )
            await fixture.contentStore.waitForNetworkResourceTaskForTesting()
            let networkNavigationController = try #require(
                networkHost.readyViewControllerForTesting
                    as? NetworkCompactNavigationController
            )
            #expect(
                networkNavigationController.viewControllers.first
                    is NetworkListViewController
            )

            await fixture.contentStore.clear()
            await runtime.close()
        }

        @Test
        func regularHostWrapsDOMSplitControllerInNavigationContent() async throws {
            let runtime = try await makeRuntime(enabledFeatures: [.dom])
            let catalog = try WebInspectorTabCatalog([.dom])
            let fixture = PresentationFixture(
                container: runtime.container,
                catalog: catalog
            )
            let host = RegularTabContentViewController(
                session: fixture.session,
                interface: fixture.interface,
                contentStore: fixture.contentStore
            )

            host.loadViewIfNeeded()
            await fixture.contentStore.waitForDOMResourceTaskForTesting()

            let resourceHost = try #require(
                host.viewControllers.first as? DOMTabResourceViewController
            )
            let rootViewController = try #require(
                resourceHost.readyViewControllerForTesting
            )
            rootViewController.loadViewIfNeeded()

            #expect(rootViewController is UISplitViewController == false)
            #expect(
                rootViewController.children.contains {
                    $0 is DOMSplitViewController
                }
            )
            #expect(resourceHost.navigationItem.centerItemGroups.isEmpty == false)
            #expect(
                resourceHost.navigationItem.trailingItemGroups
                    .flatMap(\.barButtonItems)
                    .contains {
                        $0.accessibilityIdentifier == "WebInspector.DOM.PickButton"
                    }
            )

            await fixture.contentStore.clear()
            await runtime.close()
        }

        @Test
        func DOMTreeViewControllerIsSharedAcrossCompactAndRegularHosts() async throws {
            let runtime = try await makeRuntime(enabledFeatures: [.dom])
            let catalog = try WebInspectorTabCatalog([.dom])
            let fixture = PresentationFixture(
                container: runtime.container,
                catalog: catalog
            )
            let compactHost = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: .tab(WebInspectorTab.dom.id),
                    session: fixture.session,
                    interface: fixture.interface,
                    contentStore: fixture.contentStore,
                    hostLayout: .compact
                ) as? DOMTabResourceViewController
            )
            await fixture.contentStore.waitForDOMResourceTaskForTesting()
            let compactNavigationController = try #require(
                compactHost.readyViewControllerForTesting
                    as? DOMCompactNavigationController
            )
            let compactTreeViewController = try #require(
                compactNavigationController.viewControllers.first
                    as? DOMTreeViewController
            )

            let regularHost = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: .tab(WebInspectorTab.dom.id),
                    session: fixture.session,
                    interface: fixture.interface,
                    contentStore: fixture.contentStore,
                    hostLayout: .regular
                ) as? DOMTabResourceViewController
            )
            let regularRoot = try #require(
                regularHost.readyViewControllerForTesting
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
            await fixture.contentStore.clear()
            await runtime.close()
        }

        @Test
        func networkPanelSelectionIsSharedAcrossParentHosts() async throws {
            let runtime = try await WebInspectorDataKitTestRuntime.start(
                scenario: .init(
                    configuration: .init(enabledFeatures: [.network]),
                    networkReplay: [
                        .init(
                            id: "1",
                            url: "https://example.com/app.js",
                            statusText: "OK",
                            responseHeaders: [
                                "content-type": "text/javascript"
                            ],
                            mimeType: "text/javascript",
                            resourceType: .script
                        )
                    ]
                )
            )
            let catalog = try WebInspectorTabCatalog([.network])
            let fixture = PresentationFixture(
                container: runtime.container,
                catalog: catalog
            )
            let request = try #require(
                try await fixture.session.modelContext.fetch(
                    WebInspectorFetchDescriptor<
                        WebInspectorDataKit.NetworkRequest
                    >()
                ).first
            )
            let compactHost = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: .tab(WebInspectorTab.network.id),
                    session: fixture.session,
                    interface: fixture.interface,
                    contentStore: fixture.contentStore,
                    hostLayout: .compact
                ) as? NetworkTabResourceViewController
            )
            await fixture.contentStore.waitForNetworkResourceTaskForTesting()
            let model = try #require(
                fixture.contentStore.networkPanelModelForTesting
            )
            let compactNavigationController = try #require(
                compactHost.readyViewControllerForTesting
                    as? NetworkCompactNavigationController
            )
            let window = showInWindow(
                compactNavigationController,
                useUIKitVisibility: false
            )
            defer { window.isHidden = true }

            model.selectRequest(request)

            #expect(
                await waitUntilNetworkStackSynced(
                    in: compactNavigationController
                ) {
                    compactNavigationController.viewControllers.last
                        is NetworkDetailViewController
                }
            )

            let regularHost = try #require(
                WebInspectorTab.ContentFactory.makeViewController(
                    for: .tab(WebInspectorTab.network.id),
                    session: fixture.session,
                    interface: fixture.interface,
                    contentStore: fixture.contentStore,
                    hostLayout: .regular
                ) as? NetworkTabResourceViewController
            )
            let regularRoot = try #require(
                regularHost.readyViewControllerForTesting
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

            #expect(
                await waitUntilNetworkDetailRendered(
                    in: detailViewController
                ) {
                    detailViewController.headersTextViewForTesting
                        .renderedTextForTesting.contains("GET /app.js")
                }
            )

            await fixture.contentStore.clear()
            await runtime.close()
        }

        @MainActor
        private struct PresentationFixture {
            let session: WebInspectorSession
            let interface: InterfaceModel
            let contentStore: PresentationContentStore

            init(
                container: WebInspectorModelContainer,
                catalog: WebInspectorTabCatalog = .standard
            ) {
                let session = WebInspectorSession(modelContainer: container)
                self.session = session
                self.interface = InterfaceModel(catalog: catalog)
                self.contentStore = PresentationContentStore(
                    context: WebInspectorTab.Context(session: session)
                )
            }
        }

        @MainActor
        private final class PageUserInterfaceStyleObserverSpy:
            WebInspectorPageUserInterfaceStyleObserving
        {
            let invalidated = WebInspectorTestGate()
            private(set) var startCount = 0
            private(set) var invalidateCount = 0

            func start() {
                startCount += 1
            }

            func invalidate() {
                invalidateCount += 1
                invalidated.open()
            }
        }

        private func makeRuntime(
            enabledFeatures: Set<WebInspectorFeatureID>
        ) async throws -> WebInspectorDataKitTestRuntime {
            try await WebInspectorDataKitTestRuntime.start(
                scenario: .init(
                    configuration: .init(enabledFeatures: enabledFeatures)
                )
            )
        }

        private func makeNetworkProxyRuntime() async throws -> (
            runtime: WebInspectorProxyTestRuntime,
            wire: WebInspectorRawWireDriver
        ) {
            let runtime = try await WebInspectorProxyTestRuntime.start()
            let wire = WebInspectorRawWireDriver(peer: runtime.peer)
            await wire.start()
            await wire.respond(to: "Page.enable")
            await wire.respond(to: "Network.enable")
            await wire.respond(
                to: "Page.getResourceTree",
                with: try WebInspectorTestJSONObject(
                    json: #"""
                    {
                        "frameTree": {
                            "frame": {
                                "id": "main-frame",
                                "loaderId": "main-frame-loader",
                                "name": "",
                                "url": "",
                                "mimeType": "text/html"
                            },
                            "resources": []
                        }
                    }
                    """#
                )
            )
            await wire.respond(to: "Network.disable")
            await wire.respond(to: "Page.disable")
            return (runtime, wire)
        }

        private func exhaustRequiredNetworkRecovery(
            _ request: WebInspectorDataKitTestRuntime.NetworkRequest,
            in runtime: WebInspectorDataKitTestRuntime
        ) async throws -> WebInspectorConnectionFailure {
            var networkStates = runtime.container.network.stateUpdates
                .makeAsyncIterator()
            guard case let .ready(_, initialRevision) = await networkStates.next() else {
                preconditionFailure("A started Network feature must initially be ready.")
            }

            try await runtime.emitNetworkLoadingFinished(request)
            var observedRecoveredRevision = false
            recovery: while let state = await networkStates.next() {
                switch state {
                case let .ready(_, revision) where revision > initialRevision:
                    observedRecoveredRevision = true
                    break recovery
                case let .unavailable(_, error):
                    Issue.record(
                        "Required Network published feature-local failure: \(error)."
                    )
                    break recovery
                case .disabled:
                    preconditionFailure(
                        "The connection ended during the first recovery attempt."
                    )
                case .synchronizing, .ready, .recovering:
                    continue
                }
            }
            guard observedRecoveredRevision else {
                preconditionFailure("Network did not publish a recovered revision.")
            }

            var containerStates = runtime.container.stateUpdates
                .makeAsyncIterator()
            guard case .attached = await containerStates.next() else {
                preconditionFailure("The recovered container must remain attached.")
            }
            try await runtime.emitNetworkLoadingFinished(request)
            while let state = await containerStates.next() {
                switch state {
                case let .failed(_, failure):
                    return failure
                case .detached, .attaching, .attached, .detaching:
                    continue
                case .closing, .closed:
                    throw WebInspectorCommandError.containerClosed
                }
            }
            throw WebInspectorCommandError.containerClosed
        }

        private func makeNoOpTab(
            id: WebInspectorTab.ID = .init(
                rawValue: "webinspector_test_noop"
            ),
            title: String = "Test"
        ) -> WebInspectorTab {
            WebInspectorTab(id: id, title: title) { _ in
                UIViewController()
            }
        }

        private func customContentKey(
            for tabID: WebInspectorTab.ID
        ) -> WebInspectorTab.ContentKey {
            WebInspectorTab.ContentKey(tabID: tabID, contentID: "root")
        }

        private func childViewController<T: UIViewController>(
            ofType type: T.Type,
            in rootViewController: UIViewController
        ) throws -> T {
            try #require(
                rootViewController.children.first { $0 is T } as? T
            )
        }

        private func splitRootViewController<T: UIViewController>(
            ofType type: T.Type,
            in splitViewController: UISplitViewController
        ) -> T? {
            for column in splitColumns {
                guard
                    let navigationController =
                        splitViewController
                        .viewController(for: column) as? UINavigationController,
                    let rootViewController = navigationController
                        .viewControllers.first as? T
                else {
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

        private func showInWindow(
            _ viewController: UIViewController,
            useUIKitVisibility: Bool = true
        ) -> UIWindow {
            let window = UIWindow(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
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

        private func activateNetworkRenderingForTesting(
            in viewController: UIViewController
        ) {
            if let navigationController = viewController
                as? NetworkCompactNavigationController
            {
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

            if let listViewController = viewController
                as? NetworkListViewController
            {
                listViewController.resumeRenderingForTesting()
            }

            if let detailViewController = viewController
                as? NetworkDetailViewController
            {
                detailViewController.resumeRenderingForTesting()
            }
        }

        private func waitUntilCompactHostRendered(
            in viewController: CompactTabBarController,
            _ condition: @escaping @MainActor @Sendable () -> Bool
        ) async -> Bool {
            await waitForObservedCondition(
                deliveries: {
                    [viewController.interfaceObservationDeliveryForTesting]
                        .compactMap { $0 }
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
                    [navigationController.selectionObservationDeliveryForTesting]
                        .compactMap { $0 }
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
                        viewController.syntaxBodyViewControllerForTesting
                            .bodyObservationDeliveryForTesting,
                        viewController.syntaxBodyViewControllerForTesting
                            .previewRenderObservationDeliveryForTesting,
                    ].compactMap { $0 }
                },
                sample: {
                    viewController.view.layoutIfNeeded()
                    return condition()
                }
            )
        }

        private final class PresentationDelegateRecorder: NSObject,
            UIAdaptivePresentationControllerDelegate
        {}
    }
}

@MainActor
private extension NetworkDetailViewController {
    var syntaxBodyViewControllerForTesting: NetworkBodyViewController {
        guard
            let viewController = bodyViewControllerForTesting
                as? NetworkBodyViewController
        else {
            preconditionFailure(
                "Expected NetworkDetailViewController to use NetworkBodyViewController in tests."
            )
        }
        return viewController
    }
}

private extension WebInspectorModelContainer.State {
    var isAttachedForTesting: Bool {
        if case .attached = self {
            true
        } else {
            false
        }
    }
}
#endif
