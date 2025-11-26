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

public struct WITab: Identifiable,Hashable{
    public let id: String
    public let title: LocalizedStringResource
    public let systemImage: String
    public let role: WITabRole
    private let makeViewController: @MainActor (WebInspectorModel) -> WITabViewController

    @MainActor
    public init(
        _ title: LocalizedStringResource,
        systemImage: String,
        value: String? = nil,
        role: WITabRole = .other,
        @ViewBuilder content: @escaping () -> some View
    ) {
        if let value {
            self.id = value
        } else {
            self.id = title.key
        }
        self.title = title
        self.systemImage = systemImage
        self.role = role
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
    
    public static func == (lhs: WITab, rhs: WITab) -> Bool {
        lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
public enum WITabRole {
    case inspector
    case other
}
