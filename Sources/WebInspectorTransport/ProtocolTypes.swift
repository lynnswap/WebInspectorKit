package enum ProtocolTarget {}
package enum ProtocolFrame {}
package enum RuntimeContext {}

package extension ProtocolTarget {
    struct ID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package var description: String {
            rawValue
        }
    }
}

package extension ProtocolFrame {
    struct ID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
        package let rawValue: String

        package init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        package init(rawValue: String) {
            self.rawValue = rawValue
        }

        package var description: String {
            rawValue
        }
    }
}

extension RuntimeContext {
    package struct ID: RawRepresentable, Hashable, Codable, Sendable {        package let rawValue: Int

        package init(_ rawValue: Int) {
            self.rawValue = rawValue
        }

        package init(rawValue: Int) {
            self.rawValue = rawValue
        }
    }
}

package extension ProtocolTarget {
    enum Kind: Equatable, Sendable {
        case page
        case frame
        case worker
        case serviceWorker
        case other(String)

        package init(protocolType: String) {
            switch protocolType {
            case "page", "web-page":
                self = .page
            case "frame":
                self = .frame
            case "worker":
                self = .worker
            case "service-worker":
                self = .serviceWorker
            default:
                self = .other(protocolType)
            }
        }
    }
}

package extension ProtocolTarget {
    struct Capabilities: OptionSet, Equatable, Hashable, Sendable {
        package let rawValue: UInt8

        package init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        package static let dom = Self(rawValue: 1 << 0)
        package static let runtime = Self(rawValue: 1 << 1)
        package static let target = Self(rawValue: 1 << 2)
        package static let inspector = Self(rawValue: 1 << 3)
        package static let network = Self(rawValue: 1 << 4)
        package static let css = Self(rawValue: 1 << 5)
        package static let console = Self(rawValue: 1 << 6)

        package static let pageDefault: Self = [.dom, .runtime, .target, .inspector, .network, .css, .console]
        package static let frameDefault: Self = []
        package static let workerDefault: Self = [.runtime, .console]
        package static let serviceWorkerDefault: Self = [.runtime, .network, .console]

        package static func protocolDefault(for kind: Kind) -> Self {
            switch kind {
            case .page:
                return .pageDefault
            case .frame:
                return .frameDefault
            case .worker:
                return .workerDefault
            case .serviceWorker:
                return .serviceWorkerDefault
            case .other:
                return []
            }
        }

        package static func resolved(for kind: Kind, domainNames: [String]?) -> Self {
            guard let domainNames else {
                return protocolDefault(for: kind)
            }

            let advertised = Self(domainNames: domainNames)
            guard kind == .page else {
                return advertised
            }
            return protocolDefault(for: kind).union(advertised)
        }

        package init(domainNames: [String]) {
            var capabilities: Self = []
            for domainName in domainNames {
                switch domainName.lowercased() {
                case "dom":
                    capabilities.insert(.dom)
                case "runtime":
                    capabilities.insert(.runtime)
                case "target":
                    capabilities.insert(.target)
                case "inspector":
                    capabilities.insert(.inspector)
                case "network":
                    capabilities.insert(.network)
                case "css":
                    capabilities.insert(.css)
                case "console":
                    capabilities.insert(.console)
                default:
                    break
                }
            }
            self = capabilities
        }
    }
}

package extension ProtocolTarget {
    struct Record: Equatable, Sendable {
        package var id: ID
        package var kind: Kind
        package var frameID: ProtocolFrame.ID?
        package var parentFrameID: ProtocolFrame.ID?
        package var capabilities: Capabilities
        package var isProvisional: Bool
        package var isPaused: Bool

        package init(
            id: ID,
            kind: Kind,
            frameID: ProtocolFrame.ID? = nil,
            parentFrameID: ProtocolFrame.ID? = nil,
            capabilities: Capabilities? = nil,
            isProvisional: Bool = false,
            isPaused: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.frameID = frameID
            self.parentFrameID = parentFrameID
            self.capabilities = capabilities ?? Capabilities.protocolDefault(for: kind)
            self.isProvisional = isProvisional
            self.isPaused = isPaused
        }
    }
}
