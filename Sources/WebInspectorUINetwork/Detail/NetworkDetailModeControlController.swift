#if canImport(UIKit)
import OSLog
import ObjectiveC
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
        content = NetworkDetailFloatingModeControlContent.makeIfAvailable(
            modes: NetworkDetailViewController.Mode.allCases,
            initialMode: initialMode
        ) ?? NetworkDetailAdaptiveModeControlContent()
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
    }

    private func renderControls() {
        content.render(mode: mode, isEnabled: isEnabled)
    }
}

@MainActor
private struct NetworkDetailFloatingModeControlComponents {
    let tabController: UITabBarController
    let entries: [(mode: NetworkDetailViewController.Mode, tab: UITab)]
    let floatingTabBar: UIView
    let collectionView: UICollectionView
}

@MainActor
private enum NetworkDetailFloatingModeControlRuntime {
    private typealias MaximumContainerSizeImplementation =
        @convention(c) (AnyObject, Selector) -> CGSize

    private static let floatingTabBarClassName = "_UIFloatingTabBar"
    private static let expandedFloatingTabBarClassName =
        "WIKNetworkDetailExpandedFloatingTabBar"
    private static let tabModelKey = "_tabModel"
    private static let tabModelSelector = NSSelectorFromString(tabModelKey)
    private static let setTabModelSelector = NSSelectorFromString("setTabModel:")
    private static let collectionViewSelector = NSSelectorFromString("collectionView")
    private static let showsSidebarButtonSelector = NSSelectorFromString("showsSidebarButton")
    private static let currentPlatformMetricsSelector =
        NSSelectorFromString("_currentPlatformMetrics")
    private static let maximumContainerSizeSelector =
        NSSelectorFromString("_maximumContainerSizeForPagination")
    private static let expectedMaximumContainerSizeTypeEncoding =
        "{CGSize=dd}16@0:8"
    // The phone implementation applies this scale after its standard horizontal
    // margins. Increasing the platform metric does not help because 600pt is
    // already non-binding; override only this instance's pagination result.
    private static let normalPaginationWidthScale: CGFloat = 0.65

    static func makeComponents(
        modes: [NetworkDetailViewController.Mode],
        initialMode: NetworkDetailViewController.Mode
    ) -> NetworkDetailFloatingModeControlComponents? {
        guard let floatingTabBarClass = NSClassFromString(floatingTabBarClassName) as? UIView.Type else {
            networkDetailModeControlLogger.error(
                "UIKit's floating tab bar class is unavailable; using the public adaptive mode control."
            )
            return nil
        }
        guard let initialIndex = modes.firstIndex(of: initialMode) else {
            preconditionFailure("Every Network Detail mode must have a floating-tab item.")
        }

        let tabController = UITabBarController()
        tabController.mode = .tabBar
        let entries: [(mode: NetworkDetailViewController.Mode, tab: UITab)] = modes.enumerated().map { index, mode in
            let tab = UITab(
                title: mode.title,
                image: nil,
                identifier: "WebInspector.Network.DetailMode.\(index)"
            ) { _ in
                UIViewController()
            }
            tab.preferredPlacement = .fixed
            tab.accessibilityIdentifier = "WebInspector.Network.DetailMode.\(index)"
            return (mode: mode, tab: tab)
        }
        let tabs = entries.map(\.tab)
        tabController.tabs = tabs
        tabController.selectedTab = tabs[initialIndex]

        guard let firstTab = tabs.first,
              firstTab.responds(to: tabModelSelector),
              let tabModel = firstTab.value(forKey: tabModelKey) as AnyObject? else {
            networkDetailModeControlLogger.error(
                "UITab did not expose its configured tab model; using the public adaptive mode control."
            )
            return nil
        }

        let floatingTabBar = makeFloatingTabBar(
            baseClass: floatingTabBarClass
        )
        guard floatingTabBar.responds(to: setTabModelSelector),
              floatingTabBar.responds(to: collectionViewSelector),
              floatingTabBar.responds(to: showsSidebarButtonSelector) else {
            networkDetailModeControlLogger.error(
                "UIKit's floating tab bar contract changed; using the public adaptive mode control."
            )
            return nil
        }
        floatingTabBar.setValue(tabModel, forKey: "tabModel")

        guard floatingTabBar.value(forKey: "showsSidebarButton") as? Bool == false,
              let collectionView = floatingTabBar.value(forKey: "collectionView") as? UICollectionView else {
            networkDetailModeControlLogger.error(
                "UIKit's floating tab bar produced unexpected sidebar chrome; using the public adaptive mode control."
            )
            return nil
        }

        return NetworkDetailFloatingModeControlComponents(
            tabController: tabController,
            entries: entries,
            floatingTabBar: floatingTabBar,
            collectionView: collectionView
        )
    }

