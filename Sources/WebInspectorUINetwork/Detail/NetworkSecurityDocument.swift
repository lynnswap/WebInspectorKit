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
            builder.appendStatus(
                value: plaintextStatus(for: scheme),
                scheme: plaintextSchemeText(scheme)
            )
            builder.appendUnavailableMetadata(value: notApplicableText)
        case .pending(let scheme):
            builder.appendStatus(value: pendingText, scheme: encryptedSchemeText(scheme))
            builder.appendUnavailableMetadata(value: pendingText)
        case let .encryptedScheme(scheme, metadata):
            builder.appendStatus(
                value: metadataStatus(for: scheme, metadata: metadata),
                scheme: encryptedSchemeText(scheme)
            )
            switch metadata {
            case .notReported:
                builder.appendMetadataNotReported()
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
            builder.appendStatus(
                value: unavailableStatus(for: reason),
                scheme: encryptedSchemeText(scheme)
            )
            if let reasonText = rawUnavailableReason(reason) {
                builder.append(
                    section: .status,
                    kind: .reason,
                    label: reasonLabel,
                    display: reportedScalar(reasonText)
                )
            }
            builder.appendUnavailableMetadata(value: unavailableText)
        case .notApplicable(let scheme):
            builder.append(
                section: .status,
                kind: .status,
                label: statusLabel,
                value: notClassifiedText
            )
            builder.append(
                section: .status,
                kind: .scheme,
                label: schemeLabel,
                display: reportedScalar(scheme)
            )
            builder.appendUnavailableMetadata(value: notApplicableText)
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
                kind: .connectionMetadata,
                label: connectionMetadataLabel,
                value: reportedText
            )
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
            builder.append(
                section: .connection,
                kind: .connectionMetadata,
                label: connectionMetadataLabel,
                value: notReportedText
            )
        }

        guard let certificate = security.certificate else {
            builder.append(
                section: .certificate,
                kind: .certificateMetadata,
                label: certificateMetadataLabel,
                value: notReportedText
            )
            return
        }
        builder.append(
            section: .certificate,
            kind: .certificateMetadata,
            label: certificateMetadataLabel,
            value: reportedText
        )
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
                value: notReportedText
            )
            return
        }
        guard values.isEmpty == false else {
            builder.append(
                section: .certificate,
                kind: kind == .dnsNames ? .dnsState : .ipAddressState,
                label: kind == .dnsNames ? dnsNamesLabel : ipAddressesLabel,
                value: noValuesReportedText
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
            title: isExpanded ? showLessText : showMoreText(hiddenValueCount),
            isExpanded: isExpanded
        )
    }

    private func plaintextStatus(
        for scheme: NetworkSecuritySummary.PlaintextScheme
    ) -> String {
        switch scheme {
        case .http:
            localized(
                "network.security.status.http",
                defaultValue: "HTTP scheme reported; TLS does not apply."
            )
        case .ws:
            localized(
                "network.security.status.ws",
                defaultValue: "WS scheme reported; TLS does not apply."
            )
        }
    }

    private func metadataStatus(
        for scheme: NetworkSecuritySummary.EncryptedScheme,
        metadata: NetworkSecuritySummary.Metadata
    ) -> String {
        switch metadata {
        case .notReported:
            switch scheme {
            case .https:
                localized(
                    "network.security.status.https_not_reported",
                    defaultValue: "HTTPS scheme reported; security metadata was not reported."
                )
            case .wss:
                localized(
                    "network.security.status.wss_not_reported",
                    defaultValue: "WSS scheme reported; security metadata was not reported."
                )
            }
        case .reported:
            switch scheme {
            case .https:
                localized(
                    "network.security.status.https_reported",
                    defaultValue: "HTTPS scheme and security metadata reported."
                )
            case .wss:
                localized(
                    "network.security.status.wss_reported",
                    defaultValue: "WSS scheme and security metadata reported."
                )
            }
        }
    }

    private func unavailableStatus(
        for reason: NetworkSecuritySummary.UnavailableReason
    ) -> String {
        switch reason {
        case .failedBeforeResponse:
            localized(
                "network.security.status.failed_before_response",
                defaultValue: "The request failed before a response was reported."
            )
        case .canceledBeforeResponse:
            localized(
                "network.security.status.canceled_before_response",
                defaultValue: "The request was canceled before a response was reported."
            )
        case .completedWithoutResponse:
            localized(
                "network.security.status.completed_without_response",
                defaultValue: "Loading completed without a reported response."
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
            return DisplayValue(value: notReportedText, isTechnical: false)
        }
        guard value.isEmpty == false else {
            return DisplayValue(value: emptyValueReportedText, isTechnical: false)
        }
        return DisplayValue(value: value, isTechnical: true)
    }

    private func reportedDate(_ date: Date?) -> DisplayValue {
        guard let date else {
            return DisplayValue(value: notReportedText, isTechnical: false)
        }
        return DisplayValue(
            value: date.formatted(date: .numeric, time: .complete),
            isTechnical: false
        )
    }

    private func showMoreText(_ count: Int) -> String {
        String.localizedStringWithFormat(
            localized(
                "network.security.action.show_more",
                defaultValue: "Show %lld More"
            ),
            Int64(count)
        )
    }

    private var showLessText: String {
        localized("network.security.action.show_less", defaultValue: "Show Less")
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
        localized("network.security.field.security_metadata", defaultValue: "Security Metadata")
    }

    private var connectionMetadataLabel: String {
        localized("network.security.field.connection_metadata", defaultValue: "Connection Metadata")
    }

    private var tlsProtocolLabel: String {
        localized("network.security.field.tls_protocol", defaultValue: "TLS Protocol")
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

    private var emptyValueReportedText: String {
        localized("network.security.value.empty_reported", defaultValue: "Empty value reported")
    }

    private var noValuesReportedText: String {
        localized("network.security.value.no_values_reported", defaultValue: "No values reported")
    }

    private var pendingText: String {
        localized("network.security.value.pending", defaultValue: "Response pending")
    }

    private var unavailableText: String {
        localized("network.security.value.unavailable", defaultValue: "Unavailable")
    }

    private var notApplicableText: String {
        localized("network.security.value.not_applicable", defaultValue: "Not applicable")
    }

    private var notClassifiedText: String {
        localized(
            "network.security.status.not_classified",
            defaultValue: "TLS applicability is not classified for this scheme."
        )
    }

    private func localized(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: WebInspectorUILocalization.bundle)
    }

    private struct DisplayValue {
        let value: String
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

        mutating func appendStatus(value: String, scheme: String) {
            append(section: .status, kind: .status, label: statusLabel, value: value)
            append(
                section: .status,
                kind: .scheme,
                label: schemeLabel,
                value: scheme,
                usesTechnicalValueDirection: true
            )
        }

        mutating func appendMetadataNotReported() {
            append(
                section: .status,
                kind: .securityMetadata,
                label: securityMetadataLabel,
                value: notReportedText
            )
            append(
                section: .connection,
                kind: .connectionMetadata,
                label: connectionMetadataLabel,
                value: notReportedText
            )
            append(
                section: .certificate,
                kind: .certificateMetadata,
                label: certificateMetadataLabel,
                value: notReportedText
            )
        }

        mutating func appendUnavailableMetadata(value: String) {
            append(
                section: .connection,
                kind: .connectionMetadata,
                label: connectionMetadataLabel,
                value: value
            )
            append(
                section: .certificate,
                kind: .certificateMetadata,
                label: certificateMetadataLabel,
                value: value
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
                usesTechnicalValueDirection: display.isTechnical
            )
        }

        mutating func append(
            section: NetworkSecuritySectionID,
            kind: NetworkSecurityItemID.Kind,
            label: String,
            value: String,
            usesTechnicalValueDirection: Bool = false
        ) {
            let itemID = NetworkSecurityItemID(epoch: epoch, kind: kind)
            precondition(document.rowsByItemID[itemID] == nil)
            document.itemsBySection[section, default: []].append(itemID)
            document.rowsByItemID[itemID] = NetworkSecurityRowContent(
                label: label,
                value: value,
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
                usesTechnicalValueDirection: false,
                disclosureList: kind,
                isExpanded: isExpanded
            )
        }

        private var statusLabel: String {
            localized("network.security.field.status", defaultValue: "Status")
        }

        private var schemeLabel: String {
            localized("network.security.field.scheme", defaultValue: "Scheme")
        }

        private var securityMetadataLabel: String {
            localized("network.security.field.security_metadata", defaultValue: "Security Metadata")
        }

        private var connectionMetadataLabel: String {
            localized("network.security.field.connection_metadata", defaultValue: "Connection Metadata")
        }

        private var certificateMetadataLabel: String {
            localized("network.security.field.certificate_metadata", defaultValue: "Certificate Metadata")
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
