#if canImport(UIKit)
import Darwin
import OSLog
import UIKit
import WebInspectorUIBase

private let networkDetailModeControlLogger = Logger(
    subsystem: "com.lynnswap.WebInspectorKit",
    category: "WebInspectorUINetwork.ModeControl"
)

@MainActor
private protocol NetworkDetailModeControlContent: AnyObject {
    var view: UIView { get }
    var selectionHandler: ((NetworkDetailViewController.Mode) -> Void)? { get set }

    func render(mode: NetworkDetailViewController.Mode, isEnabled: Bool)
}

@MainActor
final class NetworkDetailModeControlController {
    let view: UIView
    var selectionHandler: ((NetworkDetailViewController.Mode) -> Void)?
    private let content: any NetworkDetailModeControlContent
    private var mode: NetworkDetailViewController.Mode
    private var isEnabled = false

    init(initialMode: NetworkDetailViewController.Mode) {
        mode = initialMode
        let content: any NetworkDetailModeControlContent
        if let scrollableContent = NetworkDetailScrollableModeControlView.makeIfAvailable(
            modes: NetworkDetailViewController.Mode.allCases,
            initialMode: initialMode
        ) {
            content = scrollableContent
        } else {
            content = NetworkDetailAdaptiveModeControlContent()
        }
        self.content = content
        view = content.view
        content.selectionHandler = { [weak self] mode in
            self?.select(mode)
        }
        renderControls()
    }

    func render(mode: NetworkDetailViewController.Mode, isEnabled: Bool) {
        self.mode = mode
        self.isEnabled = isEnabled
        renderControls()
    }

    private func select(_ selectedMode: NetworkDetailViewController.Mode) {
        guard isEnabled else {
            renderControls()
            return
        }
        selectionHandler?(selectedMode)
        renderControls()
    }

    private func renderControls() {
        content.render(mode: mode, isEnabled: isEnabled)
    }
}

@MainActor
private struct NetworkDetailScrollableModePickerComponents {
    let pickerView: UIView
    let categories: [NSObject]
    let segmentClass: UIControl.Type
}

@MainActor
private enum NetworkDetailScrollableModePickerRuntime {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/MapsUI.framework/MapsUI"

    // Keep the image loaded for the process lifetime. dlclose would invalidate the
    // Objective-C classes behind live picker instances.
    private static let didLoadFramework: Bool = unsafe dlopen(
        frameworkPath,
        RTLD_NOW | RTLD_LOCAL
    ) != nil

    static func makeComponents(titles: [String]) -> NetworkDetailScrollableModePickerComponents? {
        guard didLoadFramework else {
            networkDetailModeControlLogger.error(
                "MapsUI could not be loaded; using the public adaptive mode control."
            )
            return nil
        }
        guard let pickerClass = NSClassFromString("MUScrollableSegmentedPickerView") as? UIView.Type,
              let categoryClass = NSClassFromString("MUScrollableSegmentedPickerCategory") as? NSObject.Type,
              let segmentClass = NSClassFromString("MUScrollableSegmentedPickerSegmentView") as? UIControl.Type else {
            networkDetailModeControlLogger.error(
                "MapsUI scrollable picker classes are unavailable; using the public adaptive mode control."
            )
            return nil
        }

        let pickerView = pickerClass.init(frame: .zero)
        let categoryProbe = categoryClass.init()
        let segmentProbe = segmentClass.init(frame: .zero)
        guard responds(
            pickerView,
            to: ["setViewModels:", "setSelectedIndex:", "selectedIndex", "setDelegate:"]
        ), responds(categoryProbe, to: ["setCategoryName:", "categoryName"]),
            responds(segmentProbe, to: ["viewModel"]) else {
            networkDetailModeControlLogger.error(
                "MapsUI scrollable picker selectors changed; using the public adaptive mode control."
            )
            return nil
        }

        let categories = titles.map { title in
            let category = categoryClass.init()
            category.setValue(title, forKey: "categoryName")
            return category
        }
        pickerView.setValue(categories, forKey: "viewModels")
        return NetworkDetailScrollableModePickerComponents(
            pickerView: pickerView,
            categories: categories,
            segmentClass: segmentClass
        )
    }

