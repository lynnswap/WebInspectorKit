#if canImport(UIKit)
import AVFoundation
import ObservationBridge
import Synchronization
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import UIKit
@testable import WebInspectorKit
@testable import WebInspectorUINetwork
@testable import WebInspectorUIBase

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct NetworkDetailSecurityModeTests: NetworkDetailTestSupport {
    @Test
    func securityModeMergesCompletionConnectionWithoutReplacingCertificateRows() async throws {
        let context = makeContext()
        let requestID = Network.Request.ID("security-live-update")
        let certificate = Network.Security.Certificate(
            subject: "CN=live.example.test",
            validFrom: Date(timeIntervalSince1970: 1_000.125),
            validUntil: Date(timeIntervalSince1970: 2_000.875),
            dnsNames: ["live.example.test"],
            ipAddresses: []
        )
        await context.apply(.requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://live.example.test/data",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ))
        await context.apply(.responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://live.example.test/data",
                status: 200,
                mimeType: "application/json"
            ).reporting(security: Network.Security(certificate: certificate)),
            resourceType: .fetch,
            timestamp: 2
        ))
        let request = try #require(context.registeredRequest(forProxyID: requestID))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(
            model: model,
            initialMode: .security
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            let security = viewController.securityViewControllerForTesting
            return security.view.isHidden == false
                && security.snapshotForTesting.itemIdentifiers.contains(where: {
                    $0.kind == .subject
                        && security.rowContentForTesting($0)?.value == "CN=live.example.test"
                })
                && security.snapshotForTesting.itemIdentifiers.contains(where: {
                    $0.kind == .connectionMetadata
                        && security.rowContentForTesting($0)?.label == String(
                            localized: "network.security.value.not_reported",
                            defaultValue: "Not reported",
                            bundle: WebInspectorUILocalization.bundle
                        )
                })
        })
        let securityController = viewController.securityViewControllerForTesting
        let subjectID = try #require(
            securityController.snapshotForTesting.itemIdentifiers.first { $0.kind == .subject }
        )

        await context.apply(.loadingFinished(
            id: requestID,
            timestamp: 3,
            sourceMapURL: nil,
            metrics: Network.Metrics().reporting(securityConnection: Network.Security.Connection(
                tlsProtocol: "TLS 1.3",
                cipher: "AES_128_GCM_SHA256"
            ))
        ))

        #expect(await waitUntilRendered(in: viewController) {
            let security = viewController.securityViewControllerForTesting
            return security.snapshotForTesting.itemIdentifiers.contains(subjectID)
                && security.snapshotForTesting.itemIdentifiers.contains(where: {
                    $0.kind == .tlsProtocol
                        && security.rowContentForTesting($0)?.value == "TLS 1.3"
                })
                && security.snapshotForTesting.itemIdentifiers.contains(where: {
                    $0.kind == .cipher
                        && security.rowContentForTesting($0)?.value == "AES_128_GCM_SHA256"
                })
        })
        #expect(request.security?.certificate == certificate)
        #expect(viewController.responseBodyFetchObservationDeliveryForTesting == nil)
        #expect(request.responseBody.phase == .available)
    }

    @Test
    func securityModeUsesGroupedRepresentativeThenExactExplicitMember() async throws {
        let context = makeContext()
        let frameID = FrameID("security-group-frame")
        let nodeID = DOM.Node.ID("security-group-node")
        installNavigationVisit(in: context, frameID: frameID)
        let representative = try #require(await applyGroupedRequest(
            to: context,
            requestID: "security-group-http",
            url: "http://example.test/plain",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 1
        ))
        let explicit = try #require(await applyGroupedRequest(
            to: context,
            requestID: "security-group-https",
            url: "https://example.test/encrypted",
            frameID: frameID,
            initiatorNodeID: nodeID,
            timestamp: 4
        ))
        await context.apply(.responseReceived(
            id: explicit.proxyID,
            response: Network.Response(
                url: explicit.url,
                status: 200,
                mimeType: "text/javascript"
            ).reporting(security: Network.Security(
                certificate: Network.Security.Certificate(subject: "CN=explicit.example.test")
            )),
            resourceType: .script,
            timestamp: 7
        ))
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: explicit, in: model)
        let viewController = NetworkDetailViewController(
            model: model,
            initialMode: .security
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            let security = viewController.securityViewControllerForTesting
            return model.selectedRequest === representative
                && security.snapshotForTesting.itemIdentifiers.contains(where: {
                    $0.kind == .scheme && security.rowContentForTesting($0)?.value == "HTTP"
                })
                && security.snapshotForTesting.itemIdentifiers.contains(where: {
                    $0.kind == .subject
                }) == false
        })

        let entryID = try #require(model.entryID(containing: explicit.id))
        let picker = NetworkDetailRequestPickerViewController(
            model: model,
            subject: try #require(model.detailSubject)
        )
        let pickerWindow = showInWindow(picker, useUIKitVisibility: true)
        defer { pickerWindow.isHidden = true }
        picker.resumeRenderingForTesting()
        let explicitIndex = try #require(
            picker.itemIDsForTesting.firstIndex(of: .request(explicit.id))
        )
        try selectPickerItem(
            at: IndexPath(item: explicitIndex, section: 0),
            in: picker
        )
        #expect(await waitUntilRendered(in: viewController) {
            let security = viewController.securityViewControllerForTesting
            return viewController.currentModeForTesting == .security
                && model.selection == .request(entryID: entryID, requestID: explicit.id)
                && model.selectedRequest === explicit
                && security.snapshotForTesting.itemIdentifiers.contains(where: {
                    $0.kind == .scheme && security.rowContentForTesting($0)?.value == "HTTPS"
                })
                && security.snapshotForTesting.itemIdentifiers.contains(where: {
                    $0.kind == .subject
                        && security.rowContentForTesting($0)?.value == "CN=explicit.example.test"
                })
        })
        #expect(viewController.responseBodyFetchObservationDeliveryForTesting == nil)
    }

    @Test
    func securityModePreservesExpansionAcrossHiddenUpdatesAndResetsAfterClearReregistrationAndRedirect() async throws {
        let context = makeContext()
        let proxyID = Network.Request.ID("security-epoch")
        let initialDNSNames = (1...7).map { "initial-\($0).example.test" }
        await context.apply(.requestWillBeSent(
            id: proxyID,
            request: Network.Request(
                id: proxyID,
                url: "https://example.test/initial",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ))
        await context.apply(.responseReceived(
            id: proxyID,
            response: Network.Response(
                url: "https://example.test/initial",
                status: 200
            ).reporting(security: Network.Security(
                certificate: Network.Security.Certificate(
                    subject: "CN=initial",
                    dnsNames: initialDNSNames
                )
            )),
            resourceType: .fetch,
            timestamp: 2
        ))
        let original = try #require(context.registeredRequest(forProxyID: proxyID))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(original)
        let viewController = NetworkDetailViewController(
            model: model,
            initialMode: .security
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            viewController.securityViewControllerForTesting.snapshotForTesting
                .itemIdentifiers.contains { $0.kind == .disclosure(.dnsNames) }
        })
        let securityController = viewController.securityViewControllerForTesting
        let originalEpoch = try #require(securityController.currentEpochForTesting)
        await withCheckedContinuation { continuation in
            securityController.toggleDisclosureForTesting(.dnsNames) {
                continuation.resume()
            }
        }
        #expect(securityController.expandedListsForTesting == [.dnsNames])
        let expandedOriginalIDs = Set(securityController.snapshotForTesting.itemIdentifiers)
        let modeControlIdentity = ObjectIdentifier(viewController.detailModeControlViewForTesting)
        #expect(viewController.navigationItem.titleView === viewController.detailModeControlViewForTesting)
        viewController.detailModeControlViewForTesting.traitOverrides.horizontalSizeClass = .compact
        viewController.detailModeControlViewForTesting.updateTraitsIfNeeded()
        viewController.detailModeControlViewForTesting.layoutIfNeeded()
        #expect(viewController.detailModeSelectedModeForTesting == .security)
        #expect(securityController.expandedListsForTesting == [.dnsNames])
        viewController.detailModeControlViewForTesting.traitOverrides.horizontalSizeClass = .regular
        viewController.detailModeControlViewForTesting.traitOverrides.preferredContentSizeCategory = .large
        viewController.detailModeControlViewForTesting.updateTraitsIfNeeded()
        #expect(ObjectIdentifier(viewController.detailModeControlViewForTesting) == modeControlIdentity)
        #expect(viewController.detailModeSelectedModeForTesting == .security)
        #expect(securityController.expandedListsForTesting == [.dnsNames])

        selectMode(.cookies, on: viewController)
        #expect(await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .cookies
                && securityController.view.isHidden
                && viewController.cookiesViewControllerForTesting.view.isHidden == false
        })
        let hiddenDNSNames = initialDNSNames + ["hidden-8.example.test"]
        let hiddenUpdateTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        await context.apply(.responseReceived(
            id: proxyID,
            response: Network.Response(
                url: "https://example.test/initial",
                status: 200
            ).reporting(security: Network.Security(
                certificate: Network.Security.Certificate(
                    subject: "CN=hidden-update",
                    dnsNames: hiddenDNSNames
                )
            )),
            resourceType: .fetch,
            timestamp: 3
        ))
        #expect(
            await model.waitForRawTransactionDeliveryForTesting(
                after: hiddenUpdateTransactionBaseline
            )
        )
        #expect(
            securityController.snapshotForTesting.itemIdentifiers.filter {
                if case .dnsName = $0.kind { return true }
                return false
            }.count == 7
        )

        selectMode(.security, on: viewController)
        #expect(await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .security
                && securityController.view.isHidden == false
                && viewController.cookiesViewControllerForTesting.view.isHidden
                && securityController.snapshotForTesting.itemIdentifiers.filter {
                    if case .dnsName = $0.kind { return true }
                    return false
                }.count == 8
                && securityController.snapshotForTesting.itemIdentifiers.contains(where: {
                    $0.kind == .subject
                        && securityController.rowContentForTesting($0)?.value == "CN=hidden-update"
                })
        })
        #expect(securityController.expandedListsForTesting == [.dnsNames])
        #expect(securityController.currentEpochForTesting == originalEpoch)

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        let suspendedDNSNames = hiddenDNSNames + ["suspended-9.example.test"]
        let suspendedUpdateTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        await context.apply(.responseReceived(
            id: proxyID,
            response: Network.Response(
                url: "https://example.test/initial",
                status: 200
            ).reporting(security: Network.Security(
                certificate: Network.Security.Certificate(
                    subject: "CN=suspended-update",
                    dnsNames: suspendedDNSNames
                )
            )),
            resourceType: .fetch,
            timestamp: 3.5
        ))
        #expect(
            await model.waitForRawTransactionDeliveryForTesting(
                after: suspendedUpdateTransactionBaseline
            )
        )
        #expect(
            securityController.snapshotForTesting.itemIdentifiers.filter {
                if case .dnsName = $0.kind { return true }
                return false
            }.count == 8
        )

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()
        #expect(await waitUntilRendered(in: viewController) {
            securityController.snapshotForTesting.itemIdentifiers.filter {
                if case .dnsName = $0.kind { return true }
                return false
            }.count == 9
                && securityController.snapshotForTesting.itemIdentifiers.contains(where: {
                    $0.kind == .subject
                        && securityController.rowContentForTesting($0)?.value == "CN=suspended-update"
                })
        })
        #expect(securityController.expandedListsForTesting == [.dnsNames])
        #expect(securityController.currentEpochForTesting == originalEpoch)

        let reregistrationTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        context.clearNetworkRequests()
        await context.apply(.requestWillBeSent(
            id: proxyID,
            request: Network.Request(
                id: proxyID,
                url: "https://example.test/reregistered",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 4
        ))
        await context.apply(.responseReceived(
            id: proxyID,
            response: Network.Response(
                url: "https://example.test/reregistered",
                status: 200
            ).reporting(security: Network.Security(
                certificate: Network.Security.Certificate(
                    subject: "CN=reregistered",
                    dnsNames: hiddenDNSNames
                )
            )),
            resourceType: .fetch,
            timestamp: 5
        ))
        let reregistered = try #require(context.registeredRequest(forProxyID: proxyID))
        #expect(
            await model.waitForRawTransactionDeliveryForTesting(
                after: reregistrationTransactionBaseline + 1
            )
        )
        model.selectRequest(reregistered)
        #expect(model.selectedRequest === reregistered)
        #expect(await waitUntilRendered(in: viewController) {
            model.selectedRequest === reregistered
                && securityController.currentEpochForTesting != originalEpoch
                && securityController.expandedListsForTesting.isEmpty
                && securityController.snapshotForTesting.itemIdentifiers.filter {
                    if case .dnsName = $0.kind { return true }
                    return false
                }.count == 5
        })
        #expect(
            expandedOriginalIDs.intersection(securityController.snapshotForTesting.itemIdentifiers)
                .isEmpty
        )
        original.applyResponse(
            Network.Response(
                url: original.url,
                status: 200
            ).reporting(security: Network.Security(
                certificate: Network.Security.Certificate(subject: "CN=stale-original")
            )),
            resourceType: .fetch,
            timestamp: 5.5
        )
        #expect(
            securityController.snapshotForTesting.itemIdentifiers.contains(where: {
                $0.kind == .subject
                    && securityController.rowContentForTesting($0)?.value == "CN=stale-original"
            }) == false
        )

        let reregisteredEpoch = try #require(securityController.currentEpochForTesting)
        reregistered.applyRedirect(
            to: Network.Request(
                id: proxyID,
                url: "https://example.test/redirected",
                method: "GET"
            ),
            redirectResponse: Network.Response(status: 302),
            timestamp: 6,
            resourceType: .fetch
        )
        #expect(await waitUntilRendered(in: viewController) {
            securityController.currentEpochForTesting != reregisteredEpoch
                && securityController.expandedListsForTesting.isEmpty
                && securityController.snapshotForTesting.itemIdentifiers.contains(where: {
                    $0.kind == .status
                })
        })

        context.clearNetworkRequests()
        #expect(await waitUntilRendered(in: viewController) {
            securityController.snapshotForTesting.itemIdentifiers.isEmpty
                && securityController.expandedListsForTesting.isEmpty
        })
    }

    @Test
    func securityModeOwnsSurfaceAfterInFlightResponseBodyFetchCompletes() async throws {
        let fixture = try await makeLiveNetworkDetailFixture()
        let context = fixture.context
        let requestID = Network.Request.ID("security-in-flight-body")
        let gate = WebInspectorTestGate()
        await fixture.runtime.backend.hold(
            domain: "Network",
            method: "getResponseBody",
            gate: gate
        )
        await fixture.runtime.backend.enqueue(
            Network.Body(data: #"{"stale":true}"#, base64Encoded: false),
            for: "Network",
            method: "getResponseBody"
        )
        await context.apply(.requestWillBeSent(
            id: requestID,
            request: Network.Request(
                id: requestID,
                url: "https://example.test/security-body.json",
                method: "GET"
            ),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ))
        await context.apply(.responseReceived(
            id: requestID,
            response: Network.Response(
                url: "https://example.test/security-body.json",
                status: 200,
                mimeType: "application/json"
            ),
            resourceType: .fetch,
            timestamp: 2
        ))
        await context.apply(.loadingFinished(
            id: requestID,
            timestamp: 3,
            sourceMapURL: nil,
            metrics: nil
        ))
        let request = try #require(context.registeredRequest(forProxyID: requestID))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(
            model: model,
            initialMode: .preview
        )
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        _ = await fixture.runtime.backend.waitForRecordedCommands(
            domain: "Network",
            method: "getResponseBody",
            count: 1
        )
        #expect(request.responseBody.phase == .fetching)
        #expect(viewController.responseBodyFetchObservationDeliveryForTesting != nil)

        selectMode(.security, on: viewController)
        #expect(await waitUntilRendered(in: viewController) {
            viewController.currentModeForTesting == .security
                && viewController.securityViewControllerForTesting.view.isHidden == false
                && viewController.previewViewForTesting.isHidden
                && viewController.responseBodyFetchObservationDeliveryForTesting == nil
        })
        let securityItems = viewController.securityViewControllerForTesting
            .snapshotForTesting.itemIdentifiers
        let renderCount = viewController.selectedRequestRenderCountForTesting

        await gate.open()
        #expect(await waitForNetworkBodyPhase(in: request.responseBody) { $0 == .loaded } != nil)
        #expect(viewController.currentModeForTesting == .security)
        #expect(viewController.securityViewControllerForTesting.view.isHidden == false)
        #expect(viewController.previewViewForTesting.isHidden)
        #expect(
            viewController.contentScrollView(for: .top)
                === viewController.securityViewControllerForTesting.collectionView
        )
        #expect(
            viewController.securityViewControllerForTesting.snapshotForTesting.itemIdentifiers
                == securityItems
        )
        #expect(viewController.selectedRequestRenderCountForTesting == renderCount)
        await fixture.runtime.backend.enqueue((), for: "Console", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Runtime", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Network", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Page", method: "disable")
        await fixture.runtime.backend.enqueue((), for: "Inspector", method: "disable")
        await context.stop()
        #expect(context.state == .detached)
    }
}
}
#endif
