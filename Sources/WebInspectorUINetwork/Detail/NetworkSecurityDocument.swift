#if canImport(UIKit)
import Foundation
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorUIBase

enum NetworkSecuritySectionID: CaseIterable, Hashable {
    case status
    case connection
    case certificate
}

enum NetworkSecurityListKind: Hashable {
    case dnsNames
    case ipAddresses
}

struct NetworkSecurityRequestEpoch: Hashable {
    let requestID: NetworkRequest.ID
    let requestIdentity: ObjectIdentifier
    let lifecycleRevision: UInt64
    let redirectCount: Int

    @MainActor
    init(request: NetworkRequest) {
        requestID = request.id
        requestIdentity = ObjectIdentifier(request)
        lifecycleRevision = request.lifecycleRevision
        redirectCount = request.redirects.count
    }
}

struct NetworkSecurityItemID: Hashable {
    enum Kind: Hashable {
        case status
        case scheme
        case reason
        case securityMetadata
        case connectionMetadata
        case tlsProtocol
        case cipher
        case certificateMetadata
        case subject
        case validFrom
        case validUntil
        case dnsState
        case dnsName(Int)
        case ipAddressState
        case ipAddress(Int)
        case disclosure(NetworkSecurityListKind)
    }

    let epoch: NetworkSecurityRequestEpoch
    let kind: Kind
}

struct NetworkSecurityRowContent: Equatable {
    let label: String
    let value: String?
    let accessibilityLabel: String?
    let usesTechnicalValueDirection: Bool
    let disclosureList: NetworkSecurityListKind?
    let isExpanded: Bool
}

struct NetworkSecurityDocument {
    var itemsBySection: [NetworkSecuritySectionID: [NetworkSecurityItemID]]
    var rowsByItemID: [NetworkSecurityItemID: NetworkSecurityRowContent]
}

@MainActor
struct NetworkSecurityDocumentBuilder {
    private static let collapsedValueLimit = 5

    let summary: NetworkSecuritySummary
    let epoch: NetworkSecurityRequestEpoch
    let expandedLists: Set<NetworkSecurityListKind>

    func makeDocument() -> NetworkSecurityDocument {
        var builder = Builder(epoch: epoch)
        switch summary {
        case .plaintextScheme(let scheme):
            builder.appendScheme(plaintextSchemeText(scheme))
            builder.append(
                section: .status,
                kind: .status,
                label: tlsLabel,
                value: notApplicableText
            )
        case .pending(let scheme):
            builder.appendScheme(encryptedSchemeText(scheme))
            builder.appendState(
                section: .status,
                kind: .status,
                accessibilityLabel: statusLabel,
                value: pendingText
            )
        case let .encryptedScheme(scheme, metadata):
            builder.appendScheme(encryptedSchemeText(scheme))
            switch metadata {
            case .notReported:
                builder.append(
                    section: .status,
                    kind: .securityMetadata,
                    label: securityMetadataLabel,
                    value: notReportedText
                )
            case .reported(let security):
                builder.append(
                    section: .status,
                    kind: .securityMetadata,
                    label: securityMetadataLabel,
                    value: reportedText
                )
                appendReportedSecurity(security, to: &builder)
            }
        case let .unavailable(scheme, reason):
            builder.appendScheme(encryptedSchemeText(scheme))
            builder.appendState(
                section: .status,
                kind: .status,
                accessibilityLabel: statusLabel,
                value: unavailableStatus(for: reason)
            )
            if let reasonText = rawUnavailableReason(reason) {
                builder.append(
                    section: .status,
                    kind: .reason,
                    label: reasonLabel,
                    display: reportedScalar(reasonText)
                )
            }
        case .notApplicable(let scheme):
            builder.appendScheme(scheme)
            builder.append(
                section: .status,
                kind: .status,
                label: tlsLabel,
                value: notClassifiedText
            )
        }
        return builder.document
    }