    private static func responds(_ object: NSObject, to selectorNames: [String]) -> Bool {
        selectorNames.allSatisfy { object.responds(to: NSSelectorFromString($0)) }
    }
}

@MainActor
private final class NetworkDetailModeAccessibilityElement: UIAccessibilityElement {
    let mode: NetworkDetailViewController.Mode
    weak var owner: NetworkDetailScrollableModeControlView?

    init(
        mode: NetworkDetailViewController.Mode,
        owner: NetworkDetailScrollableModeControlView
    ) {
        self.mode = mode
        self.owner = owner
        super.init(accessibilityContainer: owner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func accessibilityActivate() -> Bool {
        owner?.activate(mode: mode) == true
    }

    override func accessibilityElementDidBecomeFocused() {
        owner?.reveal(mode: mode)
    }
}

@MainActor
private final class NetworkDetailScrollableModeControlView: UIView, NetworkDetailModeControlContent {
    private static let preferredWidth: CGFloat = 640
    private static let preferredHeight: CGFloat = 44

    var view: UIView { self }
    var selectionHandler: ((NetworkDetailViewController.Mode) -> Void)?
    private let modes: [NetworkDetailViewController.Mode]
    private let pickerView: UIView
    private let categories: [NSObject]
    private let segmentClass: UIControl.Type
    private var modeAccessibilityElements: [NetworkDetailModeAccessibilityElement] = []
    private var selectedMode: NetworkDetailViewController.Mode
    private var isEnabled = false
    private var modeNeedingReveal: NetworkDetailViewController.Mode?

    static func makeIfAvailable(
        modes: [NetworkDetailViewController.Mode],
        initialMode: NetworkDetailViewController.Mode
    ) -> NetworkDetailScrollableModeControlView? {
        guard let components = NetworkDetailScrollableModePickerRuntime.makeComponents(
            titles: modes.map(\.title)
        ) else {
            return nil
        }
        return NetworkDetailScrollableModeControlView(
            modes: modes,
            initialMode: initialMode,
            components: components
        )
    }

    private init(
        modes: [NetworkDetailViewController.Mode],
        initialMode: NetworkDetailViewController.Mode,
        components: NetworkDetailScrollableModePickerComponents
    ) {
        self.modes = modes
        selectedMode = initialMode
        pickerView = components.pickerView
        categories = components.categories
        segmentClass = components.segmentClass
        super.init(frame: .zero)

        accessibilityIdentifier = "WebInspector.Network.DetailModeTabBar"
        accessibilityContainerType = .semanticGroup
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        pickerView.accessibilityIdentifier = "WebInspector.Network.DetailModeScrollablePicker"
        pickerView.setValue(self, forKey: "delegate")
        addSubview(pickerView)

        modeAccessibilityElements = modes.enumerated().map { index, mode in
            let element = NetworkDetailModeAccessibilityElement(mode: mode, owner: self)
            element.accessibilityIdentifier = "WebInspector.Network.DetailMode.\(index)"
            element.accessibilityLabel = mode.title
            return element
        }
        accessibilityElements = modeAccessibilityElements
        setSelectedMode(initialMode, needsReveal: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.preferredWidth, height: Self.preferredHeight)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let proposedWidth = size.width > 0 && size.width.isFinite
            ? size.width
            : Self.preferredWidth
        return CGSize(
            width: min(Self.preferredWidth, proposedWidth),
            height: Self.preferredHeight
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pickerView.frame = bounds
        pickerView.layoutIfNeeded()
        updateSegmentPresentation()
        revealPendingModeIfPossible()
    }

    func render(mode: NetworkDetailViewController.Mode, isEnabled: Bool) {
        self.isEnabled = isEnabled
        pickerView.isUserInteractionEnabled = isEnabled
        pickerView.alpha = isEnabled ? 1 : 0.5
        if selectedMode != mode {
            setSelectedMode(mode, needsReveal: true)
        }
        updateSegmentPresentation()
        revealPendingModeIfPossible()
    }

    fileprivate func activate(mode: NetworkDetailViewController.Mode) -> Bool {
        guard isEnabled else {
            return false
        }
        setSelectedMode(mode, needsReveal: true)
        selectionHandler?(mode)
        return true
    }

    fileprivate func reveal(mode: NetworkDetailViewController.Mode) {
        modeNeedingReveal = mode
        revealPendingModeIfPossible()
    }

    @objc(scrollableSegmentedPickerView:didChangeSelectedIndex:)
    private func pickerSelectionDidChange(_ pickerView: UIView, selectedIndex: UInt) {
        guard pickerView === self.pickerView,
              let index = Int(exactly: selectedIndex),
              modes.indices.contains(index) else {
            networkDetailModeControlLogger.fault(
                "MapsUI scrollable picker reported an invalid selection."
            )
            setSelectedMode(selectedMode, needsReveal: true)
            return
        }
        guard isEnabled else {
            setSelectedMode(selectedMode, needsReveal: true)
            return
        }
        selectedMode = modes[index]
        modeNeedingReveal = nil
        updateSegmentPresentation()
        selectionHandler?(selectedMode)
    }

    private func setSelectedMode(
        _ mode: NetworkDetailViewController.Mode,
        needsReveal: Bool
    ) {
        guard let index = modes.firstIndex(of: mode) else {
            preconditionFailure("Every Network Detail mode must have a picker item.")
        }
        selectedMode = mode
        pickerView.setValue(NSNumber(value: index), forKey: "selectedIndex")
        if needsReveal {
            modeNeedingReveal = mode
            setNeedsLayout()
        }
        updateSegmentPresentation()
    }

    private func updateSegmentPresentation() {
        let segmentsByMode = Dictionary(
            uniqueKeysWithValues: resolvedSegments().map { ($0.mode, $0.view) }
        )
        for (index, mode) in modes.enumerated() {
            guard let segment = segmentsByMode[mode] else {
                continue
            }
            segment.isEnabled = isEnabled
            let element = modeAccessibilityElements[index]
            var traits: UIAccessibilityTraits = [.button]
            if mode == selectedMode {
                traits.insert(.selected)
            }
            if isEnabled == false {
                traits.insert(.notEnabled)
            }
            element.accessibilityTraits = traits
            element.accessibilityFrameInContainerSpace = segment.convert(
                segment.bounds,
                to: self
            )
        }
    }

    private func revealPendingModeIfPossible() {
        guard let mode = modeNeedingReveal,
              bounds.width > 0,
              let scrollView = pickerScrollView,
              let segment = resolvedSegments().first(where: { $0.mode == mode })?.view else {
            return
        }
        let segmentFrame = segment.convert(segment.bounds, to: scrollView)
        scrollView.scrollRectToVisible(segmentFrame, animated: false)
        modeNeedingReveal = nil
        updateSegmentPresentation()
    }

    private var pickerScrollView: UIScrollView? {
        descendants(of: pickerView).first { $0 is UIScrollView } as? UIScrollView
    }

    private func resolvedSegments() -> [(mode: NetworkDetailViewController.Mode, view: UIControl)] {
        descendants(of: pickerView).compactMap { view in
            guard view.isKind(of: segmentClass),
                  let segment = view as? UIControl,
                  let category = segment.value(forKey: "viewModel") as? NSObject,
                  let index = categories.firstIndex(where: { $0 === category }) else {
                return nil
            }
            return (modes[index], segment)
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { subview in
            [subview] + descendants(of: subview)
        }
    }
}

@MainActor
final class NetworkDetailAdaptiveModeControlContent: NetworkDetailModeControlContent {
    var view: UIView { adaptiveView }
    var selectionHandler: ((NetworkDetailViewController.Mode) -> Void)?
    private let adaptiveView: NetworkDetailAdaptiveModeControlView
    private let segmentedControl: UISegmentedControl
    private let menuButton: UIButton

    init() {
        let segmentedControl = UISegmentedControl(
            items: NetworkDetailViewController.Mode.allCases.map(\.title)
        )
        segmentedControl.accessibilityIdentifier = "WebInspector.Network.DetailModeSegmentedControl"
        let menuButton = UIButton(type: .system)
        menuButton.accessibilityIdentifier = "WebInspector.Network.DetailModeMenuButton"
        menuButton.showsMenuAsPrimaryAction = true
        self.segmentedControl = segmentedControl
        self.menuButton = menuButton
        adaptiveView = NetworkDetailAdaptiveModeControlView(
            segmentedControl: segmentedControl,
            menuButton: menuButton
        )
        segmentedControl.addTarget(self, action: #selector(valueChanged(_:)), for: .valueChanged)
    }

    func render(mode: NetworkDetailViewController.Mode, isEnabled: Bool) {
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
                    self?.selectionHandler?(candidate)
                }
            }
        )
        adaptiveView.invalidateIntrinsicContentSize()
    }

    @objc private func valueChanged(_ sender: UISegmentedControl) {
        guard NetworkDetailViewController.Mode.allCases.indices.contains(sender.selectedSegmentIndex) else {
            return
        }
        selectionHandler?(NetworkDetailViewController.Mode.allCases[sender.selectedSegmentIndex])
    }

    private static func index(for mode: NetworkDetailViewController.Mode) -> Int {
        NetworkDetailViewController.Mode.allCases.firstIndex(of: mode) ?? UISegmentedControl.noSegment
    }
}

@MainActor
final class NetworkDetailAdaptiveModeControlView: UIView {
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
        ]) { (self: NetworkDetailAdaptiveModeControlView, _) in
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
        presentation = Self.presentation(for: traitCollection)
        segmentedControl.isHidden = presentation != .segmented
        menuButton.isHidden = presentation != .menu
        invalidateIntrinsicContentSize()
    }

