import Testing
import WebKit
#if canImport(UIKit)
import UIKit
#endif
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorTransport

@MainActor
struct WIInspectorDependenciesTests {
    @Test
    func liveValueUsesCurrentTransportSessionSupport() {
        let dependencies = WIInspectorDependencies.liveValue
        let expected = WITransportSession().supportSnapshot
        let actual = dependencies.transport.supportSnapshot()

        #expect(actual.availability == expected.availability)
        #expect(actual.capabilities == expected.capabilities)
        #expect(actual.failureReason == expected.failureReason)
    }

    @Test
    func testValueDisablesSideEffectfulClients() throws {
        let dependencies = WIInspectorDependencies.testValue
        let support = dependencies.transport.supportSnapshot()

        #expect(support.isSupported == false)

        let webView = WKWebView(frame: .zero)
        #expect(dependencies.webKitSPI.hasPrivateInspectorAccess(webView) == false)
        #expect(dependencies.webKitSPI.isInspectorConnected(webView) == nil)
        #expect(dependencies.webKitSPI.connectInspector(webView) == false)
        #expect(dependencies.webKitSPI.toggleElementSelection(webView) == false)
        #expect(dependencies.webKitSPI.setNodeSearchEnabled(webView, true) == false)
        #expect(dependencies.webKitSPI.hasNodeSearchRecognizer(webView) == false)
        #expect(dependencies.webKitSPI.removeNodeSearchRecognizers(webView))
        #expect(dependencies.webKitSPI.isElementSelectionActive(webView) == false)
    }

    @Test
    func testingAllowsIndividualClientOverrides() throws {
        let dependencies = WIInspectorDependencies.testing {
            $0.webKitSPI = WIInspectorWebKitSPIClient(
                setNodeSearchEnabled: { _, enabled in enabled }
            )
        }

        #expect(dependencies.webKitSPI.setNodeSearchEnabled(WKWebView(frame: .zero), true))
    }

    @Test
    func networkRuntimeUsesInjectedTransportSupportForBackendSelection() {
        let dependencies = WIInspectorDependencies.testing {
            $0.transport = WIInspectorTransportClient(
                supportSnapshot: {
                    .supported(
                        capabilities: [.networkDomain]
                    )
                },
                makeSessionWithConfiguration: { configuration in
                    .unsupported(
                        configuration: configuration,
                        reason: "Injected test session is not attached."
                    )
                }
            )
        }

        let runtime = WINetworkRuntime(dependencies: dependencies)

        #expect(runtime.model.session.testBackendTypeName() == "NetworkTransportDriver")
    }

    @Test
    func networkRuntimeUsesUnsupportedBackendWhenTransportIsUnsupported() {
        let runtime = WINetworkRuntime(dependencies: .testValue)

        #expect(runtime.model.session.testBackendTypeName() == "WINetworkUnsupportedBackend")
    }

#if canImport(UIKit)
    @Test
    func testingInjectsUIKitSceneActivationWithoutGlobalOverrides() async throws {
        let window = UIWindow()
        var capturedWindow: UIWindow?
        var capturedRequestingScene: UIScene?
        var capturedTimeout: Duration?
        let dependencies = WIInspectorDependencies.testing {
            $0.platform = WIInspectorPlatformClient(
                uiKitSceneActivation: WIInspectorUIKitSceneActivationClient(
                    activationTimeout: .milliseconds(42)
                ) { window, requestingScene, timeout in
                    capturedWindow = window
                    capturedRequestingScene = requestingScene
                    capturedTimeout = timeout
                }
            )
        }
        let sceneActivation = dependencies.platform.uiKitSceneActivation

        try await sceneActivation.activateWindowSceneIfNeeded(
            window,
            nil,
            sceneActivation.activationTimeout
        )

        #expect(capturedWindow === window)
        #expect(capturedRequestingScene == nil)
        #expect(capturedTimeout == .milliseconds(42))
    }
#endif
}
