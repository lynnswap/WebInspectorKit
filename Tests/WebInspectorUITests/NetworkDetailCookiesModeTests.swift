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
struct NetworkDetailCookiesModeTests: NetworkDetailTestSupport {
    @Test
    func cookiesListUsesNativeInsetGroupedLayoutAndFixedStateSections() async {
        let viewController = NetworkCookiesViewController()
        let requestEpoch = NetworkCookiesViewController.RequestEpoch.testing(viewController)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        await renderCookies(
            NetworkCookieSections(
                request: .unavailable(.notCaptured),
                response: .loading
            ),
            in: viewController
        )

        let configuration = NetworkCookiesViewController.listLayoutConfigurationForTesting
        #expect(configuration.appearance == .insetGrouped)
        #expect(configuration.headerMode == .supplementary)
        #expect(configuration.showsSeparators)
        #expect(viewController.collectionView.collectionViewLayout is UICollectionViewCompositionalLayout)
        #expect(viewController.collectionView.allowsSelection == false)
        #expect(viewController.snapshotForTesting.sectionIdentifiers == [.request, .response])
        #expect(viewController.snapshotForTesting.itemIdentifiers(inSection: .request) == [
            .state(epoch: requestEpoch, section: .request, kind: .requestNotCaptured)
        ])
        #expect(viewController.snapshotForTesting.itemIdentifiers(inSection: .response) == [
            .state(epoch: requestEpoch, section: .response, kind: .responseLoading)
        ])
        #expect(
            NetworkCookiesViewController.sectionTitleForTesting(.request)
                == localized(
                    "network.section.request",
                    defaultValue: "Request"
                )
        )
        #expect(
            NetworkCookiesViewController.sectionTitleForTesting(.response)
                == localized(
                    "network.section.response",
                    defaultValue: "Response"
                )
        )
        let requestNotCaptured = viewController.messageContentForTesting(
            .state(epoch: requestEpoch, section: .request, kind: .requestNotCaptured)
        )
        #expect(requestNotCaptured?.title == localized(
            "network.cookies.request.not_captured",
            defaultValue: "Not Captured"
        ))
        #expect(requestNotCaptured?.accessibilityLabel.contains(localized(
            "network.cookies.section.request",
            defaultValue: "Request Cookies"
        )) == true)
        #expect(
            viewController.messageContentForTesting(
                .state(epoch: requestEpoch, section: .response, kind: .responseLoading)
            )?.kind == .loading
        )
        #expect(
            viewController.messageContentForTesting(
                .state(epoch: requestEpoch, section: .response, kind: .responseLoading)
            )?.title == localized(
                "network.cookies.response.loading",
                defaultValue: "Waiting"
            )
        )

        await renderCookies(
            NetworkCookieSections(
                request: .unavailable(.servedFromMemoryCache),
                response: .noResponse
            ),
            in: viewController
        )
        #expect(viewController.snapshotForTesting.itemIdentifiers(inSection: .request) == [
            .state(epoch: requestEpoch, section: .request, kind: .requestMemoryCache)
        ])
        #expect(viewController.snapshotForTesting.itemIdentifiers(inSection: .response) == [
            .state(epoch: requestEpoch, section: .response, kind: .responseMissing)
        ])
        let memoryCache = viewController.messageContentForTesting(
            .state(epoch: requestEpoch, section: .request, kind: .requestMemoryCache)
        )
        #expect(memoryCache?.title == localized(
            "network.cookies.request.not_captured",
            defaultValue: "Not Captured"
        ))
        #expect(memoryCache?.detail == localized(
            "network.cookies.request.memory_cache",
            defaultValue: "Memory Cache"
        ))
        #expect(
            viewController.messageContentForTesting(
                .state(epoch: requestEpoch, section: .response, kind: .responseMissing)
            )?.title == localized(
                "network.cookies.response.missing",
                defaultValue: "Not Received"
            )
        )

        await renderCookies(
            NetworkCookieSections(request: .empty, response: .empty),
            in: viewController
        )
        #expect(viewController.snapshotForTesting.itemIdentifiers(inSection: .request) == [
            .state(epoch: requestEpoch, section: .request, kind: .requestEmpty)
        ])
        #expect(viewController.snapshotForTesting.itemIdentifiers(inSection: .response) == [
            .state(epoch: requestEpoch, section: .response, kind: .responseEmpty)
        ])
        let none = localized("network.cookies.request.empty", defaultValue: "None")
        #expect(viewController.messageContentForTesting(
            .state(epoch: requestEpoch, section: .request, kind: .requestEmpty)
        )?.title == none)
        #expect(viewController.messageContentForTesting(
            .state(epoch: requestEpoch, section: .response, kind: .responseEmpty)
        )?.title == localized("network.cookies.response.empty", defaultValue: "None"))
    }

    @Test
    func cookiesListKeepsValidRowsWithPartialAndAmbiguousRawWarnings() async throws {
        let requestReport = try #require(NetworkCookieParser.parseRequestHeaders([
            "Cookie": "z=3; broken; also-broken; a=1; a=2"
        ]))
        let responseReport = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": "first=1, second=2"
        ]))
        #expect(requestReport.status == .partial)
        #expect(requestReport.diagnostics.count == 2)
        #expect(responseReport.status == .ambiguousCombined)

        let viewController = NetworkCookiesViewController()
        let requestEpoch = NetworkCookiesViewController.RequestEpoch.testing(viewController)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        await renderCookies(
            NetworkCookieSections(
                request: .values(requestReport),
                response: .values(responseReport)
            ),
            in: viewController
        )

        #expect(viewController.snapshotForTesting.itemIdentifiers(inSection: .request) == [
            .requestCookie(
                epoch: requestEpoch,
                key: .init(name: "a", duplicateOccurrence: 0)
            ),
            .requestCookie(
                epoch: requestEpoch,
                key: .init(name: "a", duplicateOccurrence: 1)
            ),
            .requestCookie(
                epoch: requestEpoch,
                key: .init(name: "z", duplicateOccurrence: 0)
            ),
            .diagnostic(epoch: requestEpoch, section: .request, ordinal: 0),
        ])
        #expect(viewController.snapshotForTesting.itemIdentifiers(inSection: .response) == [
            .diagnostic(epoch: requestEpoch, section: .response, ordinal: 0)
        ])
        #expect(
            viewController.cookieContentForTesting(.requestCookie(
                epoch: requestEpoch,
                key: .init(name: "a", duplicateOccurrence: 0)
            ))?
                .fields.first?.value == "a"
        )
        #expect(
            viewController.cookieContentForTesting(.requestCookie(
                epoch: requestEpoch,
                key: .init(name: "a", duplicateOccurrence: 1)
            ))?
                .fields.first?.value == "a"
        )
        #expect(
            viewController.messageContentForTesting(
                .diagnostic(epoch: requestEpoch, section: .request, ordinal: 0)
            )?.detail == " broken\n also-broken"
        )
        #expect(
            viewController.messageContentForTesting(
                .diagnostic(epoch: requestEpoch, section: .response, ordinal: 0)
            )?.detail == "first=1, second=2"
        )
    }

    @Test
    func cookiesListKeepsSemanticIdentityOnlyWithinOneRequestEpoch() async throws {
        let initialReport = try #require(NetworkCookieParser.parseRequestHeaders([
            "Cookie": "b=2; broken; c=3"
        ]))
        let refinedReport = try #require(NetworkCookieParser.parseRequestHeaders([
            "Cookie": "a=1; broken; b=4"
        ]))
        let initialSections = NetworkCookieSections(
            request: .values(initialReport),
            response: .loading
        )
        let refinedSections = NetworkCookieSections(
            request: .values(refinedReport),
            response: .loading
        )
        let viewController = NetworkCookiesViewController()
        let firstEpoch = NetworkCookiesViewController.RequestEpoch.testing(viewController)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        await renderCookies(initialSections, requestEpoch: firstEpoch, in: viewController)
        let initialRequestIDs = viewController.snapshotForTesting.itemIdentifiers(inSection: .request)
        let initialB = try #require(initialRequestIDs.first { itemID in
            guard case let .requestCookie(_, key) = itemID else {
                return false
            }
            return key == .init(name: "b", duplicateOccurrence: 0)
        })
        let initialC = try #require(initialRequestIDs.first { itemID in
            guard case let .requestCookie(_, key) = itemID else {
                return false
            }
            return key == .init(name: "c", duplicateOccurrence: 0)
        })

        await renderCookies(refinedSections, requestEpoch: firstEpoch, in: viewController)
        let refinedIDs = viewController.snapshotForTesting.itemIdentifiers
        #expect(refinedIDs.contains(initialB))
        #expect(refinedIDs.contains(initialC) == false)

        let nextEpochOwner = NSObject()
        let nextEpoch = NetworkCookiesViewController.RequestEpoch.testing(nextEpochOwner)
        await renderCookies(refinedSections, requestEpoch: nextEpoch, in: viewController)
        let nextEpochIDs = viewController.snapshotForTesting.itemIdentifiers
        #expect(Set(refinedIDs).intersection(nextEpochIDs).isEmpty)
        #expect(nextEpochIDs.contains(where: isRequestCookieItem))
        #expect(nextEpochIDs.contains { itemID in
            if case .diagnostic = itemID {
                return true
            }
            return false
        })
        #expect(nextEpochIDs.contains { itemID in
            isCookieStateItem(itemID, section: .response, kind: .responseLoading)
        })
    }

    @Test
    func responseCookieCellShowsAllFieldsAndAdaptsColumnsAccessibilityAndRTL() async throws {
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": "session=abc; Domain=example.test; Path=/; Partitioned; "
                + "Expires=Wed, 09 Jun 2027 10:18:14 GMT; Max-Age=0; Secure; "
                + "HttpOnly; SameSite=Lax; Priority=High"
        ]))
        let viewController = NetworkCookiesViewController()
        let requestEpoch = NetworkCookiesViewController.RequestEpoch.testing(viewController)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        await renderCookies(
            NetworkCookieSections(request: .empty, response: .values(report)),
            in: viewController
        )
        let content = try #require(
            viewController.cookieContentForTesting(.responseCookie(
                epoch: requestEpoch,
                key: .init(name: "session", duplicateOccurrence: 0)
            ))
        )
        let nameLabel = localized(
            "network.cookies.field.name",
            defaultValue: "Name"
        )
        let maxAgeLabel = localized(
            "network.cookies.field.max_age",
            defaultValue: "Max-Age"
        )
        let secureLabel = localized(
            "network.cookies.field.secure",
            defaultValue: "Secure"
        )
        let httpOnlyLabel = localized(
            "network.cookies.field.http_only",
            defaultValue: "HttpOnly"
        )
        let partitionedLabel = localized(
            "network.cookies.field.partitioned",
            defaultValue: "Partitioned"
        )
        let yes = localized(
            "network.cookies.value.yes",
            defaultValue: "Yes"
        )
        #expect(content.fields.count == 11)
        #expect(content.fields.map(\.label).contains(nameLabel))
        #expect(content.fields.map(\.label).contains(maxAgeLabel))
        #expect(content.fields.first { $0.label == maxAgeLabel }?.value == "0")
        #expect(content.fields.first { $0.label == secureLabel }?.value == yes)
        #expect(content.fields.first { $0.label == httpOnlyLabel }?.value == yes)
        #expect(content.fields.first { $0.label == partitionedLabel }?.value == yes)
        #expect(content.fields.last?.isFullWidth == true)
        #expect(content.fields.last?.value.contains("Priority=High") == true)

        let host = UIViewController()
        let cellHost = UIViewController()
        host.addChild(cellHost)
        host.view.addSubview(cellHost.view)
        cellHost.view.frame = host.view.bounds
        cellHost.didMove(toParent: host)
        let cell = NetworkCookieCell(frame: CGRect(x: 0, y: 0, width: 700, height: 200))
        cellHost.view.addSubview(cell)
        let cellWindow = showInWindow(host)
        defer { cellWindow.isHidden = true }
        cellHost.traitOverrides.horizontalSizeClass = .regular
        cellHost.traitOverrides.preferredContentSizeCategory = .large
        cellHost.updateTraitsIfNeeded()
        cell.updateTraitsIfNeeded()
        cell.bind(content)
        host.view.layoutIfNeeded()
        #expect(cell.usesTwoColumnsForTesting)
        #expect(cell.fieldRowCountForTesting == 6)

        cellHost.traitOverrides.horizontalSizeClass = .compact
        cellHost.updateTraitsIfNeeded()
        cell.updateTraitsIfNeeded()
        cell.bind(content)
        #expect(cell.usesTwoColumnsForTesting == false)
        #expect(cell.fieldRowCountForTesting == content.fields.count)

        cellHost.traitOverrides.horizontalSizeClass = .regular
        cellHost.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        cellHost.updateTraitsIfNeeded()
        cell.updateTraitsIfNeeded()
        cell.bind(content)
        #expect(cell.usesTwoColumnsForTesting == false)
        #expect(cell.fieldRowCountForTesting == content.fields.count)

        cell.semanticContentAttribute = .forceRightToLeft
        cell.bind(content)
        #expect(cell.effectiveUserInterfaceLayoutDirection == .rightToLeft)
        #expect(cell.accessibilityLabel?.contains("\(secureLabel), \(yes)") == true)
        #expect(cell.accessibilityLabel?.contains("\(partitionedLabel), \(yes)") == true)
        #expect(cell.accessibilityValue == nil)

        cell.prepareForReuse()
        #expect(cell.renderedFieldsForTesting.isEmpty)
        #expect(cell.accessibilityLabel == nil)
    }

    @Test
    func responseCookieUsesDashForUnsetAttributesAndDescriptiveAccessibility() async throws {
        let report = try #require(NetworkCookieParser.parseResponseHeaders([
            "Set-Cookie": "session=abc"
        ]))
        let viewController = NetworkCookiesViewController()
        let requestEpoch = NetworkCookiesViewController.RequestEpoch.testing(viewController)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        await renderCookies(
            NetworkCookieSections(request: .empty, response: .values(report)),
            in: viewController
        )
        let content = try #require(
            viewController.cookieContentForTesting(.responseCookie(
                epoch: requestEpoch,
                key: .init(name: "session", duplicateOccurrence: 0)
            ))
        )
        let domainLabel = localized("network.cookies.field.domain", defaultValue: "Domain")
        let domain = try #require(content.fields.first { $0.label == domainLabel })
        let notSet = localized("network.cookies.value.not_set", defaultValue: "Not Set")
        #expect(domain.value == "-")
        #expect(domain.accessibilityValue == notSet)

        let cell = NetworkCookieCell(frame: .zero)
        cell.bind(content)
        #expect(cell.accessibilityLabel?.contains("\(domainLabel), \(notSet)") == true)
        #expect(cell.accessibilityLabel?.contains("\(domainLabel), -") == false)
    }

    @Test
    func cookiesModeTracksLoadingResponseAndRefinedMetricsHeaders() async throws {
        let context = makeContext()
        let request = try #require(await applyRequestWithoutResponse(
            to: context,
            requestID: "cookie-live",
            url: "https://example.com/cookie-live",
            requestHeaders: ["Cookie": "initial=1"]
        ))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model, initialMode: .cookies)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            requestCookieValue(in: viewController) == "1"
                && viewController.cookiesViewControllerForTesting.snapshotForTesting
                    .itemIdentifiers(inSection: .response)
                    .contains(where: { isCookieStateItem(
                        $0,
                        section: .response,
                        kind: .responseLoading
                    ) })
        })

        await applyResponseReceived(
            to: context,
            requestID: "cookie-live",
            url: request.url,
            responseHeaders: ["Set-Cookie": "response=2; HttpOnly"],
            responseMimeType: "text/plain",
            timestamp: 2
        )

        #expect(await waitUntilRendered(in: viewController) {
            viewController.cookiesViewControllerForTesting.snapshotForTesting
                .itemIdentifiers(inSection: .response).filter(isResponseCookieItem).count == 1
        })

        await applyLoadingFinished(
            to: context,
            requestID: "cookie-live",
            timestamp: 3,
            requestHeaders: ["Cookie": "refined=3"]
        )

        #expect(await waitUntilRendered(in: viewController) {
            requestCookieName(in: viewController) == "refined"
                && requestCookieValue(in: viewController) == "3"
        })
        #expect(viewController.selectedRequestRenderObservationDeliveryForTesting?.isActive == true)
    }

    @Test
    func cookiesModeUsesRepresentativeThenExplicitGroupedRequestWithoutAggregation() async throws {
        let context = makeContext()
        let frameID = FrameID("cookie-group-frame")
        let nodeID = DOM.Node.ID("cookie-group-node")
        installNavigationVisit(in: context, frameID: frameID)
        let first = try #require(await applyGroupedRequest(
            to: context,
            requestID: "cookie-group-first",
            url: "https://example.com/first",
            frameID: frameID,
            initiatorNodeID: nodeID,
            requestHeaders: ["Cookie": "first=1"],
            timestamp: 1
        ))
        let second = try #require(await applyGroupedRequest(
            to: context,
            requestID: "cookie-group-second",
            url: "https://example.com/second",
            frameID: frameID,
            initiatorNodeID: nodeID,
            requestHeaders: ["Cookie": "second=2"],
            timestamp: 4
        ))
        let model = NetworkPanelModel(context: context)
        try selectEntry(containing: first, in: model)
        let viewController = NetworkDetailViewController(model: model, initialMode: .cookies)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            requestCookieName(in: viewController) == "first"
        })
        let firstCookieItemID = try #require(
            viewController.cookiesViewControllerForTesting.snapshotForTesting
                .itemIdentifiers(inSection: .request).first(where: isRequestCookieItem)
        )
        #expect(
            viewController.cookiesViewControllerForTesting.snapshotForTesting
                .itemIdentifiers(inSection: .request).filter(isRequestCookieItem).count == 1
        )
        #expect(viewController.requestPickerItemForTesting != nil)

        model.selectRequest(second)

        #expect(await waitUntilRendered(in: viewController) {
            requestCookieName(in: viewController) == "second"
                && requestCookieValue(in: viewController) == "2"
        })
        let secondCookieItemID = try #require(
            viewController.cookiesViewControllerForTesting.snapshotForTesting
                .itemIdentifiers(inSection: .request).first(where: isRequestCookieItem)
        )
        #expect(secondCookieItemID != firstCookieItemID)
        #expect(
            viewController.cookiesViewControllerForTesting.snapshotForTesting
                .itemIdentifiers(inSection: .request).filter(isRequestCookieItem).count == 1
        )
        #expect(model.selectedRequest === second)
        #expect(viewController.requestPickerItemForTesting != nil)
    }

    @Test
    func cookiesModeCatchesUpHiddenUpdatesAndIgnoresClearedInstanceAfterSameIDReregistration() async throws {
        let context = makeContext()
        let request = try #require(await applyRequest(
            to: context,
            requestID: "cookie-instance",
            url: "https://example.com/original",
            requestHeaders: ["Cookie": "original=1"]
        ))
        let model = NetworkPanelModel(context: context)
        model.selectRequest(request)
        let viewController = NetworkDetailViewController(model: model, initialMode: .cookies)
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        #expect(await waitUntilRendered(in: viewController) {
            requestCookieName(in: viewController) == "original"
        })

        viewController.beginAppearanceTransition(false, animated: false)
        viewController.endAppearanceTransition()
        let transactionBaseline = model.rawTransactionDeliveryCountForTesting
        await applyLoadingFinished(
            to: context,
            requestID: "cookie-instance",
            timestamp: 4,
            requestHeaders: ["Cookie": "hidden=2"]
        )
        #expect(await model.waitForRawTransactionDeliveryForTesting(after: transactionBaseline))
        #expect(requestCookieName(in: viewController) == "original")

        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()
        #expect(await waitUntilRendered(in: viewController) {
            requestCookieName(in: viewController) == "hidden"
        })

        let proxyID = Network.Request.ID("cookie-instance")
        let reregistrationTransactionBaseline = model.rawTransactionDeliveryCountForTesting
        context.network.clearRequests()
        let reregistered = try #require(await applyRequest(
            to: context,
            requestID: "cookie-instance",
            url: "https://example.com/reregistered",
            requestHeaders: ["Cookie": "reregistered=3"]
        ))
        #expect(await model.waitForRawTransactionDeliveryForTesting(
            after: reregistrationTransactionBaseline + 1
        ))
        model.selectRequest(reregistered)

        #expect(await waitUntilRendered(in: viewController) {
            model.selectedRequest === reregistered
                && requestCookieName(in: viewController) == "reregistered"
        })

        request.applyRequestWillBeSent(
            request: Network.Request(
                id: proxyID,
                url: "https://example.com/stale",
                method: "GET",
                headers: ["Cookie": "stale=4"]
            ),
            initiator: request.initiator,
            navigationVisit: request.navigationVisit,
            resourceType: request.resourceType,
            timestamp: 5,
            chronologySequence: 5
        )
        #expect(requestCookieName(in: viewController) == "reregistered")

        reregistered.applyRequestWillBeSent(
            request: Network.Request(
                id: proxyID,
                url: "https://example.com/current",
                method: "GET",
                headers: ["Cookie": "current=5"]
            ),
            initiator: reregistered.initiator,
            navigationVisit: reregistered.navigationVisit,
            resourceType: reregistered.resourceType,
            timestamp: 6,
            chronologySequence: 6
        )
        #expect(await waitUntilRendered(in: viewController) {
            requestCookieName(in: viewController) == "current"
                && requestCookieValue(in: viewController) == "5"
        })
    }
}
}
#endif
