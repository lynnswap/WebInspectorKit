import Foundation
import WebKit

package struct WebInspectorProtocolProfile: Equatable, Sendable {
    package enum Generation: Equatable, Sendable {
        case released18
        case released26
        case latest
    }

    package enum Error: Swift.Error, Equatable, Sendable {
        case malformedFrameTargetID(String)
    }

    package let generation: Generation
    private let targetKindsByDomain: [
        ProtocolDomain: [ProtocolTarget.Kind]
    ]

    private init(
        generation: Generation,
        targetKindsByDomain: [
            ProtocolDomain: [ProtocolTarget.Kind]
        ]
    ) {
        self.generation = generation
        self.targetKindsByDomain = targetKindsByDomain
    }

    package func supports(
        _ domain: ProtocolDomain,
        on targetKind: ProtocolTarget.Kind
    ) -> Bool {
        targetKindsByDomain[domain]?.contains(targetKind) == true
    }

    package func capabilities(
        for targetKind: ProtocolTarget.Kind
    ) -> ProtocolTarget.Capabilities {
        var capabilities: ProtocolTarget.Capabilities = []
        for (domain, capability) in [
            (ProtocolDomain.css, ProtocolTarget.Capabilities.css),
            (.dom, .dom),
            (.console, .console),
            (.runtime, .runtime),
            (.network, .network),
            (.inspector, .inspector),
        ] where supports(domain, on: targetKind) {
            capabilities.insert(capability)
        }
        if targetKind == .page {
            capabilities.insert(.target)
        }
        return capabilities
    }

    package var pageTopologyMayArriveAtRoot: Bool {
        // WebKit 625's UIProcess ProxyingPageAgent emits Page topology events
        // on the multiplexing root under Site Isolation. Earlier generations,
        // and WebKit 625 without Site Isolation, emit them from a page target.
        generation == .latest
    }

    package func usesRootAgent(
        _ domain: ProtocolDomain,
        for targetKind: ProtocolTarget.Kind
    ) -> Bool {
        // Under Site Isolation, a frame target signals that WebKit 625 has
        // installed the UIProcess ProxyingNetworkAgent on the multiplexing
        // root. Frame-origin request identity remains semantic frame state,
        // but Network commands are physically handled by that root agent.
        generation == .latest && domain == .network && targetKind == .frame
    }

    package func usesRootNetworkAgent(
        forFrameTargetID targetID: ProtocolTarget.ID
    ) -> Bool {
        guard generation == .latest else {
            return false
        }
        return (try? semanticFrameID(
            for: targetID,
            targetKind: .frame
        )) != nil
    }

    package func semanticFrameID(
        for targetID: ProtocolTarget.ID,
        targetKind: ProtocolTarget.Kind
    ) throws -> ProtocolFrame.ID? {
        guard targetKind == .frame, generation == .latest else {
            return nil
        }

        // WebKit 625's FrameInspectorTarget encodes `frameID-processID`,
        // while protocol frame IDs encode `processID.frameID`. This format is
        // generation-specific; unknown generations are rejected before a
        // transport session is created.
        let prefix = "frame-"
        guard targetID.rawValue.hasPrefix(prefix) else {
            throw Error.malformedFrameTargetID(targetID.rawValue)
        }
        let components = targetID.rawValue
            .dropFirst(prefix.count)
            .split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count == 2,
              let frameValue = UInt64(components[0]),
              String(frameValue) == components[0],
              let processValue = UInt64(components[1]),
              String(processValue) == components[1]
        else {
            throw Error.malformedFrameTargetID(targetID.rawValue)
        }
        return ProtocolFrame.ID("frame-\(processValue).\(frameValue)")
    }

    package static func currentWebKit() throws -> Self {
        let webKitBundle = Bundle(for: WKWebView.self)
        guard let bundleVersion = webKitBundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String else {
            throw unsupportedBundleVersion("<missing>")
        }
        return try profile(forWebKitBundleVersion: bundleVersion)
    }

    package static func profile(
        forWebKitBundleVersion bundleVersion: String
    ) throws -> Self {
        guard let platformMajor = bundleVersion
            .split(separator: ".", maxSplits: 1)
            .first
            .flatMap({ Int($0) })
        else {
            throw unsupportedBundleVersion(bundleVersion)
        }

        // WebKit prefixes FULL_VERSION by platform (8 on iOS and 21 on
        // macOS). The trailing source major selects the protocol generation.
        switch platformMajor % 1_000 {
        case 619...621:
            return .released18
        case 622...624:
            return .released26
        case 625:
            return .latest
        default:
            throw unsupportedBundleVersion(bundleVersion)
        }
    }

    package static let released18 = Self(
        generation: .released18,
        targetKindsByDomain: domainTable(
            inspectorSupportsServiceWorkers: false
        )
    )

    package static let released26 = Self(
        generation: .released26,
        targetKindsByDomain: domainTable(
            inspectorSupportsServiceWorkers: true
        )
    )

    package static let latest = Self(
        generation: .latest,
        targetKindsByDomain: domainTable(
            inspectorSupportsServiceWorkers: true,
            frameDomains: [.css, .dom, .console, .runtime]
        )
    )

    private static func domainTable(
        inspectorSupportsServiceWorkers: Bool,
        frameDomains: Set<ProtocolDomain> = []
    ) -> [ProtocolDomain: [ProtocolTarget.Kind]] {
        var table: [ProtocolDomain: [ProtocolTarget.Kind]] = [
            .css: [.page],
            .dom: [.page],
            .console: [.page, .serviceWorker, .worker],
            .runtime: [.page, .serviceWorker, .worker],
            .network: [.page, .serviceWorker],
            .page: [.page],
            .inspector: inspectorSupportsServiceWorkers
                ? [.page, .serviceWorker]
                : [.page],
        ]
        for domain in frameDomains {
            table[domain, default: []].append(.frame)
        }
        return table
    }

    private static func unsupportedBundleVersion(
        _ bundleVersion: String
    ) -> WebInspectorProxyError {
        .unsupported([
            "WebKit protocol profile for CFBundleVersion \(bundleVersion)",
        ])
    }
}
