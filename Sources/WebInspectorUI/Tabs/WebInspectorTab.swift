#if canImport(UIKit)
import UIKit

@MainActor
public struct WebInspectorTab: Equatable, Hashable, Identifiable {
    public typealias ID = String

    public let id: ID
    public let title: String
    public let image: UIImage?
    package let builtIn: BuiltIn

    package enum BuiltIn: Hashable {
        case dom
        case network
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
        self.builtIn = builtIn
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
