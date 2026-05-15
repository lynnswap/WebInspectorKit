#if DEBUG
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    static func debugAttachSymbolNamePassesPrefilter(_ name: String) -> Bool {
        name.contains("connectFrontend")
            || name.contains("disconnectFrontend")
            || name.contains("InspectorController")
            || name.contains("FrontendChannel")
    }

    static func debugAttachSymbolCandidate(
        name: String,
        address: UInt64,
        source: String,
        imageName: String
    ) -> NativeInspectorAttachSymbolCandidate? {
        let role = debugAttachSymbolRole(for: name)
        let ownerKey = debugAttachSymbolOwnerKey(for: name)
        let score = debugAttachSymbolScore(name: name, role: role)
        guard score >= 150 else {
            return nil
        }

        return NativeInspectorAttachSymbolCandidate(
            role: role,
            source: source,
            imageName: imageName,
            ownerKey: ownerKey,
            name: name,
            address: address,
            score: score
        )
    }

    static func debugAttachSymbolRole(for name: String) -> NativeInspectorAttachSymbolRole {
        if name.contains("disconnectFrontend") {
            return .disconnect
        }
        if name.contains("connectFrontend") {
            return .connect
        }
        return .unknown
    }

    static func debugAttachSymbolOwnerKey(for name: String) -> String {
        if name.contains("WebPageInspectorController") {
            return "WebKit::WebPageInspectorController"
        }
        if name.contains("FrameInspectorController") {
            return "WebCore::FrameInspectorController"
        }
        if name.contains("PageInspectorController") {
            return "WebCore::PageInspectorController"
        }
        if name.contains("WorkerInspectorController") {
            return "WebCore::WorkerInspectorController"
        }
        if name.contains("ServiceWorkerInspector") {
            return "WebCore::ServiceWorkerInspector"
        }
        if name.contains("InspectorController") {
            return "InspectorController"
        }
        return "unknown"
    }

    static func debugAttachSymbolScore(
        name: String,
        role: NativeInspectorAttachSymbolRole
    ) -> Int {
        var score = 0
        if role != .unknown {
            score += 100
        }
        if name.contains("FrontendChannel") {
            score += 80
        }
        if name.contains("WebPageInspectorController") {
            score += 70
        } else if name.contains("PageInspectorController") || name.contains("FrameInspectorController") {
            score += 55
        }
        if name.contains("WebKit") || name.contains("WebCore") {
            score += 35
        }
        if name.contains("InspectorController") {
            score += 25
        }
        score += 20

        if name.contains("WorkerInspectorController") || name.contains("ServiceWorker") {
            score -= 60
        }
        if role != .unknown && !name.contains("FrontendChannel") {
            score -= 80
        }
        return score
    }

    static func debugAppendTopAttachSymbolCandidate(
        _ candidate: NativeInspectorAttachSymbolCandidate,
        to candidates: inout [NativeInspectorAttachSymbolCandidate]
    ) {
        candidates.append(candidate)
        candidates.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.name < $1.name
        }
        if candidates.count > 80 {
            candidates.removeLast(candidates.count - 80)
        }
    }

    static func debugLogSimilarAttachSymbolPairs(
        _ candidates: [NativeInspectorAttachSymbolCandidate]
    ) {
        let groupedCandidates = Dictionary(grouping: candidates) {
            "\($0.source)|\($0.imageName)|\($0.ownerKey)"
        }
        let pairs = groupedCandidates.compactMap { _, candidates -> (score: Int, connect: NativeInspectorAttachSymbolCandidate, disconnect: NativeInspectorAttachSymbolCandidate)? in
            guard let connect = candidates.filter({ $0.role == .connect }).max(by: { $0.score < $1.score }),
                  let disconnect = candidates.filter({ $0.role == .disconnect }).max(by: { $0.score < $1.score }) else {
                return nil
            }
            return (connect.score + disconnect.score + 50, connect, disconnect)
        }
        .sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.connect.ownerKey < $1.connect.ownerKey
        }
        .prefix(3)

        for pair in pairs {
            NativeInspectorSymbolLog.info(
                String(
                    format: "[WebInspectorNativeSymbols] similar attach pair score=%d source=%@ image=%@ owner=%@ connectAddress=0x%llx disconnectAddress=0x%llx connect=%@ disconnect=%@",
                    pair.score,
                    pair.connect.source,
                    pair.connect.imageName,
                    pair.connect.ownerKey,
                    pair.connect.address,
                    pair.disconnect.address,
                    debugTruncatedAttachSymbolName(pair.connect.name),
                    debugTruncatedAttachSymbolName(pair.disconnect.name)
                )
            )
        }
    }

    static func debugLogSimilarAttachSymbolSingles(
        _ candidates: [NativeInspectorAttachSymbolCandidate]
    ) {
        let sortedCandidates = candidates.sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.name < $1.name
        }
        for role in [NativeInspectorAttachSymbolRole.connect, .disconnect, .unknown] {
            var emittedCount = 0
            for candidate in sortedCandidates where candidate.role == role {
                guard emittedCount < 5 else {
                    break
                }
                emittedCount += 1
                NativeInspectorSymbolLog.info(
                    String(
                        format: "[WebInspectorNativeSymbols] similar attach candidate score=%d role=%@ source=%@ image=%@ owner=%@ address=0x%llx name=%@",
                        candidate.score,
                        candidate.role.rawValue,
                        candidate.source,
                        candidate.imageName,
                        candidate.ownerKey,
                        candidate.address,
                        debugTruncatedAttachSymbolName(candidate.name)
                    )
                )
            }
        }
    }

    static func debugTruncatedAttachSymbolName(_ name: String) -> String {
        let maximumLength = 240
        guard name.count > maximumLength else {
            return name
        }
        let endIndex = name.index(name.startIndex, offsetBy: maximumLength)
        return String(name[..<endIndex]) + "...[truncated]"
    }
}
#endif
