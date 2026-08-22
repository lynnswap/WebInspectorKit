#if canImport(UIKit)
import UIKit

@MainActor
protocol ScrollableTabBarContent: AnyObject {
    var view: UIView { get }
    var selectionHandler: ((Int) -> Void)? { get set }

    func render(
        selectedIndex: Int,
        isEnabled: Bool,
        accessibilityLabel: String?
    )
}

@MainActor
struct ScrollableTabBarPresentationItem {
    let title: String
    let image: UIImage?
    let accessibilityIdentifier: String?
}

/// A tab selector whose overflow items remain reachable through horizontal pagination.
///
/// The control uses UIKit's system floating-tab presentation when its runtime contract
/// is available, and otherwise presents the same ordered selection through public UIKit
/// controls. Listen for user selection with `UIControl.Event.valueChanged`.
@MainActor
public final class ScrollableTabBar<ID: Hashable>: UIControl {
    /// A tab presented by ``ScrollableTabBar``.
    public struct Item: Identifiable {
        /// The stable identity used for selection.
        public let id: ID

        /// The text describing the tab.
        public let title: String

        /// An optional image shown when the active UIKit presentation supports it.
        public let image: UIImage?

        /// An optional identifier for UI automation.
        public let accessibilityIdentifier: String?

        /// Creates a tab item with stable identity and display content.
        public init(
            id: ID,
            title: String,
            image: UIImage? = nil,
            accessibilityIdentifier: String? = nil
        ) {
            self.id = id
            self.title = title
            self.image = image
            self.accessibilityIdentifier = accessibilityIdentifier
        }
    }

    /// The immutable membership and display order of the control.
    public let items: [Item]

    /// The identifier of the selected item.
    ///
    /// Assigning this property updates the presentation without sending
    /// `UIControl.Event.valueChanged`. The identifier must belong to ``items``.
    public var selectedID: ID {
        get {
            items[selectedIndexStorage].id
        }
        set {
            guard let selectedIndex = itemIndexByID[newValue] else {
                preconditionFailure("ScrollableTabBar selectedID must identify one of its items.")
            }
            selectedIndexStorage = selectedIndex
            renderContent()
        }
    }

    /// A Boolean value that determines whether the user can change the selection.
    public override var isEnabled: Bool {
        didSet {
            renderContent()
        }
    }

    /// The contextual accessibility label propagated to the active presentation.
    public override var accessibilityLabel: String? {
        didSet {
            renderContent()
        }
    }

    private static var preferredWidth: CGFloat { 640 }
    private static var preferredHeight: CGFloat { 49 }

    let content: any ScrollableTabBarContent
    private let itemIndexByID: [ID: Int]
    private var selectedIndexStorage: Int

    /// Creates a tab selector with fixed membership and order.
    ///
    /// `items` must be nonempty, every item identifier must be unique, and
    /// `selectedID` must identify one of the supplied items.
    public init(
        items: [Item],
        selectedID: ID
    ) {
        precondition(items.isEmpty == false, "ScrollableTabBar requires at least one item.")

        var itemIndexByID: [ID: Int] = [:]
        for (index, item) in items.enumerated() {
            precondition(
                itemIndexByID.updateValue(index, forKey: item.id) == nil,
                "ScrollableTabBar item identifiers must be unique."
            )
        }
        guard let selectedIndex = itemIndexByID[selectedID] else {
            preconditionFailure("ScrollableTabBar selectedID must identify one of its items.")
        }

        let presentationItems = items.map { item in
            ScrollableTabBarPresentationItem(
                title: item.title,
                image: item.image,
                accessibilityIdentifier: item.accessibilityIdentifier
            )
        }
        let content: any ScrollableTabBarContent
        if let systemContent = SystemFloatingTabContent.makeIfAvailable(
            items: presentationItems,
            selectedIndex: selectedIndex
        ) {
            content = systemContent
        } else {
            content = AdaptiveTabContent(items: presentationItems)
        }

        self.items = items
        self.itemIndexByID = itemIndexByID
        selectedIndexStorage = selectedIndex
        self.content = content
        super.init(frame: .zero)

        isAccessibilityElement = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(content.view)
        content.selectionHandler = { [weak self] selectedIndex in
            self?.didSelectItem(at: selectedIndex)
        }
        renderContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: Self.preferredWidth, height: Self.preferredHeight)
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        let proposedWidth = size.width > 0 && size.width.isFinite
            ? size.width
            : Self.preferredWidth
        return CGSize(
            width: min(Self.preferredWidth, proposedWidth),
            height: Self.preferredHeight
        )
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        content.view.frame = bounds
        content.view.layoutIfNeeded()
    }

    func didSelectItem(at selectedIndex: Int) {
        guard items.indices.contains(selectedIndex) else {
            scrollableTabBarLogger.fault(
                "ScrollableTabBar content selected an item outside its immutable membership."
            )
            renderContent()
            return
        }
        guard isEnabled else {
            renderContent()
            return
        }

        guard selectedIndex != selectedIndexStorage else {
            return
        }
        selectedIndexStorage = selectedIndex
        renderContent()
        sendActions(for: .valueChanged)
    }

    private func renderContent() {
        content.render(
            selectedIndex: selectedIndexStorage,
            isEnabled: isEnabled,
            accessibilityLabel: accessibilityLabel
        )
    }
}
#endif
