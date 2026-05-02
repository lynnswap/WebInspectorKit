import Foundation
import WebKit
import WebInspectorBridge
import WebInspectorEngine
import WebInspectorScripts
import WebInspectorTransport

@MainActor
public protocol WIInspectorDependencyClient {
    static var liveValue: Self { get }
    static var testValue: Self { get }
}

@MainActor
public struct WIInspectorDependencies: WIInspectorDependencyClient {
    public var transport: WIInspectorTransportClient
    public var domFrontend: WIInspectorDOMFrontendClient
    public var network: WIInspectorNetworkClient
    public var webKitSPI: WIInspectorWebKitSPIClient
    public var platform: WIInspectorPlatformClient

    public init(
        transport: WIInspectorTransportClient = .liveValue,
        domFrontend: WIInspectorDOMFrontendClient = .liveValue,
        network: WIInspectorNetworkClient = .liveValue,
        webKitSPI: WIInspectorWebKitSPIClient = .liveValue,
        platform: WIInspectorPlatformClient = .liveValue
    ) {
        self.transport = transport
        self.domFrontend = domFrontend
        self.network = network
        self.webKitSPI = webKitSPI
        self.platform = platform
    }

    public static var liveValue: Self {
        Self()
    }

    public static var testValue: Self {
        Self(
            transport: .testValue,
            domFrontend: .testValue,
            network: .testValue,
            webKitSPI: .testValue,
            platform: .testValue
        )
    }

    public static func testing(_ update: (inout Self) -> Void = { _ in }) -> Self {
        var dependencies = Self.testValue
        update(&dependencies)
        return dependencies
    }

    package func makeSharedTransport() -> WISharedInspectorTransport {
        transport.makeSharedTransport()
    }

    package func makeNetworkPageAgentDependencies() -> NetworkPageAgentDependencies {
        NetworkPageAgentDependencies(
            controllerStateRegistry: network.controllerStateRegistry,
            startupMode: webKitSPI.startupBridgeMode,
            modeForAttachment: webKitSPI.bridgeModeForAttachment,
            loadNetworkAgentScriptSource: network.networkAgentScript,
            supportsResourceLoadDelegate: webKitSPI.supportsResourceLoadDelegate,
            setResourceLoadDelegate: webKitSPI.setResourceLoadDelegate
        )
    }
}

@MainActor
public struct WIInspectorTransportClient: WIInspectorDependencyClient {
    public var configuration: WITransportConfiguration
    public var supportSnapshot: @MainActor @Sendable () -> WITransportSupportSnapshot
    package var makeSessionWithConfiguration: @MainActor @Sendable (WITransportConfiguration) -> WITransportSession

    public init(
        configuration: WITransportConfiguration = .init(),
        supportSnapshot: @escaping @MainActor @Sendable () -> WITransportSupportSnapshot = {
            WITransportSession().supportSnapshot
        }
    ) {
        self.configuration = configuration
        self.supportSnapshot = supportSnapshot
        self.makeSessionWithConfiguration = { configuration in
            WITransportSession(configuration: configuration)
        }
    }

    package init(
        configuration: WITransportConfiguration = .init(),
        supportSnapshot: @escaping @MainActor @Sendable () -> WITransportSupportSnapshot,
        makeSessionWithConfiguration: @escaping @MainActor @Sendable (WITransportConfiguration) -> WITransportSession
    ) {
        self.configuration = configuration
        self.supportSnapshot = supportSnapshot
        self.makeSessionWithConfiguration = makeSessionWithConfiguration
    }

    public static var liveValue: Self {
        Self()
    }

    public static var testValue: Self {
        let snapshot = WITransportSupportSnapshot.unsupported(reason: "Test transport is unsupported.")
        return Self(
            configuration: .init(responseTimeout: .milliseconds(100)),
            supportSnapshot: { snapshot },
            makeSessionWithConfiguration: { configuration in
                WITransportSession.unsupported(
                    configuration: configuration,
                    reason: snapshot.failureReason ?? "Test transport is unsupported."
                )
            }
        )
    }

