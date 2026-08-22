#if canImport(UIKit)
import UIKit

@MainActor
final class AdaptiveTabContent: ScrollableTabBarContent {
    var view: UIView { adaptiveView }
    var selectionHandler: ((Int) -> Void)?
    let adaptiveView: AdaptiveTabView
    let segmentedControl: UISegmentedControl
    let menuButton: UIButton
    private let items: [ScrollableTabBarPresentationItem]

    init(items: [ScrollableTabBarPresentationItem]) {
        self.items = items
        segmentedControl = UISegmentedControl(items: items.map(\.title))
        menuButton = UIButton(type: .system)
        menuButton.showsMenuAsPrimaryAction = true
        adaptiveView = AdaptiveTabView(
            segmentedControl: segmentedControl,
            menuButton: menuButton
        )
        segmentedControl.addTarget(
            self,
            action: #selector(valueChanged(_:)),
            for: .valueChanged
        )
    }

    func render(
        selectedIndex: Int,
        isEnabled: Bool,
        accessibilityLabel: String?
    ) {
        let selectedItem = items[selectedIndex]
        segmentedControl.isEnabled = isEnabled
        segmentedControl.selectedSegmentIndex = selectedIndex
        segmentedControl.accessibilityLabel = accessibilityLabel
        segmentedControl.accessibilityValue = selectedItem.title
        for index in items.indices {
            segmentedControl.setEnabled(isEnabled, forSegmentAt: index)
        }

        var buttonConfiguration = menuButton.configuration ?? .plain()
        buttonConfiguration.title = selectedItem.title
        buttonConfiguration.image = UIImage(systemName: "chevron.down")
        buttonConfiguration.imagePlacement = .trailing
        buttonConfiguration.imagePadding = 6
        menuButton.configuration = buttonConfiguration
        menuButton.isEnabled = isEnabled
        menuButton.accessibilityLabel = accessibilityLabel
        menuButton.accessibilityValue = selectedItem.title
        menuButton.menu = UIMenu(
            options: .singleSelection,
            children: items.enumerated().map { index, item in
                UIAction(
                    title: item.title,
                    image: item.image,
                    state: index == selectedIndex ? .on : .off
                ) { [weak self] _ in
                    self?.selectionHandler?(index)
                }
            }
        )
        adaptiveView.invalidateIntrinsicContentSize()
    }

    @objc func valueChanged(_ sender: UISegmentedControl) {
        guard items.indices.contains(sender.selectedSegmentIndex) else {
            scrollableTabBarLogger.fault(
                "UISegmentedControl selected an item outside ScrollableTabBar's membership."
            )
            return
        }
        selectionHandler?(sender.selectedSegmentIndex)
    }
}

@MainActor
final class AdaptiveTabView: UIView {
    enum Presentation: Equatable {
        case segmented
        case menu
    }

    private(set) var presentation: Presentation
    private let segmentedControl: UISegmentedControl
    private let menuButton: UIButton

    init(segmentedControl: UISegmentedControl, menuButton: UIButton) {
        self.segmentedControl = segmentedControl
        self.menuButton = menuButton
        presentation = Self.presentation(for: UITraitCollection())
        super.init(frame: .zero)

        isAccessibilityElement = false
        let stackView = UIStackView(arrangedSubviews: [segmentedControl, menuButton])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updatePresentation()
        registerForTraitChanges([
            UITraitHorizontalSizeClass.self,
            UITraitPreferredContentSizeCategory.self,
        ]) { (self: AdaptiveTabView, _) in
            self.updatePresentation()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: CGSize {
        activeControl.intrinsicContentSize
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        activeControl.sizeThatFits(size)
    }

    static func presentation(for traitCollection: UITraitCollection) -> Presentation {
        if traitCollection.horizontalSizeClass == .regular,
           traitCollection.preferredContentSizeCategory.isAccessibilityCategory == false {
            return .segmented
        }
        return .menu
    }

    private var activeControl: UIControl {
        switch presentation {
        case .segmented:
            segmentedControl
        case .menu:
            menuButton
        }
    }

    private func updatePresentation() {
        presentation = Self.presentation(for: traitCollection)
        segmentedControl.isHidden = presentation != .segmented
        menuButton.isHidden = presentation != .menu
        invalidateIntrinsicContentSize()
    }
}
#endif
