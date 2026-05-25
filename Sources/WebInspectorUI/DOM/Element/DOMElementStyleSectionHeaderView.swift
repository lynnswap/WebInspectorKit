#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorCore

@MainActor
final class DOMElementStyleSectionHeaderView: UICollectionReusableView {
    private let observationScope = ObservationScope()
    private let contentView = UIListContentView(
        configuration: UIListContentConfiguration.header()
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureStaticViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clear()
    }

    func bind(_ section: CSSStyleSection) {
        render(section)

        observationScope.cancelAll()
        observationScope.observe(section) { [weak self] _, section in
            self?.render(section)
        }
    }

    func clear() {
        observationScope.cancelAll()
        contentView.configuration = UIListContentConfiguration.header()
    }

    private func configureStaticViews() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func render(_ section: CSSStyleSection) {
        var configuration = UIListContentConfiguration.header()
        configuration.text = section.title
        configuration.secondaryText = section.subtitle
        contentView.configuration = configuration
        accessibilityLabel = [section.title, section.subtitle]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
#endif