    package func makeSharedTransport() -> WISharedInspectorTransport {
        WISharedInspectorTransport(sessionFactory: {
            makeSessionWithConfiguration(configuration)
        })
    }
}

@MainActor
public struct WIInspectorDOMFrontendClient: WIInspectorDependencyClient {
    public var domTreeViewScript: @MainActor @Sendable () throws -> String
    public var mainFileURL: @MainActor @Sendable () -> URL?
    public var resourcesDirectoryURL: @MainActor @Sendable () -> URL?

    public init(
        domTreeViewScript: @escaping @MainActor @Sendable () throws -> String = {
            try WebInspectorScripts.domTreeView()
        },
        mainFileURL: @escaping @MainActor @Sendable () -> URL? = {
            WebInspectorScripts.resourceBundle.url(
                forResource: "dom-tree-view",
                withExtension: "html",
                subdirectory: WebInspectorScripts.domTreeViewResourceSubdirectory
            ) ?? Bundle.main.url(
                forResource: "dom-tree-view",
                withExtension: "html",
                subdirectory: WebInspectorScripts.domTreeViewResourceSubdirectory
            )
        },
        resourcesDirectoryURL: @escaping @MainActor @Sendable () -> URL? = {
            let packageURL = WebInspectorScripts.resourceBundle.url(
                forResource: "dom-tree-view",
                withExtension: "html",
                subdirectory: WebInspectorScripts.domTreeViewResourceSubdirectory
            )
            let mainURL = Bundle.main.url(
                forResource: "dom-tree-view",
                withExtension: "html",
                subdirectory: WebInspectorScripts.domTreeViewResourceSubdirectory
            )
            return (packageURL ?? mainURL)?.deletingLastPathComponent()
        }
    ) {
        self.domTreeViewScript = domTreeViewScript
        self.mainFileURL = mainFileURL
        self.resourcesDirectoryURL = resourcesDirectoryURL
    }

    public static var liveValue: Self {
        Self(
            domTreeViewScript: {
                try WebInspectorScripts.domTreeView()
            },
            mainFileURL: {
                WIAssets.mainFileURL
            },
            resourcesDirectoryURL: {
                WIAssets.resourcesDirectory
            }
        )
    }

    public static var testValue: Self {
        Self(
            domTreeViewScript: { "" },
            mainFileURL: { nil },
            resourcesDirectoryURL: { nil }
        )
    }

    func makeInspectorWebView() -> InspectorWebView {
        InspectorWebView(dependencies: self)
    }
}

@MainActor
public struct WIInspectorNetworkClient: WIInspectorDependencyClient {
    public var networkAgentScript: @MainActor @Sendable () throws -> String
    package var controllerStateRegistry: WIUserContentControllerStateRegistry

    public init(
        networkAgentScript: @escaping @MainActor @Sendable () throws -> String = {
            try WebInspectorScripts.networkAgent()
        }
    ) {
        self.networkAgentScript = networkAgentScript
        self.controllerStateRegistry = .shared
    }

    package init(
        networkAgentScript: @escaping @MainActor @Sendable () throws -> String,
        controllerStateRegistry: WIUserContentControllerStateRegistry
    ) {
        self.networkAgentScript = networkAgentScript
        self.controllerStateRegistry = controllerStateRegistry
    }

    public static var liveValue: Self {
        Self()
    }

    public static var testValue: Self {
        Self(
            networkAgentScript: { "" },
            controllerStateRegistry: .shared
        )
    }
}