    private func appendReportedSecurity(
        _ security: Network.Security,
        to builder: inout Builder
    ) {
        if let connection = security.connection {
            builder.append(
                section: .connection,
                kind: .tlsProtocol,
                label: tlsProtocolLabel,
                display: reportedScalar(connection.tlsProtocol)
            )
            builder.append(
                section: .connection,
                kind: .cipher,
                label: cipherLabel,
                display: reportedScalar(connection.cipher)
            )
        } else {
            builder.appendState(
                section: .connection,
                kind: .connectionMetadata,
                accessibilityLabel: connectionMetadataLabel,
                value: notReportedText
            )
        }

        guard let certificate = security.certificate else {
            builder.appendState(
                section: .certificate,
                kind: .certificateMetadata,
                accessibilityLabel: certificateMetadataLabel,
                value: notReportedText
            )
            return
        }
        builder.append(
            section: .certificate,
            kind: .subject,
            label: subjectLabel,
            display: reportedScalar(certificate.subject)
        )
        builder.append(
            section: .certificate,
            kind: .validFrom,
            label: validFromLabel,
            display: reportedDate(certificate.validFrom)
        )
        builder.append(
            section: .certificate,
            kind: .validUntil,
            label: validUntilLabel,
            display: reportedDate(certificate.validUntil)
        )
        append(
            certificate.dnsNames,
            kind: .dnsNames,
            to: &builder
        )
        append(
            certificate.ipAddresses,
            kind: .ipAddresses,
            to: &builder
        )
    }

    private func append(
        _ values: [String]?,
        kind: NetworkSecurityListKind,
        to builder: inout Builder
    ) {
        guard let values else {
            builder.append(
                section: .certificate,
                kind: kind == .dnsNames ? .dnsState : .ipAddressState,
                label: kind == .dnsNames ? dnsNamesLabel : ipAddressesLabel,
                display: notReportedDisplay
            )
            return
        }
        guard values.isEmpty == false else {
            builder.append(
                section: .certificate,
                kind: kind == .dnsNames ? .dnsState : .ipAddressState,
                label: kind == .dnsNames ? dnsNamesLabel : ipAddressesLabel,
                display: DisplayValue(
                    value: noneText,
                    accessibilityValue: noValuesReportedText,
                    isTechnical: false
                )
            )
            return
        }

        let isExpanded = expandedLists.contains(kind)
        let visibleValues = isExpanded
            ? values
            : Array(values.prefix(Self.collapsedValueLimit))
        for (ordinal, value) in visibleValues.enumerated() {
            builder.append(
                section: .certificate,
                kind: kind == .dnsNames ? .dnsName(ordinal) : .ipAddress(ordinal),
                label: listValueLabel(kind: kind, ordinal: ordinal),
                display: reportedScalar(value)
            )
        }
        guard values.count > Self.collapsedValueLimit else {
            return
        }
        let hiddenValueCount = values.count - Self.collapsedValueLimit
        builder.appendDisclosure(
            kind: kind,
            title: isExpanded
                ? showLessText(for: kind)
                : showMoreText(hiddenValueCount, for: kind),
            isExpanded: isExpanded
        )
    }

    private func unavailableStatus(
        for reason: NetworkSecuritySummary.UnavailableReason
    ) -> String {
        switch reason {
        case .failedBeforeResponse:
            localized(
                "network.security.status.failed_before_response",
                defaultValue: "Request Failed"
            )
        case .canceledBeforeResponse:
            localized(
                "network.security.status.canceled_before_response",
                defaultValue: "Request Canceled"
            )
        case .completedWithoutResponse:
            localized(
                "network.security.status.completed_without_response",
                defaultValue: "No Response"
            )
        }
    }

    private func rawUnavailableReason(
        _ reason: NetworkSecuritySummary.UnavailableReason
    ) -> String? {
        switch reason {
        case .failedBeforeResponse(let reason), .canceledBeforeResponse(let reason):
            reason
        case .completedWithoutResponse:
            nil
        }
    }

    private func plaintextSchemeText(
        _ scheme: NetworkSecuritySummary.PlaintextScheme
    ) -> String {
        switch scheme {
        case .http: "HTTP"
        case .ws: "WS"
        }
    }

    private func encryptedSchemeText(
        _ scheme: NetworkSecuritySummary.EncryptedScheme
    ) -> String {
        switch scheme {
        case .https: "HTTPS"
        case .wss: "WSS"
        }
    }

