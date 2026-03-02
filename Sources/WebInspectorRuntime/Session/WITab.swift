import Foundation
import WebInspectorEngine

#if canImport(UIKit)
import UIKit
public typealias WIPlatformImage = UIImage
public typealias WIPlatformViewController = UIViewController
#elseif canImport(AppKit)
import AppKit
public typealias WIPlatformImage = NSImage
public typealias WIPlatformViewController = NSViewController
#endif

@MainActor
public final class WITab: NSObject {
    public static let domTabID = "wi_dom"
    public static let elementTabID = "wi_element"
    public static let networkTabID = "wi_network"

    public enum Role: Hashable, Sendable {
        case inspector
        case other
    }

    public typealias ViewControllerProvider = @MainActor (WITab) -> WIPlatformViewController

    public let identifier: String
    public let title: String
    public let image: WIPlatformImage?
    public let role: Role
    public let viewControllerProvider: ViewControllerProvider?
    public var userInfo: Any?

    package var cachedContentViewController: WIPlatformViewController?
#if canImport(UIKit)
    package var cachedCompactUITab: UITab?
#endif

    public var id: String { identifier }

    public init(
        title: String,
        image: WIPlatformImage?,
        identifier: String,
        role: Role = .other,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.image = image
        self.role = role
        self.viewControllerProvider = viewControllerProvider
        self.userInfo = userInfo
        super.init()
    }

    public convenience init(
        id: String,
        title: String,
        image: WIPlatformImage?,
        role: Role = .other,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.init(
            title: title,
            image: image,
            identifier: id,
            role: role,
            viewControllerProvider: viewControllerProvider,
            userInfo: userInfo
        )
    }

    public convenience init(
        id: String,
        title: String,
        systemImage: String,
        role: Role = .other,
        viewControllerProvider: ViewControllerProvider? = nil,
        userInfo: Any? = nil
    ) {
        self.init(
            title: title,
            image: Self.systemImage(named: systemImage, accessibilityDescription: title),
            identifier: id,
            role: role,
            viewControllerProvider: viewControllerProvider,
            userInfo: userInfo
        )
    }

    package func resetCachedContentViewController() {
        cachedContentViewController = nil
#if canImport(UIKit)
        cachedCompactUITab = nil
#endif
    }

    private static func systemImage(named name: String, accessibilityDescription: String?) -> WIPlatformImage? {
#if canImport(UIKit)
        UIImage(systemName: name)
#elseif canImport(AppKit)
        NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
#else
        nil
#endif
    }
}
