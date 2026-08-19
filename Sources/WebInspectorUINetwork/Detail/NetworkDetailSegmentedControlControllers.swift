#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

@MainActor
final class NetworkDetailModeControlController {
    let view: NetworkDetailModeControlView
    var selectionHandler: ((NetworkDetailViewController.Mode) -> Void)?
    private let segmentedControl: UISegmentedControl
    private let menuButton: UIButton
    private var mode: NetworkDetailViewController.Mode
    private var isEnabled = false

    init(initialMode: NetworkDetailViewController.Mode) {
        mode = initialMode
        let segmentedControl = UISegmentedControl(
            items: NetworkDetailViewController.Mode.allCases.map(\.title)
        )
        segmentedControl.accessibilityIdentifier = "WebInspector.Network.DetailModeSegmentedControl"
        let menuButton = UIButton(type: .system)
        menuButton.accessibilityIdentifier = "WebInspector.Network.DetailModeMenuButton"
        menuButton.showsMenuAsPrimaryAction = true
        self.segmentedControl = segmentedControl
        self.menuButton = menuButton
        view = NetworkDetailModeControlView(
            segmentedControl: segmentedControl,
            menuButton: menuButton
        )
        view.presentationChangeHandler = { [weak self] in
            self?.renderControls()
        }
        segmentedControl.addTarget(self, action: #selector(valueChanged(_:)), for: .valueChanged)
        renderControls()
    }

    func render(mode: NetworkDetailViewController.Mode, isEnabled: Bool) {
        self.mode = mode
        self.isEnabled = isEnabled
        renderControls()
    }

    @objc private func valueChanged(_ sender: UISegmentedControl) {
        guard NetworkDetailViewController.Mode.allCases.indices.contains(sender.selectedSegmentIndex) else {
            renderControls()
            return
        }
        select(NetworkDetailViewController.Mode.allCases[sender.selectedSegmentIndex])
    }

    private func select(_ selectedMode: NetworkDetailViewController.Mode) {
        guard isEnabled else {
            renderControls()
            return
        }
        selectionHandler?(selectedMode)
    }

    private func renderControls() {
        let accessibilityLabel = String(
            localized: "network.detail.mode.label",
            defaultValue: "Detail Mode",
            bundle: WebInspectorUILocalization.bundle
        )
        segmentedControl.isEnabled = isEnabled
        segmentedControl.selectedSegmentIndex = Self.index(for: mode)
        segmentedControl.accessibilityLabel = accessibilityLabel
        segmentedControl.accessibilityValue = mode.title
        for index in NetworkDetailViewController.Mode.allCases.indices {
            segmentedControl.setEnabled(isEnabled, forSegmentAt: index)
        }

        var buttonConfiguration = menuButton.configuration ?? .plain()
        buttonConfiguration.title = mode.title
        buttonConfiguration.image = UIImage(systemName: "chevron.down")
        buttonConfiguration.imagePlacement = .trailing
        buttonConfiguration.imagePadding = 6
        menuButton.configuration = buttonConfiguration
        menuButton.isEnabled = isEnabled
        menuButton.accessibilityLabel = accessibilityLabel
        menuButton.accessibilityValue = mode.title
        menuButton.menu = UIMenu(
            options: .singleSelection,
            children: NetworkDetailViewController.Mode.allCases.map { candidate in
                UIAction(
                    title: candidate.title,
                    state: candidate == mode ? .on : .off
                ) { [weak self] _ in
                    self?.select(candidate)
                }
            }
        )
        view.invalidateIntrinsicContentSize()
    }

    private static func index(for mode: NetworkDetailViewController.Mode) -> Int {
        NetworkDetailViewController.Mode.allCases.firstIndex(of: mode) ?? UISegmentedControl.noSegment
    }
}

@MainActor
final class NetworkDetailModeControlView: UIView {
    enum Presentation: Equatable {
        case segmented
        case menu
    }

    var presentationChangeHandler: (() -> Void)?
    private(set) var presentation: Presentation
    private let segmentedControl: UISegmentedControl
    private let menuButton: UIButton

    init(segmentedControl: UISegmentedControl, menuButton: UIButton) {
        self.segmentedControl = segmentedControl
        self.menuButton = menuButton
        presentation = Self.presentation(for: UITraitCollection())
        super.init(frame: .zero)
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
        ]) { (self: NetworkDetailModeControlView, _) in
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

    private var activeControl: UIControl {
        switch presentation {
        case .segmented:
            segmentedControl
        case .menu:
            menuButton
        }
    }

    private func updatePresentation() {
        let nextPresentation = Self.presentation(for: traitCollection)
        let didChange = presentation != nextPresentation
        presentation = nextPresentation
        segmentedControl.isHidden = presentation != .segmented
        menuButton.isHidden = presentation != .menu
        invalidateIntrinsicContentSize()
        if didChange {
            presentationChangeHandler?()
        }
    }

    private static func presentation(for traitCollection: UITraitCollection) -> Presentation {
        if traitCollection.horizontalSizeClass == .regular,
           traitCollection.preferredContentSizeCategory.isAccessibilityCategory == false {
            return .segmented
        }
        return .menu
    }
}

@MainActor
final class NetworkPreviewRoleControlController {
    let containerView: NetworkDetailSegmentedControlContentView
    var selectionHandler: ((NetworkBody.Role) -> Void)?
    private let segmentedControl: UISegmentedControl
    private var roles: [NetworkBody.Role] = []
    private var selectedRole: NetworkBody.Role?
    private var isVisible = false

