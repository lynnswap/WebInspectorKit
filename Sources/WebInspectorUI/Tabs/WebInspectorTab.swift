#if canImport(UIKit)
import UIKit
import WebInspectorDataKit

/// A tab shown by the built-in WebInspectorKit UI.
///
/// Use the built-in ``dom`` and ``network`` tabs, or create a custom tab backed
/// by an asynchronous UIKit view controller factory.
///
/// Example:
///
/// ```swift
/// let consoleTab = WebInspectorTab(
///     id: "app_console",
///     title: "Console",
///     systemImage: "terminal"
/// ) { session in
///     ConsoleViewController(inspectorSession: session)
/// }
///
/// let inspector = WebInspectorViewController(
///     tabs: [.dom, .network, consoleTab]
/// )
/// ```
@MainActor
public struct WebInspectorTab: Equatable, Hashable, Identifiable {
    /// Stable identity type for an inspector tab.
    public typealias ID = String

    /// Stable tab identity.
    public let id: ID

    /// Display title used by tab UI.
    public let title: String

    /// Optional tab image.
    public let image: UIImage?

    /// Model domains that must be ready before this tab is used.
    public let requiredDomains: Set<WebInspectorModelContainer.Domain>
    package let content: Content

    package enum BuiltIn: Hashable {
        case dom
        case network
    }

    @MainActor
    package struct CustomContent {
        package let makeViewController: @MainActor (WebInspectorSession) async throws -> UIViewController
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

    /// Compares tabs by their stable identity.
    public static nonisolated func == (lhs: WebInspectorTab, rhs: WebInspectorTab) -> Bool {
        lhs.id == rhs.id
    }

    /// Hashes the tab identity.
    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private init(
        id: ID,
        title: String,
        image: UIImage?,
        builtIn: BuiltIn,
        requiredDomains: Set<WebInspectorModelContainer.Domain>
    ) {
        self.id = id
        self.title = title
        self.image = image
        self.requiredDomains = requiredDomains
        self.content = .builtIn(builtIn)
    }

    /// Creates an app-provided inspector tab backed by a UIKit view controller.
    ///
    /// The factory is called the first time the tab content is needed for a
    /// root inspector controller. While it runs, WebInspectorKit presents a
    /// native loading configuration. A failure presents a retry action.
    /// Concurrent host requests join one factory invocation, and the returned
    /// controller is reused across compact and regular hosts.
    public init(
        id: ID,
        title: String,
        image: UIImage? = nil,
        requiredDomains: Set<WebInspectorModelContainer.Domain> = [],
        makeViewController: @escaping @MainActor (_ session: WebInspectorSession) async throws -> UIViewController
    ) {
        self.id = id
        self.title = title
        self.image = image
        self.requiredDomains = requiredDomains
        self.content = .custom(CustomContent(makeViewController: makeViewController))
    }

    /// Creates an app-provided inspector tab using an SF Symbols image name.
    public init(
        id: ID,
        title: String,
        systemImage: String,
        requiredDomains: Set<WebInspectorModelContainer.Domain> = [],
        makeViewController: @escaping @MainActor (_ session: WebInspectorSession) async throws -> UIViewController
    ) {
        self.init(
            id: id,
            title: title,
            image: UIImage(systemName: systemImage),
            requiredDomains: requiredDomains,
            makeViewController: makeViewController
        )
    }

    /// Built-in DOM inspector tab.
    public static let dom = WebInspectorTab(
        id: "webinspector_dom",
        title: "DOM",
        image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
        builtIn: .dom,
        requiredDomains: [.dom, .css]
    )

    /// Built-in Network inspector tab.
    public static let network = WebInspectorTab(
        id: "webinspector_network",
        title: "Network",
        image: UIImage(systemName: "waveform.path.ecg.rectangle"),
        builtIn: .network,
        requiredDomains: [.network]
    )
}
#endif
