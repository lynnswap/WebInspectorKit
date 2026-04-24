#if canImport(UIKit)
import UIKit

@MainActor
public enum V2_ProvidedWITab: Hashable, CaseIterable {
    case dom
    case network

    public static let defaults: Set<Self> = [.dom, .network]

    func makeTab() -> UITab {
        let viewController = makeViewController()
        return UITab(title: title, image: image, identifier: identifier) { _ in
            viewController
        }
    }

    private var title: String {
        switch self {
        case .dom:
            "DOM"
        case .network:
            "Network"
        }
    }

    private var identifier: String {
        switch self {
        case .dom:
            "v2.dom"
        case .network:
            "v2.network"
        }
    }

    private var image: UIImage? {
        UIImage(systemName: systemImage)
    }

    private var systemImage: String {
        switch self {
        case .dom:
            "chevron.left.forwardslash.chevron.right"
        case .network:
            "waveform.path.ecg.rectangle"
        }
    }

    private func makeViewController() -> UIViewController {
        switch self {
        case .dom:
            V2_DOMSplitViewController()
        case .network:
            V2_NetworkSplitViewController()
        }
    }
}

@MainActor
public struct V2_WITab {
    public typealias ViewControllerProvider = @MainActor (V2_WITab) -> UIViewController

    public let identifier: String
    public let title: String
    public let image: UIImage?
    public let viewControllerProvider: ViewControllerProvider?
    public var userInfo: Any?

    public var id: String { identifier }

    public init(
        title: String,
        image: UIImage?,
        identifier: String,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.image = image
        self.viewControllerProvider = viewControllerProvider
        self.userInfo = userInfo
    }

    public init(
        id: String,
        title: String,
        image: UIImage?,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.init(
            title: title,
            image: image,
            identifier: id,
            viewControllerProvider: viewControllerProvider,
            userInfo: userInfo
        )
    }

    public init(
        id: String,
        title: String,
        systemImage: String,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.init(
            title: title,
            image: Self.systemImage(named: systemImage),
            identifier: id,
            viewControllerProvider: viewControllerProvider,
            userInfo: userInfo
        )
    }

    public init(
        identifier: String,
        title: String,
        image: UIImage? = nil,
        makeViewController: @escaping @MainActor () -> UIViewController
    ) {
        self.init(
            title: title,
            image: image,
            identifier: identifier,
            viewControllerProvider: { _ in makeViewController() }
        )
    }

    private static func systemImage(named name: String) -> UIImage? {
        UIImage(systemName: name)
    }
}

@MainActor
public final class V2_WITabBarController: UITabBarController {
    public let session: V2_WISession

    private lazy var providedTabItems = V2_ProvidedWITab.allCases
        .filter { session.interface.providedTabs.contains($0) }
        .map { $0.makeTab() }

    public init(session: V2_WISession = V2_WISession()) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        tabBar.scrollEdgeAppearance = tabBar.standardAppearance
        setTabs(providedTabItems, animated: false)
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2 WITabBarController") {
    V2_WITabBarController()
}
#endif
#endif
