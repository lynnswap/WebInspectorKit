#if canImport(UIKit)
import UIKit

@MainActor
public struct WebInspectorTab: Equatable, Hashable, Identifiable {
    public typealias ID = String

    public let id: ID
    public let title: String
    public let image: UIImage?
    package let content: Content

    package enum BuiltIn: Hashable {
        case dom
        case network
    }

    @MainActor
    package struct CustomContent {
        package let makeViewController: @MainActor (WebInspectorSession) -> UIViewController
    }

    package enum Content {
        case builtIn(BuiltIn)
        case custom(CustomContent)
    }

    package var builtIn: BuiltIn? {
        guard case let .builtIn(builtIn) = content else {
            return nil
        }
        return builtIn
    }

    public static nonisolated func == (lhs: WebInspectorTab, rhs: WebInspectorTab) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private init(
        id: ID,
        title: String,
        image: UIImage?,
        builtIn: BuiltIn
    ) {
        self.id = id
        self.title = title
        self.image = image
        self.content = .builtIn(builtIn)
    }

    /// Creates an app-provided inspector tab backed by a UIKit view controller.
    ///
    /// The factory is called the first time the tab content is needed for a
    /// session. WebInspectorKit caches the returned controller for the tab ID
    /// and reuses it across compact and regular presentations.
    public init(
        id: ID,
        title: String,
        image: UIImage? = nil,
        makeViewController: @escaping @MainActor (_ session: WebInspectorSession) -> UIViewController
    ) {
        self.id = id
        self.title = title
        self.image = image
        self.content = .custom(CustomContent(makeViewController: makeViewController))
    }

    /// Creates an app-provided inspector tab using an SF Symbols image name.
    public init(
        id: ID,
        title: String,
        systemImage: String,
        makeViewController: @escaping @MainActor (_ session: WebInspectorSession) -> UIViewController
    ) {
        self.init(
            id: id,
            title: title,
            image: UIImage(systemName: systemImage),
            makeViewController: makeViewController
        )
    }

    public static let dom = WebInspectorTab(
        id: "webinspector_dom",
        title: "DOM",
        image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
        builtIn: .dom
    )

    public static let network = WebInspectorTab(
        id: "webinspector_network",
        title: "Network",
        image: UIImage(systemName: "waveform.path.ecg.rectangle"),
        builtIn: .network
    )
}
#endif