    private func listValueLabel(kind: NetworkSecurityListKind, ordinal: Int) -> String {
        let base = kind == .dnsNames ? dnsNameLabel : ipAddressLabel
        return "\(base) \((ordinal + 1).formatted())"
    }

    private func reportedScalar(_ value: String?) -> DisplayValue {
        guard let value else {
            return notReportedDisplay
        }
        guard value.isEmpty == false else {
            return DisplayValue(
                value: emptyText,
                accessibilityValue: emptyValueReportedText,
                isTechnical: false
            )
        }
        return DisplayValue(value: value, accessibilityValue: nil, isTechnical: true)
    }

    private func reportedDate(_ date: Date?) -> DisplayValue {
        guard let date else {
            return notReportedDisplay
        }
        return DisplayValue(
            value: date.formatted(date: .numeric, time: .complete),
            accessibilityValue: nil,
            isTechnical: false
        )
    }

    private func showMoreText(_ count: Int, for kind: NetworkSecurityListKind) -> String {
        let format = switch kind {
        case .dnsNames:
            localized(
                "network.security.action.show_more_dns_names",
                defaultValue: "Show %lld More DNS Names"
            )
        case .ipAddresses:
            localized(
                "network.security.action.show_more_ip_addresses",
                defaultValue: "Show %lld More IP Addresses"
            )
        }
        return String.localizedStringWithFormat(
            format,
            Int64(count)
        )
    }

    private func showLessText(for kind: NetworkSecurityListKind) -> String {
        switch kind {
        case .dnsNames:
            localized(
                "network.security.action.show_less_dns_names",
                defaultValue: "Show Fewer DNS Names"
            )
        case .ipAddresses:
            localized(
                "network.security.action.show_less_ip_addresses",
                defaultValue: "Show Fewer IP Addresses"
            )
        }
    }

    private var statusLabel: String {
        localized("network.security.field.status", defaultValue: "Status")
    }

    private var schemeLabel: String {
        localized("network.security.field.scheme", defaultValue: "Scheme")
    }

    private var reasonLabel: String {
        localized("network.security.field.reason", defaultValue: "Reason")
    }

    private var securityMetadataLabel: String {
        localized("network.security.field.metadata", defaultValue: "Metadata")
    }

    private var connectionMetadataLabel: String {
        localized("network.security.field.connection_metadata", defaultValue: "Connection Metadata")
    }

    private var tlsProtocolLabel: String {
        localized("network.security.field.tls_protocol", defaultValue: "TLS Protocol")
    }

    private var tlsLabel: String {
        localized("network.security.field.tls", defaultValue: "TLS")
    }

    private var cipherLabel: String {
        localized("network.security.field.cipher", defaultValue: "Cipher")
    }

    private var certificateMetadataLabel: String {
        localized("network.security.field.certificate_metadata", defaultValue: "Certificate Metadata")
    }

    private var subjectLabel: String {
        localized("network.security.field.subject", defaultValue: "Subject")
    }

    private var validFromLabel: String {
        localized("network.security.field.valid_from", defaultValue: "Valid From")
    }

    private var validUntilLabel: String {
        localized("network.security.field.valid_until", defaultValue: "Valid Until")
    }

    private var dnsNamesLabel: String {
        localized("network.security.field.dns_names", defaultValue: "DNS Names")
    }

    private var dnsNameLabel: String {
        localized("network.security.field.dns_name", defaultValue: "DNS Name")
    }

    private var ipAddressesLabel: String {
        localized("network.security.field.ip_addresses", defaultValue: "IP Addresses")
    }

    private var ipAddressLabel: String {
        localized("network.security.field.ip_address", defaultValue: "IP Address")
    }

    private var reportedText: String {
        localized("network.security.value.reported", defaultValue: "Reported")
    }

    private var notReportedText: String {
        localized("network.security.value.not_reported", defaultValue: "Not reported")
    }

    private var notReportedDisplay: DisplayValue {
        DisplayValue(
            value: "-",
            accessibilityValue: notReportedText,
            isTechnical: false
        )
    }

    private var emptyText: String {
        localized("network.security.value.empty", defaultValue: "Empty")
    }