@MainActor
public struct WIInspectorWebKitSPIClient: WIInspectorDependencyClient {
    public var hasPrivateInspectorAccess: @MainActor @Sendable (WKWebView) -> Bool
    public var isInspectorConnected: @MainActor @Sendable (WKWebView) -> Bool?
    public var connectInspector: @MainActor @Sendable (WKWebView) -> Bool
    public var toggleElementSelection: @MainActor @Sendable (WKWebView) -> Bool
    public var setNodeSearchEnabled: @MainActor @Sendable (WKWebView, Bool) -> Bool
    public var hasNodeSearchRecognizer: @MainActor @Sendable (WKWebView) -> Bool
    public var removeNodeSearchRecognizers: @MainActor @Sendable (WKWebView) -> Bool
    public var isElementSelectionActive: @MainActor @Sendable (WKWebView) -> Bool?

    package var startupBridgeMode: @MainActor @Sendable () -> WIBridgeMode
    package var bridgeModeForAttachment: @MainActor @Sendable (WKWebView?) -> WIBridgeMode
    package var supportsResourceLoadDelegate: @MainActor @Sendable (WKWebView) -> Bool
    package var setResourceLoadDelegate: @MainActor @Sendable (WKWebView, AnyObject?) -> Bool
    package var dismissPageEditing: @MainActor @Sendable (WKWebView) -> Void
    package var transportInspectActivationProvider: @MainActor @Sendable (WKWebView) -> Bool
    package var transportInspectActivationTimeoutNanoseconds: UInt64

    public init(
        hasPrivateInspectorAccess: @escaping @MainActor @Sendable (WKWebView) -> Bool = { _ in false },
        isInspectorConnected: @escaping @MainActor @Sendable (WKWebView) -> Bool? = { _ in nil },
        connectInspector: @escaping @MainActor @Sendable (WKWebView) -> Bool = { _ in false },
        toggleElementSelection: @escaping @MainActor @Sendable (WKWebView) -> Bool = { _ in false },
        setNodeSearchEnabled: @escaping @MainActor @Sendable (WKWebView, Bool) -> Bool = { _, _ in false },
        hasNodeSearchRecognizer: @escaping @MainActor @Sendable (WKWebView) -> Bool = { _ in false },
        removeNodeSearchRecognizers: @escaping @MainActor @Sendable (WKWebView) -> Bool = { _ in true },
        isElementSelectionActive: @escaping @MainActor @Sendable (WKWebView) -> Bool? = { _ in false }
    ) {
        self.hasPrivateInspectorAccess = hasPrivateInspectorAccess
        self.isInspectorConnected = isInspectorConnected
        self.connectInspector = connectInspector
        self.toggleElementSelection = toggleElementSelection
        self.setNodeSearchEnabled = setNodeSearchEnabled
        self.hasNodeSearchRecognizer = hasNodeSearchRecognizer
        self.removeNodeSearchRecognizers = removeNodeSearchRecognizers
        self.isElementSelectionActive = isElementSelectionActive
        self.startupBridgeMode = {
            WISPIRuntime.shared.startupMode()
        }
        self.bridgeModeForAttachment = { webView in
            WISPIRuntime.shared.modeForAttachment(webView: webView)
        }
        self.supportsResourceLoadDelegate = { webView in
            WISPIRuntime.shared.canSetResourceLoadDelegate(on: webView)
        }
        self.setResourceLoadDelegate = { webView, delegate in
            WISPIRuntime.shared.setResourceLoadDelegate(on: webView, delegate: delegate)
        }
        self.dismissPageEditing = { webView in
            #if canImport(UIKit)
            webView.endEditing(true)
            #else
            _ = webView
            #endif
        }
        self.transportInspectActivationProvider = { _ in true }
        self.transportInspectActivationTimeoutNanoseconds = 50_000_000
    }

