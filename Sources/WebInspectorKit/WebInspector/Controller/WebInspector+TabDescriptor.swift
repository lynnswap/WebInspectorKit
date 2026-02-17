#if canImport(UIKit)
import UIKit
public typealias WIPlatformViewController = UIViewController
#elseif canImport(AppKit)
import AppKit
public typealias WIPlatformViewController = NSViewController
#endif

extension WebInspector {
#if canImport(UIKit) || canImport(AppKit)
    public typealias PlatformViewController = WIPlatformViewController
#endif

    public struct TabContext {
        public let controller: Controller

        public var domInspector: DOMInspector {
            controller.dom
        }

        public var networkInspector: NetworkInspector {
            controller.network
        }

        public init(controller: Controller) {
            self.controller = controller
        }
    }

    public struct TabDescriptor: Identifiable, Hashable {
        public typealias ID = String

        public enum Role: Hashable, Sendable {
            case inspector
            case other
        }

        public struct FeatureRequirements: OptionSet, Hashable, Sendable {
            public let rawValue: Int

            public init(rawValue: Int) {
                self.rawValue = rawValue
            }

            public static let dom = FeatureRequirements(rawValue: 1 << 0)
            public static let network = FeatureRequirements(rawValue: 1 << 1)
        }

        public struct Activation: Hashable, Sendable {
            public var domLiveUpdates: Bool
            public var networkLiveLogging: Bool

            public init(domLiveUpdates: Bool = false, networkLiveLogging: Bool = false) {
                self.domLiveUpdates = domLiveUpdates
                self.networkLiveLogging = networkLiveLogging
            }
        }

        public let id: ID
        public let title: String
        public let systemImage: String
        public let role: Role
        public let requires: FeatureRequirements
        public let activation: Activation

        private let makeViewControllerImpl: @MainActor (TabContext) -> PlatformViewController

        @MainActor
        public init(
            id: ID,
            title: String,
            systemImage: String,
            role: Role = .other,
            requires: FeatureRequirements = [],
            activation: Activation = .init(),
            makeViewController: @escaping @MainActor (TabContext) -> PlatformViewController
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
        public func makeViewController(context: TabContext) -> PlatformViewController {
            makeViewControllerImpl(context)
        }

        public static func == (lhs: TabDescriptor, rhs: TabDescriptor) -> Bool {
            lhs.id == rhs.id
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }
}
