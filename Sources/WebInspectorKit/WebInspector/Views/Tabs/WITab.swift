import SwiftUI

#if canImport(UIKit)
import UIKit
typealias WITabHostingController<Content: View> = UIHostingController<Content>
typealias WIViewController = UIViewController
#elseif canImport(AppKit)
import AppKit
typealias WITabHostingController<Content: View> = NSHostingController<Content>
typealias WIViewController = NSViewController
#endif

public struct WITab: Identifiable,Hashable{
    public let id: String
    public let title: LocalizedStringResource
    public let systemImage: String
    public let role: WITabRole
    private let makeViewController: @MainActor (WebInspectorModel) -> WIViewController

    @MainActor
    public init(
        _ title: LocalizedStringResource,
        systemImage: String,
        value: String? = nil,
        role: WITabRole = .other,
        @ViewBuilder content: @escaping (WebInspectorModel) -> some View
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
            let host = WITabHostingController(rootView: content(model))
#if canImport(UIKit)
            host.view.backgroundColor = .clear
#endif
            return host
        }
    }

    @MainActor
    func viewController(with model: WebInspectorModel) -> WIViewController {
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