    init() {
        let segmentedControl = UISegmentedControl()
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.accessibilityIdentifier = "WebInspector.Network.DetailPreviewRoleSegmentedControl"
        self.segmentedControl = segmentedControl
        containerView = NetworkDetailSegmentedControlContentView(segmentedControl: segmentedControl)
        segmentedControl.addTarget(self, action: #selector(valueChanged(_:)), for: .valueChanged)
    }

    @discardableResult
    func render(
        roles: [NetworkBody.Role],
        selectedRole: NetworkBody.Role?,
        isVisible: Bool
    ) -> Bool {
        self.selectedRole = selectedRole
        self.isVisible = isVisible
        let selectedSegmentIndex = selectedRole.flatMap(roles.firstIndex(of:))
            ?? UISegmentedControl.noSegment

        UIView.performWithoutAnimation {
            if self.roles != roles {
                self.roles = roles
                segmentedControl.selectedSegmentIndex = UISegmentedControl.noSegment
                segmentedControl.removeAllSegments()
                for (index, role) in roles.enumerated() {
                    segmentedControl.insertSegment(
                        withTitle: Self.title(for: role),
                        at: index,
                        animated: false
                    )
                }
            }
            containerView.isHidden = isVisible == false
            segmentedControl.selectedSegmentIndex = selectedSegmentIndex
            segmentedControl.accessibilityLabel = selectedRole.map(Self.title(for:))
            segmentedControl.layoutIfNeeded()
            containerView.layoutIfNeeded()
        }
        return isVisible
    }

    @objc private func valueChanged(_ sender: UISegmentedControl) {
        guard roles.indices.contains(sender.selectedSegmentIndex) else {
            render(roles: roles, selectedRole: selectedRole, isVisible: isVisible)
            return
        }
        selectionHandler?(roles[sender.selectedSegmentIndex])
    }

    private static func title(for role: NetworkBody.Role) -> String {
        switch role {
        case .request:
            String(localized: "network.section.request", bundle: WebInspectorUILocalization.bundle)
        case .response:
            String(localized: "network.section.response", bundle: WebInspectorUILocalization.bundle)
        }
    }
}

@MainActor
final class NetworkDetailSegmentedControlContentView: UIView {
    private let segmentedControl: UISegmentedControl

    init(segmentedControl: UISegmentedControl) {
        self.segmentedControl = segmentedControl
        let height = Self.preferredHeight(for: segmentedControl)
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height))
        preservesSuperviewLayoutMargins = true
        addSubview(segmentedControl)
        NSLayoutConstraint.activate([
            segmentedControl.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            segmentedControl.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            segmentedControl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.preferredHeight(for: segmentedControl))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: Self.preferredHeight(for: segmentedControl))
    }

    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        fittingSize(for: targetSize)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        fittingSize(for: targetSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func fittingSize(for targetSize: CGSize) -> CGSize {
        let width = targetSize.width == 0 ? UIView.noIntrinsicMetric : targetSize.width
        return CGSize(width: width, height: Self.preferredHeight(for: segmentedControl))
    }

    private static func preferredHeight(for segmentedControl: UISegmentedControl) -> CGFloat {
        let navigationBarHeight = UINavigationBar(frame: .zero)
            .sizeThatFits(CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            .height
        return max(segmentedControl.intrinsicContentSize.height, navigationBarHeight)
    }
}

#if DEBUG
extension NetworkDetailModeControlController {
    var isEnabledForTesting: Bool {
        isEnabled
    }

    func isModeEnabledForTesting(_ mode: NetworkDetailViewController.Mode) -> Bool {
        NetworkDetailViewController.Mode.allCases.contains(mode) && isEnabled
    }

    func selectModeForTesting(_ mode: NetworkDetailViewController.Mode) {
        select(mode)
    }

    var presentationForTesting: NetworkDetailModeControlView.Presentation {
        view.presentation
    }

    var segmentedControlForTesting: UISegmentedControl {
        segmentedControl
    }

    var menuButtonForTesting: UIButton {
        menuButton
    }

    var menuActionTitlesForTesting: [String] {
        menuButton.menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []
    }
}

extension NetworkPreviewRoleControlController {
    var isHiddenForTesting: Bool {
        containerView.isHidden
    }

    func selectRoleForTesting(_ role: NetworkBody.Role) {
        segmentedControl.selectedSegmentIndex = roles.firstIndex(of: role)
            ?? UISegmentedControl.noSegment
        valueChanged(segmentedControl)
    }
}
#endif
#endif
