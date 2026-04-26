#if canImport(UIKit)
import UIKit

@MainActor
public struct V2_WITab: Equatable, Hashable, Identifiable {
    public typealias ID = String
    public typealias ViewControllerProvider = @MainActor (V2_WITab, V2_WISession) -> UIViewController

    public let id: ID
    internal let definition: any V2_WITabDefinition
    public var userInfo: Any?

    public var title: String {
        definition.title
    }

    public var image: UIImage? {
        definition.image
    }

    public static nonisolated func == (lhs: V2_WITab, rhs: V2_WITab) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    init(
        definition: any V2_WITabDefinition,
        userInfo: Any? = nil
    ) {
        self.id = definition.id
        self.definition = definition
        self.userInfo = userInfo
    }

    public init(
        title: String,
        image: UIImage?,
        identifier: String,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.init(
            definition: V2_CustomTabDefinition(
                id: identifier,
                title: title,
                image: image,
                viewControllerProvider: viewControllerProvider
            ),
            userInfo: userInfo
        )
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
            image: UIImage(systemName: systemImage),
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
}
#endif
