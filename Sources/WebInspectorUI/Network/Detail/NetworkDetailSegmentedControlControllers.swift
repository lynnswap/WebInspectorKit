#if canImport(UIKit)
import WebInspectorCore
import UIKit

@MainActor
final class NetworkDetailModeControlController {
    let view: UISegmentedControl
    var selectionHandler: ((NetworkDetailViewController.Mode) -> Void)?
    private var mode: NetworkDetailViewController.Mode
    private var isEnabled = false

    init(initialMode: NetworkDetailViewController.Mode) {
        mode = initialMode
        view = UISegmentedControl(items: NetworkDetailViewController.Mode.allCases.map(\.title))
        view.selectedSegmentIndex = Self.index(for: initialMode)
        view.accessibilityIdentifier = "WebInspector.Network.DetailModeSegmentedControl"
        view.addTarget(self, action: #selector(valueChanged(_:)), for: .valueChanged)
    }

    func render(mode: NetworkDetailViewController.Mode, isEnabled: Bool) {
        self.mode = mode
        self.isEnabled = isEnabled
        view.isEnabled = isEnabled
        view.selectedSegmentIndex = Self.index(for: mode)
        view.accessibilityLabel = mode.title
        for index in NetworkDetailViewController.Mode.allCases.indices {
            view.setEnabled(isEnabled, forSegmentAt: index)
        }
    }

    @objc private func valueChanged(_ sender: UISegmentedControl) {
        guard NetworkDetailViewController.Mode.allCases.indices.contains(sender.selectedSegmentIndex) else {
            render(mode: mode, isEnabled: isEnabled)
            return
        }
        selectionHandler?(NetworkDetailViewController.Mode.allCases[sender.selectedSegmentIndex])
    }

    private static func index(for mode: NetworkDetailViewController.Mode) -> Int {
        NetworkDetailViewController.Mode.allCases.firstIndex(of: mode) ?? UISegmentedControl.noSegment
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
        if self.roles != roles {
            self.roles = roles
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
        segmentedControl.selectedSegmentIndex = selectedRole.flatMap(roles.firstIndex(of:))
            ?? UISegmentedControl.noSegment
        segmentedControl.accessibilityLabel = selectedRole.map(Self.title(for:))
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
            String(localized: "network.section.request", bundle: .module)
        case .response:
            String(localized: "network.section.response", bundle: .module)
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
        view.isEnabled
    }

    func isModeEnabledForTesting(_ mode: NetworkDetailViewController.Mode) -> Bool {
        view.isEnabledForSegment(at: Self.index(for: mode))
    }

    func selectModeForTesting(_ mode: NetworkDetailViewController.Mode) {
        view.selectedSegmentIndex = Self.index(for: mode)
        valueChanged(view)
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
