#if canImport(UIKit)
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import UIKit
@testable import WebInspectorUINetwork
@testable import WebInspectorUIBase

extension WebInspectorUIRenderingTests {
@MainActor
@Suite
struct NetworkSecurityViewControllerTests {
    @Test
    func nativeListRendersEverySummaryStateWithoutVerdicts() async throws {
        let request = makeRequest(id: "security-states", url: "https://example.test")
        let epoch = NetworkSecurityRequestEpoch(request: request)
        let viewController = NetworkSecurityViewController()
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        await render(.plaintextScheme(.http), epoch: epoch, in: viewController)
        #expect(
            viewController.snapshotForTesting.sectionIdentifiers
                == NetworkSecuritySectionID.allCases
        )
        #expect(row(.scheme, in: viewController)?.value == "HTTP")
        #expect(
            row(.status, in: viewController)?.value
                == localized(
                    "network.security.status.http",
                    defaultValue: "HTTP scheme reported; TLS does not apply."
                )
        )
        #expect(
            row(.connectionMetadata, in: viewController)?.value
                == localized("network.security.value.not_applicable", defaultValue: "Not applicable")
        )

        await render(.pending(.wss), epoch: epoch, in: viewController)
        #expect(row(.scheme, in: viewController)?.value == "WSS")
        #expect(
            row(.status, in: viewController)?.value
                == localized("network.security.value.pending", defaultValue: "Response pending")
        )

        await render(
            .encryptedScheme(.https, metadata: .notReported),
            epoch: epoch,
            in: viewController
        )
        #expect(row(.scheme, in: viewController)?.value == "HTTPS")
        #expect(
            row(.securityMetadata, in: viewController)?.value
                == localized("network.security.value.not_reported", defaultValue: "Not reported")
        )

        await render(
            .unavailable(.https, reason: .canceledBeforeResponse(reason: "cancelled raw")),
            epoch: epoch,
            in: viewController
        )
        #expect(row(.reason, in: viewController)?.value == "cancelled raw")
        #expect(row(.reason, in: viewController)?.usesTechnicalValueDirection == true)

        await render(.notApplicable(scheme: "Custom+Scheme"), epoch: epoch, in: viewController)
        #expect(row(.scheme, in: viewController)?.value == "Custom+Scheme")
        let visibleText = viewController.snapshotForTesting.itemIdentifiers.compactMap {
            viewController.rowContentForTesting($0)?.value
        }.joined(separator: "\n").lowercased()
        for verdict in ["trusted", "valid certificate", "hostname matched", "expired", "secure connection"] {
            #expect(visibleText.contains(verdict) == false)
        }
        #expect(NetworkSecurityViewController.listConfigurationForTesting.appearance == .insetGrouped)
        #expect(NetworkSecurityViewController.listConfigurationForTesting.headerMode == .supplementary)
        #expect(viewController.collectionView.collectionViewLayout is UICollectionViewCompositionalLayout)
    }

    @Test
    func sectionHeadersExposeHeadingSemanticsAndClearThemForReuse() async throws {
        let request = makeRequest(id: "security-headings", url: "https://example.test")
        let viewController = NetworkSecurityViewController()
        let window = showInWindow(viewController)
        defer { window.isHidden = true }

        await render(
            .pending(.https),
            epoch: NetworkSecurityRequestEpoch(request: request),
            in: viewController
        )
        for section in NetworkSecuritySectionID.allCases {
            let header = try #require(viewController.sectionHeaderForTesting(section))
            #expect(header.isAccessibilityElement)
            #expect(
                header.accessibilityLabel
                    == NetworkSecurityViewController.sectionTitleForTesting(section)
            )
            #expect(header.accessibilityTraits.contains(.header))
        }

        let reusedHeader = UICollectionViewListCell()
        reusedHeader.contentConfiguration = UIListContentConfiguration.header()
        reusedHeader.isAccessibilityElement = true
        reusedHeader.accessibilityLabel = "stale heading"
        reusedHeader.accessibilityTraits = .header
        NetworkSecurityViewController.clearSectionHeaderForTesting(reusedHeader)
        #expect(reusedHeader.contentConfiguration == nil)
        #expect(reusedHeader.isAccessibilityElement == false)
        #expect(reusedHeader.accessibilityLabel == nil)
        #expect(reusedHeader.accessibilityTraits.isEmpty)
    }

    @Test
    func reportedEmptyAndNestedEmptyMetadataRemainDistinct() async throws {
        let request = makeRequest(id: "security-empty", url: "https://example.test")
        let epoch = NetworkSecurityRequestEpoch(request: request)
        let viewController = NetworkSecurityViewController()
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        let notReported = localized(
            "network.security.value.not_reported",
            defaultValue: "Not reported"
        )
        let reported = localized("network.security.value.reported", defaultValue: "Reported")
        let empty = localized(
            "network.security.value.empty_reported",
            defaultValue: "Empty value reported"
        )
        let noValues = localized(
            "network.security.value.no_values_reported",
            defaultValue: "No values reported"
        )

        await render(
            .encryptedScheme(.https, metadata: .reported(Network.Security())),
            epoch: epoch,
            in: viewController
        )
        #expect(row(.securityMetadata, in: viewController)?.value == reported)
        #expect(row(.connectionMetadata, in: viewController)?.value == notReported)
        #expect(row(.certificateMetadata, in: viewController)?.value == notReported)
        #expect(row(.tlsProtocol, in: viewController) == nil)

        let security = Network.Security(
            connection: Network.Security.Connection(),
            certificate: Network.Security.Certificate(
                subject: "",
                dnsNames: nil,
                ipAddresses: []
            )
        )
        await render(
            .encryptedScheme(.https, metadata: .reported(security)),
            epoch: epoch,
            in: viewController
        )
        #expect(row(.connectionMetadata, in: viewController)?.value == reported)
        #expect(row(.tlsProtocol, in: viewController)?.value == notReported)
        #expect(row(.cipher, in: viewController)?.value == notReported)
        #expect(row(.certificateMetadata, in: viewController)?.value == reported)
        #expect(row(.subject, in: viewController)?.value == empty)
        #expect(row(.dnsState, in: viewController)?.value == notReported)
        #expect(row(.ipAddressState, in: viewController)?.value == noValues)
    }

    @Test
    func longListsPreserveOrdinalIdentityAndExpandIndependentlyWithinEpoch() async throws {
        let request = makeRequest(id: "security-lists", url: "https://example.test")
        let epoch = NetworkSecurityRequestEpoch(request: request)
        let viewController = NetworkSecurityViewController()
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        let longHostname = String(repeating: "unbroken-hostname-", count: 12) + ".example"
        var dnsNames = [
            "one.example",
            "duplicate.example",
            "duplicate.example",
            "",
            longHostname,
            "six.example",
        ]
        let ipAddresses = [
            "192.0.2.1",
            "192.0.2.2",
            "192.0.2.3",
            "192.0.2.4",
            "192.0.2.5",
            "192.0.2.6",
        ]

        await render(
            reportedSecurity(dnsNames: dnsNames, ipAddresses: ipAddresses),
            epoch: epoch,
            in: viewController
        )
        let collapsedDNSIDs = itemIDs(prefix: .dnsName, in: viewController)
        let collapsedIPIDs = itemIDs(prefix: .ipAddress, in: viewController)
        #expect(collapsedDNSIDs.map(\.kind) == (0..<5).map(NetworkSecurityItemID.Kind.dnsName))
        #expect(collapsedIPIDs.map(\.kind) == (0..<5).map(NetworkSecurityItemID.Kind.ipAddress))
        #expect(
            row(.dnsName(3), in: viewController)?.value
                == localized(
                    "network.security.value.empty_reported",
                    defaultValue: "Empty value reported"
                )
        )
        let dnsDisclosureID = try #require(itemID(.disclosure(.dnsNames), in: viewController))
        let ipDisclosureID = try #require(itemID(.disclosure(.ipAddresses), in: viewController))
        let showMoreDNSFormat = localized(
            "network.security.action.show_more_dns_names",
            defaultValue: "Show %lld More DNS Names"
        )
        let showMoreIPFormat = localized(
            "network.security.action.show_more_ip_addresses",
            defaultValue: "Show %lld More IP Addresses"
        )
        #expect(
            viewController.rowContentForTesting(dnsDisclosureID)?.label
                == String.localizedStringWithFormat(showMoreDNSFormat, Int64(1))
        )
        #expect(
            viewController.rowContentForTesting(ipDisclosureID)?.label
                == String.localizedStringWithFormat(showMoreIPFormat, Int64(1))
        )
        let englishShowMoreDNSFormat = try #require(localized(
            "network.security.action.show_more_dns_names",
            defaultValue: "Show %lld More DNS Names",
            locale: "en"
        ))
        let englishShowMoreIPFormat = try #require(localized(
            "network.security.action.show_more_ip_addresses",
            defaultValue: "Show %lld More IP Addresses",
            locale: "en"
        ))
        let englishDNSLabel = unsafe String(
            format: englishShowMoreDNSFormat,
            locale: Locale(identifier: "en"),
            arguments: [Int64(1)]
        )
        let englishIPLabel = unsafe String(
            format: englishShowMoreIPFormat,
            locale: Locale(identifier: "en"),
            arguments: [Int64(1)]
        )
        #expect(englishDNSLabel == "Show 1 More DNS Name")
        #expect(englishIPLabel == "Show 1 More IP Address")
        let disclosureCell = try #require(visibleCell(dnsDisclosureID, in: viewController))
        let dnsAccessibilityLabel = disclosureCell.accessibilityLabel
        #expect(disclosureCell.accessibilityTraits.contains(.button))
        #expect(disclosureCell.accessibilityValue == localized(
            "network.security.accessibility.collapsed",
            defaultValue: "Collapsed"
        ))
        #expect(disclosureCell.accessibilityHint?.isEmpty == false)
        let ipDisclosureCell = try #require(visibleCell(ipDisclosureID, in: viewController))
        #expect(dnsAccessibilityLabel != ipDisclosureCell.accessibilityLabel)
        #expect(dnsAccessibilityLabel == String.localizedStringWithFormat(
            showMoreDNSFormat,
            Int64(1)
        ))
        #expect(ipDisclosureCell.accessibilityLabel == String.localizedStringWithFormat(
            showMoreIPFormat,
            Int64(1)
        ))

        let longHostnameID = try #require(itemID(.dnsName(4), in: viewController))
        let longHostnameCell = try #require(visibleCell(longHostnameID, in: viewController))
        let longHostnameContent = try #require(
            longHostnameCell.contentConfiguration as? UIListContentConfiguration
        )
        #expect(longHostnameContent.secondaryTextProperties.numberOfLines == 0)
        #expect(longHostnameContent.secondaryTextProperties.lineBreakMode == .byCharWrapping)

        await toggle(.dnsNames, in: viewController)
        #expect(itemIDs(prefix: .dnsName, in: viewController).count == 6)
        #expect(itemIDs(prefix: .ipAddress, in: viewController).count == 5)
        #expect(Set(collapsedDNSIDs).isSubset(of: Set(viewController.snapshotForTesting.itemIdentifiers)))
        #expect(viewController.expandedListsForTesting == [.dnsNames])
        #expect(itemID(.disclosure(.dnsNames), in: viewController) == dnsDisclosureID)
        #expect(
            viewController.rowContentForTesting(dnsDisclosureID)?.label
                == localized(
                    "network.security.action.show_less_dns_names",
                    defaultValue: "Show Less DNS Names"
                )
        )
        let expandedDisclosureCell = try #require(visibleCell(dnsDisclosureID, in: viewController))
        #expect(expandedDisclosureCell.accessibilityValue == localized(
            "network.security.accessibility.expanded",
            defaultValue: "Expanded"
        ))

        dnsNames.append("seven.example")
        await render(
            reportedSecurity(dnsNames: dnsNames, ipAddresses: ipAddresses),
            epoch: epoch,
            in: viewController
        )
        #expect(itemIDs(prefix: .dnsName, in: viewController).count == 7)
        #expect(viewController.expandedListsForTesting == [.dnsNames])

        await toggle(.ipAddresses, in: viewController)
        #expect(itemIDs(prefix: .ipAddress, in: viewController).count == 6)
        #expect(viewController.expandedListsForTesting == [.dnsNames, .ipAddresses])
        #expect(
            viewController.rowContentForTesting(ipDisclosureID)?.label
                == localized(
                    "network.security.action.show_less_ip_addresses",
                    defaultValue: "Show Less IP Addresses"
                )
        )

        await toggle(.dnsNames, in: viewController)
        #expect(itemIDs(prefix: .dnsName, in: viewController).count == 5)
        #expect(viewController.expandedListsForTesting == [.ipAddresses])

        let replacement = makeRequest(id: "security-lists-replacement", url: "https://example.test")
        let replacementEpoch = NetworkSecurityRequestEpoch(request: replacement)
        await render(
            reportedSecurity(dnsNames: dnsNames, ipAddresses: ipAddresses),
            epoch: replacementEpoch,
            in: viewController
        )
        #expect(viewController.expandedListsForTesting.isEmpty)
        #expect(itemIDs(prefix: .dnsName, in: viewController).count == 5)
        #expect(Set(collapsedDNSIDs).intersection(viewController.snapshotForTesting.itemIdentifiers).isEmpty)
    }

    @Test
    func datesAreLocalizedFactsAndTechnicalValuesKeepLTRInRTL() async throws {
        let request = makeRequest(id: "security-dates", url: "https://example.test")
        let epoch = NetworkSecurityRequestEpoch(request: request)
        let viewController = NetworkSecurityViewController()
        let window = showInWindow(viewController)
        defer { window.isHidden = true }
        let later = Date(timeIntervalSince1970: 2_000.875)
        let earlier = Date(timeIntervalSince1970: 1_000.125)
        let security = Network.Security(
            connection: Network.Security.Connection(
                tlsProtocol: "TLS 1.3",
                cipher: "AES_128_GCM_SHA256"
            ),
            certificate: Network.Security.Certificate(
                subject: "CN=example.test",
                validFrom: later,
                validUntil: earlier,
                dnsNames: ["example.test"],
                ipAddresses: ["2001:db8::1"]
            )
        )
        await render(
            .encryptedScheme(.https, metadata: .reported(security)),
            epoch: epoch,
            in: viewController
        )
        #expect(row(.validFrom, in: viewController)?.value == later.formatted(date: .numeric, time: .complete))
        #expect(row(.validUntil, in: viewController)?.value == earlier.formatted(date: .numeric, time: .complete))

        viewController.collectionView.semanticContentAttribute = .forceRightToLeft
        #expect(viewController.collectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft)
        let subjectID = try #require(itemID(.subject, in: viewController))
        let subjectCell = try #require(visibleCell(subjectID, in: viewController))
        let content = try #require(subjectCell.contentConfiguration as? UIListContentConfiguration)
        #expect(viewController.technicalValueUsesLTRForTesting(subjectID))
        #expect(content.secondaryTextProperties.adjustsFontForContentSizeCategory)
        #expect(
            viewController.collectionView(
                viewController.collectionView,
                shouldSelectItemAt: try #require(indexPath(subjectID, in: viewController))
            ) == false
        )
    }

    private func reportedSecurity(
        dnsNames: [String],
        ipAddresses: [String]
    ) -> NetworkSecuritySummary {
        .encryptedScheme(
            .https,
            metadata: .reported(Network.Security(
                certificate: Network.Security.Certificate(
                    subject: "CN=example.test",
                    dnsNames: dnsNames,
                    ipAddresses: ipAddresses
                )
            ))
        )
    }

    private func makeRequest(id: String, url: String) -> NetworkRequest {
        let context = WebInspectorContext.preview(isolation: MainActor.shared)
        return NetworkRequest(
            request: Network.Request(
                id: Network.Request.ID(id),
                url: url,
                method: "GET"
            ),
            initiator: nil,
            resourceType: .fetch,
            timestamp: 1,
            modelContext: context
        )
    }

    private func render(
        _ summary: NetworkSecuritySummary,
        epoch: NetworkSecurityRequestEpoch,
        in viewController: NetworkSecurityViewController
    ) async {
        await withCheckedContinuation { continuation in
            viewController.render(summary, epoch: epoch) {
                continuation.resume()
            }
        }
        viewController.collectionView.layoutIfNeeded()
    }

    private func toggle(
        _ kind: NetworkSecurityListKind,
        in viewController: NetworkSecurityViewController
    ) async {
        await withCheckedContinuation { continuation in
            viewController.toggleDisclosureForTesting(kind) {
                continuation.resume()
            }
        }
        viewController.collectionView.layoutIfNeeded()
    }

    private func row(
        _ kind: NetworkSecurityItemID.Kind,
        in viewController: NetworkSecurityViewController
    ) -> NetworkSecurityRowContent? {
        guard let itemID = itemID(kind, in: viewController) else {
            return nil
        }
        return viewController.rowContentForTesting(itemID)
    }

    private func itemID(
        _ kind: NetworkSecurityItemID.Kind,
        in viewController: NetworkSecurityViewController
    ) -> NetworkSecurityItemID? {
        viewController.snapshotForTesting.itemIdentifiers.first { $0.kind == kind }
    }

    private func itemIDs(
        prefix: NetworkSecurityItemKindPrefix,
        in viewController: NetworkSecurityViewController
    ) -> [NetworkSecurityItemID] {
        viewController.snapshotForTesting.itemIdentifiers.filter { itemID in
            switch (prefix, itemID.kind) {
            case (.dnsName, .dnsName), (.ipAddress, .ipAddress):
                true
            default:
                false
            }
        }
    }

    private func visibleCell(
        _ itemID: NetworkSecurityItemID,
        in viewController: NetworkSecurityViewController
    ) -> UICollectionViewListCell? {
        guard let indexPath = indexPath(itemID, in: viewController) else {
            return nil
        }
        viewController.collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        viewController.collectionView.layoutIfNeeded()
        return viewController.collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell
    }

    private func indexPath(
        _ itemID: NetworkSecurityItemID,
        in viewController: NetworkSecurityViewController
    ) -> IndexPath? {
        let snapshot = viewController.snapshotForTesting
        for (sectionIndex, section) in snapshot.sectionIdentifiers.enumerated() {
            if let itemIndex = snapshot.itemIdentifiers(inSection: section).firstIndex(of: itemID) {
                return IndexPath(item: itemIndex, section: sectionIndex)
            }
        }
        return nil
    }

    private func showInWindow(_ viewController: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = viewController
        viewController.loadViewIfNeeded()
        viewController.view.frame = window.bounds
        window.layoutIfNeeded()
        return window
    }

    private func localized(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: WebInspectorUILocalization.bundle)
    }

    private func localized(
        _ key: StaticString,
        defaultValue: String.LocalizationValue,
        locale: String
    ) -> String? {
        guard let bundleURL = WebInspectorUILocalization.bundle.url(
            forResource: locale,
            withExtension: "lproj"
        ), let bundle = Bundle(url: bundleURL) else {
            return nil
        }
        return String(localized: key, defaultValue: defaultValue, bundle: bundle)
    }

    private enum NetworkSecurityItemKindPrefix {
        case dnsName
        case ipAddress
    }
}
}
#endif
