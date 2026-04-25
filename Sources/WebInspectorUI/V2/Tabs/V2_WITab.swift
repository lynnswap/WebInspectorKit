#if canImport(UIKit)
import UIKit

enum V2_WITabHostLayout {
    case compact
    case regular
}

extension V2_WITab {
    public static nonisolated func == (lhs: V2_WITab, rhs: V2_WITab) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
public struct V2_WITab: Equatable, Identifiable {
    public typealias ID = String
    public typealias ViewControllerProvider = @MainActor (V2_WITab, V2_WISession) -> UIViewController
    typealias HostLayoutViewControllerProvider = @MainActor (V2_WITab, V2_WISession, V2_WITabHostLayout) -> UIViewController

    public let id: ID
    public let title: String
    public let image: UIImage?
    public let viewControllerProvider: ViewControllerProvider?
    let hostLayoutViewControllerProvider: HostLayoutViewControllerProvider?
    public var userInfo: Any?

    public init(
        title: String,
        image: UIImage?,
        identifier: String,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.id = identifier
        self.title = title
        self.image = image
        self.viewControllerProvider = viewControllerProvider
        self.hostLayoutViewControllerProvider = nil
        self.userInfo = userInfo
    }

    init(
        title: String,
        image: UIImage?,
        identifier: String,
        hostLayoutViewControllerProvider: @escaping HostLayoutViewControllerProvider,
        userInfo: Any? = nil
    ) {
        self.id = identifier
        self.title = title
        self.image = image
        self.viewControllerProvider = nil
        self.hostLayoutViewControllerProvider = hostLayoutViewControllerProvider
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
            viewControllerProvider: { _, _ in makeViewController() }
        )
    }

    func makeViewController(session: V2_WISession) -> UIViewController {
        viewControllerProvider?(self, session) ?? UIViewController()
    }

    func makeViewController(session: V2_WISession, hostLayout: V2_WITabHostLayout) -> UIViewController {
        hostLayoutViewControllerProvider?(self, session, hostLayout) ?? makeViewController(session: session)
    }

    private static func systemImage(named name: String) -> UIImage? {
        UIImage(systemName: name)
    }
}
#endif