    package init(
        hasPrivateInspectorAccess: @escaping @MainActor @Sendable (WKWebView) -> Bool,
        isInspectorConnected: @escaping @MainActor @Sendable (WKWebView) -> Bool?,
        connectInspector: @escaping @MainActor @Sendable (WKWebView) -> Bool,
        toggleElementSelection: @escaping @MainActor @Sendable (WKWebView) -> Bool,
        setNodeSearchEnabled: @escaping @MainActor @Sendable (WKWebView, Bool) -> Bool,
        hasNodeSearchRecognizer: @escaping @MainActor @Sendable (WKWebView) -> Bool,
        removeNodeSearchRecognizers: @escaping @MainActor @Sendable (WKWebView) -> Bool,
        isElementSelectionActive: @escaping @MainActor @Sendable (WKWebView) -> Bool?,
        startupBridgeMode: @escaping @MainActor @Sendable () -> WIBridgeMode,
        bridgeModeForAttachment: @escaping @MainActor @Sendable (WKWebView?) -> WIBridgeMode,
        supportsResourceLoadDelegate: @escaping @MainActor @Sendable (WKWebView) -> Bool,
        setResourceLoadDelegate: @escaping @MainActor @Sendable (WKWebView, AnyObject?) -> Bool,
        dismissPageEditing: @escaping @MainActor @Sendable (WKWebView) -> Void,
        transportInspectActivationProvider: @escaping @MainActor @Sendable (WKWebView) -> Bool,
        transportInspectActivationTimeoutNanoseconds: UInt64
    ) {
        self.hasPrivateInspectorAccess = hasPrivateInspectorAccess
        self.isInspectorConnected = isInspectorConnected
        self.connectInspector = connectInspector
        self.toggleElementSelection = toggleElementSelection
        self.setNodeSearchEnabled = setNodeSearchEnabled
        self.hasNodeSearchRecognizer = hasNodeSearchRecognizer
        self.removeNodeSearchRecognizers = removeNodeSearchRecognizers
        self.isElementSelectionActive = isElementSelectionActive
        self.startupBridgeMode = startupBridgeMode
        self.bridgeModeForAttachment = bridgeModeForAttachment
        self.supportsResourceLoadDelegate = supportsResourceLoadDelegate
        self.setResourceLoadDelegate = setResourceLoadDelegate
        self.dismissPageEditing = dismissPageEditing
        self.transportInspectActivationProvider = transportInspectActivationProvider
        self.transportInspectActivationTimeoutNanoseconds = transportInspectActivationTimeoutNanoseconds
    }

    public static var liveValue: Self {
        #if canImport(UIKit)
        Self(
            hasPrivateInspectorAccess: {
                WIDOMUIKitInspectorSelectionEnvironment.privateInspectorAccessProvider($0)
            },
            isInspectorConnected: {
                WIDOMUIKitInspectorSelectionEnvironment.inspectorConnectedProvider($0)
            },
            connectInspector: {
                WIDOMUIKitInspectorSelectionEnvironment.inspectorConnector($0)
            },
            toggleElementSelection: {
                WIDOMUIKitInspectorSelectionEnvironment.elementSelectionToggler($0)
            },
            setNodeSearchEnabled: { webView, enabled in
                WIDOMUIKitInspectorSelectionEnvironment.nodeSearchSetter(webView, enabled)
            },
            hasNodeSearchRecognizer: {
                WIDOMUIKitInspectorSelectionEnvironment.recognizerPresenceProvider($0)
            },
            removeNodeSearchRecognizers: {
                WIDOMUIKitInspectorSelectionEnvironment.recognizerRemover($0)
            },
            isElementSelectionActive: {
                WIDOMUIKitInspectorSelectionEnvironment.selectionActiveProvider($0)
            },
            startupBridgeMode: {
                WISPIRuntime.shared.startupMode()
            },
            bridgeModeForAttachment: { webView in
                WISPIRuntime.shared.modeForAttachment(webView: webView)
            },
            supportsResourceLoadDelegate: { webView in
                WISPIRuntime.shared.canSetResourceLoadDelegate(on: webView)
            },
            setResourceLoadDelegate: { webView, delegate in
                WISPIRuntime.shared.setResourceLoadDelegate(on: webView, delegate: delegate)
            },
            dismissPageEditing: {
                WIDOMUIKitInspectorSelectionEnvironment.pageEditingDismissalHandler($0)
            },
            transportInspectActivationProvider: {
                WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationProvider($0)
            },
            transportInspectActivationTimeoutNanoseconds:
                WIDOMUIKitInspectorSelectionEnvironment.transportInspectActivationTimeoutNanoseconds
        )
        #else
        Self()
        #endif
    }

