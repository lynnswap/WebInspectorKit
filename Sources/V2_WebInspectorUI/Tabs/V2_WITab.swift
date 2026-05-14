#if canImport(UIKit)
import UIKit

@MainActor
public struct V2_WITab: Equatable, Hashable, Identifiable {
    public typealias ID = String

    public let id: ID
    public let title: String
    public let image: UIImage?
    package let builtIn: BuiltIn

    package enum BuiltIn: Hashable {
        case dom
        case network
    }

    public static nonisolated func == (lhs: V2_WITab, rhs: V2_WITab) -> Bool {
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
        self.builtIn = builtIn
    }

    public static let dom = V2_WITab(
        id: "v2_wi_dom",
        title: "DOM",
        image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
        builtIn: .dom
    )

    public static let network = V2_WITab(
        id: "v2_wi_network",
        title: "Network",
        image: UIImage(systemName: "waveform.path.ecg.rectangle"),
        builtIn: .network
    )
}
#endif
