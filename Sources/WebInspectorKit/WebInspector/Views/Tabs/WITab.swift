import SwiftUI

#if canImport(UIKit)
import UIKit
typealias WITabHostingController<Content: View> = UIHostingController<Content>
typealias WITabViewController = UIViewController
#elseif canImport(AppKit)
import AppKit
typealias WITabHostingController<Content: View> = NSHostingController<Content>
typealias WITabViewController = NSViewController
#endif

public struct WITab: Identifiable {
    public let id: String
    public let title: LocalizedStringResource
    public let systemImage: String
    private let makeViewController: @MainActor (WebInspectorModel) -> WITabViewController

    @MainActor
    public init(
        _ title: LocalizedStringResource,
        systemImage: String,
        value: String? = nil,
        @ViewBuilder content: @escaping () -> some View
    ) {
        if let value {
            self.id = value
        } else {
            self.id = title.key
        }
        self.title = title
        self.systemImage = systemImage
        self.makeViewController = { model in
            let host = WITabHostingController(rootView: content().environment(model))
#if canImport(UIKit)
            host.view.backgroundColor = .clear
#endif
            return host
        }
    }

    @MainActor
    func viewController(with model: WebInspectorModel) -> WITabViewController {
        makeViewController(model)
    }
}
