#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorDataKit
import WebInspectorUIBase

@MainActor
final class NetworkDetailRequestPickerCell: UICollectionViewListCell {
    private weak var observedRequest: NetworkRequest?
    private var requestObservation: PortableObservationTracking.Token?
    private var isRenderingActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentConfiguration = Self.makeContentConfiguration()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        requestObservation?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        unbind()
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        accessories = state.isSelected ? [.checkmark()] : []
    }

    func bind(request: NetworkRequest, renderingActive: Bool) {
        if observedRequest !== request {
            cancelRequestObservation()
            observedRequest = request
        }
        render(request: request)
        setRenderingActive(renderingActive)
    }

    func bindAllRequests(renderingActive: Bool) {
        cancelRequestObservation()
        observedRequest = nil
        isRenderingActive = renderingActive
        render(
            title: String(
                localized: "network.filter.all",
                bundle: WebInspectorUILocalization.bundle
            ),
            subtitle: nil
        )
    }

    func setRenderingActive(_ isActive: Bool) {
        guard isRenderingActive != isActive else {
            if isActive {
                renderObservedRequest()
                startRequestObservationIfNeeded()
            }
            return
        }

        isRenderingActive = isActive
        if isActive {
            renderObservedRequest()
            startRequestObservationIfNeeded()
        } else {
            cancelRequestObservation()
        }
    }

    func unbind() {
        cancelRequestObservation()
        observedRequest = nil
        isRenderingActive = false
        render(title: nil, subtitle: nil)
    }

    var boundRequest: NetworkRequest? {
        observedRequest
    }

    private func startRequestObservationIfNeeded() {
        guard requestObservation == nil,
              let observedRequest else {
            return
        }
        requestObservation = withPortableContinuousObservation { [weak self, weak observedRequest] _ in
            guard let self,
                  let observedRequest,
                  isRenderingActive,
                  self.observedRequest === observedRequest else {
                return
            }
            render(request: observedRequest)
        }
    }

    private func renderObservedRequest() {
        guard let observedRequest else {
            return
        }
        render(request: observedRequest)
    }

    private func render(request: NetworkRequest) {
        render(title: request.displayName, subtitle: request.url)
    }

    private func render(title: String?, subtitle: String?) {
        var content = (contentConfiguration as? UIListContentConfiguration)
            ?? Self.makeContentConfiguration()
        guard content.text != title || content.secondaryText != subtitle else {
            return
        }
        content.text = title
        content.secondaryText = subtitle
        contentConfiguration = content
    }

    private func cancelRequestObservation() {
        requestObservation?.cancel()
        requestObservation = nil
    }

    private static func makeContentConfiguration() -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.numberOfLines = 1
        content.textProperties.lineBreakMode = .byTruncatingMiddle
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        return content
    }
}

#if DEBUG
extension NetworkDetailRequestPickerCell {
    var titleForTesting: String? {
        (contentConfiguration as? UIListContentConfiguration)?.text
    }

    var subtitleForTesting: String? {
        (contentConfiguration as? UIListContentConfiguration)?.secondaryText
    }

    var requestObservationForTesting: PortableObservationTracking.Token? {
        requestObservation
    }

    var observedRequestForTesting: NetworkRequest? {
        observedRequest
    }
}
#endif
#endif
