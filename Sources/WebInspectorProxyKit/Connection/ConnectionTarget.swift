import Foundation

package enum ProtocolTarget {}

package extension ProtocolTarget {
    struct ID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
        package let rawValue: String

        package init(_ rawValue: String) { self.rawValue = rawValue }
        package init(rawValue: String) { self.rawValue = rawValue }
        package var description: String { rawValue }
    }

    struct Kind: RawRepresentable, Hashable, Codable, Sendable {
        package let rawValue: String

        package init(rawValue: String) { self.rawValue = rawValue }

        package static let page = Self(rawValue: "page")
        package static let frame = Self(rawValue: "frame")
        package static let worker = Self(rawValue: "worker")
        package static let serviceWorker = Self(rawValue: "service-worker")

        package init(protocolType: String) {
            switch protocolType {
            case "web-page": self = .page
            default: self.init(rawValue: protocolType)
            }
        }
    }

    struct Record: Equatable, Sendable {
        package var id: ID
        package var kind: Kind
        package var parentTargetID: ID?
        package var frameID: FrameID?
        package var isProvisional: Bool
        package var isPaused: Bool

        package init(
            id: ID,
            kind: Kind,
            parentTargetID: ID? = nil,
            frameID: FrameID? = nil,
            isProvisional: Bool = false,
            isPaused: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.parentTargetID = parentTargetID
            self.frameID = frameID
            self.isProvisional = isProvisional
            self.isPaused = isPaused
        }

        package var isTopLevelPage: Bool {
            kind == .page && parentTargetID == nil
        }
    }
}

/// A WebKit frame identifier reported by the inspector protocol.
public struct FrameID: Hashable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) { self.rawValue = rawValue }
}

package struct WebInspectorTarget: Identifiable, Hashable, Sendable {
    package struct ID: Hashable, Sendable {
        package let rawValue: String

        package init(_ rawValue: String) { self.rawValue = rawValue }
        package static let currentPage = ID("current-page")
    }

    package let id: ID
    package let kind: ProtocolTarget.Kind
    package let frameID: FrameID?
    package let isProvisional: Bool
}

package enum WebInspectorRoute: Hashable, Sendable {
    case root
    case currentPage
    case target(WebInspectorTarget.ID)
}

package struct WebInspectorTargetSelectionPolicy: Hashable, Sendable {
    package enum Anchor: Hashable, Sendable {
        case currentPage
        case target(WebInspectorTarget.ID)
    }

    package let anchor: Anchor
    package let includesAnchor: Bool
    package let descendantKinds: Set<ProtocolTarget.Kind>

    package init(
        anchor: Anchor,
        includesAnchor: Bool = true,
        descendantKinds: Set<ProtocolTarget.Kind> = []
    ) {
        self.anchor = anchor
        self.includesAnchor = includesAnchor
        self.descendantKinds = descendantKinds
    }

    package static let currentPage = Self(
        anchor: .currentPage,
        descendantKinds: [.frame]
    )

    package static func target(_ id: WebInspectorTarget.ID) -> Self {
        Self(anchor: .target(id))
    }

    package static func descendants(
        of anchor: Anchor = .currentPage,
        kinds: Set<ProtocolTarget.Kind>,
        includingAnchor: Bool = false
    ) -> Self {
        Self(anchor: anchor, includesAnchor: includingAnchor, descendantKinds: kinds)
    }
}
