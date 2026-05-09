#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
public struct WITab: Equatable, Hashable, Identifiable {
    public typealias ID = String
    public typealias ViewControllerProvider = @MainActor (WITabProviderContext) -> UIViewController

    public let id: ID
    public let title: String
    public let image: UIImage?
    let kind: Kind

    enum BuiltIn: Hashable {
        case dom
        case network
    }

    enum Kind {
        case builtIn(BuiltIn)
        case custom(CustomWITab)
    }

    public static nonisolated func == (lhs: WITab, rhs: WITab) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    init(
        id: ID,
        title: String,
        image: UIImage?,
        kind: Kind
    ) {
        self.id = id
        self.title = title
        self.image = image
        self.kind = kind
    }

    public static let dom = WITab(
        id: "wi_dom",
        title: "DOM",
        image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
        kind: .builtIn(.dom)
    )

    public static let network = WITab(
        id: "wi_network",
        title: "Network",
        image: UIImage(systemName: "waveform.path.ecg.rectangle"),
        kind: .builtIn(.network)
    )

    public static func custom(
        id: ID,
        title: String,
        image: UIImage?,
        makeViewController: @escaping ViewControllerProvider
    ) -> WITab {
        WITab(
            id: id,
            title: title,
            image: image,
            kind: .custom(
                CustomWITab(
                    id: id,
                    makeViewController: makeViewController
                )
            )
        )
    }

    public static func custom(
        id: ID,
        title: String,
        systemImage: String,
        makeViewController: @escaping ViewControllerProvider
    ) -> WITab {
        custom(
            id: id,
            title: title,
            image: UIImage(systemName: systemImage),
            makeViewController: makeViewController
        )
    }

    public init(
        id: ID,
        title: String,
        image: UIImage?,
        makeViewController: @escaping ViewControllerProvider
    ) {
        self = Self.custom(
            id: id,
            title: title,
            image: image,
            makeViewController: makeViewController
        )
    }

    public init(
        id: ID,
        title: String,
        systemImage: String,
        makeViewController: @escaping ViewControllerProvider
    ) {
        self = Self.custom(
            id: id,
            title: title,
            systemImage: systemImage,
            makeViewController: makeViewController
        )
    }
}

@MainActor
public struct WITabProviderContext {
    public let session: WISession

    public var runtime: WIRuntimeSession {
        session.runtime
    }
}

@MainActor
struct CustomWITab {
    let id: WITab.ID
    let makeViewController: WITab.ViewControllerProvider
}

extension WITab {
    var builtIn: BuiltIn? {
        guard case let .builtIn(builtIn) = kind else {
            return nil
        }
        return builtIn
    }

    var custom: CustomWITab? {
        guard case let .custom(custom) = kind else {
            return nil
        }
        return custom
    }
}
#endif
