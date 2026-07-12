#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIKit

@MainActor
package final class NetworkListCell: UICollectionViewListCell {
    private let statusIndicatorView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 8, height: 8)))
    private let fileTypeLabel = UILabel()
    private var requestObservation: PortableObservationTracking.Token?
    private var observedRequests: [NetworkRequest] = []
    private var isRenderingActive = true
#if DEBUG
    private var renderCountStorageForTesting = 0
#endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        requestObservation?.cancel()
    }

    override package func prepareForReuse() {
        super.prepareForReuse()
        unbind()
    }

    package func bind(requests: [NetworkRequest], renderingActive: Bool) {
        precondition(requests.isEmpty == false, "A Network list cell requires at least one request.")
        if hasSameRequestIdentities(as: requests) == false {
            cancelRequestObservation()
            observedRequests = requests
        }
        setRenderingActive(renderingActive)
    }

    package func setRenderingActive(_ isActive: Bool) {
        guard isRenderingActive != isActive else {
            if isActive {
                renderObservedRequests()
                startRequestObservationIfNeeded()
            }
            return
        }

        isRenderingActive = isActive
        if isActive {
            renderObservedRequests()
            startRequestObservationIfNeeded()
        } else {
            cancelRequestObservation()
        }
    }

    package func unbind() {
        cancelRequestObservation()
        observedRequests = []
        render(displayName: "", statusSeverity: .neutral, fileTypeLabel: "")
    }

    private func hasSameRequestIdentities(as requests: [NetworkRequest]) -> Bool {
        observedRequests.count == requests.count
            && zip(observedRequests, requests).allSatisfy { observed, request in
                observed === request
            }
    }

    private func startRequestObservationIfNeeded() {
        guard requestObservation == nil,
              observedRequests.isEmpty == false else {
            return
        }
        requestObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self,
                  self.isRenderingActive else {
                return
            }
            self.renderObservedRequests()
        }
    }

    private func renderObservedRequests() {
        guard observedRequests.isEmpty == false else {
            return
        }
        render(requests: observedRequests)
    }

    private func configureStaticViews() {
        statusIndicatorView.accessibilityIdentifier = "WebInspector.Network.List.StatusIndicator"
        statusIndicatorView.layer.cornerRadius = 4

        fileTypeLabel.accessibilityIdentifier = "WebInspector.Network.List.FileTypeLabel"
        fileTypeLabel.textColor = .secondaryLabel
        fileTypeLabel.font = .preferredFont(forTextStyle: .footnote)
        fileTypeLabel.adjustsFontForContentSizeCategory = true

        contentConfiguration = Self.makeContentConfiguration()
        accessories = [
            .customView(
                configuration: .init(
                    customView: statusIndicatorView,
                    placement: .leading(),
                    reservedLayoutWidth: .custom(8),
                    maintainsFixedSize: true
                )
            ),
            .customView(
                configuration: .init(
                    customView: fileTypeLabel,
                    placement: .trailing(),
                    reservedLayoutWidth: .actual,
                    maintainsFixedSize: false
                )
            ),
            .disclosureIndicator(),
        ]
    }

    private func render(
        displayName: String,
        statusSeverity: NetworkDisplay.StatusSeverity,
        fileTypeLabel: String
    ) {
        render(displayName: displayName)
        renderAccessories(statusSeverity: statusSeverity, fileTypeLabel: fileTypeLabel)
    }

    private func render(requests: [NetworkRequest]) {
#if DEBUG
        renderCountStorageForTesting += 1
#endif
        guard let representativeRequest = requests.first else {
            preconditionFailure("A Network list cell cannot render an empty entry.")
        }
        let groupSuffix = requests.count > 1 ? " ×\(requests.count)" : ""
        render(
            displayName: representativeRequest.displayName,
            statusSeverity: statusSeverity(for: requests),
            fileTypeLabel: representativeRequest.fileTypeLabel + groupSuffix
        )
    }

    private func statusSeverity(for requests: [NetworkRequest]) -> NetworkDisplay.StatusSeverity {
        var highestSeverity = NetworkDisplay.StatusSeverity.neutral
        for request in requests {
            switch request.statusSeverity {
            case .error:
                return .error
            case .warning:
                highestSeverity = .warning
            case .notice:
                if highestSeverity != .warning {
                    highestSeverity = .notice
                }
            case .success:
                if highestSeverity == .neutral {
                    highestSeverity = .success
                }
            case .neutral:
                break
            }
        }
        return highestSeverity
    }

    private func render(displayName: String) {
        var content = (contentConfiguration as? UIListContentConfiguration) ?? Self.makeContentConfiguration()
        guard content.text != displayName else {
            return
        }
        content.text = displayName
        contentConfiguration = content
    }

    private func renderAccessories(
        statusSeverity: NetworkDisplay.StatusSeverity,
        fileTypeLabel: String
    ) {
        let color = statusSeverity.color
        if statusIndicatorView.backgroundColor?.isEqual(color) != true {
            statusIndicatorView.backgroundColor = color
        }
        if self.fileTypeLabel.text != fileTypeLabel {
            self.fileTypeLabel.text = fileTypeLabel
        }
    }

    private func cancelRequestObservation() {
        requestObservation?.cancel()
        requestObservation = nil
    }

    private static func makeContentConfiguration() -> UIListContentConfiguration {
        var content = UIListContentConfiguration.cell()
        content.secondaryText = nil
        content.textProperties.numberOfLines = 2
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.textProperties.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                weight: .semibold
            )
        )
        return content
    }
}

#if DEBUG
extension NetworkListCell {
    package var displayNameForTesting: String? {
        (contentConfiguration as? UIListContentConfiguration)?.text
    }

    package var fileTypeLabelForTesting: String? {
        fileTypeLabel.text
    }

    package var hasActiveRequestObservationForTesting: Bool {
        requestObservation != nil
    }

    package var requestObservationForTesting: PortableObservationTracking.Token? {
        requestObservation
    }

    package var renderCountForTesting: Int {
        renderCountStorageForTesting
    }
}
#endif
#endif