    private static func presentation(for traitCollection: UITraitCollection) -> Presentation {
        if traitCollection.horizontalSizeClass == .regular,
           traitCollection.preferredContentSizeCategory.isAccessibilityCategory == false {
            return .segmented
        }
        return .menu
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

    var usesScrollablePickerForTesting: Bool {
        content is NetworkDetailScrollableModeControlView
    }

    var scrollablePickerViewForTesting: UIView? {
        (content as? NetworkDetailScrollableModeControlView)?.pickerViewForTesting
    }

    var scrollViewForTesting: UIScrollView? {
        (content as? NetworkDetailScrollableModeControlView)?.scrollViewForTesting
    }

    var segmentControlsForTesting: [UIControl] {
        (content as? NetworkDetailScrollableModeControlView)?.segmentControlsForTesting ?? []
    }

    var modeAccessibilityElementsForTesting: [UIAccessibilityElement] {
        (content as? NetworkDetailScrollableModeControlView)?.accessibilityElementsForTesting ?? []
    }
}

extension NetworkDetailScrollableModeControlView {
    fileprivate var pickerViewForTesting: UIView {
        pickerView
    }

    fileprivate var scrollViewForTesting: UIScrollView? {
        pickerScrollView
    }

    fileprivate var segmentControlsForTesting: [UIControl] {
        let segments = resolvedSegments()
        return modes.compactMap { mode in
            segments.first(where: { $0.mode == mode })?.view
        }
    }

    fileprivate var accessibilityElementsForTesting: [UIAccessibilityElement] {
        modeAccessibilityElements
    }
}

extension NetworkDetailAdaptiveModeControlContent {
    var presentationForTesting: NetworkDetailAdaptiveModeControlView.Presentation {
        adaptiveView.presentation
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

    func selectModeForTesting(_ mode: NetworkDetailViewController.Mode) {
        selectionHandler?(mode)
    }
}
#endif
#endif