    private static func makeFloatingTabBar(
        baseClass: UIView.Type
    ) -> UIView {
        guard #available(iOS 26.0, *),
              let expandedClass = makeExpandedFloatingTabBarClass(baseClass: baseClass) else {
            return baseClass.init(frame: .zero)
        }

        let expandedTabBar = expandedClass.init(frame: .zero)
        guard expandedTabBar.responds(to: currentPlatformMetricsSelector),
              let metrics = unsafe expandedTabBar
                .perform(currentPlatformMetricsSelector)?
                .takeUnretainedValue() else {
            networkDetailModeControlLogger.error(
                "UIKit's floating tab metrics are unavailable; retaining the standard pagination width."
            )
            return baseClass.init(frame: .zero)
        }
        guard NSStringFromClass(type(of: metrics))
            == "_UIFloatingTabBarPlatformMetrics_Glass" else {
            networkDetailModeControlLogger.error(
                "UIKit's floating tab metrics are not the verified Glass implementation; retaining the standard pagination width."
            )
            return baseClass.init(frame: .zero)
        }
        return expandedTabBar
    }

    private static func makeExpandedFloatingTabBarClass(
        baseClass: UIView.Type
    ) -> UIView.Type? {
        if let existingClass = NSClassFromString(expandedFloatingTabBarClassName) {
            guard class_getSuperclass(existingClass) === baseClass else {
                networkDetailModeControlLogger.fault(
                    "The Network Detail floating-tab runtime class has an unexpected superclass."
                )
                return nil
            }
            return existingClass as? UIView.Type
        }

        guard let method = unsafe class_getInstanceMethod(
            baseClass,
            maximumContainerSizeSelector
        ), let typeEncoding = unsafe method_getTypeEncoding(method),
            unsafe String(cString: typeEncoding)
                == expectedMaximumContainerSizeTypeEncoding else {
            networkDetailModeControlLogger.error(
                "UIKit's floating-tab pagination signature changed; retaining the standard pagination width."
            )
            return nil
        }

        let originalImplementation = unsafe method_getImplementation(method)
        let selector = maximumContainerSizeSelector
        let block: @convention(block) (AnyObject) -> CGSize = { object in
            let implementation = unsafe unsafeBitCast(
                originalImplementation,
                to: MaximumContainerSizeImplementation.self
            )
            let originalSize = implementation(object, selector)
            guard let view = object as? UIView,
                  view.bounds.width > 0,
                  originalSize.width > 0 else {
                return originalSize
            }

            let unscaledWidth = originalSize.width / normalPaginationWidthScale
            let inferredHorizontalMargin = (view.bounds.width - unscaledWidth) / 2
            guard (12...24).contains(inferredHorizontalMargin) else {
                return originalSize
            }
            return CGSize(width: unscaledWidth, height: originalSize.height)
        }
        let overrideImplementation = unsafe imp_implementationWithBlock(block)

        guard let subclass = unsafe objc_allocateClassPair(
            baseClass,
            expandedFloatingTabBarClassName,
            0
        ) else {
            unsafe imp_removeBlock(overrideImplementation)
            networkDetailModeControlLogger.error(
                "UIKit's floating-tab pagination subclass could not be allocated."
            )
            return nil
        }
        guard unsafe class_addMethod(
            subclass,
            maximumContainerSizeSelector,
            overrideImplementation,
            typeEncoding
        ) else {
            unsafe imp_removeBlock(overrideImplementation)
            objc_disposeClassPair(subclass)
            networkDetailModeControlLogger.error(
                "UIKit's floating-tab pagination override could not be installed."
            )
            return nil
        }
        objc_registerClassPair(subclass)
        return subclass as? UIView.Type
    }

#if DEBUG
    static func maximumContainerSizeForTesting(
        of floatingTabBar: UIView
    ) -> CGSize? {
        guard floatingTabBar.responds(to: maximumContainerSizeSelector) else {
            return nil
        }
        let implementation = unsafe unsafeBitCast(
            floatingTabBar.method(for: maximumContainerSizeSelector),
            to: MaximumContainerSizeImplementation.self
        )
        return implementation(floatingTabBar, maximumContainerSizeSelector)
    }
#endif
}