    public static var testValue: Self {
        Self(
            hasPrivateInspectorAccess: { _ in false },
            isInspectorConnected: { _ in nil },
            connectInspector: { _ in false },
            toggleElementSelection: { _ in false },
            setNodeSearchEnabled: { _, _ in false },
            hasNodeSearchRecognizer: { _ in false },
            removeNodeSearchRecognizers: { _ in true },
            isElementSelectionActive: { _ in false },
            startupBridgeMode: { .legacyJSON },
            bridgeModeForAttachment: { _ in .legacyJSON },
            supportsResourceLoadDelegate: { _ in false },
            setResourceLoadDelegate: { _, _ in false },
            dismissPageEditing: { _ in },
            transportInspectActivationProvider: { _ in true },
            transportInspectActivationTimeoutNanoseconds: 0
        )
    }
}

@MainActor
public struct WIInspectorPlatformClient: WIInspectorDependencyClient {
    public var environment: @MainActor @Sendable () -> [String: String]
    public var sleep: @MainActor @Sendable (Duration) async throws -> Void

    #if canImport(UIKit)
    public var uiKitSceneActivation: WIInspectorUIKitSceneActivationClient
    #endif

    public init(
        environment: @escaping @MainActor @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.environment = environment
        self.sleep = sleep
        #if canImport(UIKit)
        self.uiKitSceneActivation = .liveValue
        #endif
    }

    #if canImport(UIKit)
    public init(
        environment: @escaping @MainActor @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { duration in
            try await ContinuousClock().sleep(for: duration)
        },
        uiKitSceneActivation: WIInspectorUIKitSceneActivationClient
    ) {
        self.environment = environment
        self.sleep = sleep
        self.uiKitSceneActivation = uiKitSceneActivation
    }
    #endif

    public static var liveValue: Self {
        Self()
    }

    public static var testValue: Self {
        #if canImport(UIKit)
        Self(
            environment: { [:] },
            sleep: { _ in },
            uiKitSceneActivation: .testValue
        )
        #else
        Self(
            environment: { [:] },
            sleep: { _ in }
        )
        #endif
    }
}

#if canImport(UIKit)
import UIKit
import OSLog

private let sceneActivationLogger = Logger(
    subsystem: "WebInspectorKit",
    category: "WIInspectorUIKitSceneActivation"
)

@MainActor
public struct WIInspectorUIKitSceneActivationClient: WIInspectorDependencyClient {
    package var requester: any WIDOMUIKitSceneActivationRequesting
    package var sceneProvider: @MainActor @Sendable (UIWindow) -> (any WIDOMUIKitSceneActivationTarget)?
    package var requestingSceneProvider: @MainActor @Sendable (any WIDOMUIKitSceneActivationTarget) -> UIScene?
    public var activationTimeout: Duration
    package var activationWaiter: @MainActor @Sendable (any WIDOMUIKitSceneActivationTarget, Duration) async throws -> Void
    public var activateWindowSceneIfNeeded: @MainActor @Sendable (UIWindow, UIScene?, Duration) async throws -> Void

    public init(
        activationTimeout: Duration = .seconds(5),
        activateWindowSceneIfNeeded: @escaping @MainActor @Sendable (UIWindow, UIScene?, Duration) async throws -> Void
    ) {
        self.requester = WIInspectorNoopSceneActivationRequester()
        self.sceneProvider = { _ in nil }
        self.requestingSceneProvider = { _ in nil }
        self.activationTimeout = activationTimeout
        self.activationWaiter = { _, _ in }
        self.activateWindowSceneIfNeeded = activateWindowSceneIfNeeded
    }

