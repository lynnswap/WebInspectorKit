import SwiftUI

extension WebInspector {
    public struct Tab: Identifiable, Hashable {
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
        public let title: LocalizedStringResource
        public let systemImage: String
        public let role: Role
        public let requires: FeatureRequirements
        public let activation: Activation

        private let makeView: @MainActor (Controller) -> AnyView

        @MainActor
        public init<Content: View>(
            _ title: LocalizedStringResource,
            systemImage: String,
            id: ID? = nil,
            role: Role = .other,
            requires: FeatureRequirements = [],
            activation: Activation = .init(),
            @ViewBuilder content: @escaping @MainActor (Controller) -> Content
        ) {
            if let id {
                self.id = id
            } else {
                self.id = title.key
            }
            self.title = title
            self.systemImage = systemImage
            self.role = role
            self.requires = requires
            self.activation = activation
            self.makeView = { controller in AnyView(content(controller)) }
        }

        @MainActor
        func view(controller: Controller) -> AnyView {
            makeView(controller)
        }

        public static func == (lhs: Tab, rhs: Tab) -> Bool {
            lhs.id == rhs.id
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }
}