@MainActor
private final class NetworkDetailFloatingModeControlContent: NSObject,
    NetworkDetailModeControlContent,
    UITabBarControllerDelegate
{
    var view: UIView { floatingView }
    var selectionHandler: ((NetworkDetailViewController.Mode) -> Void)?
    private let floatingView: NetworkDetailFloatingModeControlView
    private let tabController: UITabBarController
    private let entries: [(mode: NetworkDetailViewController.Mode, tab: UITab)]
    private let collectionView: UICollectionView
    private var renderedMode: NetworkDetailViewController.Mode

    static func makeIfAvailable(
        modes: [NetworkDetailViewController.Mode],
        initialMode: NetworkDetailViewController.Mode
    ) -> NetworkDetailFloatingModeControlContent? {
        guard let components = NetworkDetailFloatingModeControlRuntime.makeComponents(
            modes: modes,
            initialMode: initialMode
        ) else {
            return nil
        }
        return NetworkDetailFloatingModeControlContent(
            initialMode: initialMode,
            components: components
        )
    }

    private init(
        initialMode: NetworkDetailViewController.Mode,
        components: NetworkDetailFloatingModeControlComponents
    ) {
        renderedMode = initialMode
        tabController = components.tabController
        entries = components.entries
        collectionView = components.collectionView
        floatingView = NetworkDetailFloatingModeControlView(
            floatingTabBar: components.floatingTabBar
        )
        super.init()
        tabController.delegate = self
    }

    isolated deinit {
        floatingView.floatingTabBar.setValue(nil, forKey: "tabModel")
    }

    func render(mode: NetworkDetailViewController.Mode, isEnabled: Bool) {
        guard let entry = entries.first(where: { $0.mode == mode }) else {
            preconditionFailure("Every Network Detail mode must have a floating-tab item.")
        }
        renderedMode = mode
        if tabController.selectedTab !== entry.tab {
            tabController.selectedTab = entry.tab
        }

        floatingView.isUserInteractionEnabled = isEnabled
        floatingView.alpha = isEnabled ? 1 : 0.5
        if #available(iOS 18.4, *) {
            for entry in entries {
                entry.tab.isEnabled = isEnabled
            }
        }
    }

    func tabBarController(
        _ tabBarController: UITabBarController,
        didSelectTab selectedTab: UITab,
        previousTab: UITab?
    ) {
        guard let selectedMode = entries.first(where: { $0.tab === selectedTab })?.mode else {
            networkDetailModeControlLogger.fault(
                "UIKit's floating tab bar selected an item outside the Network Detail mode set."
            )
            return
        }
        guard selectedMode != renderedMode else {
            return
        }
        selectionHandler?(selectedMode)
    }
}

@MainActor
private final class NetworkDetailFloatingModeControlView: UIView {
    private static let preferredWidth: CGFloat = 640
    private static let preferredHeight: CGFloat = 49

    let floatingTabBar: UIView

