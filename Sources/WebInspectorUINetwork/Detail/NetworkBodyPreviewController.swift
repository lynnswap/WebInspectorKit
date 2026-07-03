#if canImport(UIKit)
import WebInspectorUIBase
import UIKit
import WebInspectorDataKit

@MainActor
package enum NetworkBodySurface {
    case none
    case unavailableBodyPlaceholder
    case body(NetworkBody, metadata: NetworkMediaPreviewMetadata?)

    package var body: NetworkBody? {
        if case .body(let body, _) = self {
            return body
        }
        return nil
    }

    package var metadata: NetworkMediaPreviewMetadata? {
        if case .body(_, let metadata) = self {
            return metadata
        }
        return nil
    }

    package var isRenderable: Bool {
        switch self {
        case .none:
            false
        case .unavailableBodyPlaceholder, .body:
            true
        }
    }

    package func isEquivalent(to other: NetworkBodySurface) -> Bool {
        switch (self, other) {
        case (.none, .none), (.unavailableBodyPlaceholder, .unavailableBodyPlaceholder):
            return true
        case (.body(let body, let metadata), .body(let otherBody, let otherMetadata)):
            return body === otherBody && metadata == otherMetadata
        default:
            return false
        }
    }
}

@MainActor
package protocol NetworkBodyPreviewControlling: AnyObject {
    func setSurface(_ nextSurface: NetworkBodySurface)
    func resumeRendering()
    func suspendKeepingSurface()
}

package typealias NetworkBodyPreviewViewController = UIViewController & NetworkBodyPreviewControlling

package typealias NetworkBodyViewControllerFactory =
    @MainActor (_ scrollEdgeSink: any NetworkBodyScrollEdgeSink) -> NetworkBodyPreviewViewController

@MainActor
package final class UnavailableNetworkBodyPreviewViewController: UIViewController, NetworkBodyPreviewControlling {
    private var surface = NetworkBodySurface.none
    private weak var scrollEdgeSink: (any NetworkBodyScrollEdgeSink)?

    package init(scrollEdgeSink: any NetworkBodyScrollEdgeSink) {
        self.scrollEdgeSink = scrollEdgeSink
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    package func setSurface(_ nextSurface: NetworkBodySurface) {
        surface = nextSurface
    }

    package func resumeRendering() {
        scrollEdgeSink?.contentScrollView = nil
    }

    package func suspendKeepingSurface() {}
}
#endif
