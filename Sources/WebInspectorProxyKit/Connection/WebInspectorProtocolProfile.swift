import Foundation
import WebKit

package struct WebInspectorProtocolProfile: Sendable {
    package enum Generation: Equatable, Sendable {
        case released18
        case released26
        case latest
    }

    package let generation: Generation
    private let targetKindsByDomain: [
        WebInspectorProtocolDomainToken: Set<ProtocolTarget.Kind>
    ]

    private init(
        generation: Generation,
        targetKindsByDomain: [
            WebInspectorProtocolDomainToken: Set<ProtocolTarget.Kind>
        ]
    ) {
        self.generation = generation
        self.targetKindsByDomain = targetKindsByDomain
    }

    package func supports(
        _ domain: WebInspectorProtocolDomainToken,
        on targetKind: ProtocolTarget.Kind
    ) -> Bool {
        targetKindsByDomain[domain]?.contains(targetKind) == true
    }

    package func semanticFrameID(
        for targetID: ProtocolTarget.ID,
        targetKind: ProtocolTarget.Kind
    ) throws -> FrameID? {
        guard targetKind == .frame, generation == .latest else {
            return nil
        }

        // WebKit 625 encodes FrameInspectorTarget IDs as
        // `frame-{frameID}-{processID}`, while protocol frame IDs use
        // `frame-{processID}.{frameID}`. Do not generalize this opaque ID
        // format to another WebKit source major; unknown majors are rejected
        // when the profile is selected.
        let prefix = "frame-"
        guard targetID.rawValue.hasPrefix(prefix) else {
            throw malformedFrameTargetID(targetID)
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
            throw malformedFrameTargetID(targetID)
        }
        return FrameID("frame-\(processValue).\(frameValue)")
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

        // WebKit prefixes FULL_VERSION by platform (for example, 8 on iOS
        // and 21 on macOS). The trailing source major selects the protocol.
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
        targetKindsByDomain: domainTable(inspectorSupportsServiceWorkers: false)
    )

    package static let released26 = Self(
        generation: .released26,
        targetKindsByDomain: domainTable(inspectorSupportsServiceWorkers: true)
    )

    package static let latest = Self(
        generation: .latest,
        targetKindsByDomain: domainTable(
            inspectorSupportsServiceWorkers: true,
            frameDomains: ["CSS", "DOM", "Console", "Runtime"]
        )
    )

    private static func domainTable(
        inspectorSupportsServiceWorkers: Bool,
        frameDomains: Set<String> = []
    ) -> [WebInspectorProtocolDomainToken: Set<ProtocolTarget.Kind>] {
        var table: [String: Set<ProtocolTarget.Kind>] = [
            "CSS": [.page],
            "DOM": [.page],
            "Console": [.page, .serviceWorker, .worker],
            "Runtime": [.page, .serviceWorker, .worker],
            "Network": [.page, .serviceWorker],
            "Page": [.page],
            "Inspector": inspectorSupportsServiceWorkers
                ? [.page, .serviceWorker]
                : [.page],
        ]
        for domain in frameDomains {
            table[domain, default: []].insert(.frame)
        }
        return Dictionary(uniqueKeysWithValues: table.map { domain, kinds in
            (WebInspectorProtocolDomainToken(rawValue: domain), kinds)
        })
    }

    private static func unsupportedBundleVersion(
        _ bundleVersion: String
    ) -> WebInspectorProxyError {
        .unsupported([
            "WebKit protocol profile for CFBundleVersion \(bundleVersion)"
        ])
    }

    private func malformedFrameTargetID(
        _ targetID: ProtocolTarget.ID
    ) -> WebInspectorProxyError {
        .protocolViolation(
            "WebKit 625 frame target ID has an unknown encoding: \(targetID.rawValue)"
        )
    }
}