    init(floatingTabBar: UIView) {
        self.floatingTabBar = floatingTabBar
        super.init(frame: .zero)

        accessibilityIdentifier = "WebInspector.Network.DetailModeTabBar"
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(floatingTabBar)
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
        floatingTabBar.frame = bounds
        floatingTabBar.layoutIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            return
        }
        setNeedsLayout()
        layoutIfNeeded()
        if #available(iOS 26.0, *), hasLiquidLens == false {
            networkDetailModeControlLogger.error(
                "UIKit's floating tab bar did not create its Liquid Glass selection lens."
            )
        }
    }

    fileprivate var hasLiquidLens: Bool {
        containsView(named: "_UILiquidLensView", below: floatingTabBar)
    }

    private func containsView(named className: String, below view: UIView) -> Bool {
        NSStringFromClass(type(of: view)) == className
            || view.subviews.contains { containsView(named: className, below: $0) }
    }
}

@MainActor
private final class NetworkDetailAdaptiveModeControlContent: NetworkDetailModeControlContent {
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
        NetworkDetailViewController.Mode.allCases.firstIndex(of: mode)
            ?? UISegmentedControl.noSegment
    }
}

@MainActor
private final class NetworkDetailAdaptiveModeControlView: UIView {
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

    var usesFloatingTabBarForTesting: Bool {
        content is NetworkDetailFloatingModeControlContent
    }

    var floatingTabBarForTesting: UIView? {
        (content as? NetworkDetailFloatingModeControlContent)?.floatingTabBarForTesting
    }

    var floatingCollectionViewForTesting: UICollectionView? {
        (content as? NetworkDetailFloatingModeControlContent)?.collectionViewForTesting
    }

    var floatingTabTitlesForTesting: [String] {
        (content as? NetworkDetailFloatingModeControlContent)?.tabTitlesForTesting ?? []
    }

    var selectedFloatingModeForTesting: NetworkDetailViewController.Mode? {
        (content as? NetworkDetailFloatingModeControlContent)?.selectedModeForTesting
    }

    var floatingTabsAreEnabledForTesting: Bool {
        (content as? NetworkDetailFloatingModeControlContent)?.tabsAreEnabledForTesting ?? false
    }

    var floatingTabBarShowsSidebarButtonForTesting: Bool {
        (content as? NetworkDetailFloatingModeControlContent)?.showsSidebarButtonForTesting ?? true
    }

    var floatingTabBarHasLiquidLensForTesting: Bool {
        (content as? NetworkDetailFloatingModeControlContent)?.hasLiquidLensForTesting ?? false
    }

    var usesExpandedFloatingPaginationForTesting: Bool {
        (content as? NetworkDetailFloatingModeControlContent)?
            .usesExpandedPaginationForTesting ?? false
    }

    var floatingMaximumContainerWidthForTesting: CGFloat? {
        (content as? NetworkDetailFloatingModeControlContent)?
            .maximumContainerWidthForTesting
    }
}

extension NetworkDetailFloatingModeControlContent {
    fileprivate var floatingTabBarForTesting: UIView {
        floatingView.floatingTabBar
    }

    fileprivate var collectionViewForTesting: UICollectionView {
        collectionView
    }

    fileprivate var tabTitlesForTesting: [String] {
        entries.map { $0.tab.title }
    }

    fileprivate var selectedModeForTesting: NetworkDetailViewController.Mode? {
        guard let selectedTab = tabController.selectedTab else {
            return nil
        }
        return entries.first(where: { $0.tab === selectedTab })?.mode
    }

    fileprivate var tabsAreEnabledForTesting: Bool {
        if #available(iOS 18.4, *) {
            return entries.allSatisfy { $0.tab.isEnabled }
        }
        return floatingView.isUserInteractionEnabled
    }

    fileprivate var showsSidebarButtonForTesting: Bool {
        floatingView.floatingTabBar.value(forKey: "showsSidebarButton") as? Bool ?? true
    }

    fileprivate var hasLiquidLensForTesting: Bool {
        floatingView.hasLiquidLens
    }

    fileprivate var usesExpandedPaginationForTesting: Bool {
        NSStringFromClass(type(of: floatingView.floatingTabBar))
            == "WIKNetworkDetailExpandedFloatingTabBar"
    }

    fileprivate var maximumContainerWidthForTesting: CGFloat? {
        NetworkDetailFloatingModeControlRuntime.maximumContainerSizeForTesting(
            of: floatingView.floatingTabBar
        )?.width
    }
}
#endif
#endif