    private var noneText: String {
        localized("network.security.value.none", defaultValue: "None")
    }

    private var emptyValueReportedText: String {
        localized("network.security.value.empty_reported", defaultValue: "Empty value reported")
    }

    private var noValuesReportedText: String {
        localized("network.security.value.no_values_reported", defaultValue: "No values reported")
    }

    private var pendingText: String {
        localized("network.security.value.pending", defaultValue: "Waiting for Response")
    }

    private var notApplicableText: String {
        localized("network.security.value.not_applicable", defaultValue: "Not applicable")
    }

    private var notClassifiedText: String {
        localized(
            "network.security.value.not_classified",
            defaultValue: "Not Classified"
        )
    }

    private func localized(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: WebInspectorUILocalization.bundle)
    }

    private struct DisplayValue {
        let value: String
        let accessibilityValue: String?
        let isTechnical: Bool
    }

    private struct Builder {
        let epoch: NetworkSecurityRequestEpoch
        var document = NetworkSecurityDocument(
            itemsBySection: Dictionary(
                uniqueKeysWithValues: NetworkSecuritySectionID.allCases.map { ($0, []) }
            ),
            rowsByItemID: [:]
        )

        mutating func appendScheme(_ scheme: String?) {
            append(
                section: .status,
                kind: .scheme,
                label: schemeLabel,
                value: scheme ?? "-",
                accessibilityLabel: scheme == nil
                    ? [schemeLabel, notReportedText].joined(separator: ", ")
                    : nil,
                usesTechnicalValueDirection: true
            )
        }

        mutating func appendState(
            section: NetworkSecuritySectionID,
            kind: NetworkSecurityItemID.Kind,
            accessibilityLabel: String,
            value: String
        ) {
            append(
                section: section,
                kind: kind,
                label: value,
                value: nil,
                accessibilityLabel: [accessibilityLabel, value].joined(separator: ", ")
            )
        }

        mutating func append(
            section: NetworkSecuritySectionID,
            kind: NetworkSecurityItemID.Kind,
            label: String,
            display: DisplayValue
        ) {
            append(
                section: section,
                kind: kind,
                label: label,
                value: display.value,
                accessibilityLabel: display.accessibilityValue.map {
                    [label, $0].joined(separator: ", ")
                },
                usesTechnicalValueDirection: display.isTechnical
            )
        }

        mutating func append(
            section: NetworkSecuritySectionID,
            kind: NetworkSecurityItemID.Kind,
            label: String,
            value: String?,
            accessibilityLabel: String? = nil,
            usesTechnicalValueDirection: Bool = false
        ) {
            let itemID = NetworkSecurityItemID(epoch: epoch, kind: kind)
            precondition(document.rowsByItemID[itemID] == nil)
            document.itemsBySection[section, default: []].append(itemID)
            document.rowsByItemID[itemID] = NetworkSecurityRowContent(
                label: label,
                value: value,
                accessibilityLabel: accessibilityLabel,
                usesTechnicalValueDirection: usesTechnicalValueDirection,
                disclosureList: nil,
                isExpanded: false
            )
        }

        mutating func appendDisclosure(
            kind: NetworkSecurityListKind,
            title: String,
            isExpanded: Bool
        ) {
            let itemID = NetworkSecurityItemID(epoch: epoch, kind: .disclosure(kind))
            precondition(document.rowsByItemID[itemID] == nil)
            document.itemsBySection[.certificate, default: []].append(itemID)
            document.rowsByItemID[itemID] = NetworkSecurityRowContent(
                label: title,
                value: nil,
                accessibilityLabel: nil,
                usesTechnicalValueDirection: false,
                disclosureList: kind,
                isExpanded: isExpanded
            )
        }

        private var schemeLabel: String {
            localized("network.security.field.scheme", defaultValue: "Scheme")
        }

        private var notReportedText: String {
            localized("network.security.value.not_reported", defaultValue: "Not reported")
        }

        private func localized(
            _ key: StaticString,
            defaultValue: String.LocalizationValue
        ) -> String {
            String(
                localized: key,
                defaultValue: defaultValue,
                bundle: WebInspectorUILocalization.bundle
            )
        }
    }
}
#endif
