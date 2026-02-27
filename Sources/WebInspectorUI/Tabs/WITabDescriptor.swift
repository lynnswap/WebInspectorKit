#if canImport(UIKit)
import UIKit
public typealias WIPlatformViewController = UIViewController
#elseif canImport(AppKit)
import AppKit
public typealias WIPlatformViewController = NSViewController
#endif
import WebInspectorModel

@MainActor
public struct WITabContext {
    public let controller: WISession
    let networkQueryModel: WINetworkQueryModel
#if canImport(UIKit)
    public let horizontalSizeClass: UIUserInterfaceSizeClass?
#endif

    public var domInspector: WIDOMModel {
        controller.dom
    }

    public var networkInspector: WINetworkModel {
        controller.network
    }

    #if canImport(UIKit)
    public init(controller: WISession, horizontalSizeClass: UIUserInterfaceSizeClass? = nil) {
        self.controller = controller
        self.networkQueryModel = WINetworkQueryModel(inspector: controller.network)
        self.horizontalSizeClass = horizontalSizeClass
    }

    init(
        controller: WISession,
        networkQueryModel: WINetworkQueryModel,
        horizontalSizeClass: UIUserInterfaceSizeClass?
    ) {
        self.controller = controller
        self.networkQueryModel = networkQueryModel
        self.horizontalSizeClass = horizontalSizeClass
    }
    #else
    public init(controller: WISession) {
        self.controller = controller
        self.networkQueryModel = WINetworkQueryModel(inspector: controller.network)
    }

    init(controller: WISession, networkQueryModel: WINetworkQueryModel) {
        self.controller = controller
        self.networkQueryModel = networkQueryModel
    }
    #endif
}

public struct WITabDescriptor: Identifiable, Hashable {
    public typealias ID = String
    public typealias FeatureRequirements = WISessionFeatureRequirements
    public typealias Activation = WISessionTabActivation

    public enum Role: Hashable, Sendable {
        case inspector
        case other
    }

    public let id: ID
    public let title: String
    public let systemImage: String
    public let role: Role
    public let requires: FeatureRequirements
    public let activation: Activation

    private let makeViewControllerImpl: @MainActor (WITabContext) -> WIPlatformViewController

    @MainActor
    public init(
        id: ID,
        title: String,
        systemImage: String,
        role: Role = .other,
        requires: FeatureRequirements = [],
        activation: Activation = .init(),
        makeViewController: @escaping @MainActor (WITabContext) -> WIPlatformViewController
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.requires = requires
        self.activation = activation
        self.makeViewControllerImpl = makeViewController
    }

    @MainActor
    public func makeViewController(context: WITabContext) -> WIPlatformViewController {
        makeViewControllerImpl(context)
    }

    public static func == (lhs: WITabDescriptor, rhs: WITabDescriptor) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

package extension WITabDescriptor {
    var sessionTabDefinition: WISessionTabDefinition {
        WISessionTabDefinition(
            id: id,
            requires: requires,
            activation: activation
        )
    }
}