    package init(
        requester: any WIDOMUIKitSceneActivationRequesting,
        sceneProvider: @escaping @MainActor @Sendable (UIWindow) -> (any WIDOMUIKitSceneActivationTarget)?,
        requestingSceneProvider: @escaping @MainActor @Sendable (any WIDOMUIKitSceneActivationTarget) -> UIScene?,
        activationTimeout: Duration,
        activationWaiter: @escaping @MainActor @Sendable (any WIDOMUIKitSceneActivationTarget, Duration) async throws -> Void
    ) {
        self.requester = requester
        self.sceneProvider = sceneProvider
        self.requestingSceneProvider = requestingSceneProvider
        self.activationTimeout = activationTimeout
        self.activationWaiter = activationWaiter
        self.activateWindowSceneIfNeeded = { pageWindow, requestingScene, timeout in
            try await Self.activateWindowSceneIfNeeded(
                pageWindow,
                requestingScene: requestingScene,
                timeout: timeout,
                requester: requester,
                sceneProvider: sceneProvider,
                requestingSceneProvider: requestingSceneProvider,
                activationWaiter: activationWaiter
            )
        }
    }

    public static var liveValue: Self {
        Self(
            requester: WIDOMUIKitSceneActivationEnvironment.requester,
            sceneProvider: {
                WIDOMUIKitSceneActivationEnvironment.sceneProvider($0)
            },
            requestingSceneProvider: {
                WIDOMUIKitSceneActivationEnvironment.requestingSceneProvider($0)
            },
            activationTimeout: WIDOMUIKitSceneActivationEnvironment.activationTimeout,
            activationWaiter: { target, timeout in
                try await WIDOMUIKitSceneActivationEnvironment.activationWaiter(target, timeout)
            }
        )
    }

    public static var testValue: Self {
        Self(activationTimeout: .milliseconds(100)) { _, _, _ in }
    }

    private static func activateWindowSceneIfNeeded(
        _ pageWindow: UIWindow,
        requestingScene preferredRequestingScene: UIScene?,
        timeout: Duration,
        requester: any WIDOMUIKitSceneActivationRequesting,
        sceneProvider: @escaping @MainActor @Sendable (UIWindow) -> (any WIDOMUIKitSceneActivationTarget)?,
        requestingSceneProvider: @escaping @MainActor @Sendable (any WIDOMUIKitSceneActivationTarget) -> UIScene?,
        activationWaiter: @escaping @MainActor @Sendable (any WIDOMUIKitSceneActivationTarget, Duration) async throws -> Void
    ) async throws {
        guard let pageScene = sceneProvider(pageWindow) else {
            return
        }
        guard pageScene.activationState != .foregroundActive else {
            return
        }

        let requestingScene = preferredRequestingScene
            ?? requestingSceneProvider(pageScene)
        let requestErrorState = WIInspectorUIKitSceneActivationRequestErrorState()
        let activationTask = Task { @MainActor in
            try await activationWaiter(pageScene, timeout)
        }

        defer {
            activationTask.cancel()
        }

        requester.requestActivation(
            of: pageScene,
            requestingScene: requestingScene
        ) { error in
            Task { @MainActor in
                sceneActivationLogger.error("page scene activation failed: \(error.localizedDescription, privacy: .public)")
                requestErrorState.signal(error)
                activationTask.cancel()
            }
        }

        do {
            try await activationTask.value
        } catch is CancellationError {
            if let error = requestErrorState.error {
                throw DOMOperationError.scriptFailure(error.localizedDescription)
            }
            throw CancellationError()
        }
    }
}

@MainActor
private final class WIInspectorUIKitSceneActivationRequestErrorState {
    private(set) var error: Error?

    func signal(_ error: Error) {
        self.error = error
    }
}

@MainActor
private final class WIInspectorNoopSceneActivationRequester: WIDOMUIKitSceneActivationRequesting {
    func requestActivation(
        of target: any WIDOMUIKitSceneActivationTarget,
        requestingScene: UIScene?,
        errorHandler: ((any Error) -> Void)?
    ) {
        _ = target
        _ = requestingScene
        _ = errorHandler
    }
}
#endif
