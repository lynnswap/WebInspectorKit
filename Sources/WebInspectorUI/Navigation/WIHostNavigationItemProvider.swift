#if canImport(UIKit)
import UIKit

@MainActor
public protocol WIHostNavigationItemProvider: AnyObject {
    var hostNavigationState: WIHostNavigationState { get }
}
#endif
