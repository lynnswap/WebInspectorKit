#if canImport(UIKit)
import WebInspectorCore
import UIKit

@MainActor
final class NetworkDetailModeControlController {
    let view: UISegmentedControl
    var selectionHandler: ((NetworkDetailMode) -> Void)?
    private var mode: NetworkDetailMode
    private var isEnabled = false

    init(initialMode: NetworkDetailMode) {
        mode = initialMode
        view = UISegmentedControl(items: NetworkDetailMode.allCases.map(\.title))
        view.selectedSegmentIndex = Self.index(for: initialMode)
        view.accessibilityIdentifier = "WebInspector.Network.DetailModeSegmentedControl"
        view.addTarget(self, action: #selector(valueChanged(_:)), for: .valueChanged)
    }

    func render(mode: NetworkDetailMode, isEnabled: Bool) {
        self.mode = mode
        self.isEnabled = isEnabled
        view.isEnabled = isEnabled
        view.selectedSegmentIndex = Self.index(for: mode)
        view.accessibilityLabel = mode.title
        for index in NetworkDetailMode.allCases.indices {
            view.setEnabled(isEnabled, forSegmentAt: index)
        }
    }

    @objc private func valueChanged(_ sender: UISegmentedControl) {
        guard NetworkDetailMode.allCases.indices.contains(sender.selectedSegmentIndex) else {
            render(mode: mode, isEnabled: isEnabled)
            return
        }
        selectionHandler?(NetworkDetailMode.allCases[sender.selectedSegmentIndex])
    }

    private static func index(for mode: NetworkDetailMode) -> Int {
        NetworkDetailMode.allCases.firstIndex(of: mode) ?? UISegmentedControl.noSegment
    }
}

@MainActor
final class NetworkPreviewRoleControlController {
    let containerView: NetworkDetailSegmentedControlContentView
    var selectionHandler: ((NetworkBodyRole) -> Void)?
    private let segmentedControl: UISegmentedControl
    private var roles: [NetworkBodyRole] = []
    private var selectedRole: NetworkBodyRole?
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
        roles: [NetworkBodyRole],
        selectedRole: NetworkBodyRole?,
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

    private static func title(for role: NetworkBodyRole) -> String {
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

    func isModeEnabledForTesting(_ mode: NetworkDetailMode) -> Bool {
        view.isEnabledForSegment(at: Self.index(for: mode))
    }

    func selectModeForTesting(_ mode: NetworkDetailMode) {
        view.selectedSegmentIndex = Self.index(for: mode)
        valueChanged(view)
    }
}

extension NetworkPreviewRoleControlController {
    var isHiddenForTesting: Bool {
        containerView.isHidden
    }

    func selectRoleForTesting(_ role: NetworkBodyRole) {
        segmentedControl.selectedSegmentIndex = roles.firstIndex(of: role)
            ?? UISegmentedControl.noSegment
        valueChanged(segmentedControl)
    }
}
#endif
#endif
